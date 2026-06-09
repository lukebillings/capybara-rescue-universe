import SwiftUI
import SceneKit

private func formattedItemCost(_ cost: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: cost)) ?? "\(cost)"
}

// MARK: - Items Panel
struct ItemsPanel: View {
    @EnvironmentObject var gameManager: GameManager
    @ObservedObject private var localizationManager = LocalizationManager.shared
    let onBack: (() -> Void)?
    let onOpenShop: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    @State private var previewingItemId: String? = nil
    @State private var showInsufficientCoinsMessage: Bool = false
    @State private var showLooksGoodModal: Bool = false
    @State private var showHatEquipError: Bool = false
    
    init(onBack: (() -> Void)? = nil, onOpenShop: (() -> Void)? = nil) {
        self.onBack = onBack
        self.onOpenShop = onOpenShop
    }
    
    var body: some View {
        mainContent
            .overlay(insufficientCoinsOverlay)
            .overlay(looksGoodModalOverlay)
            .overlay(hatEquipErrorOverlay)
    }
    
    private var mainContent: some View {
        Group {
            // Keep iPhone (compact width) submenu layout unchanged.
            if horizontalSizeClass == .compact {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    
                    HStack(alignment: .center, spacing: 12) {
                        if let onBack = onBack {
                            Button(action: {
                                HapticManager.shared.buttonPress()
                                if let previewId = previewingItemId,
                                   !gameManager.gameState.ownedAccessories.contains(previewId) {
                                    previewingItemId = nil
                                    gameManager.clearPreview()
                                }
                                onBack()
                            }) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Color(hex: "1a5f1a")))
                            }
                        }
                        
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(filteredItems) { item in
                                        AccessoryItemButton(
                                            item: item,
                                            isOwned: gameManager.gameState.ownedAccessories.contains(item.id),
                                            isEquipped: gameManager.gameState.equippedAccessories.contains(item.id),
                                            canAfford: gameManager.canAfford(item.cost),
                                            isPreviewing: previewingItemId == item.id,
                                            hasPro: gameManager.hasProSubscription()
                                        ) {
                                            handleItemAction(item)
                                        }
                                        .frame(width: 78)
                                        .id(item.id)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                            }
                            .frame(height: 100)
                            .onAppear {
                                syncBunnyEarsPromoScroll(using: proxy)
                            }
                            .onChange(of: gameManager.showBunnyEarsItemsPromoBanner) { _, isShowing in
                                if isShowing {
                                    syncBunnyEarsPromoScroll(using: proxy)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .padding(.top, 240)
                .padding(.bottom, 12)
            } else {
                // iPad / iPad mini: keep adaptive sizing to avoid row/header clipping.
                GeometryReader { geometry in
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        
                        HStack(alignment: .center, spacing: 12) {
                            if let onBack = onBack {
                                Button(action: {
                                    HapticManager.shared.buttonPress()
                                    if let previewId = previewingItemId,
                                       !gameManager.gameState.ownedAccessories.contains(previewId) {
                                        previewingItemId = nil
                                        gameManager.clearPreview()
                                    }
                                    onBack()
                                }) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(Color(hex: "1a5f1a")))
                                }
                            }
                            
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(filteredItems) { item in
                                            AccessoryItemButton(
                                                item: item,
                                                isOwned: gameManager.gameState.ownedAccessories.contains(item.id),
                                                isEquipped: gameManager.gameState.equippedAccessories.contains(item.id),
                                                canAfford: gameManager.canAfford(item.cost),
                                                isPreviewing: previewingItemId == item.id,
                                                hasPro: gameManager.hasProSubscription()
                                            ) {
                                                handleItemAction(item)
                                            }
                                            .frame(width: 78)
                                            .id(item.id)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                }
                                .frame(height: max(100, min(geometry.size.height * 0.55, 120)))
                                .onAppear {
                                    syncBunnyEarsPromoScroll(using: proxy)
                                }
                                .onChange(of: gameManager.showBunnyEarsItemsPromoBanner) { _, isShowing in
                                    if isShowing {
                                        syncBunnyEarsPromoScroll(using: proxy)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(height: 52)
                    }
                    .padding(.top, 160)
                    .padding(.bottom, 8)
                }
            }
        }
        .onChange(of: gameManager.gameState.capycoins) { oldValue, newValue in
            // Update preview state when coins change (e.g., after buying coins)
            guard let previewId = previewingItemId, !previewId.isEmpty else { return }
            guard let item = AccessoryItem.allItems.first(where: { $0.id == previewId }) else {
                print("⚠️ Preview item not found: \(previewId)")
                return
            }
            if gameManager.canAfford(item.cost) {
                showInsufficientCoinsMessage = false
            }
        }
    }
    
