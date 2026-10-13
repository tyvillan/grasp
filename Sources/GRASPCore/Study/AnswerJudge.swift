import Foundation

// Grading a typed answer by meaning: lenient about wording, strict about
// facts. One ladder shared by Learn and Test:
//   1. a remembered answer ("I actually got this right" before) is correct;
//   2. normalise and compare the words locally;
//   3. only a borderline case asks the AI judge, which never blocks (3 s,
//      then the local verdict stands).
// Code, fill-in-the-blank, multiple choice and true/false don't come here.

public enum AnswerOutcome: String, Sendable, Equatable {
    case correct
    /// A different wording that says the same thing. Counts as correct.
    case closeEnough
    case notQuite

    public var countsAsCorrect: Bool { self != .notQuite }
}

public struct JudgedAnswer: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case empty, remembered, exact, local, ai, localFallback
    }
    public var outcome: AnswerOutcome
    /// One short sentence from the AI judge, when it gave one.
    public var reason: String?
    public var source: Source

    public init(outcome: AnswerOutcome, reason: String? = nil, source: Source) {
        self.outcome = outcome; self.reason = reason; self.source = source
    }

    /// Said under a Close enough answer the AI judge was never asked about
    /// (unreachable or too slow): the local word comparison accepted it alone.
    public static let offlineNote = "Accepted offline. Check the wording."

    /// `offlineNote` when this answer was accepted that way, else nil.
    public var offlineNoteIfAny: String? {
        outcome == .closeEnough && source == .localFallback ? Self.offlineNote : nil
    }
}

/// What the AI judge says about one answer.
public struct AIAnswerVerdict: Sendable, Equatable {
    public var outcome: AnswerOutcome
    public var reason: String?
    public init(outcome: AnswerOutcome, reason: String? = nil) {
        self.outcome = outcome; self.reason = reason
    }
}

public enum AnswerLadder {
    /// The AI step: question, expected answer, the student's answer. Nil
    /// when it can't say.
    public typealias Judge = @Sendable (_ question: String, _ expected: String, _ given: String) async -> AIAnswerVerdict?

    public static let judgeTimeout: Duration = .seconds(3)

    /// Grades one typed answer. `accepted` are answers this student has
    /// already said are right for this card.
    public static func judge(
        question: String, expected: String, given: String, accepted: [String] = [],
        judge: Judge?, timeout: Duration = judgeTimeout
    ) async -> JudgedAnswer {
        let normalizedGiven = AnswerGrading.normalize(given)
        guard !normalizedGiven.isEmpty else { return JudgedAnswer(outcome: .notQuite, source: .empty) }
        if accepted.contains(where: { AnswerGrading.normalize($0) == normalizedGiven }) {
            return JudgedAnswer(outcome: .correct, source: .remembered)
        }

        let local = LocalMeaning.compare(question: question, expected: expected, given: given)
        if let decided = local.decided {
            return JudgedAnswer(outcome: decided, source: decided == .correct && local.isExact ? .exact : .local)
        }
        // Borderline. Ask the judge, but never wait on it.
        if let judge, let verdict = await withTimeout(timeout, {
            await judge(question, expected, given)
        }) {
            return JudgedAnswer(outcome: verdict.outcome, reason: verdict.reason, source: .ai)
        }
        return JudgedAnswer(outcome: local.fallback, source: .localFallback)
    }

    /// Runs `work` against a clock; nil when the clock wins (the work is
    /// cancelled) or the work has no answer.
    static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - The local comparison

public enum LocalMeaning {
    public struct Result: Sendable, Equatable {
        /// Set when the local step is confident either way.
        public var decided: AnswerOutcome?
        /// What to say when the case is borderline and the judge can't help.
        public var fallback: AnswerOutcome
        /// Share of the card's key words found, and of the answer's that are the card's.
        public var recall: Double
        public var precision: Double
        public var isExact: Bool
    }

