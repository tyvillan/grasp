import Foundation

/// Something GRASP can hand out as a file: an overview or an exam's study
/// guide, laid out as plain blocks every format can carry.
///
/// Built once, written two ways: Markdown (Obsidian reads it, concept map
/// included) and HTML styled for print, which the Mac turns into PDF and
/// Word. Keeping the layout here, not in each app, means a Windows export
/// comes out the same.
///
/// Text in blocks may use inline Markdown: `**bold**`, `*italic*`,
/// `` `code` ``, the same subset overviews are written in.
public struct ExportDocument: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var blocks: [Block]

    public enum Block: Sendable, Equatable {
        /// Level 1 is a lesson or a part; 2 and 3 sit under it.
        case heading(String, level: Int)
        /// A line break inside is kept: a question's given values each
        /// stand on their own line.
        case paragraph(String)
        /// Quieter than a paragraph: a kicker, a note under a problem.
        case note(String)
        case bullets([String])
        case numbered([String])
        /// A labelled box: traps, key terms, "Remember".
        case callout(label: String, lines: [String])
        /// A matrix or a small table. `bar` puts a divider before that
        /// column, for an augmented matrix.
        case table(rows: [[String]], bar: Int?)
        case code(String, language: String?)
        /// A problem to try: numbered, with a hint under it.
        case problem(number: Int, label: String?, question: String, hint: String?)
        /// One entry in an answer key.
        case answer(number: Int, label: String?, steps: [String], answer: String?)
        /// A rule between what's to try and what answers it.
        case pageBreak
    }

    public init(title: String, subtitle: String? = nil, blocks: [Block] = []) {
        self.title = title
        self.subtitle = subtitle
        self.blocks = blocks
    }

    /// A file name for it: the title, without characters a file system
    /// refuses.
    public var fileName: String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "GRASP Export" : cleaned
    }

    // MARK: - Markdown

    public func markdown() -> String {
        var out = ["# \(title)"]
        if let subtitle { out.append("*\(subtitle)*") }
        for block in blocks {
            out.append("")
            switch block {
            case .heading(let text, let level):
                out.append(String(repeating: "#", count: min(max(level, 1), 3) + 1) + " " + text)
            case .paragraph(let text):
                out.append(Self.markdownLines(text))
            case .note(let text):
                out.append("*" + text + "*")
            case .bullets(let items):
                out += items.map { "- " + Self.markdownLines($0, indent: "  ") }
            case .numbered(let items):
                out += items.enumerated().map { "\($0.offset + 1). " + Self.markdownLines($0.element, indent: "   ") }
            case .callout(let label, let lines):
                out.append("> **\(label)**")
                out += lines.map { "> - " + $0.replacingOccurrences(of: "\n", with: " ") }
            case .table(let rows, let bar):
                guard let width = rows.map(\.count).max(), width > 0 else { continue }
                let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
                func row(_ cells: [String]) -> String {
                    var cells = cells
                    if let bar, bar > 0, bar < cells.count { cells[bar] = "│ " + cells[bar] }
                    return "| " + cells.joined(separator: " | ") + " |"
                }
                // Markdown tables need a header row; a matrix has none, so
                // it gets an empty one.
                out.append(row(Array(repeating: " ", count: width)))
                out.append("|" + Array(repeating: "---|", count: width).joined())
                out += padded.map(row)
            case .code(let code, let language):
                out.append("```" + (language ?? ""))
                out.append(code)
                out.append("```")
            case .problem(let number, let label, let question, let hint):
                out.append("**\(number).**" + (label.map { " *(\($0))*" } ?? "") + " " + Self.markdownLines(question))
                if let hint { out.append(""); out.append("> " + hint) }
            case .answer(let number, let label, let steps, let answer):
                out.append("**\(number).**" + (label.map { " *(\($0))*" } ?? ""))
                out += steps.map { "- " + Self.markdownLines($0, indent: "  ") }
                if let answer { out.append((steps.isEmpty ? "" : "\n") + Self.markdownLines(answer)) }
            case .pageBreak:
                out.append("---")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A line break Markdown keeps (two spaces), indented under a list item.
    static func markdownLines(_ text: String, indent: String = "") -> String {
        text.components(separatedBy: "\n").joined(separator: "  \n" + indent)
    }

    // MARK: - HTML

    /// A whole page, styled for print: black on white, a serif body, room
    /// in the margins. Web fonts are left out -- a PDF made offline has to
    /// look the same. Sizes are set small: AppKit's HTML reader, which the
    /// Mac's PDF and Word come from, draws CSS points about a third larger.
    public func html() -> String {
        var body: [String] = ["<h1>\(Self.inline(title))</h1>"]
        if let subtitle { body.append("<p class=\"subtitle\">\(Self.inline(subtitle))</p>") }
        for (index, block) in blocks.enumerated() {
            // A Mermaid concept map is a drawing only Markdown readers make;
            // on paper it would print as its source. Its heading goes too.
            if case .code(_, "mermaid") = block { continue }
            if case .heading = block, index + 1 < blocks.count, case .code(_, "mermaid") = blocks[index + 1] { continue }
            switch block {
            case .heading(let text, let level):
                let tag = "h\(min(max(level, 1), 3) + 1)"
                // AppKit's HTML reader drops heading margins, which ran a
                // heading into the text above it; an empty line keeps them
                // apart in PDF and Word alike.
                body.append("<p class=\"gap\">&nbsp;</p><\(tag)>\(Self.inline(text))</\(tag)>")
            case .paragraph(let text):
                body.append("<p>\(Self.inline(text))</p>")
            case .note(let text):
                body.append("<p class=\"note\">\(Self.inline(text))</p>")
            case .bullets(let items):
                body.append("<ul>" + items.map { "<li>\(Self.inline($0))</li>" }.joined() + "</ul>")
            case .numbered(let items):
                body.append("<ol>" + items.map { "<li>\(Self.inline($0))</li>" }.joined() + "</ol>")
            case .callout(let label, let lines):
                body.append("<div class=\"callout\"><p class=\"label\">\(Self.escape(label))</p><ul>"
                            + lines.map { "<li>\(Self.inline($0))</li>" }.joined() + "</ul></div>")
            case .table(let rows, let bar):
                let cells = rows.map { row in
                    "<tr>" + row.enumerated().map { index, cell in
                        "<td\(index == bar ? " class=\"bar\"" : "")>\(Self.inline(cell))</td>"
                    }.joined() + "</tr>"
                }
                body.append("<table>" + cells.joined() + "</table>")
            case .code(let code, _):
                body.append("<pre>\(Self.escape(code))</pre>")
            case .problem(let number, let label, let question, let hint):
                var html = "<div class=\"problem\"><p><b>\(number).</b>"
                if let label { html += " <span class=\"label\">\(Self.escape(label))</span>" }
                html += "<br>\(Self.inline(question))</p>"
                if let hint { html += "<p class=\"note\">\(Self.inline(hint))</p>" }
                body.append(html + "</div>")
            case .answer(let number, let label, let steps, let answer):
                var html = "<div class=\"answer\"><p><b>\(number).</b>"
                if let label { html += " <span class=\"label\">\(Self.escape(label))</span>" }
                html += "</p>"
                if !steps.isEmpty { html += "<ul>" + steps.map { "<li>\(Self.inline($0))</li>" }.joined() + "</ul>" }
                if let answer { html += "<p>\(Self.inline(answer))</p>" }
                body.append(html + "</div>")
            case .pageBreak:
                body.append("<hr>")
            }
        }
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>\(Self.escape(title))</title>
            <style>
            body { font-family: "Iowan Old Style", Georgia, "Times New Roman", serif; font-size: 9pt;
                   line-height: 1.45; color: #1a1a1a; background: #ffffff; }
            h1 { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 17pt; margin: 0 0 4pt; }
            h2 { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 13pt; margin: 22pt 0 6pt;
                 border-bottom: 1px solid #cccccc; padding-bottom: 3pt; }
            h3 { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 10.5pt; margin: 16pt 0 4pt; }
            h4 { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 9pt; margin: 12pt 0 3pt; }
            p { margin: 0 0 7pt; }
            .subtitle { color: #555555; font-size: 9pt; margin-bottom: 14pt; }
            .note { color: #555555; font-size: 8pt; font-style: italic; }
            .label { color: #555555; font-size: 8pt; }
            .callout { border-left: 3px solid #999999; padding: 2pt 0 2pt 10pt; margin: 8pt 0 10pt; }
            .callout .label { font-weight: bold; margin-bottom: 2pt; }
            .problem, .answer { margin: 0 0 12pt; }
            table { border-collapse: collapse; margin: 6pt 0 10pt; }
            td { border: 1px solid #bbbbbb; padding: 3pt 8pt; text-align: right; font-family: Menlo, monospace; font-size: 8pt; }
            td.bar { border-left: 2px solid #333333; }
            pre, code { font-family: Menlo, monospace; font-size: 7.5pt; }
            pre { background: #f4f4f4; padding: 6pt 8pt; white-space: pre-wrap; }
            ul, ol { margin: 0 0 8pt; padding-left: 20pt; }
            li { margin-bottom: 3pt; }
            .gap { font-size: 5pt; margin: 0; }
            hr { border: none; border-top: 1px solid #999999; margin: 18pt 0; }
            </style></head><body>
            \(body.joined(separator: "\n"))
            </body></html>
            """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Escaped text with its inline Markdown turned into tags, and line
    /// breaks kept.
    static func inline(_ text: String) -> String {
        var html = escape(text)
        for (pattern, template) in [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, "<i>$1</i>"),
        ] {
            html = html.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return html.replacingOccurrences(of: "\n", with: "<br>")
    }
}