    @ViewBuilder
    private var insufficientCoinsOverlay: some View {
        if showInsufficientCoinsMessage, 
           let previewingId = previewingItemId,
           !previewingId.isEmpty,
           let item = AccessoryItem.allItems.first(where: { $0.id == previewingId }) {
            InsufficientCoinsOverlay(
                itemName: localizedAccessoryName(id: item.id),
                itemCost: item.cost,
                currentCoins: gameManager.gameState.capycoins,
                onBuyCoins: {
                    showInsufficientCoinsMessage = false
                    previewingItemId = nil
                    gameManager.clearPreview()
                    onOpenShop?()
                },
                onDismiss: {
                    showInsufficientCoinsMessage = false
                    // Keep preview active so user can still see it on capybara
                }
            )
        }
    }
    
    @ViewBuilder
    private var looksGoodModalOverlay: some View {
        if showLooksGoodModal,
           let previewingId = previewingItemId,
           !previewingId.isEmpty,
           let item = AccessoryItem.allItems.first(where: { $0.id == previewingId }) {
            LooksGoodModal(
                itemName: localizedAccessoryName(id: item.id),
                itemCost: item.cost,
                currentCoins: gameManager.gameState.capycoins,
                onBuyNow: {
                    if gameManager.purchaseAccessory(item) {
                        HapticManager.shared.purchaseSuccess()
                        showLooksGoodModal = false
                        previewingItemId = nil
                        gameManager.clearPreview()
                    } else {
                        HapticManager.shared.purchaseFailed()
                    }
                },
                onDismiss: {
                    showLooksGoodModal = false
                    // Keep preview active so user can still see it on capybara
                }
            )
        }
    }
    
    @ViewBuilder
    private var hatEquipErrorOverlay: some View {
        if showHatEquipError {
            HatEquipErrorOverlay(
                onDismiss: {
                    showHatEquipError = false
                }
            )
        }
    }
    
    private func syncBunnyEarsPromoScroll(using proxy: ScrollViewProxy) {
        guard gameManager.showBunnyEarsItemsPromoBanner else { return }
        guard filteredItems.contains(where: { $0.id == "bunnyears" }) else { return }
        previewingItemId = "bunnyears"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo("bunnyears", anchor: .center)
            }
        }
    }
    
    private var filteredItems: [AccessoryItem] {
        // Safety check: ensure allItems is accessible
        guard !AccessoryItem.allItems.isEmpty else {
            print("⚠️ No accessory items available")
            return []
        }
        
        // Filter CNY items - Red Lantern appears from Feb 13 onwards (stays forever)
        // OR if user already owns it, keep showing it
        let filtered = AccessoryItem.allItems.filter { item in
            if item.id == "redlantern" {
                return Date.shouldShowCNYItems2026() || 
                       gameManager.gameState.ownedAccessories.contains(item.id)
            }
            return true
        }
        
        // Sort items by price (cost) in ascending order
        return filtered.sorted { $0.cost < $1.cost }
    }
    
    private func handleItemAction(_ item: AccessoryItem) {
        // Safety check: ensure item is valid
        guard !item.id.isEmpty else {
            print("⚠️ Invalid item ID")
            return
        }
        
        // Check if item is Pro-only and user doesn't have Pro
        if item.isProOnly && !gameManager.hasProSubscription() {
            // Allow preview
            if previewingItemId == item.id {
                // Second click - open shop to subscribe
                HapticManager.shared.buttonPress()
                onOpenShop?()
            } else {
                // First click - preview it (same as regular items)
                HapticManager.shared.selection()
                
                // Clear previous modals
                showInsufficientCoinsMessage = false
                showLooksGoodModal = false
                
                previewingItemId = item.id
                gameManager.previewAccessory(item.id)
            }
            return
        }
        
        if gameManager.gameState.ownedAccessories.contains(item.id) {
            // Check if this is a hat and if another hat is already equipped
            if item.isHat {
                // Check if another hat is equipped - safely access allItems
                let otherEquippedHats = gameManager.gameState.equippedAccessories.compactMap { equippedId -> String? in
                    guard !equippedId.isEmpty,
                          let equippedItem = AccessoryItem.allItems.first(where: { $0.id == equippedId }),
                          equippedItem.isHat else { return nil }
                    return equippedId
                }
                
                if !otherEquippedHats.isEmpty && !gameManager.gameState.equippedAccessories.contains(item.id) {
                    // Another hat is equipped, show error message
                    showHatEquipError = true
                    HapticManager.shared.purchaseFailed()
                    return
                }
            }
            
            // Toggle equip/unequip
            HapticManager.shared.selection()
            gameManager.equipAccessory(item.id)
            // Clear any preview when equipping
            if previewingItemId != nil {
                previewingItemId = nil
                gameManager.clearPreview()
                showInsufficientCoinsMessage = false
                showLooksGoodModal = false
            }
        } else {
            // Preview and purchase flow
            if previewingItemId == item.id {
                // Second click on previewed item - show "Looks Good?" modal if can afford
                if gameManager.canAfford(item.cost) {
                    showLooksGoodModal = true
                    HapticManager.shared.selection()
                } else {
                    // Can't afford - show insufficient coins message
                    showInsufficientCoinsMessage = true
                    HapticManager.shared.purchaseFailed()
                }
            } else {
                // First click on this item OR switching to different item - preview it
                HapticManager.shared.selection()
                
                // Clear previous modals
                showInsufficientCoinsMessage = false
                showLooksGoodModal = false
                
                previewingItemId = item.id
                gameManager.previewAccessory(item.id)
            }
        }
    }
}

