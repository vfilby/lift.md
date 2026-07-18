import Foundation

// MARK: - File Import Result

struct FileImportResult {
    let success: Bool
    let markdown: String?
    let fileName: String?
    let error: String?
}

// MARK: - FileImportService

enum FileImportService {

    private static let maxFileSize = 1_000_000 // 1 MB
    private static let validExtensions: Set<String> = ["txt", "md", "markdown"]

    // MARK: - URL Validation

    /// Check if a URL is a valid file import URL with a supported extension.
    static func isFileImportUrl(_ urlString: String) -> Bool {
        guard let fileUrl = toFileUrl(urlString) else { return false }
        let ext = (fileUrl.pathExtension).lowercased()
        return validExtensions.contains(ext)
    }

    // MARK: - Read Shared File

    /// Read the contents of a shared file from a file:// or liftmark:// URL.
    static func readSharedFile(_ urlString: String) -> FileImportResult {
        guard let fileUrl = toFileUrl(urlString) else {
            return FileImportResult(success: false, markdown: nil, fileName: nil, error: "Unsupported URL scheme.")
        }

        let path = fileUrl.path
        let fileName = fileUrl.lastPathComponent
        let ext = fileUrl.pathExtension.lowercased()

        // Validate extension
        guard validExtensions.contains(ext) else {
            return FileImportResult(
                success: false, markdown: nil, fileName: fileName,
                error: "Unsupported file type. Only .txt, .md, and .markdown files are supported."
            )
        }

        let fileManager = FileManager.default

        // Check file exists
        guard fileManager.fileExists(atPath: path) else {
            return FileImportResult(success: false, markdown: nil, fileName: fileName, error: "File not found.")
        }

        // Check file size
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let fileSize = attributes[.size] as? Int ?? 0

            if fileSize == 0 {
                return FileImportResult(success: false, markdown: nil, fileName: fileName, error: "File is empty.")
            }
            if fileSize > maxFileSize {
                return FileImportResult(
                    success: false, markdown: nil, fileName: fileName, error: "File is too large (max 1MB).")
            }
        } catch {
            return FileImportResult(
                success: false, markdown: nil, fileName: fileName,
                error: "Failed to check file size: \(error.localizedDescription)")
        }

        // Read file content
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)

            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return FileImportResult(success: false, markdown: nil, fileName: fileName, error: "File is empty.")
            }

            return FileImportResult(success: true, markdown: content, fileName: fileName, error: nil)
        } catch {
            return FileImportResult(
                success: false, markdown: nil, fileName: fileName,
                error: "Failed to read file: \(error.localizedDescription)")
        }
    }

    // MARK: - Path Safety

    /// Validate that a file path is safe for the liftmark:// deep link handler.
    /// Returns the standardized path if valid, nil otherwise.
    /// Only allows files within the app's Documents, tmp, or Inbox directories
    /// with supported extensions (.txt, .md, .markdown).
    static func validateDeepLinkPath(_ filePath: String) -> String? {
        // Resolve symlinks and eliminate ".." traversal
        let resolved = (filePath as NSString).standardizingPath

        // Allowed root directories
        let allowedRoots: [String] = {
            var roots: [String] = []
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                roots.append(docs.path)
            }
            roots.append(NSTemporaryDirectory())
            // The system Inbox directory lives inside Documents
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                roots.append(docs.appendingPathComponent("Inbox").path)
            }
            return roots.map { ($0 as NSString).standardizingPath }
        }()

        let inAllowedDir = allowedRoots.contains { root in
            resolved == root || resolved.hasPrefix(root + "/")
        }
        guard inAllowedDir else { return nil }

        // Validate extension
        let ext = (resolved as NSString).pathExtension.lowercased()
        guard validExtensions.contains(ext) else { return nil }

        return resolved
    }

    // MARK: - URL Conversion

    /// Convert a URL string to a file URL.
    /// Accepts file:// and liftmark:// schemes.
    private static func toFileUrl(_ urlString: String) -> URL? {
        if urlString.hasPrefix("file://") {
            return URL(string: urlString)
        }
        if urlString.hasPrefix("liftmark://") {
            let path = urlString.replacingOccurrences(of: "liftmark://", with: "")
            return URL(fileURLWithPath: "/\(path)")
        }
        return nil
    }
}
