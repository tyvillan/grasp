import AppKit
import GRASPCore

/// Shared by every place that lets the user hand-pick material for a
/// course: the per-course "Add Files" button and the global "Upload
/// Document to Course" flow off the "+" menu.
enum ImportPanel {
    /// A native open panel with both files and folders enabled in one
    /// picker -- exactly "a folder or any specific files" in a single
    /// selection, rather than two separate flows for the two cases.
    static func pickFilesOrFolders(
        message: String = "Choose files or a folder to add to this course", prompt: String = "Add"
    ) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = message
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}

/// Summarizes an `ImportSummary` for the one-shot alert shown after a
/// manual add -- the toolbar's vault-wide Import button instead leaves its
/// summary sitting quietly in a tooltip, but a manual pick of a handful of
/// files needs an immediate "did that work" answer.
struct ImportResultMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String

    init(summary: ImportSummary) {
        if let error = summary.errors.first {
            title = "Import failed"
            body = error
            return
        }
        if summary.filesScanned == 0 {
            title = "Nothing to import"
            body = "No supported files were found. GRASP reads Markdown, PDF, Word (.docx), and Jupyter (.ipynb) files."
            return
        }
        title = "Import complete"
        var parts: [String] = []
        parts.append("\(summary.filesImportedOrUpdated) file\(summary.filesImportedOrUpdated == 1 ? "" : "s") added")
        if summary.cardsCreated > 0 {
            parts.append("\(summary.cardsCreated) draft card\(summary.cardsCreated == 1 ? "" : "s") created")
        }
        if summary.duplicatesSkipped > 0 {
            parts.append("\(summary.duplicatesSkipped) duplicate\(summary.duplicatesSkipped == 1 ? "" : "s") skipped")
        }
        if summary.filesUnchanged > 0 {
            parts.append("\(summary.filesUnchanged) already up to date")
        }
        body = parts.joined(separator: " · ")
    }
}
