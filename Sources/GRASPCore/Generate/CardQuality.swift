import Foundation

/// Plain checks on a card the AI wrote (or a question it wrote for a test),
/// run after the model answers and before anything is saved. No model call,
/// no database: each one is a function of the text, so each one is tested
/// with real examples from the audit of the library.
///
/// Four problems are caught here:
/// - a refusal or filler where the answer should be ("not explicitly defined
///   in the provided notes");
/// - "which of the following" with no options in the question;
/// - a front that is only a heading or an assignment label ("HOMEWORK 2");
/// - a near-identical copy of a card already in the deck or in the batch.
///
/// Parser-made cards go through the placeholder and duplicate checks as
/// flags only (`reviewNotes`): nothing is hidden or removed.
public enum CardQuality {
    public enum Problem: Sendable, Equatable {
        case refusal, missingOptions, placeholderFront
    }

    /// The first problem with this card, or nil when it is usable.
    public static func problem(front: String, back: String) -> Problem? {
        if isRefusal(back) { return .refusal }
        if isPlaceholderFront(front) { return .placeholderFront }
        if hasMissingOptions(front) { return .missingOptions }
        return nil
    }

    /// The first problem with a written test question, or nil.
    public static func problem(prompt: String, answer: String) -> Problem? {
        if isRefusal(answer) { return .refusal }
        if hasMissingOptions(prompt) { return .missingOptions }
        return nil
    }

    // MARK: - Prompt rules

    /// Two rules every card-writing prompt carries. A model follows them
    /// most of the time, not every time, which is why the checks below
    /// exist; the rules themselves cannot be tested deterministically.
    public static let skipRule =
        "If the notes don't contain the answer, skip this card. Never write an answer that says the notes don't define it."
    public static let groundingRule =
        "Use only facts and examples that appear in the notes. Do not add your own examples."
    /// For a rewrite pass, where the count of items must stay the same.
    public static let unchangedRule =
        "If the notes don't contain a better answer, return the pair unchanged. Never write an answer that says the notes don't define it."

    // MARK: - Refusals

    /// Phrases that mean "the notes don't say", wherever they appear.
    private static let strongRefusals: [String] = [
        #"not (explicitly |directly |clearly )?(defined|mentioned|specified|stated|described|covered|discussed|given|included|provided|available|addressed|explained) (in|by|within|from) (the |these |this |your |any )?(provided |given |supplied |available |extracted |above )?(notes?|text|context|material|materials|document|passage|source|excerpt|lecture|content|information)"#,
        #"not (explicitly |directly )?defined in the provided"#,
        #"not (explicitly |directly |clearly )?(defined|stated|specified|mentioned|described)[^.]{0,60}\b(in|by) the (provided |given )?(notes?|text|context|material|document|passage|source)"#,
        #"not (explicitly |directly )?mentioned in the\b"#,
        #"(notes?|text|context|material|document|passage|source|excerpt) (do|does|did) not (explicitly |directly )?(contain|provide|mention|define|specify|say|state|include|describe|cover|give|explain|address)"#,
        #"(cannot|can't|can not|could not|couldn't|unable to) be (determined|found|answered|identified|derived|inferred) (from|in|using|based on)"#,
        #"(cannot|can't|can not|unable to) (determine|find|answer|say|tell|identify|derive|infer) (this |that |it |the answer |an answer )?(from|based on|using|in)"#,
        #"(there is|there's|there are|there was) no (information|mention|definition|detail|details|explanation|answer|context) (about|on|in|for|regarding|provided|available|given|to|of)"#,
        #"(no|insufficient|not enough|not sufficient) (relevant |further |additional |enough )?(information|context|detail|details) (is |are |was |were )?(available|provided|given|present|included|in the|about|to answer|to determine|from)"#,
        #"(the )?(provided|given|supplied) (notes?|text|context|material|document|passage) (do|does|did) not"#,
        #"\bas an ai\b"#,
        #"\bi (cannot|can't|can not|could not|couldn't|am unable|do not know|don't know|am not able)\b"#,
        #"\bnot enough information\b"#,
    ]

