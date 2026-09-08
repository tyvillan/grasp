import Foundation

/// A hand-rolled reader for the vault's YAML frontmatter -- the whole
/// corpus uses exactly three keys (`tags`, `type`, `source_file`) in
/// exactly two shapes (a `- ` list and a bare scalar), so a general YAML
/// parser is not worth taking as a dependency. If the vault's frontmatter
/// vocabulary ever broadens, revisit with a real parser.
public struct Frontmatter: Sendable {
    public var tags: [String]
    public var type: String?
    public var sourceFile: String?

    /// True when this note is an asset sidecar (an Obsidian stub that only
    /// embeds a binary, e.g. `Original file: [[AND_GATE.png]]`). Keying off
    /// `source_file` presence is more robust than matching the `asset` tag:
    /// verified exact match against the corpus (149 of 280 files).
    public var isAssetSidecar: Bool { sourceFile != nil }

    public static let empty = Frontmatter(tags: [], type: nil, sourceFile: nil)
}

public enum FrontmatterParser {
    /// Splits a raw markdown file into (frontmatter, body). If no
    /// frontmatter block is present, returns (.empty, the whole text).
    public static func split(_ text: String) -> (Frontmatter, body: String) {
        guard text.hasPrefix("---") else { return (.empty, text) }
        // Find the closing "---" on its own line after the opening one.
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return (.empty, text) }
        guard let closeIndex = lines.dropFirst().firstIndex(where: { $0 == "---" }) else {
            return (.empty, text)
        }
        let yamlLines = Array(lines[1..<closeIndex])
        let body = lines[(closeIndex + 1)...].joined(separator: "\n")
        return (parse(yamlLines), body)
    }

    private static func parse(_ lines: [String]) -> Frontmatter {
        var tags: [String] = []
        var type: String?
        var sourceFile: String?
        var inTagsList = false

        for rawLine in lines {
            let line = rawLine
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if let key = matchKey(line, "tags") {
                // Either `tags: [a, b]` inline, or a following `- ` list.
                let trimmed = key.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    inTagsList = true
                } else if trimmed.hasPrefix("[") {
                    tags = trimmed
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .components(separatedBy: ",")
                        .map { stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
                        .filter { !$0.isEmpty }
                    inTagsList = false
                } else {
                    tags = [stripQuotes(trimmed)]
                    inTagsList = false
                }
                continue
            }
            if inTagsList {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") {
                    tags.append(stripQuotes(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                    continue
                } else {
                    inTagsList = false
                    // fall through to check other keys on this line
                }
            }
            if let v = matchKey(line, "type") {
                type = stripQuotes(v.trimmingCharacters(in: .whitespaces))
                continue
            }
            if let v = matchKey(line, "source_file") {
                sourceFile = stripQuotes(v.trimmingCharacters(in: .whitespaces))
                continue
            }
        }
        return Frontmatter(tags: tags, type: type, sourceFile: sourceFile)
    }

    private static func matchKey(_ line: String, _ key: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        return String(line.dropFirst(key.count + 1))
    }

    private static func stripQuotes(_ s: String) -> String {
        var s = s
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}
