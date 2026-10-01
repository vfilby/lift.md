import SwiftUI

// MARK: - Enlarged Type Size

/// Dynamic Type size used by the enlarged reading view (GH #432).
///
/// Three steps above the user's current size, clamped to
/// `.accessibility2`...`.accessibility5`, so the enlarged view is always
/// legible at arm's length and still grows with the user's own setting.
/// See spec/screens/active-workout.md → "Enlarged Exercise Notes".
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

// MARK: - Modifiers

extension View {
    /// Press and hold to present `enlarged` at an enlarged Dynamic Type size
    /// in a full-screen cover; tap anywhere to dismiss. The modified view's
    /// own layout is unchanged.
    func enlargeOnLongPress<Enlarged: View>(
        accessibilityIdentifier: String,
        @ViewBuilder enlarged: @escaping () -> Enlarged
    ) -> some View {
        modifier(EnlargeOnLongPressModifier(accessibilityIdentifier: accessibilityIdentifier, enlarged: enlarged))
    }

    /// Exercise notes flavour: the enlarged view shows `title` as a heading
    /// above `notes` in large body text.
    func enlargeNotesOnLongPress(title: String, notes: String, accessibilityIdentifier: String) -> some View {
        enlargeOnLongPress(accessibilityIdentifier: accessibilityIdentifier) {
            VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                Text(title)
                    .font(.lmTitle)
                    .foregroundStyle(LiftMarkTheme.label)
                Text(notes)
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.label)
            }
        }
    }
}

private struct EnlargeOnLongPressModifier<Enlarged: View>: ViewModifier {
    let accessibilityIdentifier: String
    let enlarged: () -> Enlarged
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onLongPressGesture { isPresented = true }
            .sensoryFeedback(.impact(weight: .medium), trigger: isPresented) { _, isNowPresented in
                isNowPresented
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double-tap to show larger")
            .accessibilityAction { isPresented = true }
            .accessibilityIdentifier(accessibilityIdentifier)
            .fullScreenCover(isPresented: $isPresented) {
                EnlargedContentView(typeSize: EnlargedTypeSize.size(for: dynamicTypeSize), content: enlarged)
            }
    }
}

// MARK: - Enlarged View

private struct EnlargedContentView<Content: View>: View {
    let typeSize: DynamicTypeSize
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            content()
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
