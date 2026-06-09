import SwiftUI

// MARK: - Main Content View
struct ContentView: View {
    @EnvironmentObject var gameManager: GameManager
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    
    @State private var selectedTab: MenuTab = .food
    @State private var showRenameSheet = false
    @State private var showShopSheet = false
    @State private var showAchievementsSheet = false
    @State private var showFootballSummerSheet = false
    @State private var showSettingsSheet = false
    @State private var showPanel = false // Hide panel by default - show only menu bar
    @State private var capybaraPosition: CGPoint = .zero
    @State private var showOnboarding = false
    @State private var currentTutorialStep: TutorialStep? = nil
    @State private var shouldApplyInitialRotation = false
    @State private var showCNYPopup = false
    @State private var pendingBunnyEarsPromoAfterCNY = false
    @State private var bunnyEarsPromoRequestID = 0

    private let capybaraVisualOffsetY: CGFloat = 15
    
    private static let pendingOpenItemsDefaultsKey = "pending_open_items"
    
    // Chinese New Year background date checking
    private var shouldShowChineseNewYearTheme: Bool {
        let now = Date()
        
        // Create date components in GMT timezone
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "GMT")!
        
        // Start: Friday 13 February 2026 — 10:00 AM GMT
        var startComponents = DateComponents()
        startComponents.year = 2026
        startComponents.month = 2
        startComponents.day = 13
        startComponents.hour = 10
        startComponents.minute = 0
        startComponents.timeZone = TimeZone(identifier: "GMT")
        
        // End: Tuesday 24 February 2026 — 10:00 AM GMT
        var endComponents = DateComponents()
        endComponents.year = 2026
        endComponents.month = 2
        endComponents.day = 24
        endComponents.hour = 10
        endComponents.minute = 0
        endComponents.timeZone = TimeZone(identifier: "GMT")
        
        guard let startDate = calendar.date(from: startComponents),
              let endDate = calendar.date(from: endComponents) else {
            return false
        }
        