// MARK: - Category Tab Bar
struct CategoryTabBar: View {
    @Binding var selectedCategory: AccessoryItem.AccessoryCategory
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccessoryItem.AccessoryCategory.allCases, id: \.self) { category in
                CategoryTab(
                    title: category.rawValue,
                    isSelected: selectedCategory == category
                ) {
                    HapticManager.shared.menuTabChanged()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedCategory = category
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Category Tab
struct CategoryTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.8))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.purple.opacity(0.4) : .white.opacity(0.05))
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.purple.opacity(0.6) : .clear, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Accessory Item Button
struct AccessoryItemButton: View {
    private static let previewCornerRadius: CGFloat = 10
    private static let previewSize: CGFloat = 54
    
    let item: AccessoryItem
    let isOwned: Bool
    let isEquipped: Bool
    let canAfford: Bool
    let isPreviewing: Bool
    let hasPro: Bool
    let action: () -> Void
    
    private var itemPreviewRoundedRect: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.previewCornerRadius, style: .continuous)
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // 3D model preview (rounded rect — not circular)
                ZStack {
                    if item.id != "bunnyears" {
                        itemPreviewRoundedRect
                            .fill(backgroundColor)
                            .frame(width: Self.previewSize, height: Self.previewSize)
                    }
                    
                    if item.id == "bunnyears" {
                        Image("BunnyEarsReference")
                            .resizable()
                            .scaledToFit()
                            .padding(2)
                            .frame(width: Self.previewSize, height: Self.previewSize)
                            .clipShape(itemPreviewRoundedRect)
                    } else if let modelFileName = item.modelFileName, !modelFileName.isEmpty {
                        HatPreview3DView(fileName: modelFileName)
                            .frame(width: Self.previewSize, height: Self.previewSize)
                            .clipShape(itemPreviewRoundedRect)
                    } else {
                        Text(item.emoji)
                            .font(.system(size: 32))
                    }
                    
                    if isEquipped {
                        itemPreviewRoundedRect
                            .stroke(Color(hex: "1a5f1a"), lineWidth: 2.5)
                            .frame(width: Self.previewSize, height: Self.previewSize)
                        
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "1a5f1a"))
                            .background(Circle().fill(.black))
                            .offset(x: 18, y: -18)
                    }
                    
                    if item.isProOnly && !hasPro {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .background(
                                        Circle()
                                            .fill(Color.black.opacity(0.7))
                                            .frame(width: 18, height: 18)
                                    )
                                    .offset(x: -4, y: -4)
                            }
                        }
                        .frame(width: Self.previewSize, height: Self.previewSize)
                    }
                }
                
                // Name
                Text(localizedAccessoryName(id: item.id))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 0, maxWidth: 78, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                
                // Status / Price
                if isOwned {
                    Text(isEquipped ? L("common.equipped") : L("common.tapToEquip"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isEquipped ? .green : Color.primary.opacity(0.8))
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                } else if item.isProOnly && !hasPro {
                    // Pro-only item without subscription
                    if isPreviewing {
                        Text(L("common.unlockOnPro"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    } else {
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 10))
                                Text("PRO")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                            
                            Text(L("common.tapToPreview"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                        }
                    }
                } else {
                    if isPreviewing {
                        Text(L("common.tapToBuy"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: "1a5f1a"))
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    } else {
                    VStack(spacing: 4) {
                        HStack(spacing: 3) {
                            Text("₵")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: "B8860B"))
                            Text(formattedItemCost(item.cost))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(canAfford ? Color(hex: "1a5f1a") : Color.primary.opacity(0.7))
                        }
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                        
                        Text(L("common.tapToPreview"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(isOwned ? 0.1 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(borderColor, lineWidth: 1)
                    )
            )
            .opacity(1) // Always visible now for preview
        }
        .buttonStyle(ScaleButtonStyle())
        .overlay(
            // Chinese New Year "NEW!" badge for Red Lantern
            Group {
                if item.id == "redlantern" && Date.isChineseNewYearEvent2026() {
                    VStack {
                        HStack {
                            Spacer()
                            Text(L("common.new"))
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(Color(hex: "8B0000"))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
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
                                .offset(x: -5, y: 5)
                        }
                        Spacer()
                    }
                }
            }
        )
        .overlay(
            // Green ring when previewing (try on, not owned); gold ring when owned; CNY gold for Red Lantern
            Group {
                if isOwned {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.5
                        )
                } else if isPreviewing {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(hex: "1a5f1a"), lineWidth: 2.5)
                } else if item.id == "redlantern" && Date.isChineseNewYearEvent2026() {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                }
            }
        )
    }
    
    private var backgroundColor: Color {
        if isEquipped {
            return Color(hex: "1a5f1a").opacity(0.25)
        } else if isPreviewing {
            return Color(hex: "1a5f1a").opacity(0.2)
        } else if isOwned {
            return Color(hex: "FFD700").opacity(0.15)
        } else {
            return .white.opacity(0.1)
        }
    }
    
    private var borderColor: Color {
        if isEquipped {
            return Color(hex: "1a5f1a").opacity(0.5)
        } else if isPreviewing {
            return Color(hex: "1a5f1a").opacity(0.5)
        } else if isOwned {
            return Color(hex: "FFD700").opacity(0.5)
        } else {
            return .white.opacity(0.1)
        }
    }
}

