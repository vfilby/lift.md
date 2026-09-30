import SwiftUI

// MARK: - Enlarged Type Size

/// Dynamic Type size used by the enlarged reading view (GH #432).
///
/// Three steps above the user's current size, clamped to
/// `.accessibility2`...`.accessibility5`, so the enlarged view is always
/// legible at arm's length and still grows with the user's own setting.
/// See spec/screens/history-detail.md → "Enlarged Exercise View".
enum EnlargedTypeSize {
    static let stepsAboveCurrent = 3
    static let minimum: DynamicTypeSize = .accessibility2
    static let maximum: DynamicTypeSize = .accessibility5

    static func size(for current: DynamicTypeSize) -> DynamicTypeSize {
        let sizes = DynamicTypeSize.allCases
        guard let index = sizes.firstIndex(of: current) else { return minimum }
        let stepped = sizes[min(index + stepsAboveCurrent, sizes.count - 1)]
        return min(max(stepped, minimum), maximum)
    }
}

// MARK: - Modifier

extension View {
    /// Press and hold to present this view re-rendered at an enlarged Dynamic
    /// Type size in a full-screen cover; tap anywhere to dismiss.
    ///
    /// Apply it to read-only content only — the enlarged copy is the same view,
    /// so any controls inside it would be live in the cover too.
    func enlargeOnLongPress(accessibilityIdentifier: String) -> some View {
        modifier(EnlargeOnLongPressModifier(enlarged: self, accessibilityIdentifier: accessibilityIdentifier))
    }
}

private struct EnlargeOnLongPressModifier<Enlarged: View>: ViewModifier {
    let enlarged: Enlarged
    let accessibilityIdentifier: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onLongPressGesture { isPresented = true }
            .sensoryFeedback(.impact(weight: .medium), trigger: isPresented) { _, isNowPresented in
                isNowPresented
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityIdentifier)
            .fullScreenCover(isPresented: $isPresented) {
                EnlargedContentView(typeSize: EnlargedTypeSize.size(for: dynamicTypeSize)) {
                    enlarged
                }
            }
    }
}

// MARK: - Enlarged View

private struct EnlargedContentView<Content: View>: View {
    let typeSize: DynamicTypeSize
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            content
                .dynamicTypeSize(typeSize)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LiftMarkTheme.spacingMD)
                .padding(.top, LiftMarkTheme.spacingXL)
        }
        .safeAreaInset(edge: .bottom) {
            Text("Tap anywhere to close")
                .font(.lmFootnote)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .padding(.bottom, LiftMarkTheme.spacingSM)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.lmTitle2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            .buttonStyle(.plain)
            .padding(LiftMarkTheme.spacingMD)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("enlarged-view-close")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LiftMarkTheme.background)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("enlarged-view")
    }
}