    public static func compare(question: String, expected: String, given: String) -> Result {
        let g = AnswerGrading.normalize(given)
        let e = AnswerGrading.normalize(expected)
        func result(_ decided: AnswerOutcome?, _ fallback: AnswerOutcome, _ recall: Double = 0, _ precision: Double = 0,
                    exact: Bool = false) -> Result {
            Result(decided: decided, fallback: fallback, recall: recall, precision: precision, isExact: exact)
        }
        guard !g.isEmpty, !e.isEmpty else { return result(.notQuite, .notQuite) }

        // Exact or near-exact: no judge needed.
        if g == e || g.replacingOccurrences(of: " ", with: "") == e.replacingOccurrences(of: " ", with: "") {
            return result(.correct, .correct, 1, 1, exact: true)
        }
        let ratio = AnswerGrading.similarityRatio(g, e)

        // Facts: numbers and signs have to match as written.
        let gFacts = facts(in: g), eFacts = facts(in: e)
        if gFacts != eFacts { return result(.notQuite, .notQuite) }
        if ratio >= 0.9 { return result(.correct, .correct, 1, 1, exact: true) }

        let gTokens = tokens(g), eTokens = tokens(e)
        // Negation flipped.
        if hasNegation(gTokens) != hasNegation(eTokens) { return result(.notQuite, .notQuite) }

        let gKeys = Set(gTokens.compactMap(canonical)), eKeys = Set(eTokens.compactMap(canonical))
        // Opposites: the answer has one end of a pair, the card the other.
        for (a, b) in antonyms {
            let ca = synonymHead(a), cb = synonymHead(b)
            if (eKeys.contains(ca) && !eKeys.contains(cb) && gKeys.contains(cb) && !gKeys.contains(ca))
                || (eKeys.contains(cb) && !eKeys.contains(ca) && gKeys.contains(ca) && !gKeys.contains(cb)) {
                return result(.notQuite, .notQuite)
            }
        }
        guard !eKeys.isEmpty else {
            // Nothing but filler words on the card: only an exact match counts.
            return result(ratio >= 0.9 ? .correct : .notQuite, .notQuite)
        }
        guard !gKeys.isEmpty else { return result(.notQuite, .notQuite) }

        // An answer that only repeats the question.
        let qKeys = Set(tokens(AnswerGrading.normalize(question)).compactMap(canonical))
        if gKeys.isSubset(of: qKeys), !eKeys.isSubset(of: qKeys) { return result(.notQuite, .notQuite) }

        let matched = eKeys.filter { key in gKeys.contains { near($0, key) } }
        let matchedGiven = gKeys.filter { key in eKeys.contains { near($0, key) } }
        let recall = Double(matched.count) / Double(eKeys.count)
        let precision = Double(matchedGiven.count) / Double(gKeys.count)

        // The same words once endings and order are ignored: spelled the
        // same way by a different route, so it is simply right.
        let gStems = Set(gTokens.map(stem)), eStems = Set(eTokens.map(stem))
        if gStems == eStems { return result(.correct, .correct, recall, precision) }

        // A misspelt word on a longer answer: every word that differs is a
        // typo of a word on the other side, not a different word.
        if ratio >= 0.8, e.count >= 8, onlyTypos(gTokens, eTokens) {
            return result(.closeEnough, .closeEnough, recall, precision)
        }

        // Almost nothing in common: no need to ask.
        if matched.isEmpty || recall < 0.3 && precision < 0.5 { return result(.notQuite, .notQuite, recall, precision) }
        // The key words are all there and little else is added. One missing
        // word on a short answer is exactly where a wrong fact hides, so
        // that goes to the judge.
        if recall >= 0.9 && precision >= 0.6 { return result(.closeEnough, .closeEnough, recall, precision) }

        // Borderline: the judge decides; offline, this is what stands.
        let fallback: AnswerOutcome = (recall >= 0.6 && precision >= 0.6) || (recall >= 0.99 && precision >= 0.25)
            ? .closeEnough : .notQuite
        return result(nil, fallback, recall, precision)
    }

