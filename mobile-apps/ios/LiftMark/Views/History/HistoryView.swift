import SwiftUI

struct HistoryView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(SyncStatusStore.self) private var syncStatus
    @State private var searchText = ""
    @State private var showExportConfirmation = false
    @State private var exportFile: ExportFile?
    @State private var exportError: String?
    @State private var selectedSessionId: String?
    @State private var singleExportFile: ExportFile?

    private var completedSessions: [WorkoutSession] {
        sessionStore.sessions.filter { $0.status == .completed }
    }

    private var filteredSessions: [WorkoutSession] {
        if searchText.isEmpty {
            return completedSessions
        }
        return completedSessions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        AdaptiveSplitView {
            // iPad sidebar - session list
            VStack(spacing: 0) {
                SyncStatusBar(isSyncing: syncStatus.isSyncing)
                if completedSessions.isEmpty {
                    emptyState
                } else {
                    searchBar
                    iPadSessionList
                }
            }
            .animation(.default, value: syncStatus.isSyncing)
        } detail: {
            // iPad detail - session detail
            if let selectedSessionId {
                HistoryDetailView(sessionId: selectedSessionId, isEmbedded: true)
            } else {
                ContentUnavailableView("Select a Workout", systemImage: "dumbbell", description: Text("Choose a workout from the sidebar."))
            }
        } compact: {
            iPhoneLayout
        }
        // Contain children as their own elements so this screen identifier does
        // not propagate down and clobber the embedded detail pane's identifiers
        // on iPad (the detail's `history-detail-view`/`history-detail-screen`).
        // Mirrors WorkoutsView, whose detail pane survives for the same reason.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history-screen")
        .navigationTitle("Workouts")
        .refreshable {
            // Pull-to-refresh must actually pull from iCloud — previously it only
            // re-read the local DB, so a genuinely new remote workout never appeared.
            // Records merge in via .syncRecordsMerged; reload local immediately too.
            CKSyncEngineManager.shared.fetchChanges(manual: true)
            sessionStore.loadSessions()
        }
        .toolbar {
            if let selectedSessionId {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportSingleSession(id: selectedSessionId)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-session-button")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExportConfirmation = true
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .disabled(completedSessions.isEmpty)
                .accessibilityIdentifier("history-export-button")
            }
        }
        .alert("Export Workouts", isPresented: $showExportConfirmation) {
            Button("Export All as JSON") {
                exportAllSessions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Export \(completedSessions.count) workout\(completedSessions.count == 1 ? "" : "s") as JSON?")
        }
        .alert("Export Error", isPresented: .init(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        #if os(iOS)
        .shareSheet(item: $exportFile)
        .shareSheet(item: $singleExportFile)
        #endif
        .navigationDestination(for: AppDestination.self) { destination in
            switch destination {
            case .historyDetail(let id):
                HistoryDetailView(sessionId: id)
            default:
                EmptyView()
            }
        }
        .onChange(of: sessionStore.sessions) {
            if let id = selectedSessionId, !sessionStore.sessions.contains(where: { $0.id == id }) {
                selectedSessionId = nil
            }
        }
    }

    @ViewBuilder
    private var iPadSessionList: some View {
        ScrollView {
            LazyVStack(spacing: LiftMarkTheme.spacingSM) {
                ForEach(filteredSessions) { session in
                    Button {
                        selectedSessionId = session.id
                    } label: {
                        SessionCardView(session: session, isSelected: selectedSessionId == session.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history-session-card")
                    .contextMenu {
                        Button(role: .destructive) {
                            sessionStore.deleteSession(id: session.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .accessibilityIdentifier("history-list")
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        VStack(spacing: 0) {
            SyncStatusBar(isSyncing: syncStatus.isSyncing)
            content
        }
        .animation(.default, value: syncStatus.isSyncing)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if completedSessions.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    searchBar
                    ScrollView {
                        LazyVStack(spacing: LiftMarkTheme.spacingSM) {
                            ForEach(filteredSessions) { session in
                                NavigationLink(value: AppDestination.historyDetail(id: session.id)) {
                                    SessionCardView(session: session)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("history-session-card")
                                .contextMenu {
                                    Button(role: .destructive) {
                                        sessionStore.deleteSession(id: session.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .accessibilityIdentifier("history-list")
            }
        }
    }

    // MARK: - Shared Components

    private var emptyState: some View {
        VStack(spacing: LiftMarkTheme.spacingSM) {
            Spacer()
            Image(systemName: "clock")
                .font(.system(size: 48))
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
            Text("No Workouts Yet")
                .font(.lmTitle3.weight(.semibold))
            Text("Complete a workout to see it here")
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("history-empty-state")
    }

    private var searchBar: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .font(.system(size: 14))
            TextField("Search workouts...", text: $searchText)
                .font(.lmBody)
        }
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.vertical, LiftMarkTheme.spacingSM)
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(LiftMarkTheme.tertiaryLabel.opacity(0.3), lineWidth: 1.5))
        .padding(.horizontal)
        .padding(.vertical, LiftMarkTheme.spacingSM)
    }

    private func exportSingleSession(id: String) {
        guard let session = sessionStore.sessions.first(where: { $0.id == id }) else { return }
        let exportService = WorkoutExportService()
        do {
            let url = try exportService.exportSingleSessionAsJson(session)
            singleExportFile = ExportFile(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportAllSessions() {
        let exportService = WorkoutExportService()
        do {
            let url = try exportService.exportSessionsAsJson()
            exportFile = ExportFile(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Session Card

private struct SessionCardView: View {
    let session: WorkoutSession
    var isSelected: Bool = false

    private var completedSetsCount: Int {
        session.exercises.flatMap(\.sets).filter { $0.status == .completed }.count
    }

    private var totalSetsCount: Int {
        session.exercises.flatMap(\.sets).count
    }

    private var exerciseCount: Int {
        session.exercises.filter { !$0.sets.isEmpty }.count
    }

    private var totalVolume: Double {
        session.exercises.flatMap(\.sets)
            .filter { $0.status == .completed }
            .reduce(0.0) { total, set in
                let actual = set.entries.first?.actual
                return total + (actual?.weight?.value ?? 0) * Double(actual?.reps ?? 0)
            }
    }

    private var formattedDate: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard let date = dateFormatter.date(from: String(session.date.prefix(10))) else {
            return session.date
        }

        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day,
                  daysAgo < 7 {
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.dateFormat = "EEEE"
            return weekdayFormatter.string(from: date)
        } else {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "MMM d"
            return displayFormatter.string(from: date)
        }
    }

    private var startTimeFormatted: String? {
        SessionDateDisplay.shortTime(startTime: session.startTime)
    }

    private var durationFormatted: String? {
        SessionDateDisplay.duration(seconds: session.duration)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.lmHeadline)
                    .foregroundStyle(LiftMarkTheme.label)
                    .lineLimit(1)

                HStack(spacing: LiftMarkTheme.spacingSM) {
                    Text(formattedDate)
                    // Each component carries its own leading separator so a missing
                    // start time never leaves a dangling "· ·" gap (e.g. on a synced
                    // record whose startTime parsed to nil before the ISO8601 fix).
                    if let time = startTimeFormatted {
                        Text("·")
                        Text(time)
                    }
                    if let duration = durationFormatted {
                        Text("·")
                        Text(duration)
                    }
                }
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)

                HStack(spacing: 0) {
                    Text("\(completedSetsCount) sets")
                    Text(" · ")
                    Text("\(exerciseCount) exercises")
                    if totalVolume > 0 {
                        Text(" · ")
                        Text(formatVolume(totalVolume))
                    }
                }
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(isSelected ? LiftMarkTheme.primary.opacity(0.12) : LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
    }

    private func formatVolume(_ volume: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let formatted = formatter.string(from: NSNumber(value: volume)) ?? "\(Int(volume))"
        return "\(formatted) lbs"
    }
}
