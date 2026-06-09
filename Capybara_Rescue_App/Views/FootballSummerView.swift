import SwiftUI

// MARK: - Football Summer Event
struct FootballSummerView: View {
    @EnvironmentObject var gameManager: GameManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
    let onOpenFootballItem: () -> Void
    
    @State private var showHeaderVolleyGame = false
    
    private static let summerGreen = Color(hex: "1a5f1a")
    private static let summerGold = Color(hex: "F4A825")
    private static let summerSky = Color(hex: "4A90D9")
    
    var body: some View {
        NavigationView {
            ZStack {
                AppColors.background
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 28) {
                        VStack(spacing: 12) {
                            Text("⚽")
                                .font(.system(size: 72))
                            
                            Text(L("footballSummer.subtitle"))
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(Color(hex: "1a1a2e"))
                                .multilineTextAlignment(.center)
                            
                            Text(L("footballSummer.body"))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                        .padding(.top, 12)
                        
                        VStack(spacing: 14) {
                            FootballSummerActionButton(
                                title: L("footballSummer.playGame"),
                                subtitle: L("footballSummer.playGameSubtitle"),
                                systemImage: "figure.soccer",
                                gradient: [Self.summerGreen, Color(hex: "2d8a2d")]
                            ) {
                                HapticManager.shared.buttonPress()
                                showHeaderVolleyGame = true
                            }
                            
                            FootballSummerActionButton(
                                title: L("footballSummer.buyHat"),
                                subtitle: L("footballSummer.buyHatSubtitle"),
                                systemImage: "soccerball",
                                gradient: [Self.summerSky, Color(hex: "2E6BB5")]
                            ) {
                                HapticManager.shared.buttonPress()
                                onOpenFootballItem()
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle(L("footballSummer.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        HapticManager.shared.buttonPress()
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                }
            }
        }
        .id(localizationManager.currentLanguage)
        .fullScreenCover(isPresented: $showHeaderVolleyGame) {
            HeaderVolleyView(isPresented: $showHeaderVolleyGame)
                .environmentObject(gameManager)
        }
    }
}

private struct FootballSummerActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let gradient: [Color]
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.white.opacity(0.2)))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                    
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading)
                }
                
                Spacer(minLength: 0)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: gradient.first?.opacity(0.35) ?? .clear, radius: 8, x: 0, y: 4)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Glowing Pill Label
struct FootballSummerPillLabel: View {
    @ObservedObject private var localizationManager = LocalizationManager.shared
    @State private var glowPulse = false
    
    var body: some View {
        Text(L("footballSummer.title"))
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.black)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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
                    .stroke(Color.white.opacity(glowPulse ? 0.75 : 0.35), lineWidth: 1)
            )
            .shadow(color: Color(hex: "FFD700").opacity(glowPulse ? 0.95 : 0.5), radius: glowPulse ? 16 : 7, x: 0, y: 0)
            .shadow(color: Color(hex: "FFA502").opacity(glowPulse ? 0.8 : 0.4), radius: glowPulse ? 22 : 11, x: 0, y: 0)
            .shadow(color: Color(hex: "F5A623").opacity(glowPulse ? 0.65 : 0.3), radius: glowPulse ? 10 : 5, x: 0, y: 2)
            .background {
                Capsule()
                    .fill(Color(hex: "FFD700").opacity(glowPulse ? 0.55 : 0.2))
                    .blur(radius: glowPulse ? 14 : 8)
                    .scaleEffect(glowPulse ? 1.12 : 1.04)
            }
            .id(localizationManager.currentLanguage)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                    glowPulse = true
                }
            }
    }
}

#Preview {
    FootballSummerView(onOpenFootballItem: {})
        .environmentObject(GameManager())
}
