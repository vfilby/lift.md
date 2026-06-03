import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DebugLogsView: View {
    @State private var isLoading = true
    @State private var logs: [LogEntry] = []
    @State private var selectedLevel: LogLevel? = nil
    @State private var showClearConfirmation = false
    @State private var shareFile: ExportFile?

    private var filteredLogs: [LogEntry] {
        if let level = selectedLevel {
            return logs.filter { $0.level == level }
        }
        return logs
    }

    private var logStats: [LogLevel: Int] {
        var stats: [LogLevel: Int] = [:]
        for log in logs {
            stats[log.level, default: 0] += 1
        }
        return stats
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .accessibilityIdentifier("debug-logs-loading")
            } else if logs.isEmpty {
                VStack(spacing: LiftMarkTheme.spacingMD) {
                    Image(systemName: "doc.text")
                        .font(.lmLargeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Logs")
                        .font(.lmHeadline)
                    Text("Debug logs will appear here.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("debug-logs-empty")
            } else {
                List {
                    // Device info + stats
                    Section {
                        deviceInfoContent
                    }

                    // Filter bar
                    Section {
                        filterBar
                            .listRowInsets(EdgeInsets())
                    }

                    // Log entries
                    Section {
                        ForEach(filteredLogs, id: \.id) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("debug-logs-list")
            }
        }
        .accessibilityIdentifier("debug-logs-screen")
        .navigationTitle("Debug Logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        shareLogs()
                    } label: {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("debug-logs-share")

                    Button {
                        copyLogsToClipboard()
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("debug-logs-export")

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                    .accessibilityIdentifier("debug-logs-clear")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("debug-logs-actions")
            }
        }
        .alert("Clear Logs", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) {
                Logger.shared.clearLogs()
                logs = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to clear all debug logs?")
        }
        .shareSheet(item: $shareFile)
        .onAppear {
            loadLogs()
        }
    }

    // MARK: - Device Info Content

    @ViewBuilder
    private var deviceInfoContent: some View {
        let info = Logger.shared.getDeviceInformation()

        HStack {
            Text("Device")
            Spacer()
            Text("\(info.platform) \(info.osVersion)")
                .foregroundStyle(.secondary)
            if info.isSimulator {
                Text("(Simulator)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.lmSubheadline)

        HStack {
            Text("App")
            Spacer()
            Text("v\(info.appVersion) (\(info.buildType))")
                .foregroundStyle(.secondary)
        }
        .font(.lmSubheadline)

        HStack(spacing: LiftMarkTheme.spacingMD) {
            ForEach(LogLevel.allCases, id: \.self) { level in
                let count = logStats[level] ?? 0
                HStack(spacing: 2) {
                    Circle()
                        .fill(logLevelColor(level))
                        .frame(width: 6, height: 6)
                    Text("\(count)")
                        .font(.lmCaption)
                        .fontWeight(.medium)
                    Text(level.rawValue)
                        .font(.lmCaption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Filter Bar

    @ViewBuilder
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LiftMarkTheme.spacingSM) {
                FilterChip(label: "All", isSelected: selectedLevel == nil) {
                    selectedLevel = nil
                }
                ForEach(LogLevel.allCases, id: \.self) { level in
                    FilterChip(
                        label: level.rawValue.capitalized,
                        isSelected: selectedLevel == level,
                        color: logLevelColor(level)
                    ) {
                        selectedLevel = selectedLevel == level ? nil : level
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, LiftMarkTheme.spacingSM)
        }
    }

    // MARK: - Actions

    private func loadLogs() {
        logs = Logger.shared.getLogs(limit: 200)
        isLoading = false
    }

    private func shareLogs() {
        let logText = Logger.shared.exportLogs()
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let fileName = "liftmark_debug_logs_\(timestamp).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try logText.write(to: tempURL, atomically: true, encoding: .utf8)
            shareFile = ExportFile(url: tempURL)
        } catch {
            Logger.shared.error(.app, "Failed to write log file", error: error)
        }
    }

    private func copyLogsToClipboard() {
        let logText = Logger.shared.exportLogs()
        #if canImport(UIKit)
        UIPasteboard.general.string = logText
        #endif
    }

    // MARK: - Helpers

    private func logLevelColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return LiftMarkTheme.primary
        case .warn: return LiftMarkTheme.warning
        case .error: return LiftMarkTheme.destructive
        }
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isExpanded = false

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .gray
        case .info: return LiftMarkTheme.primary
        case .warn: return LiftMarkTheme.warning
        case .error: return LiftMarkTheme.destructive
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            HStack(alignment: .top) {
                Circle()
                    .fill(levelColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(formatTimestamp(entry.timestamp))
                            .font(.lmMono(size: 11, relativeTo: .caption2))
                            .foregroundStyle(.secondary)
                        Text(entry.category.rawValue)
                            .font(.lmCaption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(LiftMarkTheme.secondaryBackground)
                            .clipShape(Capsule())
                    }

                    Text(entry.message)
                        .font(.lmMono(size: 12, relativeTo: .caption))
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer()

                if entry.metadata != nil || entry.stackTrace != nil {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.lmCaption)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded {
                if let metadata = entry.metadata, !metadata.isEmpty {
                    let formatted = metadata.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                    Text(formatted)
                        .font(.lmMono(size: 11, relativeTo: .caption2))
                        .foregroundStyle(.secondary)
                        .padding(.leading, LiftMarkTheme.spacingMD)
                }
                if let stackTrace = entry.stackTrace {
                    Text(stackTrace)
                        .font(.lmMono(size: 11, relativeTo: .caption2))
                        .foregroundStyle(LiftMarkTheme.destructive.opacity(0.8))
                        .padding(.leading, LiftMarkTheme.spacingMD)
                }
            }
        }
        .padding(.vertical, LiftMarkTheme.spacingXS)
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else {
            return timestamp
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    var color: Color = LiftMarkTheme.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.lmCaption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, LiftMarkTheme.spacingSM)
                .padding(.vertical, LiftMarkTheme.spacingXS)
                .background(isSelected ? color.opacity(0.15) : Color.clear)
                .foregroundStyle(isSelected ? color : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? color.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
