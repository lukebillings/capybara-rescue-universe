import SwiftUI
import RealityKit
import ARKit

// MARK: - 3D Capybara View (iOS 17+ compatible)
@available(iOS 17.0, *)
struct Capybara3DView: View {
    let emotion: CapybaraEmotion
    let equippedAccessories: [String]
    let previewingAccessoryId: String?
    let onPet: () -> Void
    let initialRotation: Double?
    
    @State private var isPressed = false
    @State private var heartOffset: CGFloat = 0
    @State private var showHeart = false
    @State private var rotationAngle: Double = 0
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragValue: CGFloat = 0
    @State private var useProceduralModel = false // Try to load USDZ model first
    @State private var hasAppliedInitialRotation = false
    /// Idle rotation: slow right→left sway over front 180° only. When user drags, we resume from current angle.
    @State private var isUserDragging = false
    @State private var idleRotationStartTime = Date()
    @State private var idlePhase: Double = 0
    @State private var idleRotationTimer: Timer?
    
    /// Front 180° range: right = +90°, left = -90°. Full cycle (right→left→right) duration in seconds.
    private static let idleRotationPeriod: Double = 16
    
    init(emotion: CapybaraEmotion, equippedAccessories: [String], previewingAccessoryId: String?, onPet: @escaping () -> Void, initialRotation: Double? = nil) {
        self.emotion = emotion
        self.equippedAccessories = equippedAccessories
        self.previewingAccessoryId = previewingAccessoryId
        self.onPet = onPet
        self.initialRotation = initialRotation
    }
    
    var body: some View {
        ZStack {
            // 3D Capybara Model (iOS 17+ compatible using ARView)
            RealityKitView(
                rotationAngle: $rotationAngle,
                useProceduralModel: useProceduralModel,
                equippedHat: equippedHat,
                equippedGroundItems: equippedGroundItems,
                previewingAccessoryId: previewingAccessoryId,
                onModelLoaded: { }
            )
            .frame(width: 400, height: 500) // Increased height to show full face
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isUserDragging = true
                        let delta = value.translation.width - lastDragValue
                        rotationAngle += Double(delta) * 0.5 // Adjust sensitivity
                        rotationAngle = min(90, max(-90, rotationAngle)) // Clamp to front 180°
                        lastDragValue = value.translation.width
                    }
                    .onEnded { _ in
                        lastDragValue = 0
                        rotationAngle = min(90, max(-90, rotationAngle))
                        // Resume idle rotation from current angle (phase so cos matches)
                        let clamped = max(-1, min(1, rotationAngle / 90))
                        idlePhase = acos(clamped)
                        idleRotationStartTime = Date()
                        isUserDragging = false
                    }
            )
            
            // Accessories overlay removed - all accessories are now 3D models in Garden Items category
            
            // Floating heart animation
            if showHeart {
                Text("❤️")
                    .font(.system(size: 40))
                    .offset(y: heartOffset - 100)
                    .opacity(heartOffset < -50 ? 0 : 1)
                    .animation(.easeOut(duration: 0.8), value: heartOffset)
            }
        }
        .onTapGesture {
            handlePet()
        }
        .onLongPressGesture(minimumDuration: 0.1, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .onAppear {
            // Apply initial rotation on first load
            if !hasAppliedInitialRotation {
                if let initialRotation = initialRotation {
                    rotationAngle = min(90, max(-90, initialRotation))
                } else {
                    rotationAngle = 30
                }
                hasAppliedInitialRotation = true
                idlePhase = acos(max(-1, min(1, rotationAngle / 90)))
                idleRotationStartTime = Date()
            }
            // Slow idle rotation: right → left → right over front 180° only
            idleRotationTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                guard !isUserDragging else { return }
                let elapsed = Date().timeIntervalSince(idleRotationStartTime)
                let angle = 90 * cos(2 * .pi * elapsed / Self.idleRotationPeriod + idlePhase)
                rotationAngle = angle
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            idleRotationTimer = timer
        }
        .onDisappear {
            idleRotationTimer?.invalidate()
            idleRotationTimer = nil
        }
        .onChange(of: initialRotation) { oldValue, newValue in
            // Apply rotation when it becomes available
            if let newRotation = newValue, !hasAppliedInitialRotation {
                rotationAngle = newRotation
                hasAppliedInitialRotation = true
            }
        }
    }
    
    private var equippedHat: AccessoryItem? {
        // First check if previewing a hat
        if let previewId = previewingAccessoryId,
           let previewItem = AccessoryItem.allItems.first(where: { $0.id == previewId }),
           previewItem.isHat {
            return previewItem
        }
        // Otherwise find equipped hat - wearable item
        return AccessoryItem.allItems.first { item in
            equippedAccessories.contains(item.id) && item.isHat
        }
    }
    
    private var equippedGroundItems: [AccessoryItem] {
        var items: [AccessoryItem] = []
        
        // Add previewing ground item if any
        if let previewId = previewingAccessoryId,
           let previewItem = AccessoryItem.allItems.first(where: { $0.id == previewId }),
           !previewItem.isHat && previewItem.modelFileName != nil {
            items.append(previewItem)
        }
        
        // Add equipped ground items (like Sunflower) - items that go on the ground
        let equipped = AccessoryItem.allItems.filter { item in
            equippedAccessories.contains(item.id) && !item.isHat && item.modelFileName != nil
        }
        items.append(contentsOf: equipped)
        
        return items
    }
    
    private func handlePet() {
        HapticManager.shared.petCapybara()
        onPet()
        
        // Show heart animation
        showHeart = true
        heartOffset = 0
        
        withAnimation(.easeOut(duration: 0.8)) {
            heartOffset = -80
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            showHeart = false
            heartOffset = 0
        }
    }
    
}

