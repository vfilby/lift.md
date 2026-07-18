import SwiftUI
import UniformTypeIdentifiers

struct SettingsDataSection: View {
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var exportFile: ExportFile?
    @State private var showImportSheet = false
    @State private var showImportConfirm = false
    @State private var importSourceURL: URL?
    @State private var importIsDatabase = false
    @State private var showImportResult = false
    @State private var importResultMessage = ""
    @State private var showImportError = false
    @State private var importErrorMessage = ""

    var body: some View {
        Group {
            Button {
                exportData()
            } label: {
                Label("Export Data", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("export-data-button")

            Button {
                showImportSheet = true
            } label: {
                Label("Import Data", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("import-data-button")
        }
        .modifier(DatabaseBackupModifiers(
            exportFile: $exportFile,
            showImportSheet: $showImportSheet,
            handleImportFileSelection: handleImportFileSelection,
            showExportError: $showExportError,
            exportErrorMessage: exportErrorMessage,
            showImportConfirm: $showImportConfirm,
            importIsDatabase: importIsDatabase,
            performImport: performImport,
            showImportResult: $showImportResult,
            importResultMessage: importResultMessage,
            showImportError: $showImportError,
            importErrorMessage: importErrorMessage
        ))
    }

    // MARK: - Data Export (JSON)

    private func exportData() {
        do {
            let service = WorkoutExportService()
            let url = try service.exportUnifiedJson()
            exportFile = ExportFile(url: url)
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    // MARK: - Data Import (JSON + DB)

    private func handleImportFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importErrorMessage = "Unable to access the selected file."
                showImportError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Copy to a temporary location so we can validate and import later
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                importErrorMessage = "Failed to copy file: \(error.localizedDescription)"
                showImportError = true
                return
            }

            let isJson = url.pathExtension.lowercased() == "json"

            if isJson {
                // Validate JSON
                let importService = JsonImportService()
                guard importService.validateJsonFile(at: tempURL) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    importErrorMessage = "The selected file is not a valid lift.md export."
                    showImportError = true
                    return
                }
                importSourceURL = tempURL
                importIsDatabase = false
                showImportConfirm = true
            } else {
                // Validate database
                guard DatabaseBackupService.validateDatabaseFile(at: tempURL) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    importErrorMessage = "The selected file is not a valid lift.md database."
                    showImportError = true
                    return
                }
                importSourceURL = tempURL
                importIsDatabase = true
                showImportConfirm = true
            }

        case .failure(let error):
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }

    private func performImport() {
        guard let sourceURL = importSourceURL else { return }

        if importIsDatabase {
            // Database import (replaces all data)
            do {
                try DatabaseBackupService.importDatabase(from: sourceURL)
                try? FileManager.default.removeItem(at: sourceURL)
                importResultMessage = "Your data has been replaced successfully."
                showImportResult = true
            } catch {
                try? FileManager.default.removeItem(at: sourceURL)
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        } else {
            // JSON import (merges data)
            do {
                let importService = JsonImportService()
                let result = try importService.importUnifiedJson(from: sourceURL)
                try? FileManager.default.removeItem(at: sourceURL)
                importResultMessage = result.summary
                showImportResult = true
            } catch {
                try? FileManager.default.removeItem(at: sourceURL)
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        }
    }
}

// MARK: - Database Backup Modifiers

struct DatabaseBackupModifiers: ViewModifier {
    @Binding var exportFile: ExportFile?
    @Binding var showImportSheet: Bool
    let handleImportFileSelection: (Result<[URL], Error>) -> Void
    @Binding var showExportError: Bool
    let exportErrorMessage: String
    @Binding var showImportConfirm: Bool
    let importIsDatabase: Bool
    let performImport: () -> Void
    @Binding var showImportResult: Bool
    let importResultMessage: String
    @Binding var showImportError: Bool
    let importErrorMessage: String

    func body(content: Content) -> some View {
        content
            .shareSheet(item: $exportFile)
            .fileImporter(
                isPresented: $showImportSheet,
                allowedContentTypes: [.json, .database, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImportFileSelection(result)
            }
            .alert("Export Error", isPresented: $showExportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
            .alert(importIsDatabase ? "Replace All Data?" : "Import Data?", isPresented: $showImportConfirm) {
                Button("Cancel", role: .cancel) {}
                Button(importIsDatabase ? "Replace" : "Import", role: importIsDatabase ? .destructive : nil) {
                    performImport()
                }
            } message: {
                if importIsDatabase {
                    Text("This will replace all your workout data with the imported database. This cannot be undone.")
                } else {
                    Text("This will merge the imported data with your existing data. "
                        + "Duplicate plans and sessions will be skipped.")
                }
            }
            .alert("Import Successful", isPresented: $showImportResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importResultMessage)
            }
            .alert("Import Error", isPresented: $showImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage)
            }
    }
}
