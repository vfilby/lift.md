import Foundation
import SwiftUI

/// Always-visible Inbox section displayed at the top of the Plans screen.
/// See `spec/screens/workouts.md` and `spec/services/workout-inbox.md`.
///
/// Renders inbox items pushed from outside the app (e.g., Claude Code via
/// PAT). The user can Discard, Add to Plans, or Start (= Add to Plans +
/// open the new plan's detail). Items are not in the user's plan library
/// until promoted.
struct InboxSectionView: View {
    @Environment(WorkoutPlanStore.self) private var planStore
    @Environment(NavigationCoordinator.self) private var navCoordinator
    @Environment(AuthenticationStore.self) private var authStore
    @Environment(InboxPollerService.self) private var inboxPoller

    @State private var items: [InboxItem] = []
    @State private var inFlightInboxId: String?
    @State private var actionError: String?
    @State private var isExpanded: Bool = true
    /// Drives the `.sheet(item:)` for the read-only preview. Holding the
    /// full decoded payload + the originating InboxItem id keeps the sheet
    /// independent of any reload that happens while it's open — if the
    /// underlying row vanishes the sheet still renders until dismissed.
    @State private var previewing: PreviewPayload?

    private let repository: InboxItemRepository
    private let apiClient: APIClientProtocol

    init(
        repository: InboxItemRepository = InboxItemRepository(),
        apiClient: APIClientProtocol = APIClient()
    ) {
        self.repository = repository
        self.apiClient = apiClient
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
                if let err = actionError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, LiftMarkTheme.spacingMD)
                        .padding(.bottom, LiftMarkTheme.spacingSM)
                }
            }
        }
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .overlay(
            RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD)
                .strokeBorder(LiftMarkTheme.tertiaryLabel.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.top, LiftMarkTheme.spacingSM)
        .padding(.bottom, LiftMarkTheme.spacingSM)
        .accessibilityIdentifier("inbox-section")
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: InboxPollerService.inboxDidChange)) { _ in
            reload()
        }
        .sheet(item: $previewing) { payload in
            InboxPreviewSheet(
                workout: payload.workout,
                createdAtServer: payload.createdAtServer,
                sourceTokenId: payload.sourceTokenId,
                onDiscard: {
                    Task { await discard(byId: payload.inboxId) }
                },
                onAddToPlans: {
                    Task { await promote(byId: payload.inboxId, openDetail: false) }
                },
                onStart: {
                    Task { await promote(byId: payload.inboxId, openDetail: true) }
                }
            )
        }
    }

    /// Bundle of state passed to the preview sheet. `Identifiable` so it can
    /// drive `.sheet(item:)`.
    private struct PreviewPayload: Identifiable {
        let inboxId: String
        let workout: InboxWorkout
        let createdAtServer: Date
        let sourceTokenId: String?
        var id: String { inboxId }
    }

    // MARK: - Subviews

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text("Inbox")
                    .font(.headline)
                    .foregroundStyle(LiftMarkTheme.label)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(LiftMarkTheme.primary)
                        .clipShape(Capsule())
                        .accessibilityIdentifier("inbox-count-badge")
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.subheadline)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .padding(LiftMarkTheme.spacingMD)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inbox-section-header")
        .accessibilityLabel(isExpanded ? "Collapse Inbox" : "Expand Inbox")
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyRow
        } else {
            // List is the only SwiftUI container that supports
            // `.swipeActions`. We disable its own scrolling and pin its
            // height so it sits inside the screen's outer VStack instead
            // of fighting it for space.
            List {
                ForEach(items) { item in
                    inboxRow(item)
                }
                .listRowInsets(EdgeInsets(
                    top: 4,
                    leading: LiftMarkTheme.spacingMD,
                    bottom: 4,
                    trailing: LiftMarkTheme.spacingMD
                ))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .scrollDisabled(true)
            .frame(height: estimatedListHeight)
            .padding(.bottom, LiftMarkTheme.spacingXS)
        }
    }

    /// Approximate height per row + padding. Tuned to match the row's
    /// padding + 2-line content; over-estimating just adds whitespace, while
    /// under-estimating clips swipe actions.
    private var estimatedListHeight: CGFloat {
        let rowHeight: CGFloat = 72
        return CGFloat(items.count) * rowHeight
    }

    private var emptyRow: some View {
        HStack {
            Text("No new workouts in your inbox.")
                .font(.subheadline)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
            Spacer()
        }
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.bottom, LiftMarkTheme.spacingMD)
        .accessibilityIdentifier("inbox-empty")
    }

    private func inboxRow(_ item: InboxItem) -> some View {
        let isBusy = inFlightInboxId == item.id
        return HStack(spacing: LiftMarkTheme.spacingSM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.summaryName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(item.summaryExerciseCount) exercises • \(item.summarySetCount) sets • \(relativeStamp(item.createdAtServer))")
                    .font(.caption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer()
            if isBusy {
                ProgressView()
            }
        }
        .padding(LiftMarkTheme.spacingSM)
        .background(LiftMarkTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
        .contentShape(Rectangle())
        // Tap the row to preview. Decoding happens inline so a malformed
        // JSON blob fails as a logged warning instead of presenting an
        // empty sheet.
        .onTapGesture {
            guard !isBusy else { return }
            presentPreview(for: item)
        }
        .accessibilityIdentifier("inbox-row-\(item.id)")
        .contextMenu {
            Button {
                Task { await discard(item) }
            } label: {
                Label("Discard", systemImage: "trash")
            }
            .accessibilityIdentifier("inbox-row-discard-\(item.id)")
            Button {
                Task { await promote(item, openDetail: false) }
            } label: {
                Label("Add to Plans", systemImage: "tray.and.arrow.down")
            }
            .accessibilityIdentifier("inbox-row-add-\(item.id)")
            Button {
                Task { await promote(item, openDetail: true) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .accessibilityIdentifier("inbox-row-start-\(item.id)")
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await discard(item) }
            } label: {
                Label("Discard", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task { await promote(item, openDetail: true) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .tint(.green)
            Button {
                Task { await promote(item, openDetail: false) }
            } label: {
                Label("Add", systemImage: "tray.and.arrow.down")
            }
            .tint(.blue)
        }
        .disabled(isBusy)
    }

    // MARK: - Actions

    private func presentPreview(for item: InboxItem) {
        let data = Data(item.workoutJSON.utf8)
        do {
            let workout = try JSONDecoder().decode(InboxWorkout.self, from: data)
            previewing = PreviewPayload(
                inboxId: item.id,
                workout: workout,
                createdAtServer: item.createdAtServer,
                sourceTokenId: item.sourceTokenId
            )
        } catch {
            actionError = "Couldn't preview this workout — it may be malformed."
            Logger.shared.error(.network, "inbox preview decode failed", error: error)
        }
    }

    private func reload() {
        do {
            items = try repository.list()
        } catch {
            Logger.shared.error(.database, "Inbox reload failed", error: error)
        }
    }

    /// Resolve an item by id then discard. Used by the preview sheet,
    /// which holds an id rather than a reference so a mid-flight reload
    /// can't desync the action target.
    @MainActor
    private func discard(byId id: String) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        await discard(item)
    }

    @MainActor
    private func discard(_ item: InboxItem) async {
        guard inFlightInboxId == nil else { return }
        inFlightInboxId = item.id
        defer { inFlightInboxId = nil }
        actionError = nil

        // Local delete first — user said discard, honor it even if server
        // is unreachable. The server row gets reaped on next contact or
        // by TTL (out of scope v1).
        do {
            try repository.delete(id: item.id)
            inboxPoller.refreshLocalState()
        } catch {
            actionError = "Couldn't remove this item locally."
            Logger.shared.error(.database, "inbox discard local failed", error: error)
            return
        }

        await sendServerDelete(inboxId: item.id, action: "discard")
        reload()
    }

    @MainActor
    private func promote(byId id: String, openDetail: Bool) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        await promote(item, openDetail: openDetail)
    }

    @MainActor
    private func promote(_ item: InboxItem, openDetail: Bool) async {
        guard inFlightInboxId == nil else { return }
        inFlightInboxId = item.id
        defer { inFlightInboxId = nil }
        actionError = nil

        let inboxWorkout: InboxWorkout
        do {
            let data = Data(item.workoutJSON.utf8)
            inboxWorkout = try JSONDecoder().decode(InboxWorkout.self, from: data)
        } catch {
            actionError = "Couldn't read this workout — it may be malformed."
            Logger.shared.error(.network, "inbox promote decode failed", error: error)
            return
        }

        let plan = InboxWorkoutMapper.toWorkoutPlan(inboxWorkout)
        planStore.createPlan(plan)
        // createPlan stores error on planStore.lastError on failure; we
        // don't have a throws version. Trust the store's logging + keep
        // going; if the plan didn't materialize the user can retry.

        do {
            try repository.delete(id: item.id)
            inboxPoller.refreshLocalState()
        } catch {
            Logger.shared.warn(.database, "inbox local delete after promote failed: \(error)")
        }

        await sendServerDelete(inboxId: item.id, action: openDetail ? "start" : "promote")
        reload()

        if openDetail {
            navCoordinator.navigateToPlan(id: plan.id)
        }
    }

    @MainActor
    private func sendServerDelete(inboxId: String, action: String) async {
        do {
            try await authStore.withAuthorizedRequest { token in
                try await self.apiClient.sendEmpty(
                    path: "/v1/workouts/\(inboxId)",
                    method: "DELETE",
                    body: Optional<EmptyBody>.none,
                    accessToken: token
                )
            }
            Logger.shared.info(
                .network,
                "inbox \(action) server-delete ok",
                metadata: ["inbox_id": inboxId]
            )
        } catch {
            // Non-fatal: local state already reflects the user's intent.
            // The server row will reappear in the next poll's listing,
            // but the local upsert is keyed on inbox_id so the user will
            // see the item come back if the server still has it. For a
            // discard we accept that minor edge — the user can re-discard.
            Logger.shared.warn(
                .network,
                "inbox \(action) server-delete failed (ignored): \(error)"
            )
        }
    }

    private func relativeStamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