// MARK: - ARView host (SwiftUI .position() often leaves ARView at 0×0 without this)
@available(iOS 17.0, *)
final class RealityKitHostingView: UIView {
    let arView: ARView
    
    init(arView: ARView) {
        self.arView = arView
        super.init(frame: .zero)
        backgroundColor = .clear
        arView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arView)
        NSLayoutConstraint.activate([
            arView.leadingAnchor.constraint(equalTo: leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: trailingAnchor),
            arView.topAnchor.constraint(equalTo: topAnchor),
            arView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - iOS 17 Compatible RealityKit View Wrapper
@available(iOS 17.0, *)
struct RealityKitView: UIViewRepresentable {
    @Binding var rotationAngle: Double
    var useProceduralModel: Bool = false
    var equippedHat: AccessoryItem?
    var equippedGroundItems: [AccessoryItem] = []
    var previewingAccessoryId: String?
    var isUserInteractionEnabled: Bool = true
    let onModelLoaded: () -> Void
    
    // Hat positioning constants - single source of truth
    // Positive Z moves hat forward toward camera (onto head, not back)
    // Hat positioning constants - single source of truth
    // Positive Z moves hat forward toward camera (onto head, not back)
    private static let hatPosition: SIMD3<Float> = [-0.1, 4.8, 2.5]
    private static let sombreroPosition: SIMD3<Float> = [-0.1, 4, 2.2] // Lower Y for sombrero and z
    private static let baseballcapPosition: SIMD3<Float> = [0.3, 4.2, 2.4] // "baseballcap" matches hat ID in GameState
    private static let cowboyhatPosition: SIMD3<Float> = [-0.1, 4, 2.2]
    private static let tophatPosition: SIMD3<Float> = [0, 4.8, 2.4]
    private static let wizardhatPosition: SIMD3<Float> = [-0.1, 3.9, 2.3]
    private static let piratehatPosition: SIMD3<Float> = [-0.1, 4.4, 2.2]
    private static let propellerhatPosition: SIMD3<Float> = [0, 4.2, 2.5]
    private static let froghatPosition: SIMD3<Float> = [0, 4.3, 2.2]
    private static let bunnyearsPosition: SIMD3<Float> = [0, 4.4, 2.25]
    private static let foxhatPosition: SIMD3<Float> = [0, 4.3, 1.9]
    private static let santahatPosition: SIMD3<Float> = [-0.1, 4.8, 2.5]

    // Hat scaling constants
    private static let tophatScale: SIMD3<Float> = [0.5, 0.5, 0.5]
    private static let santahatScale: SIMD3<Float> = [10, 10, 10] // 10x bigger than tophat
    private static let sombreroScale: SIMD3<Float> = [0.8, 0.8, 0.8]
    private static let baseballcapScale: SIMD3<Float> = [0.8, 0.8, 0.8]
    private static let cowboyhatScale: SIMD3<Float> = [2, 2, 2]
    private static let wizardhatScale: SIMD3<Float> = [0.5, 0.5, 0.5]
    private static let piratehatScale: SIMD3<Float> = [0.2, 0.2, 0.2]
    private static let propellerhatScale: SIMD3<Float> = [0.2, 0.2, 0.2]
    private static let froghatScale: SIMD3<Float> = [2, 2, 2]
    private static let bunnyearsScale: SIMD3<Float> = [0.01, 0.01, 0.01]
    private static let foxhatScale: SIMD3<Float> = [2.8, 2.8, 2.8]
    private static let conePosition: SIMD3<Float> = [0, 4.5, 2.4]
    private static let coneScale: SIMD3<Float> = [1.2, 1.2, 1.2]
    private static let pizzahatPosition: SIMD3<Float> = [0, 4.25, 2.4]
    private static let pizzahatScale: SIMD3<Float> = [3.0, 3.0, 3.0]
    private static let redlanternPosition: SIMD3<Float> = [0, 4.9, 2.4] // Sphere pivot at center; Y above pizza hat so base clears the head
    private static let redlanternScale: SIMD3<Float> = [2.5, 2.5, 2.5]
    
    private func hatPosition(for hatId: String?) -> SIMD3<Float> {
        guard let hatId = hatId else { return Self.hatPosition }
        
        switch hatId {
        case "sombrerohat":
            return Self.sombreroPosition
        case "baseballcap":
            return Self.baseballcapPosition
        case "cowboyhat":
            return Self.cowboyhatPosition
        case "tophat":
            return Self.tophatPosition
        case "wizardhat":
            return Self.wizardhatPosition
        case "piratehat":
            return Self.piratehatPosition
        case "propellerhat":
            return Self.propellerhatPosition
        case "froghat":
            return Self.froghatPosition
        case "bunnyears":
            return Self.bunnyearsPosition
        case "foxhat":
            return Self.foxhatPosition
        case "santahat":
            return Self.santahatPosition
        case "cone":
            return Self.conePosition
        case "pizzahat":
            return Self.pizzahatPosition
        case "redlantern":
            return Self.redlanternPosition
        default:
            return Self.hatPosition
        }
    }
    
    private func hatScale(for hatId: String?) -> SIMD3<Float> {
        guard let hatId = hatId else { return Self.tophatScale }
        
        switch hatId {
        case "tophat":
            return Self.tophatScale
        case "santahat":
            return Self.santahatScale
        case "sombrerohat":
            return Self.sombreroScale
        case "baseballcap":
            return Self.baseballcapScale
        case "cowboyhat":
            return Self.cowboyhatScale
        case "wizardhat":
            return Self.wizardhatScale
        case "piratehat":
            return Self.piratehatScale
        case "propellerhat":
            return Self.propellerhatScale
        case "froghat":
            return Self.froghatScale
        case "bunnyears":
            return Self.bunnyearsScale
        case "foxhat":
            return Self.foxhatScale
        case "cone":
            return Self.coneScale
        case "pizzahat":
            return Self.pizzahatScale
        case "redlantern":
            return Self.redlanternScale
        default:
            return Self.tophatScale
        }
    }
    
    private func hatRotation(for hatId: String?) -> simd_quatf {
        guard let hatId = hatId else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) } // No rotation
        
        switch hatId {
        case "froghat":
            // Rotate 90 degrees around Y axis to face forward
            return simd_quatf(angle: Float.pi / 2, axis: [0, 1, 0])
        case "pizzahat":
            // Rotate 90 degrees around Z axis to lay flat
            return simd_quatf(angle: Float.pi / 2, axis: [0, 0, 1])
        default:
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) // No rotation for other hats
        }
    }
    