        return now >= startDate && now < endDate
    }
    
    private func checkTutorialStatus() {
        let hasCompletedOnboarding = gameManager.gameState.hasCompletedOnboarding
        let hasCompletedTutorial = gameManager.gameState.hasCompletedTutorial
        if hasCompletedOnboarding && !hasCompletedTutorial && currentTutorialStep == nil {
            currentTutorialStep = .feedFood
        }
    }
    
    private func checkOnboardingStatus() {
        showOnboarding = !gameManager.gameState.hasCompletedOnboarding
    }
    
    private func openItemsFromNotification() {
        guard !gameManager.gameState.ownedAccessories.contains("bunnyears") else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            selectedTab = .items
            showPanel = true
            showShopSheet = false
        }
    }
    
    private func consumePendingOpenItemsIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.pendingOpenItemsDefaultsKey) {
            UserDefaults.standard.set(false, forKey: Self.pendingOpenItemsDefaultsKey)
            openItemsFromNotification()
        }
    }
    
    private func openItemsWithBunnyEarsPromo() {
        guard !gameManager.gameState.ownedAccessories.contains("bunnyears") else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            selectedTab = .items
            showPanel = true
            showShopSheet = false
        }
        gameManager.presentBunnyEarsItemsPromo()
    }
    
    private func openItemsWithFootballPromo() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            selectedTab = .items
            showPanel = true
            showShopSheet = false
        }
        gameManager.previewAccessory("football")
    }
    
    /// After delay: open Items + Bunny Ears nudge, or queue behind CNY popup.
    private func requestBunnyEarsPromoAfterDelay() {
        bunnyEarsPromoRequestID += 1
        let request = bunnyEarsPromoRequestID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            guard request == bunnyEarsPromoRequestID else { return }
            guard !showOnboarding else { return }
            guard gameManager.gameState.hasCompletedTutorial else { return }
            guard !gameManager.gameState.ownedAccessories.contains("bunnyears") else { return }
            if showCNYPopup {
                pendingBunnyEarsPromoAfterCNY = true
            } else {
                openItemsWithBunnyEarsPromo()
            }
        }
    }
    
    /// Formatted coin count for header (full number with commas, no K/M).
    private func formattedCoinString(_ coins: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: coins)) ?? "\(coins)"
    }
    
    var body: some View {
        Group {
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .environmentObject(gameManager)
                    .onChange(of: showOnboarding) { oldValue, newValue in
                        if !newValue {
                            // Onboarding (including pledge) completed — go to main content
                            shouldApplyInitialRotation = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                checkTutorialStatus()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                shouldApplyInitialRotation = false
                            }
                        }
                    }
            } else {
                mainContentView
                    .onAppear {
                        checkTutorialStatus()
                        consumePendingOpenItemsIfNeeded()
                        // Pro Weekly: grant 500 coins every 7 days if eligible
                        gameManager.grantWeeklySubscriptionCoinsIfNeeded()
                        // Pro Monthly: grant coins every month if eligible
                        gameManager.grantMonthlySubscriptionCoinsIfNeeded()
                        // Pro Annual: grant yearly coin allotment if eligible
                        gameManager.grantAnnualSubscriptionCoinsIfNeeded()
                        
                        // Check if we should show CNY popup
                        if shouldShowChineseNewYearTheme && !gameManager.gameState.hasSeenCNY2026Popup {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                showCNYPopup = true
                            }
                        }
                    }
            }
        }
        .onAppear {
            checkOnboardingStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .capybaraOpenItems)) { _ in
            guard !showOnboarding else { return }
            openItemsFromNotification()
        }
        .onChange(of: localizationManager.currentLanguage) { _, _ in
            gameManager.refreshHatPromotionNotification()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !showOnboarding {
                consumePendingOpenItemsIfNeeded()
            }
        }
        .onChange(of: gameManager.gameState.hasCompletedTutorial) { _, completed in
            if completed, !showOnboarding {
                requestBunnyEarsPromoAfterDelay()
            }
        }
        .onChange(of: gameManager.gameState.hasCompletedOnboarding) { oldValue, newValue in
            checkOnboardingStatus()
            if !newValue {
                currentTutorialStep = nil
                showPanel = false
            }
        }
    }
    
    private var mainContentView: some View {
        GeometryReader { geometry in
            ZStack {
                // Background - switches between CNY and regular theme
                if shouldShowChineseNewYearTheme {
                    ChineseNewYearBackground()
                        .ignoresSafeArea()
                } else {
                    AnimatedBackground()
                        .ignoresSafeArea()
                }
                
                // Main content
                VStack(spacing: 0) {
                    // Header: two rows so name and coins don’t cramp; compact coin format for large balances
                    VStack(spacing: 12) {
                        // Line 1: Name (top left), medal + music + gear (top right)
                        HStack(spacing: 12) {
                            Button(action: {
                                HapticManager.shared.buttonPress()
                                showRenameSheet = true
                            }) {
                                Text(gameManager.gameState.capybaraName)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("\(gameManager.gameState.capybaraName), \(L("settings.renameCapybara"))")
                            .accessibilityHint("Double tap to rename your capybara")
                            
                            Button(action: {
                                HapticManager.shared.buttonPress()
                                showAchievementsSheet = true
                            }) {
                                Image(systemName: "medal.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .tutorialHighlight(key: "achievements_button")
                            .accessibilityLabel(L("tutorial.achievements"))
                            .accessibilityHint("\(L("tutorial.youCanCheckStreaks")) \(L("tutorial.achievementsButton"))")
                            
                            Button(action: {
                                HapticManager.shared.buttonPress()
                                showSettingsSheet = true
                            }) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .accessibilityLabel(L("settings.title"))
                            .accessibilityHint("Opens settings")
                        }
                        
                        // Line 2: Coins (left), Get More (bottom right)
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 28, height: 28)
                                        .shadow(color: Color(hex: "FFD700").opacity(0.4), radius: 6, x: 0, y: 2)
                                    
                                    Text("₵")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                
                                Text(formattedCoinString(gameManager.gameState.capycoins))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            
                            Spacer(minLength: 8)
                            
                            // Get More (bottom right)
                            Button(action: {
                                HapticManager.shared.buttonPress()
                                showShopSheet = true
                            }) {
                                HStack(spacing: 8) {
                                    Text(L("common.getMore"))
                                        .font(.system(size: 14, weight: .semibold))
                                    CoinIcon(size: 24)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule()
                                        .fill(Color(hex: "1a5f1a"))
                                )
                                .shadow(color: Color(hex: "1a5f1a").opacity(0.35), radius: 6, x: 0, y: 3)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .accessibilityLabel(L("common.getMore"))
                            .accessibilityHint("Opens shop to get more coins")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        GlassBackground()
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    
                    // Stats display (Bunny Ears promo banner overlays this row when active)
                    ZStack {
                        StatsDisplayView(
                            food: gameManager.gameState.food,
                            drink: gameManager.gameState.drink,
                            happiness: gameManager.gameState.happiness
                        )
                        .id(localizationManager.currentLanguage)
                        
                        if gameManager.showBunnyEarsItemsPromoBanner, selectedTab == .items, showPanel {
                            BunnyEarsItemsPromoBanner(
                                capybaraName: gameManager.gameState.capybaraName,
                                onDismiss: {
                                    gameManager.dismissBunnyEarsItemsPromoBanner()
                                }
                            )
                            .padding(.horizontal, 10)
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .zIndex(0) // Stats + banner behind capybara
                    
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        showFootballSummerSheet = true
                    }) {
                        FootballSummerPillLabel()
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .accessibilityLabel(L("footballSummer.title"))
                    .accessibilityHint(L("footballSummer.topBarHint"))
                    
                    Spacer()
                    
                    // Capybara in the center (3D) - moved up higher
                    Capybara3DView(
                        emotion: gameManager.gameState.capybaraEmotion,
                        equippedAccessories: gameManager.gameState.equippedAccessories,
                        previewingAccessoryId: gameManager.previewingAccessoryId,
                        onPet: {
                            gameManager.petCapybara()
                        },
                        initialRotation: shouldApplyInitialRotation ? 45 : nil
                    )
                    .frame(height: 420) // Taller container so hats aren't cut off at top
                    .offset(y: capybaraVisualOffsetY) // Move up higher on the page
                    .zIndex(100) // Ensure capybara and accessories appear above stats
                    .tutorialHighlight(key: "capybara_tap")
                    .background(
                        GeometryReader { capyGeometry in
                            Color.clear.preference(
                                key: CapybaraFramePreferenceKey.self,
                                value: capyGeometry.frame(in: .named("main"))
                            )
                        }
                    )
                    
                    // Spacer - always present to maintain capybara position
                    Spacer()
                }
                
                // Panel area - show specific panel as overlay
                if showPanel {
                    VStack {
                        Spacer()
                        panelContent
                            .frame(minHeight: 180, maxHeight: 280) // Extra height so Items panel can sit below capybara
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? max(8, geometry.safeAreaInsets.bottom - 8) : 8)
                    }
                    .zIndex(99) // Below master panel overlay but above main content
                }
                
                // Master panel at bottom - replaces menu bar
                VStack {
                    Spacer(minLength: 0)
                    
                    if !showPanel {
                        // Show master panel at bottom
                        MasterPanel(onCategorySelected: { tab in
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                selectedTab = tab
                                if tab == .shop {
                                    showPanel = false
                                    showShopSheet = true
                                } else {
                                    showPanel = true
                                }
                            }
                        })
                        .id(localizationManager.currentLanguage)
                        .padding(.leading, max(geometry.safeAreaInsets.leading, 0) + 20)
                        .padding(.trailing, max(geometry.safeAreaInsets.trailing, 0) + 20)
                        .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? max(8, geometry.safeAreaInsets.bottom - 12) : 4)
                    }
                }
                .zIndex(100) // Ensure master panel is always on top
                
                // Thrown item animation overlay    
                FoodThrowingOverlay(
                    item: gameManager.thrownItem,
                    capybaraPosition: capybaraPosition,
                    onAnimationComplete: {}
                )
                
                // Confetti (stat 100 or achievement earned)
                ConfettiView(
                    isActive: gameManager.stat100ConfettiTrigger != nil || gameManager.recentAchievement != nil,
                    onComplete: {
                        gameManager.stat100ConfettiTrigger = nil
                    }
                )
                .id(gameManager.stat100ConfettiTrigger ?? (gameManager.recentAchievement != nil ? "achievement" : "idle"))
                .zIndex(200)
                .onChange(of: gameManager.stat100ConfettiTrigger) { _, newValue in
                    guard newValue != nil else { return }
                    let state = gameManager.gameState
                    guard state.food == 100, state.drink == 100, state.happiness == 100 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        requestReview()
                    }
                }
                
                // Love hearts overlay (when happiness >= 80)
                LoveHeartsOverlay(
                    isActive: gameManager.gameState.happiness >= 80,
                    capybaraPosition: capybaraPosition
                )
                
                // Unhappy emojis overlay (when happiness < 50)
                UnhappyEmojisOverlay(
                    isActive: gameManager.gameState.happiness < 50,
                    capybaraPosition: capybaraPosition
                )
                
                // Speech bubble overlay (when food or drink < 80)
                CapybaraSpeechBubbleOverlay(
                    food: gameManager.gameState.food,
                    drink: gameManager.gameState.drink,
                    capybaraPosition: capybaraPosition
                )
                
                // Run away overlay
                if gameManager.gameState.hasRunAway {
                    RunAwayView(onRestart: {
                        gameManager.rescueNewCapybara()
                    })
                    .transition(.opacity)
                }
                
                // Tutorial overlay
                if currentTutorialStep != nil {
                    TutorialOverlay(currentStep: $currentTutorialStep, showPanel: $showPanel)
                        .zIndex(200) // Above everything else
                }
                
                // Toast overlay
                if let toastMessage = gameManager.toastMessage {
                    VStack {
                        Spacer()
                        ToastView(message: toastMessage)
                            .padding(.bottom, 100)
                    }
                    .zIndex(201) // Above everything including tutorial
                }
                
                // Chinese New Year popup
                if showCNYPopup {
                    ChineseNewYearPopup(onDismiss: {
                        showCNYPopup = false
                        gameManager.markCNYPopupSeen()
                        if pendingBunnyEarsPromoAfterCNY {
                            pendingBunnyEarsPromoAfterCNY = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                openItemsWithBunnyEarsPromo()
                            }
                        }
                    })
                    .zIndex(203) // Above everything
                }
                
                // Achievement reward popup + confetti ("Well done on [achievement], here's [X] coins")
                if let achievement = gameManager.recentAchievement {
                    AchievementRewardPopup(achievementName: achievement.name, coins: achievement.coins)
                        .zIndex(204)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                gameManager.clearRecentAchievementReward()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                let state = gameManager.gameState
                                if state.food == 100, state.drink == 100, state.happiness == 100 {
                                    requestReview()
                                }
                            }
                        }
                }
            }
            .coordinateSpace(name: "main")
            .onPreferenceChange(CapybaraFramePreferenceKey.self) { frame in
                guard frame != .zero else { return }
                capybaraPosition = CGPoint(
                    x: frame.midX,
                    y: frame.midY
                )
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSheet(
                isPresented: $showRenameSheet,
                name: $gameManager.gameState.capybaraName,
                onSave: { newName in
                    gameManager.renameCapybara(to: newName)
                }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showShopSheet) {
            ShopSheetView()
                .environmentObject(gameManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAchievementsSheet) {
            AchievementsView()
                .environmentObject(gameManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFootballSummerSheet) {
            FootballSummerView {
                showFootballSummerSheet = false
                openItemsWithFootballPromo()
            }
            .environmentObject(gameManager)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
                .environmentObject(gameManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Master panel shows by default (showPanel = false)
    }
    
    @ViewBuilder
    private var panelContent: some View {
        switch selectedTab {
        case .food:
            FoodPanel(
                onFoodSelected: { item in
                    if gameManager.feedCapybara(with: item) {
                        gameManager.throwItem(emoji: item.emoji, isFood: true)
                    }
                },
                onBack: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showPanel = false // Go back to master panel
                    }
                }
            )
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            
        case .drink:
            DrinkPanel(
                onDrinkSelected: { item in
                    if gameManager.giveWater(with: item) {
                        gameManager.throwItem(emoji: item.emoji, isFood: false)
                    }
                },
                onBack: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showPanel = false // Go back to master panel
                    }
                }
            )
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            
        case .items:
            ItemsPanel(
                onBack: {
                    gameManager.dismissBunnyEarsItemsPromoBanner()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showPanel = false // Go back to master panel
                    }
                },
                onOpenShop: {
                    showPanel = false
                    showShopSheet = true
                }
            )
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            
        case .shop:
            EmptyView()
        }
    }
}