    // MARK: Words

    private static let filler: Set<String> = [
        "a", "an", "the", "of", "to", "on", "in", "at", "for", "and", "or", "is", "are", "was", "were", "be", "been",
        "that", "which", "who", "it", "its", "this", "these", "those", "as", "by", "with", "from", "into", "can",
        "will", "would", "should", "used", "use", "uses", "using", "called", "known", "also", "type", "kind", "way",
        "thing", "something", "one", "has", "have", "had", "when", "where", "what", "how", "so", "than", "then",
    ]

    private static let negations: Set<String> = [
        "not", "no", "never", "without", "cannot", "cant", "dont", "doesnt", "isnt", "arent", "wont", "non",
        "none", "neither", "nor", "wasnt", "werent", "didnt", "hasnt", "havent",
    ]

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "first": "1st", "second": "2nd", "third": "3rd",
    ]

    /// Near-synonym groups; the first word is the head.
    private static let synonymGroups: [[String]] = [
        ["program", "software", "application", "app"], ["big", "large", "huge"], ["small", "little", "tiny"],
        ["fast", "quick", "rapid", "quickly"], ["use", "utilize", "employ"],
        ["make", "create", "build", "produce", "generate"], ["get", "obtain", "retrieve", "fetch"],
        ["show", "display"], ["start", "begin", "initiate"], ["help", "assist"], ["buy", "purchase"],
        ["need", "require"], ["many", "several", "numerous"], ["car", "automobile"],
        ["error", "mistake", "fault"], ["delete", "remove", "erase"], ["change", "modify", "alter"],
        ["keep", "retain"], ["send", "transmit"], ["often", "frequently"], ["method", "technique", "approach"],
        ["goal", "objective", "aim", "purpose"], ["allow", "permit", "enable"],
        ["increase", "rise", "grow", "expand"], ["decrease", "reduce", "shrink", "fall", "drop"],
        ["group", "collection", "set"], ["part", "piece", "component", "section"], ["idea", "concept", "notion"],
        ["answer", "response", "reply"], ["begin", "start"], ["end", "finish", "conclude"], ["tell", "inform"],
        ["happen", "occur"], ["choose", "select", "pick"], ["look", "appear", "seem"], ["fix", "repair"],
        ["quantity", "amount", "number"], ["total", "sum"], ["near", "close"], ["whole", "entire", "complete"],
    ]

    private static let antonyms: [(String, String)] = [
        ("increase", "decrease"), ("true", "false"), ("before", "after"), ("more", "less"), ("high", "low"),
        ("open", "closed"), ("add", "remove"), ("first", "last"), ("start", "end"), ("up", "down"),
        ("positive", "negative"), ("internal", "external"), ("public", "private"), ("input", "output"),
        ("inside", "outside"), ("allow", "prevent"), ("always", "never"), ("all", "none"),
        ("same", "different"), ("maximum", "minimum"), ("greater", "smaller"), ("static", "dynamic"),
        ("parent", "child"), ("synchronous", "asynchronous"), ("mutable", "immutable"), ("hot", "cold"),
        ("above", "below"), ("left", "right"), ("push", "pop"), ("enqueue", "dequeue"), ("win", "lose"),
        ("early", "late"), ("fast", "slow"), ("big", "small"), ("strong", "weak"), ("local", "global"),
    ]

    private static let synonymHeads: [String: String] = {
        var map: [String: String] = [:]
        for group in synonymGroups {
            for word in group where map[word] == nil { map[word] = group[0] }
        }
        return map
    }()

    private static func synonymHead(_ word: String) -> String {
        let s = stem(word)
        return synonymHeads[word] ?? synonymHeads[s] ?? s
    }