    func makeUIView(context: Context) -> RealityKitHostingView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.isUserInteractionEnabled = isUserInteractionEnabled
        arView.backgroundColor = .clear // Transparent background
        
        // Disable problematic rendering features
        arView.environment.background = .color(.clear)
        arView.renderOptions = [.disableDepthOfField, .disableMotionBlur, .disableAREnvironmentLighting]
        
        // Create anchor for the model
        let anchor = AnchorEntity(world: [0, 0, 0])
        arView.scene.addAnchor(anchor)
        
        // Set up a custom camera positioned further back to see the whole model
        let camera = PerspectiveCamera()
        camera.position = [0, 0.4, 3.0] // Camera: x=center, y=higher up, z=back much further to see full model including head
        // Set camera clipping planes to prevent hats/accessories from being cut off
        camera.camera.near = 0.01  // Very close near plane to avoid clipping nearby objects
        camera.camera.far = 100.0  // Far plane for distant objects
        let cameraAnchor = AnchorEntity(world: [0, 0, 0])
        cameraAnchor.addChild(camera)
        arView.scene.addAnchor(cameraAnchor)
        
        // Add simple ambient lighting (no shadows)
        let light = DirectionalLight()
        light.light.intensity = 800
        light.position = [0.5, 1, 1]
        light.light.isRealWorldProxy = false // Disable real-world lighting
        let lightAnchor = AnchorEntity(world: [0, 0, 0])
        lightAnchor.addChild(light)
        arView.scene.addAnchor(lightAnchor)
        
