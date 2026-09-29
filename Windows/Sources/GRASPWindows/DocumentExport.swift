import Foundation
import GRASPCore

/// Saves an `ExportDocument` (a study guide or an overview) as Markdown or a
/// PDF. The PDF comes from Edge or Chrome printing the document's HTML
/// headlessly, which lays the page out the way the HTML was written for.
nonisolated enum DocumentExport {
    enum Format: CaseIterable {
        case pdf, markdown

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .markdown: return "md"
            }
        }

        var label: String {
            switch self {
            case .pdf: return "PDF"
            case .markdown: return "Markdown"
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func write(_ document: ExportDocument, as format: Format, to url: URL) async throws {
        switch format {
        case .markdown:
            try Data(document.markdown().utf8).write(to: url)
        case .pdf:
            try await Task.detached { try printPDF(html: document.html(), to: url) }.value
        }
    }

    private static func printPDF(html: String, to url: URL) throws {
        guard let browser = browserPath else {
            throw Failure(message: "Saving a PDF needs Microsoft Edge or Google Chrome, and neither was found. Save as Markdown instead.")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let page = work.appendingPathComponent("document.html")
        // Not atomic: an atomic write fails if anything has the file open.
        try Data(html.utf8).write(to: page)
        try? FileManager.default.removeItem(at: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: browser)
        // Its own profile folder, so it never attaches to a browser window
        // Tyler already has open.
        process.arguments = [
            "--headless", "--disable-gpu", "--no-first-run", "--no-pdf-header-footer",
            "--user-data-dir=\(nativePath(work.appendingPathComponent("profile")))",
            "--print-to-pdf=\(nativePath(url))",
            page.absoluteString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: "The browser couldn't make the PDF. Save as Markdown instead.")
        }
    }

    /// Edge, else Chrome, wherever either installs itself.
    static var browserPath: String? {
        let env = ProcessInfo.processInfo.environment
        let roots = [env["ProgramFiles(x86)"] ?? #"C:\Program Files (x86)"#,
                     env["ProgramFiles"] ?? #"C:\Program Files"#,
                     env["LOCALAPPDATA"]].compactMap { $0 }
        let apps = [#"\Microsoft\Edge\Application\msedge.exe"#, #"\Google\Chrome\Application\chrome.exe"#]
        return apps.lazy.flatMap { app in roots.map { $0 + app } }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }
}
