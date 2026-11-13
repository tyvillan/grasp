import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// The understanding meter for questions that are not cards, read from
/// test answers, and shared by a guide example and its saved question.
@Suite("Question understanding")
struct QuestionUnderstandingTests {
    private func library() async throws -> (db: GRASPDatabase, guideId: String, example: StudyGuideDocument.Example) {
        let db = try GRASPDatabase.inMemory()
        let course = Course(semesterId: nil, name: "Microeconomic Principles", code: "ECO 2023")
        let material = Material(courseId: course.id, relativePath: "/vault/guide.md", kind: .markdown,
                                title: "ECO 2023 - Exam 1 Study Guide")
        let guideId = try await db.queue.write { conn -> String in
            try course.insert(conn)
            try material.insert(conn)
            return try StudyGuideActions.importGuide(material: material, pages: [GuideQuestionsTests.text], db: conn).id
        }
        let example = try await db.queue.read { conn in
            try #require(try StudyGuide.fetchOne(conn, key: guideId)?.document()?.parts.flatMap(\.examples).first)
        }
        return (db, guideId, example)
    }

    /// One test over these questions, each answered right or wrong in order.
    private func answer(_ questions: [LearnEngine.RoundQuestion], _ marks: [Bool], db: GRASPDatabase,
                        at date: Date) async throws {
        try await db.queue.write { conn in
            let id = try Study.startRetry(questions: questions, deckIds: [], db: conn)
            try conn.execute(sql: "UPDATE testAttempt SET startedAt = ? WHERE id = ?", arguments: [date, id])
            for (ordinal, right) in marks.enumerated() {
                try Study.submitTestAnswer(attemptId: id, ordinal: ordinal, given: "x", isCorrect: right, db: conn)
            }
        }
    }

    private func guideQuestion(_ example: StudyGuideDocument.Example, typed: Bool) throws -> LearnEngine.RoundQuestion {
        let item = try #require(GuideExamples.choiceItem(question: example.question, answer: example.answer ?? ""))
        var rng = SystemRandomNumberGenerator()
        return try #require(GuideExamples.round([.choice(item)], count: 1, allowWritten: typed,
                                                allowMultipleChoice: !typed, using: &rng).first)
    }

    @Test("the example, its typed and multiple choice forms and its saved question share one key")
    func oneKey() async throws {
        let (db, guideId, example) = try await library()
        try await db.queue.write { _ = try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        let saved = try await db.queue.read { try TestQuestion.fetchAll($0) }
        let mc = try #require(saved.first { $0.problem?.kind == .multipleChoice })
        let key = QuestionUnderstanding.key(of: example)
        #expect(QuestionUnderstanding.key(of: try guideQuestion(example, typed: false)) == key)
        #expect(QuestionUnderstanding.key(of: try guideQuestion(example, typed: true)) == key)
        #expect(QuestionUnderstanding.key(of: mc) == key)
        #expect(QuestionUnderstanding.key("It\u{2019}s  A\nTest ") == QuestionUnderstanding.key("it's a test"))
    }

    @Test("answers in a guide test and as a saved question move the same meter")
    func shared() async throws {
        let (db, guideId, example) = try await library()
        try await db.queue.write { _ = try GuideQuestions.addQuestions(guideId: guideId, db: $0) }
        let saved = try await db.queue.read { try TestQuestion.fetchAll($0) }
        let mc = try #require(saved.first { $0.problem?.kind == .multipleChoice })

        let before = try await db.queue.read { try QuestionUnderstanding.states(of: [mc], db: $0) }
        #expect(before[mc.id] == .of(level: nil))

        // Right in the guide's test: recognition, on both.
        try await answer([try guideQuestion(example, typed: false)], [true], db: db, at: Date(timeIntervalSince1970: 100))
        let key = QuestionUnderstanding.key(of: example)
        var states = try await db.queue.read { try QuestionUnderstanding.states(forKeys: [key], db: $0) }
        #expect(states[key]?.level == .recognition)

        // Right again as the saved question: recall, on both.
        let round = try await db.queue.read { conn -> [LearnEngine.RoundQuestion] in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: 10, inDecks: [mc.deckId], allowWritten: true,
                                                  allowMultipleChoice: true, using: &rng, db: conn)
        }
        let asked = try #require(round.first { $0.bankQuestionId == mc.id })
        try await answer([asked], [true], db: db, at: Date(timeIntervalSince1970: 200))
        states = try await db.queue.read { try QuestionUnderstanding.states(forKeys: [key], db: $0) }
        let bySaved = try await db.queue.read { try QuestionUnderstanding.states(of: [mc], db: $0) }
        #expect(states[key]?.level == .recall)
        #expect(bySaved[mc.id] == states[key])
    }

    @Test("the card ladder's rules: one miss is remembered, a second in a row drops a level")
    func ladder() async throws {
        let (db, _, example) = try await library()
        let question = try guideQuestion(example, typed: false)
        let key = QuestionUnderstanding.key(of: example)
        try await answer([question], [true], db: db, at: Date(timeIntervalSince1970: 100))
        try await answer([question], [true], db: db, at: Date(timeIntervalSince1970: 150))
        try await answer([question], [false], db: db, at: Date(timeIntervalSince1970: 200))
        var state = try await db.queue.read { try QuestionUnderstanding.states(forKeys: [key], db: $0) }[key]
        #expect(state?.level == .recall && state?.missedOnce == true)
        try await answer([question], [false], db: db, at: Date(timeIntervalSince1970: 300))
        state = try await db.queue.read { try QuestionUnderstanding.states(forKeys: [key], db: $0) }[key]
        #expect(state?.level == .recognition && state?.asked == true)
    }

    @Test("a card's answers stay on the card")
    func cardsLeftOut() async throws {
        let (db, _, example) = try await library()
        var question = try guideQuestion(example, typed: false)
        let card = Card(materialId: nil, front: question.prompt, back: question.correctAnswer, origin: .manual, status: .active)
        question.cardId = card.id
        let asked = question
        try await db.queue.write { conn in
            try card.insert(conn)
            let id = try Study.startRetry(questions: [asked], deckIds: [], db: conn)
            try Study.submitTestAnswer(attemptId: id, ordinal: 0, given: "x", isCorrect: true, db: conn)
        }
        let key = QuestionUnderstanding.key(of: example)
        let state = try await db.queue.read { try QuestionUnderstanding.states(forKeys: [key], db: $0) }[key]
        #expect(state == .of(level: nil))
    }
}