    /// The content words of a card's front or back: normalized, stemmed,
    /// synonyms folded together, and filler left out. Used to tell whether
    /// two cards say the same thing (`CardQuality`).
    ///
    /// One-letter words (`w` in "File mode w", `x` in "Reflection across the
    /// x2 axis") are kept, because there they are what tells two cards apart.
    static func contentWords(_ text: String) -> Set<String> {
        Set(tokens(AnswerGrading.normalize(text)).compactMap { token -> String? in
            if token.count == 1, token.first?.isLetter == true, !filler.contains(token) { return token }
            return canonical(token)
        })
    }

    private static func tokens(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init).map { numberWords[$0] ?? $0 }
    }

    private static func hasNegation(_ tokens: [String]) -> Bool {
        tokens.contains { negations.contains($0) }
    }

    /// Digits and the symbols that change an answer.
    private static func facts(in normalized: String) -> [String] {
        var out: [String] = []
        for token in normalized.split(separator: " ") {
            let mapped = numberWords[String(token)] ?? String(token)
            let digits = mapped.filter { $0.isNumber || "+-=<>'^/*%".contains($0) }
            if !digits.isEmpty { out.append(digits) }
        }
        return out
    }

    /// A content word: stemmed and mapped to its synonym head. Nil for filler
    /// and negations (which are compared on their own).
    private static func canonical(_ token: String) -> String? {
        guard !filler.contains(token), !negations.contains(token) else { return nil }
        guard token.count > 1 || token.first?.isNumber == true else { return nil }
        return synonymHead(token)
    }

    /// Two key words that are the same word, give or take a typo.
    private static func near(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        guard shorter >= 5 else { return false }
        let distance = AnswerGrading.levenshteinDistance(Array(a), Array(b))
        return distance <= (shorter >= 9 ? 2 : 1)
    }

    /// True when the words that differ between the two answers pair up as
    /// misspellings of each other (one letter off, or two on a long word).
    private static func onlyTypos(_ given: [String], _ expected: [String]) -> Bool {
        let extraGiven = given.filter { !expected.contains($0) }
        var extraExpected = expected.filter { !given.contains($0) }
        guard !extraGiven.isEmpty, extraGiven.count == extraExpected.count else { return false }
        for word in extraGiven {
            guard let index = extraExpected.firstIndex(where: { other in
                let shorter = min(word.count, other.count)
                guard shorter >= 4 else { return false }
                let distance = AnswerGrading.levenshteinDistance(Array(word), Array(other))
                return distance <= (shorter >= 9 ? 2 : 1)
            }) else { return false }
            extraExpected.remove(at: index)
        }
        return true
    }

    /// A light stemmer: plurals and the common verb endings.
    static func stem(_ word: String) -> String {
        var w = word
        guard w.count > 3, w.allSatisfy({ $0.isLetter }) else { return w }
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") { return String(w.dropLast(2)) }
        if w.hasSuffix("ing"), w.count > 5 {
            w = String(w.dropLast(3))
            if let last = w.last, w.count > 2, w[w.index(before: w.endIndex)] == w[w.index(w.endIndex, offsetBy: -2)],
               !"aeiou".contains(last), last != "l", last != "s" { w.removeLast() }
            return w
        }
        if w.hasSuffix("ed"), w.count > 4 {
            w = String(w.dropLast(2))
            if let last = w.last, w.count > 2, w[w.index(before: w.endIndex)] == w[w.index(w.endIndex, offsetBy: -2)],
               !"aeiou".contains(last), last != "l", last != "s" { w.removeLast() }
            return w
        }
        if w.hasSuffix("es"), w.count > 4 {
            // "boxes", "watches", "classes" lose "es"; "increases", "uses",
            // "cases" lose only the "s".
            if w.hasSuffix("xes") || w.hasSuffix("zes") || w.hasSuffix("ches") || w.hasSuffix("shes") || w.hasSuffix("sses") {
                return String(w.dropLast(2))
            }
            return String(w.dropLast())
        }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { return String(w.dropLast()) }
        return w
    }
}