    /// Short replies that are a refusal only when they are nearly the whole
    /// answer, so a real sentence that happens to use the words is safe.
    private static let wholeAnswerRefusals: [String] = [
        #"^(no information( available| provided| given)?|information not (available|provided|given|specified)|not specified|not defined|not mentioned|not provided|not available|not stated|unknown|undefined|n/?a|none( provided| given)?|nothing|no answer|no definition( provided| given)?|cannot be determined|can't be determined|not applicable|unclear|tbd)\.?$"#,
        #"^(this |the )?(note|notes|text|context|material|document)s? (does not|doesn't|do not|don't) (say|mention|define|specify|contain|provide|cover)[^.]{0,60}\.?$"#,
    ]

    /// True when the text says the notes don't define it, or is a bare
    /// "no information" style reply. Case and spacing do not matter.
    public static func isRefusal(_ text: String) -> Bool {
        let t = squash(text)
        guard !t.isEmpty else { return false }
        for pattern in strongRefusals where t.range(of: pattern, options: .regularExpression) != nil { return true }
        for pattern in wholeAnswerRefusals where t.range(of: pattern, options: .regularExpression) != nil { return true }
        return false
    }

    private static func squash(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'*_`"))
    }

    // MARK: - Missing options

    private static let optionPhrases: [String] = [
        #"which (one )?of the following"#, #"select all (of )?(the |that apply|the following)"#,
        #"select all that apply"#, #"choose (the|one|all|which)\b"#, #"select (the|one) (correct|best|right|following)"#,
        #"pick (the|one) (correct|best|right)"#, #"which of these"#, #"which of (the )?(options|choices)"#,
        #"(from|among) the (following|options|choices)"#,
    ]

    /// True when the question asks to pick from options but lists none: a
    /// "which of the following" with no lines like `A)`, `1.` or `- `.
    public static func hasMissingOptions(_ prompt: String) -> Bool {
        let t = squash(prompt)
        guard optionPhrases.contains(where: { t.range(of: $0, options: .regularExpression) != nil }) else { return false }
        return optionCount(in: prompt) < 2
    }