// MARK: - 3D Hat Preview using SceneKit (more stable for multiple instances)
struct HatPreview3DView: View {
    let fileName: String
    
    var body: some View {
        HatPreviewSceneView(fileName: fileName)
    }
}

// SceneKit-based preview - much more stable than RealityKit for multiple simultaneous views
struct HatPreviewSceneView: UIViewRepresentable {
    let fileName: String
    
    // Preview-specific scale adjustments for items panel (matching original RealityKit values)
    private func previewScale(for fileName: String) -> Float {
        if fileName.contains("Santa") {
            return 1.0
        } else if fileName.contains("Cowboy") {
            return 0.3
        } else if fileName.contains("Wizard") {
            return 0.15
        } else if fileName.contains("Pirate") {
            return 0.15
        } else if fileName.contains("Propeller") {
            return 0.15
        } else if fileName.contains("Bunny") {
            // Face-on framing: both ears + pink inner visible in the item preview.
            return 0.042
        } else if fileName.contains("Fox") {
            return 0.35
        } else if fileName.contains("Frog") {
            return 0.35
        } else if fileName.contains("Baseball") {
            return 0.2
        } else if fileName.contains("Sombrero") {
            return 0.2
        } else if fileName.contains("Cone") {
            return 0.4
        } else if fileName.contains("Pizza") {
            return 0.5
        } else if fileName.contains("red-lantern") {
            return 0.6
        } else if fileName.contains("Football") {
            return 0.45
        } else {
            return 0.2 // Default
        }
    }
    
    // Preview-specific position adjustments (matching original RealityKit values)
    private func previewPosition(for fileName: String) -> SCNVector3 {
        if fileName.contains("Baseball") {
            return SCNVector3(0.1, 0.0, 0.0) // More to the right
        } else if fileName.contains("Santa") {
            return SCNVector3(0, 0.1, 0)
        } else if fileName.contains("Pirate") {
            return SCNVector3(0, 0.1, 0) // Move up
        } else if fileName.contains("Wizard") {
            return SCNVector3(0, -0.1, 0) // Move down
        } else if fileName.contains("Cone") {
            return SCNVector3(0, 0.0, 0.0) // Centered
        } else if fileName.contains("Pizza") {
            return SCNVector3(0, 0.0, 0.0) // Centered
        } else if fileName.contains("Bunny") {
            return SCNVector3(0, 0.035, 0)
        } else {
            return SCNVector3(0, 0.0, 0.0) // Default centered
        }
    }
    
