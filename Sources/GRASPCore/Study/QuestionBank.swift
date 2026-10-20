import Foundation
import GRDB

/// A question a student writes: multiple choice, written, or true/false.
public struct UserQuestionInput: Sendable, Equatable {
    public var kind: ProblemKind
    public var prompt: String
    /// Multiple choice: 2 to 6 options, and the index of the right one.
    public var choices: [String]
    public var correct: Int
    /// Written: the answer, and other wordings that count.
    public var answer: String
    public var accepted: [String]
    /// True/false: whether the statement is true.
    public var isTrue: Bool
    public var explanation: String
    /// A card this question helps, if any.
    public var cardId: String?

    public static let choiceRange = 2...6

    public init(kind: ProblemKind = .multipleChoice, prompt: String = "", choices: [String] = ["", ""],
                correct: Int = 0, answer: String = "", accepted: [String] = [], isTrue: Bool = true,
                explanation: String = "", cardId: String? = nil) {
        self.kind = kind; self.prompt = prompt; self.choices = choices; self.correct = correct
        self.answer = answer; self.accepted = accepted; self.isTrue = isTrue
        self.explanation = explanation; self.cardId = cardId
    }

    /// The three kinds a student can write.
    public static let writableKinds: [ProblemKind] = [.multipleChoice, .written, .trueFalse]

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What is missing, in plain words, or nil when it can be saved.
    public var problem: String? {
        if trimmed(prompt).isEmpty { return "Write the question first." }
        switch kind {
        case .multipleChoice:
            let options = choices.map(trimmed)
            if options.contains(where: \.isEmpty) { return "Fill in every choice, or remove the empty ones." }
            if !Self.choiceRange.contains(options.count) { return "A multiple choice question needs 2 to 6 choices." }
            if Set(options.map { $0.lowercased() }).count != options.count { return "Two choices are the same." }
            if !options.indices.contains(correct) { return "Pick which choice is right." }
        case .written:
            if trimmed(answer).isEmpty { return "Write the answer." }
        case .trueFalse:
            break
        default:
            return "That kind of question can't be written by hand yet."
        }
        return nil
    }

    /// The saved form. Call only when `problem` is nil.
    func asProblem() -> ProblemQuestion {
        let why = trimmed(explanation).isEmpty ? nil : trimmed(explanation)
        switch kind {
        case .multipleChoice:
            return ProblemQuestion(kind: .multipleChoice, subject: .concepts, prompt: trimmed(prompt),
                                   choices: choices.map(trimmed), correct: correct, explanation: why)
        case .written:
            let others = accepted.map(trimmed).filter { !$0.isEmpty }
            return ProblemQuestion(kind: .written, subject: .concepts, prompt: trimmed(prompt), explanation: why,
                                   answer: trimmed(answer), accepted: others.isEmpty ? nil : others)
        default:
            return ProblemQuestion(kind: .trueFalse, subject: .concepts, prompt: trimmed(prompt), explanation: why,
                                   isTrue: isTrue)
        }
    }

    /// Reads a saved question back into the form, for editing.
    public init?(_ record: TestQuestion) {
        guard let saved = record.problem, Self.writableKinds.contains(saved.kind) else { return nil }
        self.init(kind: saved.kind, prompt: saved.prompt, choices: saved.choices ?? ["", ""],
                  correct: saved.correct ?? 0, answer: saved.answer ?? "", accepted: saved.accepted ?? [],
                  isTrue: saved.isTrue ?? true, explanation: saved.explanation ?? "", cardId: record.cardId)
    }
}

/// The recent results of one saved question: how many of its last answers were right.
public struct QuestionHistory: Sendable, Equatable {
    public var right: Int
    public var of: Int

    /// "Right 2 of the last 3", or nil when it has not been asked yet.
    public var line: String? {
        guard of > 0 else { return nil }
        return of == 1 ? "Right 1 of 1" : "Right \(right) of the last \(of)"
    }
}

/// Saved questions as a feature: writing, editing, status, history. The
/// older `CodeQuestionBank` still picks questions for a test and holds the
/// code and math questions.
public enum QuestionBank {
    public static let historyWindow = 3

    /// Every question of these decks that has not been deleted, newest
    /// first, whatever its status: what the Questions tab lists.
    public static func listing(inDecks deckIds: [String], db: Database) throws -> [TestQuestion] {
        try CodeQuestionBank.questions(inDecks: deckIds, db: db)
    }

    /// The questions a test may ask.
    public static func active(inDecks deckIds: [String], db: Database) throws -> [TestQuestion] {
        guard !deckIds.isEmpty else { return [] }
        return try TestQuestion
            .filter(deckIds.contains(Column("deckId")))
            .filter(Column("deletedAt") == nil)
            .filter(Column("status") == QuestionStatus.active.rawValue)
            .order(Column("createdAt").desc)
            .fetchAll(db)
    }