    /// Option markers in the text: lettered or numbered lines, bullets, and
    /// inline "(a) ... (b) ...".
    static func optionCount(in text: String) -> Int {
        var lines = 0
        for line in text.components(separatedBy: .newlines) {
            if line.range(of: #"^\s*(\(?[A-Ha-h]\)|[A-Ha-h][\).:]|\(?[1-9]\)|[1-9][\).:]|[-•*▪◦])\s+\S"#,
                          options: .regularExpression) != nil { lines += 1 }
        }
        let inline = (try? NSRegularExpression(pattern: #"(?:^|\s)\(([a-hA-H1-9])\)\s+\S"#))
            .map { $0.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) } ?? 0
        return max(lines, inline)
    }

    // MARK: - Placeholder fronts

    private static let labelWords =
        "homework|hw|assignment|exercise|problem|question|part|lecture|week|lab|quiz|exam|test|chapter|section|module|unit|step|run|case|example|task|project|session|day|slide|page|figure|table|deliverable|activity|worksheet|practice|drill"
    private static let standaloneLabels: Set<String> = [
        "homework", "hw", "task", "tasks", "instructions", "instruction", "deliverable", "deliverables", "assignment",
        "assignments", "submission", "submission format", "submission policy", "report contents", "agenda", "due date",
        "due dates", "requirements", "grading", "rubric", "extra credit", "bonus",
    ]

    /// True when the front is only a heading or an assignment label:
    /// "HOMEWORK 2", "Task", "Run A", "Part 3", "Problem 5", "Lecture 7",
    /// "Week 4: Sorting". A front that is a real term ("Set", "Eigenvalue",
    /// "Task scheduler", "Problem solving") is never one.
    public static func isPlaceholderFront(_ front: String) -> Bool {
        var t = front.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n*_`#\"'"))
            .lowercased()
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ":.-\u{2013}\u{2014} "))
        guard !t.isEmpty, !t.contains("?") else { return false }
        if standaloneLabels.contains(t) { return true }
        // "<label> <number|letter>" and an optional short title after it.
        // The number or letter must be set off by a space or "#", or be a
        // number stuck on the word ("part2"), so "setf" or "stepper" is no label.
        let pattern = #"^(\#(labelWords))s?(?:\s+#?\s*|\s*#\s*)([0-9]+(\.[0-9]+)*[a-z]?|[ivx]{1,4}|[a-z])(\s*[:.\-\u2013\u2014]\s*(.*))?$|^(\#(labelWords))s?([0-9]+(\.[0-9]+)*[a-z]?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))
        else { return false }
        let tail = match.range(at: 5).location != NSNotFound ? (t as NSString).substring(with: match.range(at: 5)) : ""
        // A short title is part of the label; a long tail may be a real question.
        return tail.split(separator: " ").count <= 7
    }

    // MARK: - Near duplicates

    /// Two cards are near-duplicates when their fronts are the same term
    /// (the same content words, or one front's words contained in the
    /// other's) and their answers say the same thing (identical content
    /// words, or at least 60% shared, with 4 or more words each). Two
    /// definitions of one term that really differ are kept.
    public static func areNearDuplicates(front: String, back: String, otherFront: String, otherBack: String) -> Bool {
        areNearDuplicates(frontWords: LocalMeaning.contentWords(front), backWords: LocalMeaning.contentWords(back),
                          otherFrontWords: LocalMeaning.contentWords(otherFront),
                          otherBackWords: LocalMeaning.contentWords(otherBack))
    }

    static func areNearDuplicates(frontWords a: Set<String>, backWords x: Set<String>,
                                  otherFrontWords b: Set<String>, otherBackWords y: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let sameTerm = a == b
        guard sameTerm || a.isSubset(of: b) || b.isSubset(of: a) else { return false }
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard min(x.count, y.count) >= 4 else { return false }
        let jaccard = Double(x.intersection(y).count) / Double(x.union(y).count)
        return jaccard >= (sameTerm ? 0.5 : 0.6)
    }

    // MARK: - Flags for parser-made cards

    /// A short note to show under a parser-made draft, or none: "This front
    /// looks like a heading." or "Looks like a duplicate of "Set"." Flags
    /// only. Nothing is hidden or removed, and approved or suspended cards,
    /// and cards the student wrote, are never flagged. Duplicates are
    /// reported on the later card of a pair, in the order given.
    public static func reviewNotes(for cards: [Card]) -> [String: String] {
        var notes: [String: String] = [:]
        // Inverted index from a front's words to the earlier cards using them.
        var byWord: [String: [Int]] = [:]
        var fronts: [Set<String>] = []
        var backs: [Set<String>] = []
        fronts.reserveCapacity(cards.count); backs.reserveCapacity(cards.count)
        for (index, card) in cards.enumerated() {
            let f = LocalMeaning.contentWords(card.front)
            let b = LocalMeaning.contentWords(card.back)
            fronts.append(f); backs.append(b)
            defer { for word in f { byWord[word, default: []].append(index) } }
            guard card.origin == .parser, card.status == .draft else { continue }
            if isPlaceholderFront(card.front) {
                notes[card.id] = "This front looks like a heading."
                continue
            }
            guard !f.isEmpty, !b.isEmpty else { continue }
            // Any earlier card sharing the rarest word of this front.
            guard let rarest = f.min(by: { (byWord[$0]?.count ?? 0) < (byWord[$1]?.count ?? 0) }),
                  let candidates = byWord[rarest] else { continue }
            for other in candidates where other < index {
                if areNearDuplicates(frontWords: f, backWords: b, otherFrontWords: fronts[other], otherBackWords: backs[other]) {
                    let name = cards[other].front.trimmingCharacters(in: .whitespacesAndNewlines)
                    notes[card.id] = "Looks like a duplicate of \u{201C}\(name.count > 40 ? String(name.prefix(37)) + "\u{2026}" : name)\u{201D}."
                    break
                }
            }
        }
        return notes
    }
}