@Suite("Exam 2 guide meters", .enabled(if: FileManager.default.fileExists(atPath: Exam2Fixture.file.path)))
struct Exam2QuestionUnderstandingTests {
    @Test("each of the 59 questions has its own meter, shared by its guide test forms and its saved question")
    func fiftyNineKeys() async throws {
        let page = try await Exam2Fixture.page()
        let examples = page.parts.flatMap(\.examples).map(\.example).filter { $0.answer?.isEmpty == false }
        let keys = Set(examples.map(QuestionUnderstanding.key(of:)))
        #expect(examples.count == 59 && keys.count == 59)

        let items = GuideExamples.items(from: page)
        var rng = SystemRandomNumberGenerator()
        for (written, choice) in [(true, false), (false, true)] {
            let round = GuideExamples.round(items, count: 100, allowWritten: written, allowMultipleChoice: choice, using: &rng)
            #expect(!round.isEmpty)
            #expect(round.allSatisfy { keys.contains(QuestionUnderstanding.key(of: $0)) })
        }

        let db = try GRASPDatabase.inMemory()
        let course = Course(semesterId: nil, name: "Microeconomic Principles", code: "ECO 2023")
        let material = Material(courseId: course.id, relativePath: "/vault/guide.md", kind: .markdown, title: "Exam 2")
        let text = try String(contentsOf: Exam2Fixture.file, encoding: .utf8)
        try await db.queue.write { conn in
            try course.insert(conn)
            try material.insert(conn)
            let guide = try StudyGuideActions.importGuide(material: material, pages: [text], db: conn)
            _ = try GuideQuestions.addQuestions(guideId: guide.id, db: conn)
        }
        let saved = try await db.queue.read { try TestQuestion.fetchAll($0) }
        #expect(Set(saved.map(QuestionUnderstanding.key(of:))) == keys)
    }
}
