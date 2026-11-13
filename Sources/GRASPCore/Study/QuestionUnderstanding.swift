import Foundation
import GRDB

/// The understanding meter for a question that is not a card: a saved
/// question, or a study guide's worked example asked in a guide test. Read
/// from the answers already kept in `testItem`, replayed through the Learn
/// ladder (`LearnEngine.advance`), so nothing new is stored or synced.
///
/// A question is known by its words, not by a row id, so one question asked
/// in two places has one meter: a guide example and the saved question made
/// from it ("<exam> practice") share every answer. The words are compared
/// loosely: case, spacing, curly quotes and the five "(a) ..." option lines
/// a typed multiple-choice question shows under its stem don't count.
public enum QuestionUnderstanding {
    private static let codeBlanksSuffix = "Fill in the missing piece of the answer."
    private static let optionLine = try! NSRegularExpression(pattern: #"^\([a-e]\)\s+\S"#)

    /// What identifies a question across the places it is asked.
    public static func key(_ prompt: String) -> String {
        var text = GuideExamples.straightQuotes(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(codeBlanksSuffix) { text.removeLast(codeBlanksSuffix.count) }
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = lines.last, last.isEmpty || StudyGuideParser.match(optionLine, last) != nil {
            lines.removeLast()
        }
        return lines.joined(separator: " ").lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A guide's worked example, as every test and saved question asks it.
    public static func key(of example: StudyGuideDocument.Example) -> String { key(example.question) }

    /// A saved question.
    public static func key(of question: TestQuestion) -> String { key(question.promptText) }

    /// A question in a test. A predict-the-output question shows its code
    /// apart from its words, so both count, as in the guide's example.
    public static func key(of question: LearnEngine.RoundQuestion) -> String {
        if let code = question.code, code.kind == .predictOutput { return key(question.prompt + "\n" + code.code) }
        return key(question.prompt)
    }

    /// The meter for each of these keys. A key never answered is "New".
    public static func states(forKeys keys: Set<String>, db: Database) throws -> [String: UnderstandingState] {
        guard !keys.isEmpty else { return [:] }
        // Card questions have their own meter on the card.
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.promptText AS prompt, i.questionType AS type, i.payloadJSON AS payload,
                   i.questionId AS questionId, i.isCorrect AS isCorrect
            FROM testItem i JOIN testAttempt a ON a.id = i.attemptId
            WHERE i.cardId IS NULL AND i.isCorrect IS NOT NULL
            ORDER BY a.startedAt, i.ordinal
            """)
        // A saved question's history follows its current words, so editing
        // it keeps its answers.
        let questionIds = Set(rows.compactMap { $0["questionId"] as String? })
        var savedPrompt: [String: String] = [:]
        for chunk in stride(from: 0, to: questionIds.count, by: 400).map({ Array(Array(questionIds)[$0..<min($0 + 400, questionIds.count)]) }) {
            for question in try TestQuestion.filter(chunk.contains(Column("id"))).fetchAll(db) {
                savedPrompt[question.id] = question.promptText
            }
        }
        var ladder: [String: (level: LearnEngine.Level, run: Int)] = [:]
        for row in rows {
            let prompt: String = row["prompt"]
            let questionId: String? = row["questionId"]
            let itemKey: String
            if let questionId, let saved = savedPrompt[questionId] {
                itemKey = key(saved)
            } else if (row["type"] as String?) == "code", let code = CodeQuestion.decode(row["payload"]),
                      code.kind == .predictOutput {
                itemKey = key(prompt + "\n" + code.code)
            } else {
                itemKey = key(prompt)
            }
            guard keys.contains(itemKey) else { continue }
            let current = ladder[itemKey] ?? (.new, 0)
            let next = LearnEngine.advance(level: current.level, consecutiveCorrect: current.run, wasCorrect: row["isCorrect"])
            ladder[itemKey] = (next.level, next.consecutiveCorrect)
        }
        var result: [String: UnderstandingState] = [:]
        for key in keys {
            if let step = ladder[key] {
                result[key] = .of(level: step.level, asked: true, consecutiveCorrect: step.run)
            } else {
                result[key] = .of(level: nil)
            }
        }
        return result
    }

    /// Each saved question's meter, by question id.
    public static func states(of questions: [TestQuestion], db: Database) throws -> [String: UnderstandingState] {
        let byKey = try states(forKeys: Set(questions.map(key(of:))), db: db)
        return Dictionary(questions.map { ($0.id, byKey[key(of: $0)] ?? .of(level: nil)) }, uniquingKeysWith: { a, _ in a })
    }
}