        // Try to load the USDZ model first
        if !useProceduralModel, let model = loadCapybaraModel() {
            model.scale = [0.30, 0.30, 0.30] // Slightly smaller so hats don't clip at top
            model.position = [0, -0.1, 0] // Slightly lower to center better in view
            
            // Try to disable shadows on all entities to avoid rendering pipeline issues
            disableShadowsRecursively(on: model)
            
            anchor.addChild(model)
            context.coordinator.modelEntity = model
            
            // Load and attach hat if equipped
            if let hat = equippedHat {
                print("🎩 Attempting to load hat: \(hat.name), fileName: \(hat.modelFileName ?? "nil")")
                if let hatModel = loadHatModel(fileName: hat.modelFileName) {
                    hatModel.position = hatPosition(for: hat.id)
                    hatModel.scale = hatScale(for: hat.id)
                    hatModel.orientation = hatRotation(for: hat.id)
                    model.addChild(hatModel)
                    context.coordinator.hatEntity = hatModel
                    context.coordinator.currentHatId = hat.id
                    print("✅ \(hat.name) loaded and attached to capybara's head")
                } else {
                    print("❌ Failed to load hat model for: \(hat.name)")
                }
            } else {
                print("⚠️ No hat equipped or equippedHat is nil")
            }
            
            // Load and position ground items (like Sunflower) next to capybara
            // Attach to model so they rotate with the capybara
            if let model = context.coordinator.modelEntity {
                loadGroundItems(items: equippedGroundItems, model: model, coordinator: context.coordinator)
            }
        } else if let proceduralModel = createProceduralCapybara() {
            // Fallback to procedural model if USDZ fails to load
            proceduralModel.scale = [0.30, 0.30, 0.30] // Slightly smaller so hats don't clip at top
            proceduralModel.position = [0, -0.1, 0] // Slightly lower to center better in view
            anchor.addChild(proceduralModel)
            context.coordinator.modelEntity = proceduralModel
            
            // Load and attach hat if equipped
            if let hat = equippedHat {
                print("🎩 Attempting to load hat: \(hat.name), fileName: \(hat.modelFileName ?? "nil")")
                if let hatModel = loadHatModel(fileName: hat.modelFileName) {
                    hatModel.position = hatPosition(for: hat.id)
                    hatModel.scale = hatScale(for: hat.id)
                    hatModel.orientation = hatRotation(for: hat.id)
                    proceduralModel.addChild(hatModel)
                    context.coordinator.hatEntity = hatModel
                    context.coordinator.currentHatId = hat.id
                    print("✅ \(hat.name) loaded and attached to procedural capybara")
                } else {
                    print("❌ Failed to load hat model for: \(hat.name)")
                }
            }
            
            // Load and position ground items (like Sunflower) next to capybara
            // Attach to model so they rotate with the capybara
            if let model = context.coordinator.modelEntity {
                loadGroundItems(items: equippedGroundItems, model: model, coordinator: context.coordinator)
            }
        }
        
