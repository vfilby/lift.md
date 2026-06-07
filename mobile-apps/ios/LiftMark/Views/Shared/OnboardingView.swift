import SwiftUI

struct OnboardingView: View {
    let onAccept: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    // App icon and welcome
                    VStack(spacing: 12) {
                        Image("BrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                            .accessibilityHidden(true)

                        // Wordmark logo (custom 'l') rather than the typeface.
                        Image("BrandWordmark")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 40)
                            .accessibilityLabel("lift.md")

                        Text("Markdown workouts you own")
                            .font(.lmSubheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    // Brief explanation
                    Text("Track your workouts in markdown — portable, yours, and ready for any text editor or AI assistant.")
                        .font(.lmBody)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // Disclaimer card
                    DisclaimerText()
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                    // Accept button inside scroll content
                    Button {
                        onAccept()
                    } label: {
                        Text("I Understand")
                            .font(.lmHeadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding-accept-button")
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
                // Cap the readable column width, then fill the viewport so the
                // column centers both horizontally and vertically when it fits;
                // taller content (small screens / large Dynamic Type) scrolls.
                .frame(maxWidth: 500)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .accessibilityIdentifier("onboarding-screen")
    }
}
