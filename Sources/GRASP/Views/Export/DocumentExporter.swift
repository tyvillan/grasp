import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GRASPCore

/// The file formats an overview or a study guide downloads as.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF"
    case word = "Word Document"
    case markdown = "Markdown"

    var id: String { rawValue }

    var contentType: UTType {
        switch self {
        case .pdf: return .pdf
        case .word: return UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .markdown: return UTType("net.daringfireball.markdown") ?? .plainText
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .word: return "docx"
        case .markdown: return "md"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .word: return "doc.text"
        case .markdown: return "text.document"
        }
    }
}

/// Saves an `ExportDocument` where the student picks. Markdown is written
/// as is; PDF and Word both come from its print HTML, read by AppKit's own
/// HTML importer, so the two look alike and no web view is needed.
enum DocumentExporter {
    static func save(_ document: ExportDocument, as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(document.fileName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(document, as: format, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func write(_ document: ExportDocument, as format: ExportFormat, to url: URL) throws {
        switch format {
        case .markdown:
            try document.markdown().write(to: url, atomically: true, encoding: .utf8)
        case .word:
            let text = try attributed(document)
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url, options: .atomic)
        case .pdf:
            try writePDF(attributed(document), to: url)
        }
    }

    static func attributed(_ document: ExportDocument) throws -> NSAttributedString {
        try NSAttributedString(
            data: Data(document.html(fontScale: ExportDocument.appKitFontScale).utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }

    /// US Letter with one-inch margins, paginated by the text system so
    /// pages break between lines, never through one.
    static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 72; info.bottomMargin = 72
        info.leftMargin = 72; info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        // Paper, not the window: in dark mode a text view would otherwise
        // draw its own dark background under the black text.
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(for: container)
        }
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// "Download as" with one item per format.
struct ExportMenu: View {
    let title: String
    let make: () -> ExportDocument?

    var body: some View {
        Menu(title) {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    if let document = make() { DocumentExporter.save(document, as: format) }
                } label: {
                    Label(format.rawValue, systemImage: format.systemImage)
                }
            }
        }
    }
}
