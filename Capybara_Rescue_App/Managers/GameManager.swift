import Foundation
import SwiftUI
import Combine
@preconcurrency import UserNotifications
import StoreKit

/// File scope so UNUserNotificationCenter Sendable callbacks can compare identifiers without MainActor isolation.
private let hatPromoNotificationIdentifier = "bunny_hat_promo_weekly"

/// Wall-clock seconds before each of food, drink, and happiness drops by 1 (file scope for Sendable notification closures).
private let statDecayIntervalSeconds: TimeInterval = 600

// MARK: - Game Manager
@MainActor
class GameManager: ObservableObject {
    @Published var gameState: GameState {
        didSet {
            if isRestoring || isSaving { return }
            saveGameState()
            // Note: Notifications are now handled by scheduleFutureNotifications()
            // which schedules them in advance based on stat decay rates
        }
    }
    
    @Published var thrownItem: ThrownItem?
    @Published var showRunAwayAlert: Bool = false
    /// When set to "food", "drink", or "happiness", triggers confetti + sound (stat reached 100). Cleared by UI after animation.
    @Published var stat100ConfettiTrigger: String? = nil
    @Published var previewingAccessoryId: String? = nil // For previewing items before purchase
    /// Golden banner on Items when nudging toward Bunny Ears (launch / resume promo).
    @Published var showBunnyEarsItemsPromoBanner: Bool = false
    @Published var toastMessage: String? = nil // For showing toast messages to user
    /// When set, UI shows celebration popup + confetti: "Well done on [name], here's [X] coins."
    @Published var recentAchievement: (name: String, coins: Int)? = nil
    
    private var decayTimer: Timer?
    private let storageKey = "capybara_rescue_game_state"
    /// Reliable on-device copy so progress survives iCloud KVS unavailability, simulator, and first-sync delays.
    private let userDefaultsStateKey = "capybara_rescue_game_state_local"
    private var isSaving = false
    private var isRestoring = false
    private let cloudStore = NSUbiquitousKeyValueStore.default

    /// Local backup for onboarding/tutorial completion so progress survives iCloud hiccups or stale sync.
    private enum ProgressDefaultsKey {
        static let hasCompletedOnboarding = "has_completed_onboarding"
        static let hasCompletedTutorial = "has_completed_tutorial"
    }

    private static func decodeGameState(_ data: Data) -> GameState? {
        try? JSONDecoder().decode(GameState.self, from: data)
    }

    /// Picks the newest saved state by `lastUpdateTime`; prefers local when equal (avoids flaky iCloud wiping progress).
    private static func loadMergedState(
        userDefaultsKey: String,
        iCloudKey: String,
        cloudStore: NSUbiquitousKeyValueStore
    ) -> GameState {
        let local = UserDefaults.standard.data(forKey: userDefaultsKey).flatMap { decodeGameState($0) }
        let cloud = cloudStore.data(forKey: iCloudKey).flatMap { decodeGameState($0) }
        switch (local, cloud) {
        case let (l?, c?):
            return l.lastUpdateTime >= c.lastUpdateTime ? l : c
        case let (l?, nil):
            return l
        case let (nil, c?):
            return c
        default:
            return GameState.defaultState
        }
    }

    // MARK: - StoreKit (IAP)
    @Published private(set) var iapProducts: [String: Product] = [:]
    @Published private(set) var isIAPLoading: Bool = false
    @Published var iapLastErrorMessage: String? = nil
    
    struct ThrownItem: Identifiable {
        let id = UUID()
        let emoji: String
        let isFood: Bool
    }
    
    /// Coins granted once on the post-pledge “thanks for adopting” screen, before the subscription paywall.
    static let onboardingAdoptionGiftCoins = 100
    
    /// Awards `onboardingAdoptionGiftCoins` the first time the user reaches the adoption gift screen.
    /// Skips the credit if they already have at least that much (legacy installs that started with 100 coins).
    func grantOnboardingAdoptionCoinsIfNeeded() {
        guard !gameState.hasGrantedOnboardingAdoptionCoins else { return }
        gameState.hasGrantedOnboardingAdoptionCoins = true
        if gameState.capycoins < Self.onboardingAdoptionGiftCoins {
            gameState.capycoins += Self.onboardingAdoptionGiftCoins
        }
    }
    
    init() {
        isRestoring = true
        self.gameState = Self.loadMergedState(
            userDefaultsKey: userDefaultsStateKey,
            iCloudKey: storageKey,
            cloudStore: cloudStore
        )
        isRestoring = false
        saveGameState()
        print("✅ Game state ready (UserDefaults + iCloud, newest by last update time)")

        // Set up iCloud sync notification observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudStoreChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore
        )
        
        // Migrate old UserDefaults values if needed (for backward compatibility)
        migrateFromUserDefaults()
        
        applyRetroactiveEarnedAchievementCoinsRecoveryIfNeeded()
        
        // Apply time-based decay from last session
        applyOfflineDecay()
        
        // Check and update login streak
        checkDailyLogin()
        
        // Check notification permissions (will request if not determined)
        checkNotificationPermissions()
        
        // Clear badge when app opens (user has seen the app)
        clearBadge()
        
        // Schedule future notifications for when app is closed
        scheduleFutureNotifications()
        
        // Start decay timer
        startDecayTimer()

        // Load StoreKit products
        Task {
            await loadIAPProducts()
            // Unlock Pro items if user has Pro subscription
            unlockProItemsIfNeeded()
        }
        
