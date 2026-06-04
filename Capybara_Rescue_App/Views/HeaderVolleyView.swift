import SwiftUI

// MARK: - Header Volley Mini-Game
/// Daily mini-game: drag your capybara to head the ball. Reach the header goal without letting it hit the ground.
struct HeaderVolleyView: View {
    @EnvironmentObject var gameManager: GameManager
    @Binding var isPresented: Bool
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    private let targetHeaders = 15
    private let ballRadius: CGFloat = 22
    private let gravity: CGFloat = 720
    private let floorPadding: CGFloat = 16
    private let goalHeight: CGFloat = 112
    
    @State private var headerCount = 0
    @State private var capybaraX: CGFloat = 0
    @State private var capyDragOriginX: CGFloat?
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
                        HeaderVolleyGoalNetView(playAreaWidth: geo.size.width)
                            .position(
                                x: geo.size.width / 2,
                                y: goalNetCenterY(in: geo.size)
                            )
                            .allowsHitTesting(false)
                        
                        HeaderVolleyStaticCapybaraView()
                            .position(x: capybaraX, y: capybaraAnchorY(in: geo.size))
                            .allowsHitTesting(false)
                        
                        Text("⚽")
                            .font(.system(size: ballRadius * 2.1))
                            .position(x: ballX, y: ballY)
                            .allowsHitTesting(false)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(capybaraDragGesture(in: geo.size))
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
    
    private func capybaraDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !showSuccess, !showFail else { return }
                if capyDragOriginX == nil {
                    capyDragOriginX = capybaraX
                }
                capybaraX = clampCapyX(capyDragOriginX! + value.translation.width, in: size)
            }
            .onEnded { _ in
                capyDragOriginX = nil
            }
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
        
        if playAreaSize.width > 0 {
            resetBall(in: playAreaSize)
        }
        
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
            startGame()
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
    
    private func goalNetCenterY(in size: CGSize) -> CGFloat {
        size.height - floorPadding - goalHeight / 2
    }
    
    private func capybaraAnchorY(in size: CGSize) -> CGFloat {
        size.height - floorPadding - goalHeight - 28
    }
    
    private func capybaraHitRect(in size: CGSize) -> CGRect {
        let w = HeaderVolleyStaticCapybaraView.displayWidth * 0.95
        let h = HeaderVolleyStaticCapybaraView.displayHeight * 0.9
        let centerY = capybaraAnchorY(in: size)
        return CGRect(
            x: capybaraX - w / 2,
            y: centerY - h / 2,
            width: w,
            height: h
        )
    }
    
    private func ballHitsCapybara(rect: CGRect) -> Bool {
        let closestX = min(max(ballX, rect.minX), rect.maxX)
        let closestY = min(max(ballY, rect.minY), rect.maxY)
        let dx = ballX - closestX
        let dy = ballY - closestY
        return dx * dx + dy * dy < ballRadius * ballRadius
    }
    
    /// Ball crosses this Y (into the net mouth) = miss.
    private func goalMouthY(in size: CGSize) -> CGFloat {
        size.height - floorPadding - goalHeight + 10
    }
    
    private func clampCapyX(_ x: CGFloat, in size: CGSize) -> CGFloat {
        // Allow sliding nearly edge-to-edge (sprite can extend slightly past the pitch).
        let margin: CGFloat = 48
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
        
        if ballX < ballRadius {
            ballX = ballRadius
            ballVX = abs(ballVX) * 0.75
        } else if ballX > size.width - ballRadius {
            ballX = size.width - ballRadius
            ballVX = -abs(ballVX) * 0.75
        }
        
        if ballY < ballRadius + 20 {
            ballY = ballRadius + 20
            if ballVY < 0 { ballVY = abs(ballVY) * 0.5 }
        }
        
        let capyRect = capybaraHitRect(in: size)
        
        if ballHitsCapybara(rect: capyRect),
           ballVY > 0,
           now > headBounceCooldownUntil {
            headBounceCooldownUntil = now.addingTimeInterval(0.12)
            ballY = capyRect.minY - ballRadius - 4
            ballVY = -max(520, abs(ballVY) * 1.05)
            ballVX += (ballX - capybaraX) * 1.4
            headerCount += 1
            HapticManager.shared.buttonPress()
            
            if headerCount >= targetHeaders {
                stopGame()
                showSuccess = true
            }
        }
        
        if ballY > goalMouthY(in: size) - ballRadius {
            HapticManager.shared.purchaseFailed()
            stopGame()
            showFail = true
        }
    }
}