// MARK: - Preferences
private struct CapybaraFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Shop Sheet View
struct ShopSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    var body: some View {
        NavigationView {
            ZStack {
                AppColors.background
                    .ignoresSafeArea()
                
                ShopPanel()
            }
            .navigationTitle(L("menu.shop"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.primary.opacity(0.7))
                    }
                }
            }
        }
    }
}

// MARK: - Regular Background (solid color, respects dark mode)
struct AnimatedBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Color(hex: colorScheme == .dark ? "1a1a2e" : "FFF8E7")
            .ignoresSafeArea()
    }
}

// MARK: - Bunny Ears Items promo banner (golden strip under status bar)
struct BunnyEarsItemsPromoBanner: View {
    @ObservedObject private var localizationManager = LocalizationManager.shared
    let capybaraName: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: L("promo.bunnyEarsBannerFormat"), capybaraName))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: "3d2f00"))
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.8)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(action: {
                HapticManager.shared.buttonPress()
                onDismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(hex: "3d2f00").opacity(0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("common.dismiss"))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "FFE566"),
                            Color(hex: "FFD700"),
                            Color(hex: "F5A623")
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Color(hex: "F5A623").opacity(0.45), radius: 12, x: 0, y: 5)
    }
}

// MARK: - Chinese New Year Background (Year of the Horse)
struct ChineseNewYearBackground: View {
    @State private var phase: CGFloat = 0
    @State private var lanternPhase: CGFloat = 0
    
