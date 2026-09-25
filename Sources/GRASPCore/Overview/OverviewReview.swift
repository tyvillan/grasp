import Foundation

/// Applying the second pass, and the deterministic clean-up every lesson
/// gets -- both when it's written and when it's read, so lessons written
/// before a rule existed benefit from it too.
public enum OverviewReview {
    // MARK: - Fact-check fixes

    /// Applies review corrections to a section. A fix only lands where its
    /// `original` text actually appears, so a reviewer that paraphrases
    /// instead of quoting changes nothing. A paragraph a removal empties is
    /// dropped; a check whose question or answer was removed goes with it.
    public static func apply(_ proposed: [OverviewFix], to section: OverviewSection) -> OverviewSection {
        guard !proposed.isEmpty else { return section }
        // A reviewer that wants to delete much of a section has misread its
        // job -- measured on a real lesson, one marked every sentence of a
        // correct section for removal because the notes didn't spell each
        // one out. Corrections still apply; wholesale removal doesn't.
        let sentenceCount = section.paragraphs.map { OverviewChunker.sentences(of: $0).count }.reduce(0, +)
        let removals = proposed.filter { $0.corrected == nil }.count
        let fixes = removals > max(1, sentenceCount / 3) ? proposed.filter { $0.corrected != nil } : proposed
        guard !fixes.isEmpty else { return section }
        var section = section
        func fix(_ text: String) -> String {
            var result = text
            for fix in fixes {
                let original = fix.original.trimmingCharacters(in: .whitespacesAndNewlines)
                // Very short quotes would match in the wrong place.
                guard original.count >= 12, let range = result.range(of: original) else { continue }
                result.replaceSubrange(range, with: fix.corrected ?? "")
            }
            return result
                .replacingOccurrences(of: "  ", with: " ")
                .replacingOccurrences(of: " .", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        section.paragraphs = section.paragraphs.map(fix).filter { $0.count > 20 }
        if let check = section.check {
            let question = fix(check.question), answer = fix(check.answer)
            section.check = question.count > 10 && answer.count > 5
                ? OverviewCheck(question: question, answer: answer) : nil
        }
        section.terms = section.terms.map { term in
            var term = term
            term.text = fix(term.text)
            term.example = term.example.map(fix).flatMap { $0.isEmpty ? nil : $0 }
            term.nonExample = term.nonExample.map(fix).flatMap { $0.isEmpty ? nil : $0 }
            return term
        }.filter { !$0.text.isEmpty }
        if var example = section.example {
            example.steps = example.steps.map { step in
                var step = step
                step.action = fix(step.action)
                step.result = step.result.map(fix).flatMap { $0.isEmpty ? nil : $0 }
                step.why = step.why.map(fix).flatMap { $0.isEmpty ? nil : $0 }
                return step
            }.filter { !$0.action.isEmpty }
            example.outcome = example.outcome.map(fix).flatMap { $0.isEmpty ? nil : $0 }
            section.example = example.steps.count >= 2 ? example : nil
        }
        return section
    }

    /// Drops what the lesson-level review found repeated. A dropped
    /// section's key terms move to the section it repeats, unless that
    /// already defines them -- the terms are often the one thing the
    /// repeat added.
    public static func apply(_ repetition: OverviewRepetition, to document: OverviewDocument) -> OverviewDocument {
        var document = document
        var drop: Set<Int> = []
        for pair in repetition.sections
        where pair.repeated != pair.original
            && document.sections.indices.contains(pair.repeated)
            && document.sections.indices.contains(pair.original)
            && pair.original < pair.repeated
            && !drop.contains(pair.original) {
            drop.insert(pair.repeated)
            let known = Set(document.sections[pair.original].terms.map { AnswerGrading.normalize($0.term) })
            let moved = document.sections[pair.repeated].terms.filter { !known.contains(AnswerGrading.normalize($0.term)) }
            document.sections[pair.original].terms = Array((document.sections[pair.original].terms + moved)
                .prefix(OverviewLimits.termsPerSection))
            if document.sections[pair.original].figure == nil {
                document.sections[pair.original].figure = document.sections[pair.repeated].figure
            }
            if document.sections[pair.original].example == nil {
                document.sections[pair.original].example = document.sections[pair.repeated].example
            }
        }
        // Never empty a lesson on a reviewer's say-so.
        if drop.count < document.sections.count {
            document.sections = document.sections.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        let dropTakeaways = Set(repetition.takeaways)
        if dropTakeaways.count < document.takeaways.count {
            document.takeaways = document.takeaways.enumerated().filter { !dropTakeaways.contains($0.offset) }.map(\.element)
        }
        return document
    }

    // MARK: - Clean-up

    /// The rules every lesson gets: no invented math in a lecture that
    /// isn't about math, no figure beside a section that doesn't discuss
    /// it, and no takeaway that says the same thing twice.
    public static func cleaned(_ document: OverviewDocument, noteText: String) -> OverviewDocument {
        var document = document
        let isMath = NoteMath.isMathematical(noteText)
        if !isMath {
            let hasCode = noteText.contains("```")
            let keep = { (text: String) in !containsFakeMath(text, codeCourse: hasCode) }
            func strip(_ text: String) -> String {
                OverviewChunker.sentences(of: text).filter(keep).joined(separator: " ")
            }
            document.hook = document.hook.map(strip).flatMap { $0.isEmpty ? nil : $0 }
            document.objectives = document.objectives.filter(keep)
            document.takeaways = document.takeaways.filter(keep)
            // A lecture that isn't about math has no formulas to list; the
            // ones found in the side lectures were all invented.
            document.formulas = []
            document.sections = document.sections.map { section in
                var section = section
                section.paragraphs = section.paragraphs.map(strip).filter { !$0.isEmpty }
                section.terms = section.terms.filter { keep($0.term) && keep($0.text) && !namesAVariable($0.term) }
                if let check = section.check, !(keep(check.question) && keep(check.answer)) { section.check = nil }
                return section
            }.filter { !$0.paragraphs.isEmpty }
        }
        document.sections = document.sections.map { section in
            var section = section
            if let figure = section.figure, !figureFits(figure, in: section) { section.figure = nil }
            return section
        }
        document.takeaways = withoutNearDuplicates(document.takeaways)
        document.objectives = document.objectives.filter { objective in
            // "covers" -- a plan's field name leaking into its content.
            objective.split(separator: " ").count >= 3 && !objective.contains("],[") && !objective.contains("{")
        }
        return document
    }

    /// LaTeX, or an equation between invented variables, in a sentence
    /// from a lecture that isn't about math: `$P_{popular} = S_{safe}$`,
    /// `E = T - Friction`. Dollar amounts (`$20 plan`) are not math, and in a
    /// programming course `x = 5` is code, so that rule is skipped there.
    static func containsFakeMath(_ text: String, codeCourse: Bool) -> Bool {
        let latex = #"\$(?!\d)[^$\n]{1,80}\$|\\(?:text|frac|sum|cdot|times)\b|\text\{|[_^]\{"#
        if text.range(of: latex, options: .regularExpression) != nil { return true }
        guard !codeCourse else { return false }
        let equation = #"(?<![\w.])[A-Za-z](?:_\w+)?\s*=\s*[A-Za-z(\\][^.]*[-+/*][^.]*"#
        return text.range(of: equation, options: .regularExpression) != nil
    }

    /// "Total Execution E", "Execution quality E": a term named after a
    /// made-up variable.
    static func namesAVariable(_ term: String) -> Bool {
        term.range(of: #"\s[A-Z]$|\$"#, options: .regularExpression) != nil
    }

    /// Whether a figure belongs beside this section: it has to discuss what
    /// the figure shows. Measured on real lessons: a 2x2 transformation beside
    /// "matrices organize coefficients", and two lines beside a proof about
    /// linear dependence.
    public static func figureFits(_ figure: OverviewFigure, in section: OverviewSection) -> Bool {
        var parts = [section.heading] + section.paragraphs + section.terms.flatMap { [$0.term, $0.text] }
        if let example = section.example { parts += example.steps.map(\.action) }
        let text = parts.joined(separator: " ")
        let lower = text.lowercased()
        switch figure.kind {
        case .linearTransform:
            return lower.range(of: #"transform|shear|rotat|reflect|stretch|squash|unit square|basis|lands|î|ĵ|\be_?[12]\b|image of|maps? "#,
                               options: .regularExpression) != nil
        case .systemOfLines:
            // The section has to be about *this* system: its equation
            // written out, or at least two of its numbers.
            if text.range(of: #"\d*\s*x\s*[+\-−]\s*\d*\s*y\s*=\s*[+\-−]?\s*\d"#, options: .regularExpression) != nil {
                return true
            }
            let wanted = Set((figure.equations ?? []).joined().map { abs($0) }.filter { $0 > 1 + 1e-9 })
            let mentioned = NoteMath.numbers(in: text)
            return wanted.filter { value in mentioned.contains { abs($0 - value) < 1e-9 } }.count >= 2
        case .rowReduction:
            return lower.range(of: #"row|echelon|pivot|elimina|reduc|augmented|free variable|basic variable"#,
                               options: .regularExpression) != nil
        }
    }

    /// Takeaways that are near-copies of an earlier one, dropped.
    static func withoutNearDuplicates(_ items: [String]) -> [String] {
        var kept: [String] = []
        for item in items {
            let key = AnswerGrading.normalize(item)
            if kept.contains(where: { AnswerGrading.similarityRatio(AnswerGrading.normalize($0), key) >= 0.85 }) { continue }
            kept.append(item)
        }
        return kept
    }
}

// MARK: - Code in notes

/// The code a programming lecture writes out, placed beside the sections
/// that talk about it -- the programming counterpart of the row-reduction
/// figure. A section describing `self.__balance` in prose, with the
/// lecture's actual `BankAccount` class right there in the notes, is the
/// same failure as describing a matrix in a sentence.
public enum NoteCode {
    public struct Snippet: Sendable, Equatable {
        public let language: String?
        public let code: String
        /// Names the code defines or uses -- `BankAccount`, `deposit`,
        /// `__balance` -- for matching to the sections that mention them.
        public let identifiers: Set<String>
    }

    /// Fenced code blocks in `raw` note text (before reflow, which is what
    /// keeps their line breaks and indentation), skipping blocks that are
    /// really matrices or plain text.
    public static func snippets(in raw: String) -> [Snippet] {
        let pattern = try! NSRegularExpression(pattern: #"```([A-Za-z0-9+#]*)[ \t]*\n(.*?)\n[ \t]*```"#,
                                               options: [.dotMatchesLineSeparators])
        let ns = raw as NSString
        return pattern.matches(in: raw, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let language = ns.substring(with: match.range(at: 1))
            let code = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .newlines)
            guard looksLikeCode(code, declared: !language.isEmpty), code.split(separator: "\n").count <= 40 else { return nil }
            return Snippet(language: language.isEmpty ? nil : language, code: code, identifiers: identifiers(in: code))
        }
    }

    static func looksLikeCode(_ code: String, declared: Bool) -> Bool {
        if !NoteMatrices.matrices(in: code).isEmpty { return false }
        let signals = #"\b(def|class|return|import|public|private|void|int|print|func|let|var|const|function|if|for|while|self|this)\b|[;{}]|\w\(|=="#
        let hits = (try? NSRegularExpression(pattern: signals))?
            .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)) ?? 0
        return declared ? hits >= 1 : hits >= 3
    }

    /// Distinctive names: what's defined (`class X`, `def f`, `x =`), and
    /// dunder or dotted attributes. Common words (`self`, `print`) are not
    /// distinctive enough to place a snippet by.
    static func identifiers(in source: String) -> Set<String> {
        // Strings and comments first: a docstring saying "a class
        // demonstrating encapsulation" doesn't define a class.
        let code = source
            .replacingOccurrences(of: #"(?s)""".*?"""|'''.*?'''"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #""[^"\n]*"|'[^'\n]*'"#, with: "\"\"", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)(#|//).*$"#, with: "", options: .regularExpression)
        var names: Set<String> = []
        let patterns = [
            #"\b(?:class|def|func|function|interface|struct|enum)\s+([A-Za-z_]\w*)"#,
            #"\bself\.(\w+)"#, #"\bthis\.(\w+)"#,
            #"^\s*([A-Za-z_]\w*)\s*=[^=]"#,
            #"\b(__\w+__|__\w+)\b"#,
            #"\b([A-Z][a-z]+(?:[A-Z][a-z]+)+)\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                if let range = Range(match.range(at: 1), in: code) { names.insert(String(code[range])) }
            }
        }
        let common: Set<String> = ["self", "print", "init", "main", "value", "name", "data", "result", "i", "x", "y"]
        return names.filter { $0.count >= 3 && !common.contains($0) }
    }

    /// Which snippet goes beside which section: each snippet at most once,
    /// beside the section that mentions the most of its names -- and only
    /// if it mentions at least one.
    public static func placements(of snippets: [Snippet], in sections: [OverviewSection]) -> [Int: Snippet] {
        var result: [Int: Snippet] = [:]
        var scored: [(section: Int, snippet: Int, score: Int)] = []
        for (s, section) in sections.enumerated() {
            var parts = [section.heading] + section.paragraphs + section.terms.flatMap { [$0.term, $0.text] }
            if let example = section.example { parts += example.steps.flatMap { [$0.action, $0.result ?? ""] } }
            let text = parts.joined(separator: " ")
            for (n, snippet) in snippets.enumerated() {
                let score = snippet.identifiers.filter { text.contains($0) }.count
                if score > 0 { scored.append((s, n, score)) }
            }
        }
        var usedSnippets: Set<Int> = []
        for entry in scored.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.section < $1.section })
        where result[entry.section] == nil && !usedSnippets.contains(entry.snippet) {
            result[entry.section] = snippets[entry.snippet]
            usedSnippets.insert(entry.snippet)
        }
        return result
    }
}
