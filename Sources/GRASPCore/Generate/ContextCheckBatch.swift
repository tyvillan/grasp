import Foundation

/// The context check for several cards of one note in one request: the
/// note goes once, each card is a numbered entry, and the reply is a list
/// keyed by those numbers. Everything about the reply is validated, because
/// a wrong guess here deletes or rewrites a card.
extension OllamaGenerator {
    static func validateContextBatchPrompt(
        items: [ContextCheckItem], noteContext: String, courseName: String
    ) -> String {
        let entries = items.enumerated().map { index, item in
            "\(index + 1). Term: \(item.front)\n   Extracted definition: \(item.back)"
        }.joined(separator: "\n")
        return """
        You are checking flashcards auto-extracted from a student's notes for the course \
        "\(courseName)". A flashcard's front is a term and its back should be a general, \
        academically accurate definition of that term -- the kind of definition that belongs in a \
        course glossary, true regardless of which specific assignment or example it came from.

        For reference, the note these were extracted from:
        \(noteContext.prefix(2000))

        The cards:
        \(entries)

        Judge every card on its own. For each one, first decide: is the term itself a real, general \
        concept a student in "\(courseName)" would need to know, or only a label specific to this one \
        document (a draft's section heading, an assignment instruction, a personal narrative, a \
        fragment)? Judge the TERM, not the quality of its extracted definition.
        - Not a real general concept: {"id": "N", "verdict": "reject"}.
        - A real concept whose definition already states it accurately: {"id": "N", "verdict": "valid"}.
        - A real concept whose definition does not: {"id": "N", "verdict": "refine", "refinedBack": "..."} \
        with a brand-new, general, academically accurate definition written from your own knowledge \
        of the subject. Do not just shorten or paraphrase the extracted text.

        Answer for all \(items.count) cards, once each, using the numbers above as the ids. Respond \
        with ONLY one JSON object shaped {"results": [{"id": "1", "verdict": "...", "refinedBack": \
        "..."}]} ("refinedBack" only for "refine"). No other text.
        """
    }

    /// Reads a batch reply. `count` is how many cards were sent, numbered
    /// 1 to `count`. Returns, by number, the verdicts that are valid:
    /// - an id that was not sent, or sent twice, makes the whole reply
    ///   untrustworthy, so nothing is returned;
    /// - a card missing from the reply, with an unknown verdict, or a
    ///   "refine" without text, is simply left out so the caller asks again.
    static func parseContextBatch(_ raw: String, count: Int) -> [Int: ContextValidation] {
        struct Reply: Decodable {
            var results: [Entry]
            struct Entry: Decodable {
                var id: Flexible
                var verdict: String?
                var refinedBack: String?
            }
            struct Flexible: Decodable {
                let text: String
                init(from decoder: Decoder) throws {
                    let box = try decoder.singleValueContainer()
                    if let s = try? box.decode(String.self) { text = s }
                    else if let i = try? box.decode(Int.self) { text = String(i) }
                    else { text = "" }
                }
            }
        }
        guard let data = salvageJSON(raw).data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return [:] }
        var seen = Set<Int>()
        for entry in reply.results {
            guard let n = Int(entry.id.text.trimmingCharacters(in: .whitespaces)), (1...max(count, 1)).contains(n),
                  seen.insert(n).inserted else { return [:] }
        }
        var out: [Int: ContextValidation] = [:]
        for entry in reply.results {
            guard let n = Int(entry.id.text.trimmingCharacters(in: .whitespaces)) else { continue }
            switch entry.verdict?.lowercased().trimmingCharacters(in: .whitespaces) {
            case "valid": out[n] = ContextValidation(.valid)
            case "reject": out[n] = ContextValidation(.reject)
            case "refine":
                guard let back = entry.refinedBack?.trimmingCharacters(in: .whitespacesAndNewlines), !back.isEmpty
                else { continue }
                out[n] = ContextValidation(.refine(newBack: back))
            default: continue
            }
        }
        return out
    }

    public func validateContextBatch(
        items: [ContextCheckItem], noteContext: String, courseName: String
    ) async -> [String: ContextValidation] {
        guard !noteContext.isEmpty, items.count > 1 else { return [:] }
        let prompt = Self.validateContextBatchPrompt(items: items, noteContext: noteContext, courseName: courseName)
        guard let content = try? await chat(prompt: prompt) else { return [:] }
        var result: [String: ContextValidation] = [:]
        for (number, verdict) in Self.parseContextBatch(content, count: items.count) {
            result[items[number - 1].id] = verdict
        }
        return result
    }
}
