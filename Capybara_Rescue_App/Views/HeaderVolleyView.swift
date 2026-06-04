import SwiftUI

// MARK: - Header Volley Mini-Game
/// Daily mini-game: drag your capybara to head the ball. Reach the header goal without letting it hit the ground.
struct HeaderVolleyView: View {
    @EnvironmentObject var gameManager: GameManager
    @Binding var isPresented: Bool
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    private let targetHeaders = 15
    private let ballRadius: CGFloat = 22
    private let capyScale: CGFloat = 0.52
    private let capyHitRadius: CGFloat = 58
    private let gravity: CGFloat = 720
    private let floorPadding: CGFloat = 24
    
    @State private var headerCount = 0
    @State private var capybaraX: CGFloat = 0
    @State private var ballX: CGFloat = 0
    @State private var ballY: CGFloat = 0
    @State private var ballVX: CGFloat = 0
    @State private var ballVY: CGFloat = 0
    @State private var hasInitializedLayout = false
    @State private var showSuccess = false
    @State private var showFail = false
    @State private var physicsTimer: Timer?
    @State private var lastTickTime: Date?
    @State private var headBounceCooldownUntil: Date = .distantPast
    @State private var playAreaSize: CGSize = .zero
    
    var body: some View {
        ZStack {
            Color(hex: "E8F5E9")
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                headerBar
                
                GeometryReader { geo in
                    ZStack {
                        pitchDecoration(size: geo.size)
                        
                        Text("⚽")
                            .font(.system(size: ballRadius * 2.1))
                            .position(x: ballX, y: ballY)
                        
                        HeaderVolleyCapybaraSprite(
                            emotion: .happy,
                            equippedAccessories: gameManager.gameState.equippedAccessories
                        )
                        .scaleEffect(capyScale)
                        .position(x: capybaraX, y: capybaraBottomY(in: geo.size))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard !showSuccess, !showFail else { return }
                                    capybaraX = clampCapyX(value.location.x, in: geo.size)
                                }
                        )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .onAppear {
                        playAreaSize = geo.size
                        layoutIfNeeded(size: geo.size)
                    }
                    .onChange(of: geo.size) { _, newSize in
                        playAreaSize = newSize
                        layoutIfNeeded(size: newSize)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            if showSuccess { successOverlay }
            if showFail { failOverlay }
        }
        .id(localizationManager.currentLanguage)
        .onAppear { startGame() }
        .onDisappear { stopGame() }
    }
    
    // MARK: - Header
    
    private var headerBar: some View {
        HStack {
            Button(action: {
                HapticManager.shared.buttonPress()
                stopGame()
                isPresented = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(hex: "1a1a2e").opacity(0.6))
            }
            Spacer()
            Text(String(format: L("headerVolley.progressFormat"), headerCount, targetHeaders))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(hex: "1a1a2e"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    
    @ViewBuilder
    private func pitchDecoration(size: CGSize) -> some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: "1a5f1a").opacity(0.25))
                .frame(height: 6)
                .padding(.horizontal, 16)
                .padding(.bottom, floorPadding + 8)
        }
        .frame(width: size.width, height: size.height)
    }
    
    // MARK: - Overlays
    
    private static let cream = Color(hex: "FFF8E7")
    private static let primaryText = Color(hex: "1a1a2e")
    private static let secondaryText = Color(hex: "5A5A5A")
    private static let settingsGreen = Color(hex: "1a5f1a")
    
    private var successOverlay: some View {
        gameOverlay(
            emoji: "⚽",
            title: L("headerVolley.successTitle"),
            body: L("headerVolley.successBody"),
            action: {
                HapticManager.shared.buttonPress()
                gameManager.completeHeaderVolleyGame()
                isPresented = false
            }
        )
    }
    
    private var failOverlay: some View {
        gameOverlay(
            emoji: "😢",
            title: L("headerVolley.failTitle"),
            body: L("headerVolley.failBody"),
            action: {
                HapticManager.shared.buttonPress()
                isPresented = false
            }
        )
    }
    
