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

// MARK: - One review over the whole lesson

extension OllamaGenerator {
    static func reviewOverviewPrompt(noteContext: String, sections: [OverviewSection]) -> String {
        let written = sections.enumerated().map { index, section -> String in
            var lines = ["Section \(index + 1): \(section.heading)"]
            lines += section.paragraphs.map { "Paragraph: \($0)" }
            lines += section.terms.map { "Term: \($0.term) -- \($0.text)" }
            if let check = section.check {
                lines.append("Question: \(check.question)")
                lines.append("Answer: \(check.answer)")
            }
            if let example = section.example {
                for step in example.steps {
                    lines.append("Example step: \(step.action)" + (step.result.map { " -> \($0)" } ?? ""))
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return noteOpening(courseName: "this course", noteContext: noteContext) + """
        You are checking a lesson a student will study from, written about the notes above. Find \
        only statements that are false: they contradict the notes, get the subject's facts or math \
        wrong, or give a wrong answer to a question. A true statement the notes don't happen to \
        mention is NOT an error -- leave it alone. Style, wording and missing detail are not errors \
        either. Most lessons have no errors, and at most one or two sentences in a section are ever \
        wrong -- an empty list is the normal result.

        The lesson:
        \(written)

        For each false statement, give the section number, copy the sentence exactly, character \
        for character, as original, and give corrected: the sentence rewritten to be true. Use an \
        empty string only when the sentence cannot be fixed and should be removed.

        Respond with ONLY one JSON object shaped {"sections": [{"section": 1, "items": [{"original": \
        "...", "corrected": "..."}]}]}. Leave out sections with no errors. No other text.
        """
    }

    /// One array of fixes per section, or nil when the reply is not a
    /// usable review. A section number that was not in the lesson is
    /// dropped; each fix is still checked against its section's text when
    /// applied (`OverviewReview.apply`), so a quoted sentence that is not
    /// there changes nothing.
    static func parseOverviewReview(_ raw: String, sectionCount: Int) -> [[OverviewFix]]? {
        struct Reply: Decodable {
            var sections: [Entry]?
            struct Entry: Decodable {
                var section: Int?
                var items: [Item]?
            }
            struct Item: Decodable {
                var original: String?
                var corrected: String?
            }
        }
        guard let data = salvageJSON(raw).data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let entries = reply.sections else { return nil }
        var out = [[OverviewFix]](repeating: [], count: sectionCount)
        for entry in entries {
            guard let number = entry.section, (1...max(sectionCount, 1)).contains(number) else { continue }
            for item in entry.items ?? [] {
                guard let original = clean(item.original) else { continue }
                out[number - 1].append(OverviewFix(original: original, corrected: clean(item.corrected)))
            }
        }
        return out
    }

    public func reviewOverview(noteContext: String, sections: [OverviewSection]) async -> [[OverviewFix]]? {
        guard !noteContext.isEmpty, !sections.isEmpty else { return nil }
        let prompt = Self.reviewOverviewPrompt(noteContext: noteContext, sections: sections)
        guard let content = try? await chat(prompt: prompt, maxTokens: 1_200) else { return nil }
        return Self.parseOverviewReview(content, sectionCount: sections.count)
    }
}
