import Foundation
import GRDB

/// Tests built from a study guide itself, the way a deck's are built from
/// its cards: the guide's key terms, and questions the AI writes from each
/// part, become a pool of question-and-answer pairs that the ordinary test
/// builder turns into multiple choice, true/false and written questions.
/// Written questions are saved (on this device) so they're written once.
public enum GuideTest {
    /// Ids for pool entries that aren't cards, so a test never grades a card
    /// that doesn't exist.
    public static let idPrefix = "guide:"

    public struct SavedQuestion: Sendable, Equatable {
        public var guideId: String
        public var partIndex: Int
        public var prompt: String
        public var answer: String
    }

    /// What one part says, as the text a question is written from.
    public static func partContext(_ part: StudyGuideActions.PagePart) -> String {
        var lines: [String] = ["Topic: \(part.title)"]
        if !part.skills.isEmpty { lines.append("Students should be able to: " + part.skills.map(\.text).joined(separator: "; ")) }
        lines += part.terms.map { "\($0.term): \($0.definition)" }
        if !part.traps.isEmpty { lines.append("Common mistakes: " + part.traps.joined(separator: "; ")) }
        lines += part.remember
        lines += part.notes
        lines += part.formulas
        for example in part.examples.prefix(4) {
            lines.append("Example: " + example.example.question + (example.example.answer.map { " Answer: " + $0 } ?? ""))
        }
        return String(lines.joined(separator: "\n").prefix(2400))
    }

    /// The pool a guide's test draws from: every key term with its
    /// definition, and every saved question with its answer.
    public static func pool(page: StudyGuideActions.ExamPage,
                            saved: [SavedQuestion]) -> [(cardId: String, front: String, back: String)] {
        var seen = Set<String>()
        var pool: [(cardId: String, front: String, back: String)] = []
        for term in page.parts.flatMap(\.terms) where !term.definition.isEmpty {
            let key = term.term.lowercased()
            guard seen.insert(key).inserted else { continue }
            pool.append((idPrefix + "term:" + key, term.term, term.definition))
        }
        for question in saved {
            let key = question.prompt.lowercased()
            guard seen.insert(key).inserted else { continue }
            pool.append((idPrefix + "q:" + String(key.hashValue), question.prompt, question.answer))
        }
        return pool
    }

    /// Questions from the pool carry no card.
    public static func detachingPool(_ questions: [LearnEngine.RoundQuestion]) -> [LearnEngine.RoundQuestion] {
        questions.map { question in
            var copy = question
            if copy.cardId?.hasPrefix(idPrefix) == true { copy.cardId = nil }
            return copy
        }
    }

    // MARK: - Saved questions

    public static func saved(for page: StudyGuideActions.ExamPage, db: Database) throws -> [SavedQuestion] {
        let guideIds = page.guides.map(\.id)
        guard !guideIds.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT guideId, partIndex, prompt, answer FROM guideQuestion
            WHERE guideId IN (\(guideIds.map { _ in "?" }.joined(separator: ","))) ORDER BY createdAt
            """, arguments: StatementArguments(guideIds))
            .map { SavedQuestion(guideId: $0["guideId"], partIndex: $0["partIndex"], prompt: $0["prompt"], answer: $0["answer"]) }
    }

    public static func save(_ questions: [SavedQuestion], db: Database) throws {
        for question in questions {
            try db.execute(sql: """
                INSERT INTO guideQuestion (id, guideId, partIndex, prompt, answer, createdAt) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, question.guideId, question.partIndex, question.prompt, question.answer, Date()])
        }
    }

    /// Writes questions for the parts that have none yet, a few each, until
    /// `needed` are written or every part has its share.
    public static func write(page: StudyGuideActions.ExamPage, saved: [SavedQuestion], needed: Int,
                             perPart: Int = 3, using generator: any CardGenerator,
                             skipped: @escaping @Sendable () -> Bool = { false }) async -> [SavedQuestion] {
        guard needed > 0, await generator.isAvailable else { return [] }
        let covered = Set(saved.map { "\($0.guideId)#\($0.partIndex)" })
        let parts = page.parts.filter { part in
            guard let source = part.sources.first else { return false }
            return !covered.contains("\(source.guideId)#\(source.partIndex)")
        }
        var written: [SavedQuestion] = []
        let progress = AIProgress.current
        progress?.expect(min(parts.count, (needed + perPart - 1) / perPart))
        for part in parts {
            if Task.isCancelled || skipped() || written.count >= needed { break }
            guard let source = part.sources.first else { continue }
            let context = partContext(part)
            guard context.count > 40 else { continue }
            progress?.begin("Writing questions about \(part.title)")
            let proposed = await generator.generateGuideQuestions(context: context, count: perPart)
            written += proposed.map {
                SavedQuestion(guideId: source.guideId, partIndex: source.partIndex,
                              prompt: PlainMath.clean($0.prompt), answer: PlainMath.clean($0.correctAnswer))
            }
            progress?.advance()
        }
        return written
    }
}