    public static func activeCount(inDecks deckIds: [String], db: Database) throws -> Int {
        guard !deckIds.isEmpty else { return 0 }
        return try TestQuestion
            .filter(deckIds.contains(Column("deckId")))
            .filter(Column("deletedAt") == nil)
            .filter(Column("status") == QuestionStatus.active.rawValue)
            .fetchCount(db)
    }

    /// Saves a new question of the student's own, active at once.
    @discardableResult
    public static func create(_ input: UserQuestionInput, deckId: String, now: Date = Date(),
                              db: Database) throws -> TestQuestion {
        guard input.problem == nil else { throw QuestionBankError.invalid(input.problem ?? "") }
        guard let deck = try Deck.fetchOne(db, key: deckId) else { throw QuestionBankError.invalid("That deck is gone.") }
        let problem = input.asProblem()
        guard let body = problem.encoded() else { throw QuestionBankError.invalid("That question couldn't be saved.") }
        let record = TestQuestion(courseId: deck.courseId, deckId: deckId, problem: problem, bodyJSON: body,
                                  verifiedBy: "written by you", createdAt: now,
                                  source: .yours, status: .active, cardId: input.cardId)
        try record.insert(db)
        return record
    }

    /// Rewrites a question's content. Its source, status and history stay.
    public static func update(_ id: String, with input: UserQuestionInput, db: Database) throws {
        guard input.problem == nil else { throw QuestionBankError.invalid(input.problem ?? "") }
        guard var record = try TestQuestion.fetchOne(db, key: id) else { return }
        let problem = input.asProblem()
        guard let body = problem.encoded() else { throw QuestionBankError.invalid("That question couldn't be saved.") }
        record.kind = problem.kind.rawValue
        record.language = problem.subject.rawValue
        record.bodyJSON = body
        record.cardId = input.cardId
        try record.save(db)
    }

    // MARK: Drafts

    /// Drafts waiting for review, newest first.
    public static func drafts(inDecks deckIds: [String], db: Database) throws -> [TestQuestion] {
        try listing(inDecks: deckIds, db: db).filter { $0.statusKind == .draft }
    }

    public static func draftCount(inDecks deckIds: [String], db: Database) throws -> Int {
        guard !deckIds.isEmpty else { return 0 }
        return try TestQuestion
            .filter(deckIds.contains(Column("deckId")))
            .filter(Column("deletedAt") == nil)
            .filter(Column("status") == QuestionStatus.draft.rawValue)
            .fetchCount(db)
    }

