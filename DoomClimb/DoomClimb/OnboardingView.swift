import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "figure.climbing",
            iconColor: .dcPrimary,
            title: "Welcome to\nDoomClimb",
            subtitle: "AI-powered boulder route generation for your Kilter Board."
        ),
        OnboardingPage(
            icon: "grid.circle.fill",
            iconColor: .dcSecondary,
            title: "What is a\nKilter Board?",
            subtitle: "A Kilter Board is a LED-equipped adjustable climbing wall. Holds light up to mark each route — start, hands, and finish."
        ),
        OnboardingPage(
            icon: "cpu.fill",
            iconColor: .dcSecondary,
            title: "AI Route\nGeneration",
            subtitle: "DoomClimb generates new boulder problems using a custom ML model trained on thousands of real Kilter routes, tuned to your grade and angle."
        ),
        OnboardingPage(
            icon: "antenna.radiowaves.left.and.right",
            iconColor: .dcSecondary,
            title: "Connect Your\nBoard",
            subtitle: "Pair via Bluetooth and send any route directly to your board — the LEDs light up automatically."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut(duration: 0.3), value: currentPage)

            VStack(spacing: 12) {
                if currentPage < pages.count - 1 {
                    Button {
                        withAnimation { currentPage += 1 }
                    } label: {
                        Text("Next")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.dcPrimary)

                    Button("Skip") {
                        hasSeenOnboarding = true
                    }
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                } else {
                    Button {
                        hasSeenOnboarding = true
                    } label: {
                        Text("Get Started")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.dcPrimary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(page.iconColor.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: page.icon)
                    .font(.system(size: 52))
                    .foregroundStyle(page.iconColor)
            }

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(page.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }
}

#Preview {
    OnboardingView()
        .preferredColorScheme(.dark)
}