    /// Per-hat preview orientation so thumbnails match how items read on the capybara / face the user.
    private func applyPreviewRotation(to node: SCNNode, fileName: String) {
        node.eulerAngles = SCNVector3(0, 0, 0)
        if fileName.contains("Bunny") {
            // Face-on for this asset: stand ears upright, then quarter-turn so broad surfaces face camera.
            node.eulerAngles.x = 0
            node.eulerAngles.y = .pi / 2
            node.eulerAngles.z = .pi / 2
        } else if fileName.contains("Frog") {
            node.eulerAngles.y = .pi / 2
        }
    }
    
    // Camera position based on hat type (matching original RealityKit values)
    private func cameraPosition(for fileName: String) -> SCNVector3 {
        if fileName.contains("Propeller") {
            return SCNVector3(0, 0.1, 1.0)
        } else if fileName.contains("Pirate") {
            return SCNVector3(0, 0.1, 1.5)
        } else if fileName.contains("Cowboy") {
            return SCNVector3(0, 0.1, 0.8)
        } else if fileName.contains("Bunny") {
            // Unused when look(at:) is applied in makeUIView for Bunny.
            return SCNVector3(0, 0.06, 0.5)
        } else if fileName.contains("Santa") || fileName.contains("Fox") || fileName.contains("Frog") {
            return SCNVector3(0, 0.1, 0.3)
        } else {
            return SCNVector3(0, 0.1, 0.6)
        }
    }
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView(frame: .zero)
        sceneView.backgroundColor = .clear
        sceneView.autoenablesDefaultLighting = true
        sceneView.allowsCameraControl = false
        
        // Create scene
        let scene = SCNScene()
        sceneView.scene = scene
        
        // Set up camera with position matching original RealityKit implementation
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 10.0
        if fileName.contains("Bunny") {
            // Straight-on to ear fronts: camera level with hat, looking along −Z.
            let p = previewPosition(for: fileName)
            let eyeY = p.y + 0.025
            let focus = SCNVector3(p.x, eyeY, p.z)
            cameraNode.position = SCNVector3(p.x, eyeY, 0.52)
            cameraNode.look(at: focus, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        } else {
            cameraNode.position = cameraPosition(for: fileName)
        }
        scene.rootNode.addChildNode(cameraNode)
        
        // Add lighting matching original implementation
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 1500
        light.position = SCNVector3(0.5, 1, 1)
        light.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(light)
        
        // Add ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .directional
        ambientLight.light?.intensity = 500
        ambientLight.position = SCNVector3(-0.5, -0.5, -1)
        ambientLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(ambientLight)
        
        if fileName.contains("Bunny") {
            let fillLight = SCNNode()
            fillLight.light = SCNLight()
            fillLight.light?.type = .directional
            fillLight.light?.intensity = 1400
            fillLight.light?.castsShadow = false
            fillLight.position = SCNVector3(0, 0.06, 0.72)
            fillLight.look(at: SCNVector3(0, 0.045, 0))
            scene.rootNode.addChildNode(fillLight)
        }
        
        // Load hat model
        guard !fileName.isEmpty else {
            return sceneView
        }
        
        let usdzURL = Bundle.main.url(forResource: fileName, withExtension: "usdz")
            ?? Bundle.main.url(forResource: fileName.replacingOccurrences(of: " ", with: "_"), withExtension: "usdz")
        guard let usdzURL else {
            print("⚠️ Hat file not found: \(fileName).usdz")
            return sceneView
        }
        
        do {
            let hatScene = try SCNScene(url: usdzURL, options: [.checkConsistency: true])
            let sourceRoot = hatScene.rootNode
            
            // Create container node for transformations
            let containerNode = SCNNode()
            
            // Many USDZ hats attach geometry on the root with no child nodes; only cloning children leaves an empty preview.
            if sourceRoot.childNodes.isEmpty {
                containerNode.addChildNode(sourceRoot.clone())
            } else {
                for child in sourceRoot.childNodes {
                    containerNode.addChildNode(child.clone())
                }
            }
            
            // Apply scale (matching original values)
            let scale = previewScale(for: fileName)
            containerNode.scale = SCNVector3(scale, scale, scale)
            
            // Apply position offset (matching original values)
            containerNode.position = previewPosition(for: fileName)
            
            applyPreviewRotation(to: containerNode, fileName: fileName)
            
            scene.rootNode.addChildNode(containerNode)
            
        } catch {
            print("❌ Failed to load hat: \(error.localizedDescription)")
        }
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        // No updates needed for static preview
    }
}

