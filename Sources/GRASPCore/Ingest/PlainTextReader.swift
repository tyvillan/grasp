import Foundation

/// Reads a note file as text: `.md` and `.txt` as they are, `.rtf` with its
/// formatting codes removed. Pure Swift, so it builds on Windows too.
public enum PlainTextReader {
    /// UTF-8 when the file is valid UTF-8, else Windows-1252 (what older
    /// Windows editors save plain text as), which never fails.
    public static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        return url.pathExtension.lowercased() == "rtf" || looksLikeRTF(text) ? rtfToText(text) : text
    }

    static func looksLikeRTF(_ text: String) -> Bool { text.hasPrefix("{\\rtf") }

    /// A small RTF reader: keeps the visible text, paragraph and line breaks,
    /// tabs, `\'hh` bytes and `\uN` characters, and drops everything else
    /// (fonts, colours, pictures, headers and other destination groups).
    public static func rtfToText(_ rtf: String) -> String {
        let scalars = Array(rtf.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var skipDepth: Int?          // depth at which a skipped group began
        var depth = 0
        var unicodeSkip = 1          // \ucN: fallback characters after \uN
        var pendingSkip = 0
        // Groups whose contents are not document text.
        let hidden: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer",
                                   "footnote", "object", "themedata", "colorschememapping", "latentstyles",
                                   "datastore", "listtable", "listoverridetable", "generator", "xmlnstbl"]

        func emit(_ scalar: Unicode.Scalar) {
            if skipDepth == nil { out.append(scalar) }
        }

        while i < scalars.count {
            let c = scalars[i]
            if pendingSkip > 0, c != "\\", c != "{", c != "}" {
                pendingSkip -= 1; i += 1; continue
            }
            switch c {
            case "{":
                depth += 1; i += 1
            case "}":
                if let start = skipDepth, depth <= start { skipDepth = nil }
                depth -= 1; i += 1
            case "\\":
                i += 1
                guard i < scalars.count else { break }
                let n = scalars[i]
                if n == "\\" || n == "{" || n == "}" {
                    emit(n); i += 1
                } else if n == "'" {
                    // \'hh : one byte in Windows-1252
                    if i + 2 < scalars.count,
                       let byte = UInt8(String(String.UnicodeScalarView([scalars[i + 1], scalars[i + 2]])), radix: 16),
                       let ch = String(data: Data([byte]), encoding: .windowsCP1252)?.unicodeScalars.first {
                        emit(ch)
                    }
                    i += 3
                } else if n == "*" {
                    // \* marks an optional destination: skip the whole group.
                    if skipDepth == nil { skipDepth = depth }
                    i += 1
                } else if n == "~" {
                    emit("\u{00A0}"); i += 1
                } else if n == "-" || n == "_" {
                    if n == "_" { emit("-") }
                    i += 1
                } else if n.properties.isAlphabetic {
                    var word = ""
                    while i < scalars.count, scalars[i].isASCII, scalars[i].properties.isAlphabetic {
                        word.unicodeScalars.append(scalars[i]); i += 1
                    }
                    var number = ""
                    if i < scalars.count, scalars[i] == "-" { number.append("-"); i += 1 }
                    while i < scalars.count, ("0"..."9").contains(scalars[i]) {
                        number.unicodeScalars.append(scalars[i]); i += 1
                    }
                    if i < scalars.count, scalars[i] == " " { i += 1 }   // the delimiter
                    if hidden.contains(word), skipDepth == nil { skipDepth = depth }
                    switch word {
                    case "par", "line", "sect", "page": emit("\n")
                    case "tab": emit("\t")
                    case "emdash": emit("\u{2014}")
                    case "endash": emit("\u{2013}")
                    case "bullet": emit("\u{2022}")
                    case "lquote": emit("\u{2018}")
                    case "rquote": emit("\u{2019}")
                    case "ldblquote": emit("\u{201C}")
                    case "rdblquote": emit("\u{201D}")
                    case "uc": unicodeSkip = Int(number) ?? 1
                    case "u":
                        if var code = Int(number) {
                            if code < 0 { code += 65536 }
                            if let scalar = Unicode.Scalar(UInt32(code)) { emit(scalar) }
                            pendingSkip = unicodeSkip
                        }
                    default: break
                    }
                } else {
                    i += 1
                }
            case "\n", "\r":
                i += 1                    // line breaks in the file are not text
            default:
                emit(c); i += 1
            }
        }
        // Tidy: trim trailing spaces per line and collapse runs of blank lines.
        let lines = String(out).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty == true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