// MARK: - Static capybara art (side profile, transparent PNG — instant load)
private struct HeaderVolleyStaticCapybaraView: View {
    static let assetName = "HeaderVolleyCapybara"
    static let displayWidth: CGFloat = 240
    static let displayHeight: CGFloat = 200
    
    var body: some View {
        Image(Self.assetName)
            .resizable()
            .scaledToFit()
            .frame(width: Self.displayWidth, height: Self.displayHeight)
            .shadow(color: .black.opacity(0.15), radius: 5, y: 3)
    }
}

// MARK: - Goal net (posts, crossbar, mesh)
private struct HeaderVolleyGoalNetView: View {
    let playAreaWidth: CGFloat
    
    private let postWidth: CGFloat = 8
    private let crossbarHeight: CGFloat = 8
    private let goalHeight: CGFloat = 112
    private let frameColor = Color.white
    
    private var goalWidth: CGFloat {
        max(200, playAreaWidth - 28)
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            GoalNetMeshPattern(
                width: goalWidth - postWidth * 2 - 6,
                height: goalHeight - crossbarHeight - 10
            )
            .padding(.top, crossbarHeight + 6)
            
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(frameColor)
                    .frame(width: goalWidth, height: crossbarHeight)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                
                HStack(alignment: .top, spacing: 0) {
                    goalPost
                    Spacer(minLength: 0)
                    goalPost
                }
                .frame(width: goalWidth, height: goalHeight - crossbarHeight)
            }
        }
        .frame(width: goalWidth, height: goalHeight)
    }
    
    private var goalPost: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(frameColor)
            .frame(width: postWidth, height: goalHeight - crossbarHeight)
            .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
    }
}

private struct GoalNetMeshPattern: View {
    let width: CGFloat
    let height: CGFloat
    
    private let meshSpacing: CGFloat = 14
    
    var body: some View {
        Canvas { context, size in
            let netRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            context.fill(
                Path(roundedRect: netRect, cornerRadius: 2),
                with: .color(Color(hex: "1a5f1a").opacity(0.12))
            )
            
            var meshPath = Path()
            var x: CGFloat = 0
            while x <= size.width {
                meshPath.move(to: CGPoint(x: x, y: 0))
                meshPath.addLine(to: CGPoint(x: x, y: size.height))
                x += meshSpacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                meshPath.move(to: CGPoint(x: 0, y: y))
                meshPath.addLine(to: CGPoint(x: size.width, y: y))
                y += meshSpacing
            }
            
            context.stroke(
                meshPath,
                with: .color(.white.opacity(0.5)),
                lineWidth: 1.2
            )
            
            var depthPath = Path()
            depthPath.move(to: CGPoint(x: 0, y: 0))
            depthPath.addLine(to: CGPoint(x: size.width / 2, y: size.height * 0.35))
            depthPath.addLine(to: CGPoint(x: size.width, y: 0))
            depthPath.move(to: CGPoint(x: 0, y: size.height))
            depthPath.addLine(to: CGPoint(x: size.width / 2, y: size.height * 0.65))
            depthPath.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(depthPath, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
        .frame(width: width, height: height)
    }
}

#Preview {
    HeaderVolleyView(isPresented: .constant(true))
        .environmentObject(GameManager())
}