// MARK: - Looks Good Modal
struct LooksGoodModal: View {
    let itemName: String
    let itemCost: Int
    let currentCoins: Int
    let onBuyNow: () -> Void
    let onDismiss: () -> Void
    
    private static let cream = Color(hex: "FFF8E7")
    private static let primaryText = Color(hex: "1a1a2e")
    private static let secondaryText = Color(hex: "5A5A5A")
    private static let settingsGreen = Color(hex: "1a5f1a")
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            
            VStack(spacing: 20) {
                Text(L("common.looksGood"))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Self.primaryText)
                    .multilineTextAlignment(.center)
                
                Text(itemName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Self.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(L("common.cost"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Self.secondaryText)
                        Text("₵\(formattedItemCost(itemCost))")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(hex: "B8860B"))
                        Text("•")
                            .foregroundStyle(Self.secondaryText)
                        Text(L("common.youHave"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Self.secondaryText)
                        Text("₵\(formattedItemCost(currentCoins))")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Self.primaryText)
                    }
                }
                
                Button(action: {
                    HapticManager.shared.buttonPress()
                    onBuyNow()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "cart.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(L("common.buyNow"))
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Self.settingsGreen)
                    )
                    .shadow(color: Self.settingsGreen.opacity(0.4), radius: 8, x: 0, y: 4)
                }
                
                Button(action: {
                    HapticManager.shared.buttonPress()
                    onDismiss()
                }) {
                    Text(L("common.maybeLater"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Self.settingsGreen)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Self.cream)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Self.primaryText.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Insufficient Coins Overlay
struct InsufficientCoinsOverlay: View {
    let itemName: String
    let itemCost: Int
    let currentCoins: Int
    let onBuyCoins: () -> Void
    let onDismiss: () -> Void
    
    private static let cream = Color(hex: "FFF8E7")
    private static let primaryText = Color(hex: "1a1a2e")
    private static let secondaryText = Color(hex: "5A5A5A")
    private static let settingsGreen = Color(hex: "1a5f1a")
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            
            VStack(spacing: 20) {
                Text(L("common.looksGood"))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Self.primaryText)
                    .multilineTextAlignment(.center)
                
                Text(itemName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Self.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                
                VStack(spacing: 8) {
                    Text(L("common.youNeedMoreCoins"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Self.primaryText)
                        .multilineTextAlignment(.center)
                    
                    HStack(spacing: 6) {
                        Text(L("common.cost"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Self.secondaryText)
                        Text("₵\(formattedItemCost(itemCost))")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(hex: "B8860B"))
                        Text("•")
                            .foregroundStyle(Self.secondaryText)
                        Text(L("common.youHave"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Self.secondaryText)
                        Text("₵\(formattedItemCost(currentCoins))")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Self.primaryText)
                    }
                }
                
                Button(action: {
                    HapticManager.shared.buttonPress()
                    onBuyCoins()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "cart.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(L("common.buyMoreCoins"))
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Self.settingsGreen)
                    )
                    .shadow(color: Self.settingsGreen.opacity(0.4), radius: 8, x: 0, y: 4)
                }
                
                Button(action: {
                    HapticManager.shared.buttonPress()
                    onDismiss()
                }) {
                    Text(L("common.maybeLater"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Self.settingsGreen)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Self.cream)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Self.primaryText.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Hat Equip Error Overlay
struct HatEquipErrorOverlay: View {
    let onDismiss: () -> Void
    
    private static let cream = Color(hex: "FFF8E7")
    private static let primaryText = Color(hex: "1a1a2e")
    private static let secondaryText = Color(hex: "5A5A5A")
    private static let settingsGreen = Color(hex: "1a5f1a")
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            
            VStack(spacing: 20) {
                Text(L("hat.oneAtATime"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Self.primaryText)
                    .multilineTextAlignment(.center)
                
                Text(L("hat.deselectCurrent"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Self.secondaryText)
                    .multilineTextAlignment(.center)
                
                Button(action: {
                    HapticManager.shared.buttonPress()
                    onDismiss()
                }) {
                    Text("OK")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Self.settingsGreen)
                        )
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Self.cream)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Self.primaryText.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 32)
        }
    }
}

#Preview {
    ZStack {
        AppColors.background
            .ignoresSafeArea()
        
        ItemsPanel()
            .environmentObject(GameManager())
    }
}

