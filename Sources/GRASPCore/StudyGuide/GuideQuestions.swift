import Foundation
import GRDB

/// A study guide's worked examples as saved questions, so they sit in the
/// Questions tab ("All Cards" lists every deck's) and a test can include
/// them. They are questions, never flashcards. Only on request, once per
/// guide: asking again adds nothing.
///
/// A lettered multiple-choice example (five options, a matching lettered
/// answer) is saved as a multiple choice question with its options in the
/// note's order. Anything else is a written question: the example as asked,
/// the answer as written. The guide's own steps become the "why".
public enum GuideQuestions {
    public struct Result: Sendable, Equatable {
        public var added = 0
        /// Examples already saved as questions, kept or deleted.
        public var alreadyThere = 0
        /// Examples with no answer, or that lean on a table or figure in the file.
        public var skipped = 0
        public var deckId: String?
        public var deckName = ""
    }

    /// The question an example would be, or nil when it can't be one.
    public static func input(for example: StudyGuideDocument.Example) -> UserQuestionInput? {
        let question = example.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let answer = example.answer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty, !answer.isEmpty, example.usesFigure != true else { return nil }
        // The guide's "Step 1:" labels would read as an internal format in the
        // explanation, so only the sentences stay.
        let why = example.steps
            .map { $0.replacingOccurrences(of: #"^\s*step\s*\d+\s*[:.]\s*"#, with: "",
                                           options: [.regularExpression, .caseInsensitive]) }
            .joined(separator: "\n")
        let input: UserQuestionInput
        if let choice = GuideExamples.choiceItem(question: question, answer: answer) {
            input = UserQuestionInput(kind: .multipleChoice, prompt: choice.stem, choices: choice.options,
                                      correct: choice.correct, explanation: why)
        } else {
            input = UserQuestionInput(kind: .written, prompt: question, answer: answer, explanation: why)
        }
        return input.problem == nil ? input : nil
    }

    /// The deck's name: the exam the guide prepares for, else the guide's own title.
    static func deckName(for guide: StudyGuide, db: Database) throws -> String {
        let exam = try guide.examEventId.flatMap { try CalendarEvent.fetchOne(db, key: $0) }
        return (exam?.title ?? guide.title) + " practice"
    }

    @discardableResult
    public static func addQuestions(guideId: String, now: Date = Date(), db: Database) throws -> Result {
        var result = Result()
        guard let guide = try StudyGuide.fetchOne(db, key: guideId), let document = guide.document() else { return result }
        let name = try deckName(for: guide, db: db)
        result.deckName = name

        // Every question this guide has already made, deleted ones too, so
        // a question the student removed stays removed.
        let made = try TestQuestion.filter(Column("materialId") == guide.materialId).fetchAll(db)
        var known = Set(made.map(\.promptText))
        var pending: [UserQuestionInput] = []
        for example in document.parts.flatMap(\.examples) {
            guard let input = input(for: example) else { result.skipped += 1; continue }
            let prompt = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if known.contains(prompt) { result.alreadyThere += 1; continue }
            known.insert(prompt)
            pending.append(input)
        }

        var deck = try Deck.filter(Column("courseId") == guide.courseId && Column("name") == name
                                   && Column("deletedAt") == nil).fetchOne(db)
        if deck == nil, !pending.isEmpty {
            let id = try LibraryActions.createDeck(courseId: guide.courseId, name: name, db: db)
            deck = try Deck.fetchOne(db, key: id)
        }
        result.deckId = deck?.id
        guard let deck else { return result }

        for (index, input) in pending.enumerated() {
            let problem = input.asProblem()
            guard let body = problem.encoded() else { result.skipped += 1; continue }
            // Newest first in the list, so the guide's first example is on top.
            let record = TestQuestion(courseId: guide.courseId, deckId: deck.id, materialId: guide.materialId,
                                      problem: problem, bodyJSON: body, verifiedBy: "from your study guide",
                                      createdAt: now.addingTimeInterval(-Double(index)),
                                      source: .yours, status: .active)
            try record.insert(db)
            result.added += 1
        }
        return result
    }
}