    /// What is wrong with a question's wording or answer, as the end of a
    /// sentence beginning "It ...", or nil when it passes. The same rules the
    /// drafter applies, so a draft that was edited into something unclear
    /// cannot be approved.
    public static func qualityProblem(_ problem: ProblemQuestion) -> String? {
        let words = problem.prompt.split(whereSeparator: { $0.isWhitespace }).count
        if words < 4 { return "is too short to be a clear question" }
        switch problem.kind {
        case .multipleChoice:
            guard let choices = problem.choices, choices.count >= 2 else { return "has fewer than two choices" }
            if choices.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "has an empty choice" }
            if Set(choices.map { $0.lowercased() }).count != choices.count { return "repeats a choice" }
            guard let correct = problem.correct, choices.indices.contains(correct) else { return "has no right answer marked" }
        case .written:
            if (problem.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "has no answer" }
        default:
            break
        }
        // A multiple choice question's options are its choices, so "which of
        // the following" is fine there.
        switch CardQuality.problem(front: problem.prompt, back: problem.answerText) {
        case .refusal?: return "has an answer that says the notes don't cover it"
        case .placeholderFront?: return "reads like a placeholder"
        case .missingOptions? where problem.kind != .multipleChoice: return "asks \"which of the following\" without showing the options"
        default: return nil
        }
    }

    /// Why this saved question may not be approved, or nil when it may.
    public static func approvalProblem(_ record: TestQuestion) -> String? {
        if let code = record.question { return CodeQuestionValidator.problem(in: code).map { "It " + $0 + "." } }
        if let problem = record.problem { return qualityProblem(problem).map { "It " + $0 + "." } }
        return "It can't be read."
    }

    /// Approves one draft: it becomes active, and from then on it syncs.
    /// Returns why it was not approved, or nil on success. Nothing that fails
    /// a check is approved.
    @discardableResult
    public static func approve(_ id: String, db: Database) throws -> String? {
        guard let record = try TestQuestion.fetchOne(db, key: id), record.deletedAt == nil,
              record.statusKind == .draft else { return nil }
        if let why = approvalProblem(record) { return why }
        try setStatus(id, to: .active, db: db)
        return nil
    }

    public struct ApproveAllResult: Sendable, Equatable {
        public var approved = 0
        /// Drafts that failed a check and were left for review, with why.
        public var skipped: [(id: String, reason: String)] = []
        public init() {}
        public static func == (a: ApproveAllResult, b: ApproveAllResult) -> Bool {
            a.approved == b.approved && a.skipped.map(\.id) == b.skipped.map(\.id)
        }
    }

    /// Approves every draft of these decks that passes every check.
    public static func approveAll(inDecks deckIds: [String], db: Database) throws -> ApproveAllResult {
        var result = ApproveAllResult()
        for draft in try drafts(inDecks: deckIds, db: db) {
            if let why = try approve(draft.id, db: db) { result.skipped.append((draft.id, why)) } else { result.approved += 1 }
        }
        return result
    }

    public static func setStatus(_ id: String, to status: QuestionStatus, db: Database) throws {
        guard var record = try TestQuestion.fetchOne(db, key: id), record.status != status.rawValue else { return }
        record.status = status.rawValue
        try record.save(db)
    }

    // MARK: Moving and copying

    public struct MoveResult: Sendable, Equatable {
        /// Questions moved or copied.
        public var changed = 0
        /// Copies not made because the deck already has that question.
        public var skippedRepeats = 0
        public init(changed: Int = 0, skippedRepeats: Int = 0) { self.changed = changed; self.skippedRepeats = skippedRepeats }
    }

    /// Moves questions to another deck. A question keeps its history, source
    /// and status. Its note link stays only when the note is in the new
    /// deck's course, and its card link only when that card is in the new deck.
    @discardableResult
    public static func move(_ ids: [String], toDeck deckId: String, db: Database) throws -> MoveResult {
        guard let deck = try Deck.fetchOne(db, key: deckId), deck.deletedAt == nil else {
            throw QuestionBankError.invalid("That deck is gone.")
        }
        var result = MoveResult()
        for id in ids {
            guard var record = try TestQuestion.fetchOne(db, key: id), record.deletedAt == nil,
                  record.deckId != deckId else { continue }
            relink(&record, toDeck: deck, db: db)
            record.deckId = deckId
            record.courseId = deck.courseId
            try record.save(db)
            result.changed += 1
        }
        return result
    }

    /// Copies questions into another deck as new questions (no history). A
    /// question the deck already has, word for word, is not copied again.
    @discardableResult
    public static func copy(_ ids: [String], toDeck deckId: String, now: Date = Date(), db: Database) throws -> MoveResult {
        guard let deck = try Deck.fetchOne(db, key: deckId), deck.deletedAt == nil else {
            throw QuestionBankError.invalid("That deck is gone.")
        }
        var have = Set(try listing(inDecks: [deckId], db: db).map { $0.promptText.lowercased() })
        var result = MoveResult()
        for id in ids {
            guard var record = try TestQuestion.fetchOne(db, key: id), record.deletedAt == nil else { continue }
            if !record.promptText.isEmpty, have.contains(record.promptText.lowercased()) { result.skippedRepeats += 1; continue }
            relink(&record, toDeck: deck, db: db)
            record.id = UUID().uuidString
            record.deckId = deckId
            record.courseId = deck.courseId
            record.createdAt = now
            try record.insert(db)
            have.insert(record.promptText.lowercased())
            result.changed += 1
        }
        return result
    }

    private static func relink(_ record: inout TestQuestion, toDeck deck: Deck, db: Database) {
        if let materialId = record.materialId,
           (try? Material.fetchOne(db, key: materialId))?.courseId != deck.courseId { record.materialId = nil }
        if let cardId = record.cardId,
           (try? DeckCard.filter(Column("deckId") == deck.id && Column("cardId") == cardId).fetchCount(db)) ?? 0 == 0 {
            record.cardId = nil
        }
    }

    /// Sets the status of several questions at once.
    public static func setStatus(_ ids: [String], to status: QuestionStatus, db: Database) throws {
        for id in ids { try setStatus(id, to: status, db: db) }
    }

    /// The card a saved question helps, if that card still exists.
    public static func linkedCardId(ofQuestion id: String, db: Database) throws -> String? {
        guard let cardId = try TestQuestion.fetchOne(db, key: id)?.cardId,
              let card = try Card.fetchOne(db, key: cardId), card.deletedAt == nil else { return nil }
        return cardId
    }

    /// Each question's last answers, from finished and unfinished tests
    /// alike (only answered items count). History is never deleted with a
    /// question.
    public static func history(of ids: [String], db: Database) throws -> [String: QuestionHistory] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: QuestionHistory] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.questionId AS questionId, i.isCorrect AS isCorrect FROM testItem i
                JOIN testAttempt a ON a.id = i.attemptId
                WHERE i.questionId IN (\(marks)) AND i.isCorrect IS NOT NULL
                ORDER BY a.startedAt DESC, i.ordinal DESC
                """, arguments: StatementArguments(chunk))
            var seen: [String: [Bool]] = [:]
            for row in rows {
                let id: String = row["questionId"]
                if (seen[id]?.count ?? 0) < historyWindow { seen[id, default: []].append(row["isCorrect"]) }
            }
            for (id, marks) in seen { result[id] = QuestionHistory(right: marks.filter { $0 }.count, of: marks.count) }
        }
        return result
    }
}

public enum QuestionBankError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