    var body: some View {
        ZStack {
            baseGradient
            
            GeometryReader { geometry in
                ZStack {
                    horseElements
                    lanternElements
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .onAppear {
            withAnimation(
                .linear(duration: 10)
                .repeatForever(autoreverses: false)
            ) {
                phase = .pi * 2
            }
            withAnimation(
                .easeInOut(duration: 3)
                .repeatForever(autoreverses: true)
            ) {
                lanternPhase = .pi
            }
        }
    }
    
    private var baseGradient: some View {
        LinearGradient(
            colors: [
                Color(hex: "5A0000"),
                Color(hex: "8B0000"),
                Color(hex: "6B0000")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var horseElements: some View {
        ForEach(0..<3, id: \.self) { index in
            horseElement(index: index)
        }
    }
    
    private func horseElement(index: Int) -> some View {
        let xOffset = sin(phase + Double(index) * 2) * 80 + CGFloat(index * 120) - 180
        let yOffset = cos(phase * 0.5 + Double(index)) * 60 + CGFloat(index * 200) - 100
        let rotation = sin(phase + Double(index)) * 15
        
        return Text("🐴")
            .font(.system(size: 60))
            .opacity(0.08)
            .offset(x: xOffset, y: yOffset)
            .rotationEffect(.degrees(rotation))
    }
    
    private var lanternElements: some View {
        ForEach(0..<4, id: \.self) { index in
            lanternElement(index: index)
        }
    }
    
    private func lanternElement(index: Int) -> some View {
        let xOffset = cos(phase * 0.6 + Double(index) * 1.5) * 100 + CGFloat(index * 100) - 150
        let yOffset = sin(phase * 0.8 + Double(index)) * 70 + CGFloat(index * 150) - 50
        let rotation = cos(lanternPhase + Double(index)) * 10
        
        return Text("🏮")
            .font(.system(size: 40))
            .opacity(0.12)
            .offset(x: xOffset, y: yOffset)
            .rotationEffect(.degrees(rotation))
    }
}

// MARK: - Chinese New Year Popup
struct ChineseNewYearPopup: View {
    let onDismiss: () -> Void
    
    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            
            // Popup card
            VStack(spacing: 24) {
                // Title with lantern emoji
                VStack(spacing: 8) {
                    Text("🏮")
                        .font(.system(size: 60))
                    
                    Text("Celebrate Chinese New Year!")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .multilineTextAlignment(.center)
                    
                    Text("New Items")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                
                // Items list
                VStack(alignment: .leading, spacing: 16) {
                    CNYItemRow(emoji: "🥠", category: "Food", name: "Fortune Cookie")
                    CNYItemRow(emoji: "🫖", category: "Drinks", name: "Jasmine Tea")
                    CNYItemRow(emoji: "🏮", category: "Items", name: "Red Lantern")
                }
                .padding(.horizontal, 20)
                
                // Close button
                Button(action: {
                    HapticManager.shared.buttonPress()
                    onDismiss()
                }) {
                    Text("Let's Celebrate!")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "DC143C"), Color(hex: "8B0000")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                        .shadow(color: Color(hex: "DC143C").opacity(0.5), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 32)
            .padding(.horizontal, 24)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "1a1a2e"),
                                Color(hex: "16213e")
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(hex: "FFD700").opacity(0.6), Color(hex: "FFA500").opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .shadow(color: Color(hex: "FFD700").opacity(0.3), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - CNY Item Row
struct CNYItemRow: View {
    let emoji: String
    let category: String
    let name: String
    
    var body: some View {
        HStack(spacing: 16) {
            // Emoji in circle
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "FFD700").opacity(0.3), Color(hex: "FFA500").opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                
                Text(emoji)
                    .font(.system(size: 28))
            }
            
            // Text info
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                
                HStack(spacing: 6) {
                    Text("in")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    
                    Text(category)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
            
            Spacer()
            
            // NEW badge
            Text("NEW!")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: "8B0000"))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
    }
}

// MARK: - Toast View
struct ToastView: View {
    let message: String
    
    var body: some View {
        Text(message)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.red.opacity(0.9), Color.orange.opacity(0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            )
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Achievement Reward Popup ("Well done on [achievement], here's [X] coins")
struct AchievementRewardPopup: View {
    let achievementName: String
    let coins: Int
    
    private static let cream = Color(hex: "FFF8E7")
    private static let primaryText = Color(hex: "1a1a2e")
    private static let secondaryText = Color(hex: "5A5A5A")
    private static let settingsGreen = Color(hex: "1a5f1a")
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                Text("🏆")
                    .font(.system(size: 50))
                
                Text(achievementName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Self.primaryText)
                    .multilineTextAlignment(.center)
                
                Text("\(coins) \(L("common.coins"))")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Self.secondaryText)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Self.cream)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Self.settingsGreen.opacity(0.5), lineWidth: 2)
                    )
            )
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }
}

#Preview {
    ContentView()
        .environmentObject(GameManager())
}

/// Preview that shows the homepage (main content) without going through onboarding.
#Preview("Homepage") {
    let manager = GameManager()
    var state = manager.gameState
    state.hasCompletedOnboarding = true
    state.hasCompletedTutorial = true
    state.capybaraName = "Capy"
    manager.gameState = state
    return ContentView()
        .environmentObject(manager)
}

/// Preview that shows the homepage with the tutorial overlay active (click through steps).
#Preview("Tutorial") {
    let manager = GameManager()
    var state = manager.gameState
    state.hasCompletedOnboarding = true
    state.hasCompletedTutorial = false
    state.capybaraName = "Capy"
    manager.gameState = state
    return ContentView()
        .environmentObject(manager)
}