    private func gameOverlay(emoji: String, title: String, body: String, action: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                Text(emoji)
                    .font(.system(size: 64))
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Self.primaryText)
                    .multilineTextAlignment(.center)
                Text(body)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Self.secondaryText)
                    .multilineTextAlignment(.center)
                
                Button(action: action) {
                    Text(L("common.gotIt"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Self.settingsGreen)
                        )
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Self.cream)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Self.primaryText.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(40)
        }
    }
    
    // MARK: - Game loop
    
    private func startGame() {
        headerCount = 0
        showSuccess = false
        showFail = false
        lastTickTime = nil
        headBounceCooldownUntil = .distantPast
        
        physicsTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            DispatchQueue.main.async {
                tickPhysics()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        physicsTimer = timer
    }
    
    private func stopGame() {
        physicsTimer?.invalidate()
        physicsTimer = nil
        lastTickTime = nil
    }
    
    private func layoutIfNeeded(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if !hasInitializedLayout {
            capybaraX = size.width / 2
            resetBall(in: size)
            hasInitializedLayout = true
        } else {
            capybaraX = clampCapyX(capybaraX, in: size)
            ballX = min(max(ballRadius, ballX), size.width - ballRadius)
        }
    }
    
    private func resetBall(in size: CGSize) {
        ballX = size.width / 2 + CGFloat.random(in: -40...40)
        ballY = ballRadius + 40
        ballVX = CGFloat.random(in: -60...60)
        ballVY = 80
    }
    
    private func capybaraBottomY(in size: CGSize) -> CGFloat {
        size.height - floorPadding - 50
    }
    
    private func headCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: capybaraX, y: capybaraBottomY(in: size) - 95 * capyScale)
    }
    
    private func floorY(in size: CGSize) -> CGFloat {
        size.height - floorPadding
    }
    
    private func clampCapyX(_ x: CGFloat, in size: CGSize) -> CGFloat {
        let margin: CGFloat = 90
        return min(max(x, margin), size.width - margin)
    }
    
    private func tickPhysics() {
        guard !showSuccess, !showFail else { return }
        guard hasInitializedLayout, playAreaSize.width > 0, playAreaSize.height > 0 else { return }
        
        let now = Date()
        let dt = CGFloat(min(0.05, lastTickTime.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)))
        lastTickTime = now
        
        let size = playAreaSize
        
        ballVY += gravity * dt
        ballVX *= (1 - 0.15 * dt)
        ballX += ballVX * dt
        ballY += ballVY * dt
        
        // Side walls
        if ballX < ballRadius {
            ballX = ballRadius
            ballVX = abs(ballVX) * 0.75
        } else if ballX > size.width - ballRadius {
            ballX = size.width - ballRadius
            ballVX = -abs(ballVX) * 0.75
        }
        
        // Ceiling
        if ballY < ballRadius + 20 {
            ballY = ballRadius + 20
            if ballVY < 0 { ballVY = abs(ballVY) * 0.5 }
        }
        
        // Head bounce
        let head = headCenter(in: size)
        let dx = ballX - head.x
        let dy = ballY - head.y
        let distSq = dx * dx + dy * dy
        let hitRadius = capyHitRadius + ballRadius
        
        if distSq < hitRadius * hitRadius,
           ballVY > 0,
           now > headBounceCooldownUntil {
            headBounceCooldownUntil = now.addingTimeInterval(0.12)
            ballY = head.y - hitRadius * 0.85
            ballVY = -max(320, abs(ballVY) * 0.88)
            ballVX += dx * 1.8
            headerCount += 1
            HapticManager.shared.buttonPress()
            
            if headerCount >= targetHeaders {
                stopGame()
                showSuccess = true
            }
        }
        
        // Missed ground
        if ballY > floorY(in: size) - ballRadius {
            HapticManager.shared.purchaseFailed()
            stopGame()
            showFail = true
        }
    }
}

// MARK: - 2D capybara sprite (no pet tap)
private struct HeaderVolleyCapybaraSprite: View {
    let emotion: CapybaraEmotion
    let equippedAccessories: [String]
    
    private var equippedHat: AccessoryItem? {
        AccessoryItem.allItems.first { item in
            equippedAccessories.contains(item.id) && item.isHat
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let hatAccessory = equippedHat {
                Text(hatAccessory.emoji)
                    .font(.system(size: 50))
                    .offset(y: 20)
            }
            CapybaraBody(emotion: emotion)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    HeaderVolleyView(isPresented: .constant(true))
        .environmentObject(GameManager())
}
