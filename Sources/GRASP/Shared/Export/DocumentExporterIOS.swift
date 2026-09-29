#if os(iOS)
import SwiftUI
import UIKit
import GRASPCore

// The iPhone's counterpart to the Mac's `DocumentExporter`
// (`Views/Export/DocumentExporter.swift`), under the same names so shared
// views can offer "Download" without knowing which app they're in. The
// file goes to the share sheet -- Save to Files, AirDrop, another app --
// since an iPhone has no save panel. No Word: iOS can't write .docx.

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF"
    case markdown = "Markdown"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .markdown: return "md"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .markdown: return "text.document"
        }
    }
}

enum DocumentExporter {
    static func save(_ document: ExportDocument, as format: ExportFormat) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(document.fileName).\(format.fileExtension)")
        do {
            switch format {
            case .markdown:
                try document.markdown().write(to: url, atomically: true, encoding: .utf8)
            case .pdf:
                try pdfData(html: document.html()).write(to: url, options: .atomic)
            }
        } catch {
            return
        }
        share(url)
    }

    /// US Letter with one-inch margins, laid out by WebKit's print path.
    static func pdfData(html: String) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 612, height: 792)
        renderer.setValue(paper, forKey: "paperRect")
        renderer.setValue(paper.insetBy(dx: 72, dy: 72), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// The share sheet, over whatever is on screen. A menu item has no
    /// sheet state of its own to present one from.
    static func share(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                                                  width: 0, height: 0)
        top.present(sheet, animated: true)
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
#endif