        // Listen for transaction updates (e.g. Ask to Buy, delayed completion) so successful purchases are never missed
        Task {
            await listenForTransactionUpdates()
        }
    }
    
    /// Listens for transaction updates at launch. Handles coin pack purchases that may complete asynchronously (e.g. Ask to Buy).
    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            do {
                let transaction = try checkVerified(result)
                let productId = transaction.productID
                
                // Coin pack purchase
                if let pack = CoinPack.packs.first(where: { $0.productId == productId }) {
                    let grant = pack.grantCoins
                    gameState.capycoins += grant
                    showToast("\(grant) coins added! 🎉")
                }
                // Subscription purchases are handled by SubscriptionManager's listener
                
                await transaction.finish()
                print("✅ Processed transaction update for \(productId)")
            } catch {
                print("❌ Failed to process transaction update: \(error)")
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - iCloud Sync
    @objc private func handleCloudStoreChange(_ notification: Notification) {
        // Handle external changes from iCloud sync
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }
        
        // Only reload if the change came from another device
        if reason == NSUbiquitousKeyValueStoreServerChange ||
           reason == NSUbiquitousKeyValueStoreInitialSyncChange {
            print("☁️ iCloud sync detected - reloading game state")
            loadGameState()
        }
    }
    
    private func loadGameState() {
        guard let data = cloudStore.data(forKey: storageKey),
              let remote = Self.decodeGameState(data) else {
            return
        }
        if remote.lastUpdateTime > gameState.lastUpdateTime {
            gameState = remote
            print("☁️ Applied newer game state from iCloud")
        }
        applyProgressFlagsFromUserDefaults()
        applyRetroactiveEarnedAchievementCoinsRecoveryIfNeeded()
    }

    private func clearProgressDefaultsBackup() {
        UserDefaults.standard.removeObject(forKey: ProgressDefaultsKey.hasCompletedOnboarding)
        UserDefaults.standard.removeObject(forKey: ProgressDefaultsKey.hasCompletedTutorial)
    }

    /// Merges locally stored completion flags into `gameState` (never downgrades). Call after every KVS load so a stale iCloud payload cannot wipe onboarding/tutorial progress.
    private func applyProgressFlagsFromUserDefaults() {
        var s = gameState
        var changed = false
        if UserDefaults.standard.bool(forKey: ProgressDefaultsKey.hasCompletedOnboarding), !s.hasCompletedOnboarding {
            s.hasCompletedOnboarding = true
            changed = true
            print("🔄 Restored onboarding completion from UserDefaults backup")
        }
        if UserDefaults.standard.bool(forKey: ProgressDefaultsKey.hasCompletedTutorial), !s.hasCompletedTutorial {
            s.hasCompletedTutorial = true
            changed = true
            print("🔄 Restored tutorial completion from UserDefaults backup")
        }
        if changed {
            gameState = s
        }
    }
    
    private func migrateFromUserDefaults() {
        applyProgressFlagsFromUserDefaults()
    }
    
    /// One-time recovery for saves where achievement badges persisted but coin rewards did not (e.g. balance stuck near onboarding adoption coins).
    /// Credits the sum of `achievementCoins` for every ID still in `earnedAchievements`, then marks completion so we don't repeat.
    private func applyRetroactiveEarnedAchievementCoinsRecoveryIfNeeded() {
        guard !gameState.hasAppliedEarnedAchievementRetroactiveCoinsRecovery else { return }
        
        let rewardSum = gameState.earnedAchievements.reduce(0) { partial, id in
            partial + (Self.achievementCoins[id] ?? 0)
        }
        
        let adoptionCeiling = Self.onboardingAdoptionGiftCoins
        if rewardSum > 0, gameState.capycoins <= adoptionCeiling {
            gameState.capycoins += rewardSum
            print("💰 Retroactively credited \(rewardSum) capycoins for earned achievements (balance recovery)")
        }
        
        gameState.hasAppliedEarnedAchievementRetroactiveCoinsRecovery = true
        saveGameState()
    }
    
    // MARK: - Achievement System
    func checkDailyLogin() {
        let calendar = Calendar.current
        let now = Date()
        
        // Check if we have a last login date
        if let lastLogin = gameState.lastLoginDate {
            // Check if it's a new day
            if calendar.isDateInToday(lastLogin) {
                // Already logged in today, do nothing
                return
            }
            
            // Check if last login was yesterday
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(lastLogin, inSameDayAs: yesterday) {
                // Logged in yesterday, continue streak
                gameState.loginStreak += 1
            } else {
                // Streak broken (more than 1 day gap), reset to 1
                gameState.loginStreak = 1
            }
        } else {
            // First login ever
            gameState.loginStreak = 1
        }
        
        // Update last login date
        gameState.lastLoginDate = now
        
        // Check stats streak (all stats > 50)
        checkStatsStreak()
        
        // Check for achievements
        checkAchievements()
    }
    
    private func checkStatsStreak() {
        let calendar = Calendar.current
        let now = Date()
        
        // Check if all stats are above 50
        let allStatsAbove50 = gameState.food > 50 && gameState.drink > 50 && gameState.happiness > 50
        
        if allStatsAbove50 {
            // Check if we've already checked today
            if let lastCheck = gameState.lastStatsCheckDate {
                if calendar.isDateInToday(lastCheck) {
                    // Already checked today, do nothing
                    return
                }
                
                // Check if last check was yesterday
                if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                   calendar.isDate(lastCheck, inSameDayAs: yesterday) {
                    // Checked yesterday and all stats were > 50, continue streak
                    gameState.statsStreak += 1
                } else {
                    // Gap in checking, reset streak to 1 (today is day 1)
                    gameState.statsStreak = 1
                }
            } else {
                // First time checking - don't set streak to 1 yet
                // The streak will become 1 on the next day if stats are still above 50
                // This prevents awarding the 1-day achievement immediately on first launch
                gameState.statsStreak = 0
            }
            
            // Update last check date
            gameState.lastStatsCheckDate = now
        } else {
            // Stats not all above 50, reset streak
            gameState.statsStreak = 0
            gameState.lastStatsCheckDate = now
        }
    }
    
    private static let achievementDisplayNameKeys: [String: String] = [
        "streak_3": "achievements.streak_3.name",
        "streak_7": "achievements.streak_7.name",
        "streak_30": "achievements.streak_30.name",
        "streak_100": "achievements.streak_100.name",
        "streak_365": "achievements.streak_365.name",
        "first_100_food": "achievements.first_100_food.name",
        "first_100_drink": "achievements.first_100_drink.name",
        "first_100_happy": "achievements.first_100_happy.name",
        "first_all_100": "achievements.first_all_100.name"
    ]
    
    private static let achievementCoins: [String: Int] = [
        "streak_3": 1500, "streak_7": 2500, "streak_30": 5000, "streak_100": 10000, "streak_365": 25000,
        "first_100_food": 500, "first_100_drink": 500, "first_100_happy": 500, "first_all_100": 1500
    ]

    private func localizedAchievementName(for id: String) -> String {
        guard let key = Self.achievementDisplayNameKeys[id] else { return id }
        return L(key)
    }
    
    private func grantAchievement(id: String, name: String? = nil, coins: Int? = nil) {
        let displayName = name ?? localizedAchievementName(for: id)
        let coinAmount = coins ?? Self.achievementCoins[id] ?? 0
        gameState.capycoins += coinAmount
        recentAchievement = (displayName, coinAmount)
    }
    
    private func checkAchievements() {
        let streak = gameState.statsStreak
        
        let achievementRewards: [Int: (String, Int)] = [
            3: ("streak_3", 1500),
            7: ("streak_7", 2500),
            30: ("streak_30", 5000),
            100: ("streak_100", 10000),
            365: ("streak_365", 25000)
        ]
        
        var totalCoins = 0
        var names: [String] = []
        
        for (days, (achievementId, coins)) in achievementRewards.sorted(by: { $0.key < $1.key }) {
            if streak >= days && !gameState.earnedAchievements.contains(achievementId) {
                gameState.earnedAchievements.insert(achievementId)
                gameState.capycoins += coins
                totalCoins += coins
                names.append(localizedAchievementName(for: achievementId))
            }
        }
        
        if totalCoins > 0 {
            let name = names.isEmpty ? L("achievements.title") : names.joined(separator: " & ")
            recentAchievement = (name, totalCoins)
        }
    }
    
    /// Call when the achievement reward popup has been dismissed.
    func clearRecentAchievementReward() {
        recentAchievement = nil
    }
    
    // MARK: - Persistence
    private func saveGameState() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // IMPORTANT:
        // `lastUpdateTime` is used as the anchor for stat decay timing.
        // Do NOT update it on every save, otherwise time-based decay
        // never properly accumulates (especially when backgrounded).

        if let data = try? JSONEncoder().encode(gameState) {
            UserDefaults.standard.set(data, forKey: userDefaultsStateKey)
            cloudStore.set(data, forKey: storageKey)
            cloudStore.synchronize()
            print("💾 Saved game state (UserDefaults + iCloud)")
        }
        if gameState.hasCompletedOnboarding {
            UserDefaults.standard.set(true, forKey: ProgressDefaultsKey.hasCompletedOnboarding)
        }
        if gameState.hasCompletedTutorial {
            UserDefaults.standard.set(true, forKey: ProgressDefaultsKey.hasCompletedTutorial)
        }
    }
    
    // MARK: - Decay System
    private func applyOfflineDecay(now: Date = Date()) {
        // Apply decay for each full `statDecayIntervalSeconds` elapsed since `lastUpdateTime`,
        // and advance the anchor in whole steps (preserves remainder in the current interval).
        let elapsed = now.timeIntervalSince(gameState.lastUpdateTime)
        
        // If device clock changed and we end up in the "future", just reset the anchor.
        guard elapsed >= 0 else {
            gameState.lastUpdateTime = now
            return
        }
        
        let step = statDecayIntervalSeconds
        let stepCount = Int(elapsed / step)
        guard stepCount > 0 else { return }
        
        let decayAmount = stepCount
        gameState.food = max(0, gameState.food - decayAmount)
        gameState.drink = max(0, gameState.drink - decayAmount)
        gameState.happiness = max(0, gameState.happiness - decayAmount)
        
        gameState.lastUpdateTime = gameState.lastUpdateTime.addingTimeInterval(TimeInterval(stepCount) * step)
        
        checkRunAway()
        
        // Reschedule future notifications based on new stat values
        scheduleFutureNotifications()
    }
    
    private func startDecayTimer() {
        // Poll so wall-clock decay applies on schedule while the app stays open (interval can be < stat decay length).
        decayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.applyOfflineDecay(now: Date())
            }
        }
    }

    // Call this when the app becomes active to account for time spent backgrounded.
    func handleAppBecameActive() {
        applyOfflineDecay(now: Date())
    }
    
    /// Returns false so the "remove ads" / subscription promo popup is never shown.
    /// Call this from UI instead of showing any periodic remove-ads prompt.
    func shouldShowAdRemovalPromo() -> Bool {
        return false
    }
    
    // MARK: - Catch the Orange (daily mini-game)
    /// Coins awarded when user catches 20 oranges in one run (once per day).
    static let catchTheOrangeCoinsReward = 100
    
    /// True if the user has not yet completed Catch the Orange today (calendar day).
    func canPlayCatchTheOrangeToday() -> Bool {
        guard let last = gameState.lastCatchTheOrangeCompletedDate else { return true }
        return !Calendar.current.isDateInToday(last)
    }
    
    /// Call when user catches 20 oranges. Awards coins and marks day as completed.
    func completeCatchTheOrangeGame() {
        gameState.capycoins += Self.catchTheOrangeCoinsReward
        gameState.lastCatchTheOrangeCompletedDate = Date()
        showToast("\(Self.catchTheOrangeCoinsReward) coins earned! 🍊")
    }
    
    // MARK: - Header Volley (daily mini-game)
    /// Coins awarded when user reaches the header goal in one run (once per day).
    static let headerVolleyCoinsReward = 100
    
    /// True if the user has not yet completed Header Volley today (calendar day).
    func canPlayHeaderVolleyToday() -> Bool {
        guard let last = gameState.lastHeaderVolleyCompletedDate else { return true }
        return !Calendar.current.isDateInToday(last)
    }
    
    /// Call when user wins Header Volley. Awards coins and marks day as completed.
    func completeHeaderVolleyGame() {
        gameState.capycoins += Self.headerVolleyCoinsReward
        gameState.lastHeaderVolleyCompletedDate = Date()
        showToast("\(Self.headerVolleyCoinsReward) coins earned! ⚽")
    }
    
    private func checkRunAway() {
        if gameState.food == 0 && gameState.drink == 0 && gameState.happiness == 0 {
            gameState.hasRunAway = true
            showRunAwayAlert = true
        }
    }
    
    // MARK: - Walkthrough
    enum WalkthroughPlayStat {
        case food, drink, happiness
    }
    
    /// If a walkthrough step waits for food/drink/pet to increase but that stat is already 100 (e.g. user filled it early),
    /// clamp it to 99 so the next action can still land at 100 with full effects. No-op after tutorial is finished.
    func prepareWalkthroughPlayStep(stat: WalkthroughPlayStat) {
        guard !gameState.hasCompletedTutorial else { return }
        switch stat {
        case .food:
            if gameState.food >= 100 { gameState.food = 99 }
        case .drink:
            if gameState.drink >= 100 { gameState.drink = 99 }
        case .happiness:
            if gameState.happiness >= 100 { gameState.happiness = 99 }
        }
    }
    
    // MARK: - Actions
    func feedCapybara(with item: FoodItem) -> Bool {
        // Check if food is already at max
        guard gameState.food < 100 else {
            showToast("CAPYBARA IS FULL 😊")
            return false
        }
        
        guard canAfford(item.cost) else { return false }
        
        gameState.capycoins -= item.cost
        
        let previousFood = gameState.food
        gameState.food = min(100, gameState.food + item.foodValue)
        
        var awardNames: [String] = []
        var awardCoins = 0
        
        if gameState.food == 100 && previousFood < 100 {
            stat100ConfettiTrigger = "food"
            SoundManager.shared.playStat100Celebration()
            if !gameState.earnedAchievements.contains("first_100_food") {
                gameState.earnedAchievements.insert("first_100_food")
                let c = Self.achievementCoins["first_100_food"] ?? 200
                gameState.capycoins += c
                awardCoins += c
                awardNames.append(localizedAchievementName(for: "first_100_food"))
            }
            if gameState.drink == 100 && gameState.happiness == 100 && !gameState.earnedAchievements.contains("first_all_100") {
                gameState.earnedAchievements.insert("first_all_100")
                let c = Self.achievementCoins["first_all_100"] ?? 500
                gameState.capycoins += c
                awardCoins += c
                awardNames.append(localizedAchievementName(for: "first_all_100"))
            }
        }
        
        if !awardNames.isEmpty {
            recentAchievement = (awardNames.joined(separator: " & "), awardCoins)
        }
        
        scheduleFutureNotifications()
        return true
    }
    
    func giveWater(with item: DrinkItem) -> Bool {
        guard gameState.drink < 100 else {
            showToast("CAPYBARA HAS HAD ENOUGH TO DRINK 😊")
            return false
        }
        guard canAfford(item.cost) else { return false }
        
        gameState.capycoins -= item.cost
        let previousDrink = gameState.drink
        gameState.drink = min(100, gameState.drink + item.drinkValue)
        
        var awardNames: [String] = []
        var awardCoins = 0
        
        if gameState.drink == 100 && previousDrink < 100 {
            stat100ConfettiTrigger = "drink"
            SoundManager.shared.playStat100Celebration()
            if !gameState.earnedAchievements.contains("first_100_drink") {
                gameState.earnedAchievements.insert("first_100_drink")
                let c = Self.achievementCoins["first_100_drink"] ?? 200
                gameState.capycoins += c
                awardCoins += c
                awardNames.append(localizedAchievementName(for: "first_100_drink"))
            }
            if gameState.food == 100 && gameState.happiness == 100 && !gameState.earnedAchievements.contains("first_all_100") {
                gameState.earnedAchievements.insert("first_all_100")
                let c = Self.achievementCoins["first_all_100"] ?? 500
                gameState.capycoins += c
                awardCoins += c
                awardNames.append(localizedAchievementName(for: "first_all_100"))
            }
        }
        if !awardNames.isEmpty {
            recentAchievement = (awardNames.joined(separator: " & "), awardCoins)
        }
        
        scheduleFutureNotifications()
        return true
    }
    
    func petCapybara() {
        let previousHappiness = gameState.happiness
        gameState.happiness = min(100, gameState.happiness + 1)
        
        var awardNames: [String] = []
        var awardCoins = 0
        
        if gameState.happiness == 100 && previousHappiness < 100 {
            stat100ConfettiTrigger = "happiness"
            SoundManager.shared.playStat100Celebration()
            if !gameState.earnedAchievements.contains("first_100_happy") {
                gameState.earnedAchievements.insert("first_100_happy")
                let c = Self.achievementCoins["first_100_happy"] ?? 200
                gameState.capycoins += c
                awardCoins += c
                awardNames.append(localizedAchievementName(for: "first_100_happy"))
            }
            if gameState.food == 100 && gameState.drink == 100 && !gameState.earnedAchievements.contains("first_all_100") {
                gameState.earnedAchievements.insert("first_all_100")
                let c = Self.achievementCoins["first_all_100"] ?? 500
                gameState.capycoins += c
                awardCoins += c
                awardNames.append(localizedAchievementName(for: "first_all_100"))
            }
        }
        
        if !awardNames.isEmpty {
            recentAchievement = (awardNames.joined(separator: " & "), awardCoins)
        }
        
        scheduleFutureNotifications()
    }
    
    func purchaseAccessory(_ item: AccessoryItem) -> Bool {
        guard canAfford(item.cost) else { return false }
        guard !gameState.ownedAccessories.contains(item.id) else { return false }
        
        gameState.capycoins -= item.cost
        
        gameState.ownedAccessories.append(item.id)
        
        // Once Bunny ears are owned, stop all Bunny promo surfaces.
        if item.id == "bunnyears" {
            showBunnyEarsItemsPromoBanner = false
            if previewingAccessoryId == "bunnyears" {
                previewingAccessoryId = nil
            }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [hatPromoNotificationIdentifier])
        }
        return true
    }
    
    func equipAccessory(_ itemId: String) {
        if gameState.equippedAccessories.contains(itemId) {
            gameState.equippedAccessories.removeAll { $0 == itemId }
        } else {
            gameState.equippedAccessories.append(itemId)
        }
    }
    
    func previewAccessory(_ itemId: String) {
        previewingAccessoryId = itemId
    }
    
    /// Opens Items flow with Bunny Ears preview + top banner (no modal).
    func presentBunnyEarsItemsPromo() {
        guard !gameState.ownedAccessories.contains("bunnyears") else { return }
        showBunnyEarsItemsPromoBanner = true
        previewAccessory("bunnyears")
    }
    
    func dismissBunnyEarsItemsPromoBanner() {
        showBunnyEarsItemsPromoBanner = false
    }
    
    func clearPreview() {
        previewingAccessoryId = nil
    }
    
    func canAfford(_ cost: Int) -> Bool {
        return gameState.capycoins >= cost
    }
    
    // MARK: - Coins & Purchases
    func displayPrice(forProductId productId: String, fallback: String) -> String {
        if let product = iapProducts[productId] {
            return product.displayPrice
        }
        return fallback
    }

    func purchaseCoinPack(_ pack: CoinPack) async -> Bool {
        do {
            let product = try await product(for: pack.productId)
            let transaction = try await purchase(product: product)

            // Deliver goods for consumable
            if transaction.productID == pack.productId {
                let grant = pack.grantCoins
                gameState.capycoins += grant
                showToast("\(grant) coins added! 🎉")
                return true
            }
            iapLastErrorMessage = "Purchase completed but product ID didn’t match. Expected \(pack.productId)."
            return false
        } catch is CancellationError {
            // User cancelled / task cancelled; no toast needed
            return false
        } catch {
            let message = "Purchase failed: \(error.localizedDescription)"
            iapLastErrorMessage = message
            showToast(message)
            return false
        }
    }
    
    // MARK: - StoreKit helpers
    private func loadIAPProducts() async {
        guard !isIAPLoading else { return }
        isIAPLoading = true
        defer { isIAPLoading = false }

        let ids = Set(CoinPack.packs.map(\.productId))

        do {
            let products = try await Product.products(for: Array(ids))
            var dict: [String: Product] = [:]
            for product in products {
                dict[product.id] = product
            }
            iapProducts = dict
        } catch {
            // Keep fallbacks if StoreKit is unavailable
        }
    }
    
    /// Reloads consumable coin pack `Product`s from App Store Connect (prices, availability).
    func refreshIAPProducts() async {
        await loadIAPProducts()
    }

    private func product(for productId: String) async throws -> Product {
        if let cached = iapProducts[productId] {
            return cached
        }

        let products = try await Product.products(for: [productId])
        guard let product = products.first else {
            throw NSError(
                domain: "IAP",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Product not found (\(productId)). Check App Store Connect product IDs + bundle ID match."]
            )
        }
        iapProducts[product.id] = product
        return product
    }

    private func purchase(product: Product) async throws -> StoreKit.Transaction {
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            return transaction
        case .userCancelled:
            throw CancellationError()
        case .pending:
            // Pending (e.g. Ask to Buy) — don't grant items yet.
            throw NSError(domain: "IAP", code: 102, userInfo: [NSLocalizedDescriptionKey: "Purchase pending (Ask to Buy / approval needed)."])
        @unknown default:
            throw NSError(domain: "IAP", code: 999, userInfo: [NSLocalizedDescriptionKey: "Unknown purchase result"])
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw NSError(domain: "IAP", code: 401, userInfo: [NSLocalizedDescriptionKey: "Transaction unverified"])
        case .verified(let safe):
            return safe
        }
    }
    
    func markCNYPopupSeen() {
        gameState.hasSeenCNY2026Popup = true
    }
    
    func renameCapybara(to newName: String) {
        gameState.capybaraName = newName
        refreshHatPromotionNotification()
    }
    
    /// Refreshes Bunny-hat promo copy. Resets the weekly repeating timer.
    func refreshHatPromotionNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [hatPromoNotificationIdentifier])
        guard !gameState.ownedAccessories.contains("bunnyears") else { return }
        guard SettingsManager.shared.notificationsEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            Task { @MainActor in
                self.addHatPromoNotificationRequest()
            }
        }
    }
    
    // MARK: - Subscription Management
    
    /// Upgrades the user's subscription tier and grants coins.
    /// This ADDS the tier's starting coins to the user's existing balance (does not override).
    /// Use this when user purchases a subscription from the shop or upgrades after initial paywall.
    func upgradeSubscription(to tier: SubscriptionManager.SubscriptionTier) {
        let previousTier = currentSubscriptionTier()
        
        gameState.subscriptionTier = tier.rawValue
        gameState.lastSubscriptionCheckDate = Date()
        
        // Restore / duplicate callbacks can fire when tier is unchanged — avoid granting starter coins twice.
        guard tier != previousTier else {
            if tier != .free {
                unlockProItemsIfNeeded()
            }
            print("ℹ️ Subscription tier unchanged (\(tier.displayName)) — skipping starter coins")
            return
        }
        
        gameState.capycoins += tier.startingCoins
        
        if tier != .free {
            gameState.hasRemovedBannerAds = true
            unlockProItemsIfNeeded()
        }
        
        if tier == .weekly {
            gameState.lastWeeklyCoinsGrantDate = Date()
        }
        if tier == .monthly {
            gameState.lastMonthlyCoinsGrantDate = Date()
        }
        if tier == .annual {
            gameState.lastAnnualCoinsGrantDate = Date()
        }
        
        print("✅ Subscription upgraded from \(previousTier.displayName) to \(tier.displayName)")
        print("   Added \(tier.startingCoins) coins to balance")
        print("   New balance: \(gameState.capycoins) coins")
    }
    
    func hasProSubscription() -> Bool {
        guard let tierString = gameState.subscriptionTier,
              let tier = SubscriptionManager.SubscriptionTier(rawValue: tierString) else {
            return false
        }
        return tier != .free
    }
    
    func currentSubscriptionTier() -> SubscriptionManager.SubscriptionTier {
        guard let tierString = gameState.subscriptionTier,
              let tier = SubscriptionManager.SubscriptionTier(rawValue: tierString) else {
            return .free
        }
        return tier
    }
    
    /// Grants recurring weekly coins to Pro Weekly subscribers. Call from main content onAppear.
    func grantWeeklySubscriptionCoinsIfNeeded() {
        guard currentSubscriptionTier() == .weekly else { return }
        let amount = SubscriptionManager.SubscriptionTier.weekly.weeklyCoins
        let now = Date()
#if DEBUG
        // In Debug: use 7-second interval so you can test without waiting 7 days
        let interval: TimeInterval = 7
#else
        let interval: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds
#endif
        
        if let last = gameState.lastWeeklyCoinsGrantDate {
            let nextGrant = last.addingTimeInterval(interval)
            guard now >= nextGrant else {
                return
            }
            gameState.capycoins += amount
            gameState.lastWeeklyCoinsGrantDate = now
            showToast("Weekly Pro reward: \(amount) coins! 🎉")
            print("✅ Granted \(amount) weekly coins (Pro Weekly). New balance: \(gameState.capycoins)")
        } else {
            // First time we see weekly subscriber (e.g. existing user before this feature): start 7-day window
            gameState.lastWeeklyCoinsGrantDate = now
        }
    }
    
    // MARK: - Pro Items Management
    private func unlockProItemsIfNeeded() {
        // If user has Pro subscription, automatically unlock all Pro-only items
        guard hasProSubscription() else { return }
        
        let proItems = AccessoryItem.allItems.filter { $0.isProOnly }
        var unlocked = false
        
        for item in proItems {
            if !gameState.ownedAccessories.contains(item.id) {
                gameState.ownedAccessories.append(item.id)
                unlocked = true
                print("✅ Unlocked Pro item: \(item.name)")
            }
        }
        
        if unlocked {
            print("🎉 Pro items unlocked for Pro subscriber")
        }
    }
    
    /// Grants 10,000 coins to Pro Monthly subscribers every calendar month. Call from main content onAppear.
    func grantMonthlySubscriptionCoinsIfNeeded() {
        let tier = currentSubscriptionTier()
        guard tier == .monthly else { return }
        let amount = tier.monthlyCoins
        let now = Date()
        let calendar = Calendar.current
        if let last = gameState.lastMonthlyCoinsGrantDate {
            guard let nextGrant = calendar.date(byAdding: .month, value: 1, to: last), now >= nextGrant else {
                return
            }
            gameState.capycoins += amount
            gameState.lastMonthlyCoinsGrantDate = now
            showToast("Monthly Pro reward: \(amount) coins! 🎉")
            print("✅ Granted \(amount) monthly coins (Pro). New balance: \(gameState.capycoins)")
        } else {
            gameState.lastMonthlyCoinsGrantDate = now
        }
    }
    
    /// Grants recurring coins to Pro Annual subscribers every 7 days (same rhythm as weekly; billing is yearly). Call from main content onAppear.
    func grantAnnualSubscriptionCoinsIfNeeded() {
        guard currentSubscriptionTier() == .annual else { return }
        let amount = SubscriptionManager.SubscriptionTier.annual.annualCoins
        let now = Date()
#if DEBUG
        let interval: TimeInterval = 7
#else
        let interval: TimeInterval = 7 * 24 * 60 * 60
#endif
        if let last = gameState.lastAnnualCoinsGrantDate {
            let nextGrant = last.addingTimeInterval(interval)
            guard now >= nextGrant else { return }
            gameState.capycoins += amount
            gameState.lastAnnualCoinsGrantDate = now
            showToast("Annual Pro reward: \(amount) coins! 🎉")
            print("✅ Granted \(amount) annual tier coins (7-day cycle). New balance: \(gameState.capycoins)")
        } else {
            gameState.lastAnnualCoinsGrantDate = now
        }
    }
    
    // MARK: - Subscription schedule (Get More / shop UI)
    
    /// Next recurring capycoin grant for the **active** subscription tier, for display in Get More.
    /// - If `scheduledDate` is `nil`, the grant is due (or overdue) and will apply on the next grant pass.
    func nextSubscriptionCoinGrantInfo() -> (capycoinAmount: Int, scheduledDate: Date?)? {
        guard hasProSubscription() else { return nil }
        let tier = currentSubscriptionTier()
        let amount: Int
        switch tier {
        case .free: return nil
        case .weekly: amount = tier.weeklyCoins
        case .monthly: amount = tier.monthlyCoins
        case .annual: amount = tier.annualCoins
        }
        let calendar = Calendar.current
        let now = Date()
#if DEBUG
        let weekInterval: TimeInterval = 7
#else
        let weekInterval: TimeInterval = 7 * 24 * 60 * 60
#endif
        let lastEvent: Date?
        switch tier {
        case .weekly:
            lastEvent = gameState.lastWeeklyCoinsGrantDate
        case .monthly:
            lastEvent = gameState.lastMonthlyCoinsGrantDate
        case .annual:
            lastEvent = gameState.lastAnnualCoinsGrantDate
        case .free:
            return nil
        }
        let anchor = lastEvent ?? gameState.lastSubscriptionCheckDate ?? now
        let rawNext: Date
        switch tier {
        case .weekly:
            rawNext = anchor.addingTimeInterval(weekInterval)
        case .monthly:
            rawNext = calendar.date(byAdding: .month, value: 1, to: anchor) ?? anchor.addingTimeInterval(30 * 24 * 60 * 60)
        case .annual:
            rawNext = anchor.addingTimeInterval(weekInterval)
        case .free:
            return nil
        }
        if rawNext > now {
            return (amount, rawNext)
        }
        return (amount, nil)
    }
    
    // MARK: - Reset
    
    /// Resets only capybara-specific state (stats + run-away). Keeps coins, name, unlocked/equipped items, achievements, and all other progress.
    func rescueNewCapybara() {
        var state = gameState
        state.food = GameState.defaultState.food
        state.drink = GameState.defaultState.drink
        state.happiness = GameState.defaultState.happiness
        state.lastUpdateTime = Date()
        state.hasRunAway = false
        gameState = state
        showRunAwayAlert = false
    }
    
    /// Full reset to default state (e.g. for debugging). Use rescueNewCapybara() when user taps "Rescue Another Capybara".
    func resetGame() {
        clearProgressDefaultsBackup()
        gameState = GameState.defaultState
        showRunAwayAlert = false
    }
    
    /// Resets all game progress to a fresh start (onboarding, walkthrough, stats, coins, items, achievements).
    /// Preserves subscription tier and related entitlements so subscribers keep Pro benefits.
    func resetProgressToBeginning() {
        let tier = gameState.subscriptionTier
        let subEnd = gameState.subscriptionEndDate
        let lastSubCheck = gameState.lastSubscriptionCheckDate
        let removedAds = gameState.hasRemovedBannerAds
        let weekly = gameState.lastWeeklyCoinsGrantDate
        let monthly = gameState.lastMonthlyCoinsGrantDate
        let annual = gameState.lastAnnualCoinsGrantDate
        
        var fresh = GameState.defaultState
        fresh.subscriptionTier = tier
        fresh.subscriptionEndDate = subEnd
        fresh.lastSubscriptionCheckDate = lastSubCheck
        fresh.hasRemovedBannerAds = removedAds
        fresh.lastWeeklyCoinsGrantDate = weekly
        fresh.lastMonthlyCoinsGrantDate = monthly
        fresh.lastAnnualCoinsGrantDate = annual
        
        clearProgressDefaultsBackup()
        gameState = fresh
        showRunAwayAlert = false
        thrownItem = nil
        previewingAccessoryId = nil
        showBunnyEarsItemsPromoBanner = false
        recentAchievement = nil
        stat100ConfettiTrigger = nil
        toastMessage = nil
        scheduleFutureNotifications()
    }
    
    func throwItem(emoji: String, isFood: Bool) {
        thrownItem = ThrownItem(emoji: emoji, isFood: isFood)
        
        // Clear after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.thrownItem = nil
        }
    }
    
    func showToast(_ message: String) {
        toastMessage = message
        
        // Clear after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.toastMessage = nil
        }
    }
    
    // MARK: - Notification Permissions
    private func checkNotificationPermissions() {
        // Only check the status, don't request authorization automatically
        // Authorization should only be requested when user taps the button in onboarding
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .notDetermined:
                    print("⚠️ Notification permissions not determined. Will request in onboarding.")
                case .denied:
                    print("❌ Notification permissions denied. User needs to enable in Settings.")
                case .authorized:
                    print("✅ Notification permissions authorized")
                case .provisional:
                    print("⚠️ Notification permissions provisional")
                case .ephemeral:
                    print("⚠️ Notification permissions ephemeral")
                @unknown default:
                    print("⚠️ Unknown notification permission status")
                }
            }
        }
    }
    
    // MARK: - Notifications
    private func checkCurrentStatsForNotifications() {
        // Check if stats are already below thresholds and send notifications
        if gameState.food < 80 {
            sendNotification(statType: "food", urgent: gameState.food < 50)
        }
        if gameState.drink < 80 {
            sendNotification(statType: "drink", urgent: gameState.drink < 50)
        }
        if gameState.happiness < 80 {
            sendNotification(statType: "petting", urgent: gameState.happiness < 50)
        }
    }
    
    private func checkThresholdCrossing(statType: String, oldValue: Int, newValue: Int) {
        // Check if we crossed the 80 threshold (going down)
        if oldValue >= 80 && newValue < 80 {
            sendNotification(statType: statType, urgent: false)
        }
        
        // Check if we crossed the 50 threshold (going down)
        if oldValue >= 50 && newValue < 50 {
            sendNotification(statType: statType, urgent: true)
        }
    }
    
    private func sendNotification(statType: String, urgent: Bool) {
        // Capture the name before the async closure
        let name = gameState.capybaraName
        
        // Check notification authorization
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                guard settings.authorizationStatus == .authorized else {
                    print("❌ Notifications not authorized. Status: \(settings.authorizationStatus.rawValue)")
                    print("   Please enable notifications in Settings → Capybara Rescue App → Notifications")
                    return
                }
                
                let message: String
                
                switch statType {
                case "food":
                    message = urgent ? "\(name) really needs some food" : "\(name) needs some food"
                case "drink":
                    message = urgent ? "\(name) really needs some drink" : "\(name) needs some drink"
                case "petting":
                    message = urgent ? "\(name) really needs some petting" : "\(name) needs some petting"
                default:
                    return
                }
                
                let content = UNMutableNotificationContent()
                content.title = "Capybara Alert"
                content.body = message
                content.sound = .default
                content.badge = 1
                content.categoryIdentifier = "CAPYBARA_ALERT"
                
                // Create a unique identifier for this notification
                let identifier = "\(statType)_\(urgent ? "urgent" : "normal")_\(Date().timeIntervalSince1970)"
                
                // Use a date trigger with a very short delay (1 second) to ensure it fires
                // Minimum time interval is 1 second for UNTimeIntervalNotificationTrigger
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        print("❌ Failed to send notification: \(error.localizedDescription)")
                    } else {
                        print("✅ Notification scheduled: \(message)")
                        print("   Identifier: \(identifier)")
                    }
                }
            }
        }
    }
    
    // MARK: - Badge Management
    private func clearBadge() {
        // Clear badge count
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error = error {
                print("❌ Failed to clear badge: \(error.localizedDescription)")
            } else {
                print("✅ Badge cleared")
            }
        }
        
        // Also remove all delivered notifications from notification center
        // This ensures when user opens app, old notifications are cleared
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        print("✅ Cleared all delivered notifications")
    }
    
    // MARK: - Schedule Future Notifications
    func scheduleFutureNotifications() {
        guard SettingsManager.shared.notificationsEnabled else {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            return
        }
        
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            
            // Cancel pending requests except the 3-day hat promo (keep its repeating fire schedule)
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                let keepIds: Set<String> = [hatPromoNotificationIdentifier]
                let toRemove = requests.map(\.identifier).filter { !keepIds.contains($0) }
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: toRemove)
                
                DispatchQueue.main.async {
                    let name = self.gameState.capybaraName
                    let currentFood = self.gameState.food
                    let currentDrink = self.gameState.drink
                    let currentHappiness = self.gameState.happiness
                
                // Track which notifications we're scheduling to set badge correctly
                var scheduledNotifications: [(hours: Int, title: String, body: String, identifier: String)] = []
                
                // Calculate when each stat will hit 80 and 50 thresholds
                // One decay step per `statDecayIntervalSeconds` of wall time
                // Only schedule notifications for future threshold crossings
                
                // Schedule food notifications
                if currentFood >= 80 {
                    let hoursUntil79 = currentFood - 79
                    scheduledNotifications.append((hoursUntil79, "Food Alert", "\(name) needs some food", "food_80"))
                } else if currentFood >= 50 {
                    let hoursUntil49 = currentFood - 49
                    scheduledNotifications.append((hoursUntil49, "Food Alert!", "\(name) really needs some food!", "food_50"))
                }
                
                // Schedule drink notifications
                if currentDrink >= 80 {
                    let hoursUntil79 = currentDrink - 79
                    scheduledNotifications.append((hoursUntil79, "Drink Alert", "\(name) needs some drink", "drink_80"))
                } else if currentDrink >= 50 {
                    let hoursUntil49 = currentDrink - 49
                    scheduledNotifications.append((hoursUntil49, "Drink Alert!", "\(name) really needs some drink!", "drink_50"))
                }
                
                // Schedule happiness notifications
                if currentHappiness >= 80 {
                    let hoursUntil79 = currentHappiness - 79
                    scheduledNotifications.append((hoursUntil79, "Happiness Alert", "\(name) needs some petting", "happiness_80"))
                } else if currentHappiness >= 50 {
                    let hoursUntil49 = currentHappiness - 49
                    scheduledNotifications.append((hoursUntil49, "Happiness Alert!", "\(name) really needs some petting!", "happiness_50"))
                }
                
                // Now schedule all notifications with badges based on their index
                for (index, notification) in scheduledNotifications.enumerated() {
                    self.scheduleNotificationAt(
                        hours: notification.hours,
                        title: notification.title,
                        body: notification.body,
                        identifier: notification.identifier,
                        badgeNumber: index + 1
                    )
                }
                
                // Daily 8am reminder: "Catch the Orange" mini-game to earn coins
                self.scheduleCatchTheOrangeDailyReminder()

                // Every 3 days: hat / Items nudge (tap opens Items)
                self.ensureHatPromoScheduled()
                }
            }
        }
    }
    
    /// Ensures the repeating Bunny-hat promo exists (keeps schedule if already present).
    private func ensureHatPromoScheduled() {
        guard !gameState.ownedAccessories.contains("bunnyears") else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [hatPromoNotificationIdentifier])
            return
        }
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            guard !requests.contains(where: { $0.identifier == hatPromoNotificationIdentifier }) else { return }
            Task { @MainActor in
                self.addHatPromoNotificationRequest()
            }
        }
    }
    
    private func addHatPromoNotificationRequest() {
        guard !gameState.ownedAccessories.contains("bunnyears") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Bunny hat now available!"
        content.body = "Bunny hat now available to purchase!"
        content.sound = .default
        content.userInfo = ["action": "openItems"]
        
        let oneWeek: TimeInterval = 7 * 24 * 60 * 60
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: oneWeek, repeats: true)
        let request = UNNotificationRequest(identifier: hatPromoNotificationIdentifier, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to schedule hat promo notification: \(error.localizedDescription)")
            } else {
                print("✅ Scheduled repeating Bunny-hat promo (every 7 days)")
            }
        }
    }
    
    private func scheduleCatchTheOrangeDailyReminder() {
        let content = UNMutableNotificationContent()
        content.title = "Catch the Orange! 🍊"
        content.body = "Let's catch some oranges to earn some coins!"
        content.sound = .default
        
        var dateComponents = DateComponents()
        dateComponents.hour = 8
        dateComponents.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "catch_orange_8am", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to schedule Catch the Orange reminder: \(error.localizedDescription)")
            } else {
                print("✅ Scheduled daily 8am Catch the Orange reminder")
            }
        }
    }

    private func scheduleNotificationAt(hours: Int, title: String, body: String, identifier: String, badgeNumber: Int) {
        // `hours` = number of decay steps until the threshold (one step per `statDecayIntervalSeconds`).
        guard hours > 0 else { return }
        
        // Query current delivered notifications to calculate proper badge
        UNUserNotificationCenter.current().getDeliveredNotifications { deliveredNotifications in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // Set badge to current delivered count + this notification
            content.badge = NSNumber(value: deliveredNotifications.count + 1)
            
            let timeInterval = TimeInterval(hours) * statDecayIntervalSeconds
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("❌ Failed to schedule notification: \(error.localizedDescription)")
                } else {
                    print("✅ Scheduled notification '\(identifier)' for \(hours) decay step(s) from now")
                }
            }
        }
    }
    
}

