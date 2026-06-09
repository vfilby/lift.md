import SwiftUI

/// A dismissible error banner that appears at the top of the screen.
struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.lmSubheadline)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.lmCaption.bold())
                    .foregroundStyle(.white.opacity(0.8))
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusLG))
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("error-banner")
    }
}