        notifyModelLoadedIfNeeded(coordinator: context.coordinator)
        return RealityKitHostingView(arView: arView)
    }
    
    func updateUIView(_ uiView: RealityKitHostingView, context: Context) {
        let arView = uiView.arView
        arView.isUserInteractionEnabled = isUserInteractionEnabled
        
        // Update rotation
        if let model = context.coordinator.modelEntity {
            let radians = rotationAngle * .pi / 180
            model.orientation = simd_quatf(angle: Float(radians), axis: [0, 1, 0])
        }
        
        // Update hat if equipped status changed
        if let hat = equippedHat {
            print("🎩 Update: Hat equipped - \(hat.name)")
            // Check if hat ID has changed - if so, remove old hat first
            if let currentHatId = context.coordinator.currentHatId, currentHatId != hat.id {
                // Hat ID changed - remove old hat
                if let hatEntity = context.coordinator.hatEntity {
                    hatEntity.removeFromParent()
                    context.coordinator.hatEntity = nil
                    context.coordinator.currentHatId = nil
                    print("✅ Old hat removed (switching from \(currentHatId) to \(hat.id))")
                }
            }
            
            // Only load and attach if not already attached
            if context.coordinator.hatEntity == nil, let model = context.coordinator.modelEntity {
                if let hatModel = loadHatModel(fileName: hat.modelFileName) {
                    hatModel.position = hatPosition(for: hat.id)
                    hatModel.scale = hatScale(for: hat.id)
                    hatModel.orientation = hatRotation(for: hat.id)
                    model.addChild(hatModel)
                    context.coordinator.hatEntity = hatModel
                    context.coordinator.currentHatId = hat.id
                    print("✅ \(hat.name) attached to capybara's head")
                } else {
                    print("❌ Failed to load hat model in update")
                }
            } else if let hatEntity = context.coordinator.hatEntity, context.coordinator.currentHatId == hat.id {
                // Update hat position if it already exists and is the same hat (in case model was reloaded)
                hatEntity.position = hatPosition(for: hat.id)
                hatEntity.scale = hatScale(for: hat.id)
            }
        } else {
            // Remove hat if unequipped
            if let hatEntity = context.coordinator.hatEntity {
                hatEntity.removeFromParent()
                context.coordinator.hatEntity = nil
                context.coordinator.currentHatId = nil
                print("✅ Hat removed")
            }
        }
        
        // Update ground items - attach to model so they rotate with capybara
        if let model = context.coordinator.modelEntity {
            updateGroundItems(items: equippedGroundItems, model: model, coordinator: context.coordinator)
        }
        
        notifyModelLoadedIfNeeded(coordinator: context.coordinator)
    }
    
    // Load and position ground items on the ground next to capybara
    // Attach to model so they rotate with the capybara
    private func loadGroundItems(items: [AccessoryItem], model: ModelEntity, coordinator: Coordinator) {
        for (index, item) in items.enumerated() {
            if let groundModel = loadHatModel(fileName: item.modelFileName) {
                // Scale for ground items - 10x bigger
                groundModel.scale = [2.0, 2.0, 2.0] // 10x bigger (0.2 * 10 = 2.0)
                
                // Position on ground to the right side of capybara
                // Right side = positive X value
                // Space multiple items along the right side - moved further away since it's 10x bigger
                // Y position aligns green stalk of sunflower with capybara's feet
                let x: Float = 2.0 + Float(index) * 1.0 // Start at 2.0 (further to the right), space items 1.0 apart
                let z: Float = 0.0 // Center front/back
                groundModel.position = [x, 1.0, z] // Green stalk level with capybara's feet
                
                // Add as child of capybara model so it rotates with it
                model.addChild(groundModel)
                
                // Store in coordinator
                if coordinator.groundItemEntities[item.id] == nil {
                    coordinator.groundItemEntities[item.id] = groundModel
                }
                
                print("✅ \(item.name) loaded and positioned on right side at [\(x), 0.3, \(z)]")
            }
        }
    }
    
    // Update ground items when equipped status changes
    // Attach to model so they rotate with the capybara
    private func updateGroundItems(items: [AccessoryItem], model: ModelEntity, coordinator: Coordinator) {
        // Get current item IDs
        let currentItemIds = Set(items.map { $0.id })
        let existingItemIds = Set(coordinator.groundItemEntities.keys)
        
        // Remove items that are no longer equipped
        for itemId in existingItemIds {
            if !currentItemIds.contains(itemId), let entity = coordinator.groundItemEntities[itemId] {
                entity.removeFromParent()
                coordinator.groundItemEntities.removeValue(forKey: itemId)
                print("✅ Ground item removed: \(itemId)")
            }
        }
        
        // Add new items
        for item in items {
            if coordinator.groundItemEntities[item.id] == nil {
                if let groundModel = loadHatModel(fileName: item.modelFileName) {
                    groundModel.scale = [2.0, 2.0, 2.0] // 10x bigger (0.2 * 10 = 2.0)
                    
                    // Position on ground to the right side of capybara
                    // Right side = positive X value
                    // Space multiple items along the right side - moved further away since it's 10x bigger
                    // Y position aligns green stalk of sunflower with capybara's feet
                    let existingCount = coordinator.groundItemEntities.count
                    let x: Float = 3.0 + Float(existingCount) * 1.0 // Start at 2.0 (further to the right), space items 1.0 apart
                    let z: Float = 0.0 // Center front/back
                    groundModel.position = [x, 2.5, z] // Green stalk level with capybara's feet
                    
                    // Add as child of capybara model so it rotates with it
                    model.addChild(groundModel)
                    coordinator.groundItemEntities[item.id] = groundModel
                    print("✅ \(item.name) added to right side at [\(x), 0.3, \(z)]")
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var modelEntity: ModelEntity?
        var hatEntity: ModelEntity?
        var currentHatId: String? // Track current hat ID to detect changes
        var groundItemEntities: [String: ModelEntity] = [:] // Store ground items by item ID
        var didNotifyModelLoaded = false
    }
    
    private func notifyModelLoadedIfNeeded(coordinator: Coordinator) {
        guard coordinator.modelEntity != nil, !coordinator.didNotifyModelLoaded else { return }
        coordinator.didNotifyModelLoaded = true
        // Brief delay so SwiftUI can lay out the ARView host before we treat the model as visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onModelLoaded()
        }
    }
    
    private func loadHatModel(fileName: String?) -> ModelEntity? {
        guard let fileName = fileName else { 
            print("⚠️ loadHatModel: fileName is nil")
            return nil 
        }
        
        // Try loading USDZ file (e.g., "Tophat" -> "Tophat.usdz")
        print("🔍 Looking for hat model: \(fileName).usdz")
        if let usdzURL = Bundle.main.url(forResource: fileName, withExtension: "usdz") {
            print("✅ Found \(fileName).usdz at: \(usdzURL.path)")
            do {
                let loadedEntity = try Entity.load(contentsOf: usdzURL)
                
                // Create a container ModelEntity to hold the full hierarchy
                // This preserves all child entities and their visual components
                let containerModel = ModelEntity()
                
                // Clone all children from the loaded entity to preserve full model
                for child in loadedEntity.children {
                    containerModel.addChild(child.clone(recursive: true))
                }
                
                // If the loaded entity itself has model components, we need to handle it
                if let directModel = loadedEntity as? ModelEntity {
                    return directModel
                }
                
                // If container has children, return it
                if !containerModel.children.isEmpty {
                    print("✅ Loaded \(fileName) with \(containerModel.children.count) children")
                    return containerModel
                }
                
                // Fallback: try to find any ModelEntity in hierarchy
                if let anyModel = findFirstModelEntity(in: loadedEntity) {
                    return anyModel
                }
            } catch {
                print("❌ Failed to load hat USDZ model: \(error.localizedDescription)")
            }
        } else {
            print("⚠️ \(fileName).usdz not found in bundle")
        }
        
        return nil
    }
    
    // Helper function to try to simplify materials (shadows are handled at render level)
    private func disableShadowsRecursively(on entity: Entity) {
        // Shadows are controlled at the ARView render level, not per entity
        // The renderOptions we set should handle this
        // This function is kept for potential future material modifications
        if entity is ModelEntity {
            // Could modify materials here if needed
        }
        
        // Recursively process children
        for child in entity.children {
            disableShadowsRecursively(on: child)
        }
    }
    
    private func loadCapybaraModel() -> ModelEntity? {
        // Try loading USDZ first (preferred format for iOS)
        if let usdzURL = Bundle.main.url(forResource: "Capybara", withExtension: "usdz") {
            print("✅ Found Capybara.usdz at: \(usdzURL.path)")
            do {
                let modelEntity = try Entity.load(contentsOf: usdzURL)
                print("✅ Successfully loaded USDZ model")
                
                // Check if it's a direct ModelEntity
                if let model = modelEntity as? ModelEntity {
                    print("✅ Using direct ModelEntity")
                    return model
                }
                
                // If it's a scene, get the first model entity
                print("Model has \(modelEntity.children.count) children")
                if let firstModel = modelEntity.children.first(where: { $0 is ModelEntity }) as? ModelEntity {
                    print("✅ Using first child ModelEntity")
                    return firstModel
                }
                
                // Try to find any ModelEntity in the hierarchy
                if let anyModel = findFirstModelEntity(in: modelEntity) {
                    print("✅ Found ModelEntity in hierarchy")
                    return anyModel
                }
                
                print("⚠️ USDZ loaded but no ModelEntity found")
            } catch {
                print("❌ Failed to load USDZ model: \(error)")
            }
        } else {
            print("⚠️ Capybara.usdz not found in bundle")
        }
        
        // Try loading GLB file
        if let glbURL = Bundle.main.url(forResource: "Capybara", withExtension: "glb") {
            print("✅ Found Capybara.glb at: \(glbURL.path)")
            do {
                let modelEntity = try Entity.load(contentsOf: glbURL)
                print("✅ Successfully loaded GLB model")
                
                // Check if it's a direct ModelEntity
                if let model = modelEntity as? ModelEntity {
                    print("✅ Using direct ModelEntity from GLB")
                    return model
                }
                
                // If it's a scene, get the first model entity
                print("GLB Model has \(modelEntity.children.count) children")
                if let firstModel = modelEntity.children.first(where: { $0 is ModelEntity }) as? ModelEntity {
                    print("✅ Using first child ModelEntity from GLB")
                    return firstModel
                }
                
                // Try to find any ModelEntity in the hierarchy
                if let anyModel = findFirstModelEntity(in: modelEntity) {
                    print("✅ Found ModelEntity in GLB hierarchy")
                    return anyModel
                }
                
                print("⚠️ GLB loaded but no ModelEntity found")
            } catch {
                print("❌ Failed to load GLB model: \(error)")
                print("⚠️ GLB files are NOT supported by RealityKit on iOS!")
                print("📦 SOLUTION: Convert Capybara.glb to Capybara.usdz using:")
                print("   1. Reality Converter app (free from Mac App Store)")
                print("   2. Or an online GLB to USDZ converter")
                print("   Then add Capybara.usdz to your Xcode project")
            }
        } else {
            print("⚠️ Capybara.glb not found in bundle")
            print("⚠️ Make sure the file is added to your Xcode project and included in the app target")
        }
        
        print("⚠️ Falling back to procedural model")
        return nil
    }
    
    private func findFirstModelEntity(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity {
            return model
        }
        for child in entity.children {
            if let model = findFirstModelEntity(in: child) {
                return model
            }
        }
        return nil
    }
    
    private func createProceduralCapybara() -> ModelEntity? {
        // Create a simple capybara shape using basic meshes
        let body = ModelEntity(
            mesh: .generateSphere(radius: 0.2),
            materials: [SimpleMaterial(color: UIColor(red: 0.55, green: 0.45, blue: 0.35, alpha: 1.0), isMetallic: false)]
        )
        body.position.y = 0.1
        
        let head = ModelEntity(
            mesh: .generateSphere(radius: 0.15),
            materials: [SimpleMaterial(color: UIColor(red: 0.61, green: 0.52, blue: 0.40, alpha: 1.0), isMetallic: false)]
        )
        head.position = [0, 0.25, 0.1]
        
        let snout = ModelEntity(
            mesh: .generateBox(size: [0.08, 0.05, 0.06]),
            materials: [SimpleMaterial(color: UIColor(red: 0.66, green: 0.57, blue: 0.46, alpha: 1.0), isMetallic: false)]
        )
        snout.position = [0, 0.3, 0.15]
        
        // Create a parent entity to hold all parts
        let capybara = ModelEntity()
        capybara.addChild(body)
        capybara.addChild(head)
        capybara.addChild(snout)
        
        return capybara
    }
}

#Preview {
    ZStack {
        AppColors.background
            .ignoresSafeArea()
        
        Capybara3DView(
            emotion: .happy,
            equippedAccessories: ["crown", "sunglasses"],
            previewingAccessoryId: nil,
            onPet: {}
        )
    }
}

