import Foundation
import Testing
import GRDB
@testable import GRASPCore

@Suite("Questions as a feature")
struct QuestionsTabTests {
    // MARK: Fixtures

    private struct Library {
        var db: GRASPDatabase
        var courseId: String
        var deckId: String
        var cardId: String
    }

    private func makeLibrary(cards: Int = 1) throws -> Library {
        let db = try GRASPDatabase.inMemory()
        return try db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Anthropology"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Module 1"); try deck.insert(conn)
            var first = ""
            for index in 0..<cards {
                let card = Card(materialId: nil, front: "Term \(index)", back: "Definition \(index)", origin: .manual,
                                status: .active, stability: 4, difficulty: 5, reps: 3)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
                if index == 0 { first = card.id }
            }
            return Library(db: db, courseId: course.id, deckId: deck.id, cardId: first)
        }
    }

    private func mc(_ prompt: String = "Which is right?", card: String? = nil) -> UserQuestionInput {
        UserQuestionInput(kind: .multipleChoice, prompt: prompt, choices: ["A", "B", "C"], correct: 1,
                          explanation: "Because B.", cardId: card)
    }

    // MARK: Migration

    @Test("the v19 migration keeps every old question and gives it the defaults")
    func migrationKeepsRows() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-q-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DatabaseQueue(path: path.path)
        let migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v18_learn_streak")
        let now = Date()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO course (id, name, sortIndex, isArchived, createdAt, updatedAt) VALUES ('c', 'C', 0, 0, ?, ?)",
                           arguments: [now, now])
            try db.execute(sql: "INSERT INTO deck (id, courseId, name, origin, sortIndex, createdAt, updatedAt) VALUES ('d', 'c', 'D', 'auto', 0, ?, ?)",
                           arguments: [now, now])
            for index in 0..<253 {
                try db.execute(sql: """
                    INSERT INTO testQuestion (id, courseId, deckId, kind, language, bodyJSON, verifiedBy, createdAt)
                    VALUES (?, 'c', 'd', 'multipleChoice', 'concepts', '{}', 'by hand', ?)
                    """, arguments: ["q\(index)", now])
            }
            try db.execute(sql: "INSERT INTO testAttempt (id, configJSON, startedAt) VALUES ('a', '{}', ?)", arguments: [now])
            try db.execute(sql: """
                INSERT INTO testItem (id, attemptId, ordinal, questionType, promptText, isAIGenerated)
                VALUES ('i', 'a', 0, 'problem', 'p', 1)
                """)
        }
        try migrator.migrate(queue)
        try queue.read { db in
            #expect(try TestQuestion.fetchCount(db) == 253)
            let first = try #require(try TestQuestion.fetchOne(db, key: "q0"))
            #expect(first.source == "ai" && first.status == "active")
            #expect(first.cardId == nil && first.imageId == nil && first.deletedAt == nil)
            #expect(try TestQuestion.filter(Column("source") == "ai").filter(Column("status") == "active").fetchCount(db) == 253)
            let item = try #require(try TestItem.fetchOne(db, key: "i"))
            #expect(item.questionId == nil && item.isAIGenerated)
        }
    }

    // MARK: Writing

    @Test("a multiple choice question needs two to six distinct choices and one right answer")
    func choiceValidation() {
        #expect(mc().problem == nil)
        var one = mc(); one.choices = ["A"]; #expect(one.problem != nil)
        var seven = mc(); seven.choices = (1...7).map { "C\($0)" }; #expect(seven.problem != nil)
        var six = mc(); six.choices = (1...6).map { "C\($0)" }; six.correct = 5; #expect(six.problem == nil)
        var blank = mc(); blank.choices = ["A", " "]; #expect(blank.problem != nil)
        var same = mc(); same.choices = ["A", "a", "B"]; #expect(same.problem != nil)
        var badIndex = mc(); badIndex.correct = 9; #expect(badIndex.problem != nil)
        var empty = mc(); empty.prompt = "  "; #expect(empty.problem != nil)
    }

    @Test("written needs an answer and true/false needs only a statement")
    func otherKindsValidation() {
        #expect(UserQuestionInput(kind: .written, prompt: "Define X").problem != nil)
        #expect(UserQuestionInput(kind: .written, prompt: "Define X", answer: "y").problem == nil)
        #expect(UserQuestionInput(kind: .trueFalse, prompt: "X is y", isTrue: false).problem == nil)
        #expect(UserQuestionInput(kind: .number, prompt: "x").problem != nil)
    }

    @Test("writing a question saves it active, from you, in the deck's course")
    func createSavesActive() throws {
        let lib = try makeLibrary()
        let saved = try lib.db.queue.write { try QuestionBank.create(mc(), deckId: lib.deckId, db: $0) }
        #expect(saved.sourceKind == .yours && saved.statusKind == .active)
        #expect(saved.courseId == lib.courseId && saved.deckId == lib.deckId)
        #expect(saved.problem?.choices == ["A", "B", "C"])
        #expect(try lib.db.queue.read { try QuestionBank.listing(inDecks: [lib.deckId], db: $0) }.count == 1)
    }

    @Test("an invalid question is refused with a plain sentence")
    func createRefuses() throws {
        let lib = try makeLibrary()
        var bad = mc(); bad.choices = ["A"]
        #expect(throws: QuestionBankError.self) {
            try lib.db.queue.write { try QuestionBank.create(bad, deckId: lib.deckId, db: $0) }
        }
    }

    @Test("editing changes the content and keeps source, status and history link")
    func editKeepsIdentity() throws {
        let lib = try makeLibrary()
        let saved = try lib.db.queue.write { try QuestionBank.create(mc(), deckId: lib.deckId, db: $0) }
        try lib.db.queue.write { try QuestionBank.setStatus(saved.id, to: .suspended, db: $0) }
        var edited = mc("A new prompt?"); edited.explanation = ""
        try lib.db.queue.write { try QuestionBank.update(saved.id, with: edited, db: $0) }
        let after = try #require(try lib.db.queue.read { try TestQuestion.fetchOne($0, key: saved.id) })
        #expect(after.problem?.prompt == "A new prompt?" && after.problem?.explanation == nil)
        #expect(after.sourceKind == .yours && after.statusKind == .suspended && after.id == saved.id)
    }

    @Test("deleting hides a question but never touches test history")
    func deleteKeepsHistory() throws {
        let lib = try makeLibrary()
        let saved = try lib.db.queue.write { try QuestionBank.create(mc(), deckId: lib.deckId, db: $0) }
        try lib.db.queue.write { db in
            try TestAttempt(deckId: lib.deckId, configJSON: "{}").insert(db)
            let attempt = try #require(try TestAttempt.fetchOne(db))
            try TestItem(attemptId: attempt.id, cardId: nil, ordinal: 0, questionType: "problem", promptText: "p",
                         isCorrect: true, questionId: saved.id).insert(db)
            try CodeQuestionBank.delete(saved.id, db: db)
        }
        #expect(try lib.db.queue.read { try QuestionBank.listing(inDecks: [lib.deckId], db: $0) }.isEmpty)
        #expect(try lib.db.queue.read { try TestItem.fetchCount($0) } == 1)
    }

    // MARK: Status and picking

    private func pick(_ lib: Library, count: Int = 10, written: Bool = true, choice: Bool = true,
                      trueFalse: Bool = true) throws -> [LearnEngine.RoundQuestion] {
        try lib.db.queue.read { db in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: count, inDecks: [lib.deckId], allowWritten: written,
                                                  allowMultipleChoice: choice, allowTrueFalse: trueFalse,
                                                  using: &rng, db: db)
        }
    }

    @Test("only active questions reach a test; suspended and drafts do not")
    func statusGatesTests() throws {
        let lib = try makeLibrary()
        let ids = try lib.db.queue.write { db in
            [try QuestionBank.create(mc("one?"), deckId: lib.deckId, db: db).id,
             try QuestionBank.create(mc("two?"), deckId: lib.deckId, db: db).id,
             try QuestionBank.create(mc("three?"), deckId: lib.deckId, db: db).id]
        }
        #expect(try pick(lib).count == 3)
        try lib.db.queue.write { try QuestionBank.setStatus(ids[0], to: .suspended, db: $0) }
        try lib.db.queue.write { try QuestionBank.setStatus(ids[1], to: .draft, db: $0) }
        #expect(try pick(lib).map(\.prompt) == ["three?"])
        #expect(try lib.db.queue.read { try QuestionBank.activeCount(inDecks: [lib.deckId], db: $0) } == 1)
        // They stay in the tab's listing.
        #expect(try lib.db.queue.read { try QuestionBank.listing(inDecks: [lib.deckId], db: $0) }.count == 3)
        try lib.db.queue.write { try QuestionBank.setStatus(ids[0], to: .active, db: $0) }
        #expect(try pick(lib).count == 2)
    }

    @Test("the type switches decide which saved questions are asked")
    func typeSwitches() throws {
        let lib = try makeLibrary()
        try lib.db.queue.write { db in
            try QuestionBank.create(mc("mc?"), deckId: lib.deckId, db: db)
            try QuestionBank.create(UserQuestionInput(kind: .written, prompt: "w?", answer: "ans", accepted: ["alt"]),
                                    deckId: lib.deckId, db: db)
            try QuestionBank.create(UserQuestionInput(kind: .trueFalse, prompt: "tf statement", isTrue: false),
                                    deckId: lib.deckId, db: db)
        }
        #expect(Set(try pick(lib).map(\.prompt)) == ["mc?", "w?", "tf statement"])
        #expect(Set(try pick(lib, written: false).map(\.prompt)) == ["mc?", "tf statement"])
        #expect(Set(try pick(lib, written: false, choice: false).map(\.prompt)) == ["tf statement"])
        #expect(Set(try pick(lib, trueFalse: false).map(\.prompt)) == ["mc?", "w?"])
        // As before, a multiple choice question fits a test that allows written answers too.
        #expect(Set(try pick(lib, written: true, choice: false, trueFalse: false).map(\.prompt)) == ["mc?", "w?"])
        let written = try #require(try pick(lib).first { $0.prompt == "w?" })
        #expect(written.type == .written && written.correctAnswer == "ans" && written.acceptedAnswers == ["alt"])
        let tf = try #require(try pick(lib).first { $0.prompt == "tf statement" })
        #expect(tf.type == .trueFalse && tf.statementIsTrue == false && tf.correctAnswer == "False")
    }

    @Test("Test setup counts the questions the chosen types really match")
    func matchingCount() throws {
        let lib = try makeLibrary(cards: 0)
        try lib.db.queue.write { db in
            try QuestionBank.create(mc("mc?"), deckId: lib.deckId, db: db)
            try QuestionBank.create(UserQuestionInput(kind: .written, prompt: "w?", answer: "ans"), deckId: lib.deckId, db: db)
            try QuestionBank.create(UserQuestionInput(kind: .trueFalse, prompt: "tf statement", isTrue: false), deckId: lib.deckId, db: db)
        }
        func count(mc: Bool, written: Bool, tf: Bool, n: Int = 10, questions: Bool = true) throws -> Int {
            let config = TestBuilder.Config(questionCount: n, allowMultipleChoice: mc, allowWritten: written, allowTrueFalse: tf,
                                            shuffle: true, excludeMastered: false, weakSpotsOnly: false, includeFlashcards: false)
            return try lib.db.queue.read {
                try Study.matchingTestQuestionCount(deckIds: [lib.deckId], config: config, includeQuestions: questions, db: $0)
            }
        }
        #expect(try count(mc: true, written: true, tf: true) == 3)
        #expect(try count(mc: true, written: false, tf: false) == 1)
        #expect(try count(mc: false, written: false, tf: true) == 1)
        #expect(try count(mc: true, written: true, tf: true, n: 2) == 2)
        #expect(try count(mc: true, written: true, tf: true, questions: false) == 0)
        // With cards, the saved share is a third and cards fill the rest.
        let withCards = try makeLibrary(cards: 12)
        try withCards.db.queue.write { db in
            for index in 0..<4 { try QuestionBank.create(mc("mc \(index)?"), deckId: withCards.deckId, db: db) }
        }
        let config = TestBuilder.Config(questionCount: 30, allowMultipleChoice: true, allowWritten: false, allowTrueFalse: false,
                                        shuffle: true, excludeMastered: false, weakSpotsOnly: false, includeFlashcards: true)
        // 4 saved (share is 10) plus 12 cards, short of the 30 asked for.
        #expect(try withCards.db.queue.read {
            try Study.matchingTestQuestionCount(deckIds: [withCards.deckId], config: config, includeQuestions: true, db: $0)
        } == 16)
    }

    // MARK: Test switches

    @Test("neither switch on is refused in plain words")
    func neitherRefused() {
        #expect(Study.testSourcesProblem(includeFlashcards: false, includeQuestions: false) != nil)
        #expect(Study.testSourcesProblem(includeFlashcards: true, includeQuestions: false) == nil)
        #expect(Study.testSourcesProblem(includeFlashcards: false, includeQuestions: true) == nil)
        #expect(Study.testSourcesProblem(includeFlashcards: true, includeQuestions: true) == nil)
    }

    @Test("saved questions are about a third with flashcards, all of them without")
    func share() {
        #expect(Study.savedQuestionShare(for: 10, withFlashcards: true) == 3)
        #expect(Study.savedQuestionShare(for: 30, withFlashcards: true) == 10)
        #expect(Study.savedQuestionShare(for: 10, withFlashcards: false) == 10)
    }

    private func run(_ lib: Library, flashcards: Bool, questions: Bool, count: Int = 10) throws
        -> (attemptId: String, questions: [LearnEngine.RoundQuestion]) {
        var config = TestBuilder.Config(questionCount: count, allowMultipleChoice: true, allowWritten: false,
                                        allowTrueFalse: true, includeFlashcards: flashcards)
        config.shuffle = false
        let saved = questions
            ? try pick(lib, count: Study.savedQuestionShare(for: count, withFlashcards: flashcards),
                       written: false, choice: true, trueFalse: true)
            : []
        return try lib.db.queue.write { db in
            var rng = SystemRandomNumberGenerator()
            return try Study.startTest(deckIds: [lib.deckId], config: config, aiQuestions: saved, using: &rng, db: db)
        }
    }

    @Test("flashcards only, questions only, both: what each test is made of")
    func switchCombinations() throws {
        let lib = try makeLibrary(cards: 12)
        try lib.db.queue.write { db in
            for index in 0..<8 { try QuestionBank.create(mc("saved \(index)?"), deckId: lib.deckId, db: db) }
        }
        // Flashcards only: every question is a card's, as today.
        let cardsOnly = try run(lib, flashcards: true, questions: false)
        #expect(cardsOnly.questions.count == 10)
        #expect(cardsOnly.questions.allSatisfy { $0.cardId != nil && $0.bankQuestionId == nil })
        // Both: a third saved (3 of 10), the rest from cards.
        let both = try run(lib, flashcards: true, questions: true)
        #expect(both.questions.count == 10)
        #expect(both.questions.filter { $0.bankQuestionId != nil }.count == 3)
        #expect(both.questions.filter { $0.cardId != nil }.count == 7)
        // Questions only: the test is all saved questions, and uses what exists.
        let only = try run(lib, flashcards: false, questions: true)
        #expect(only.questions.count == 8)
        #expect(only.questions.allSatisfy { $0.bankQuestionId != nil && $0.cardId == nil })
        // Fewer saved than the share: use what exists, cards fill the rest.
        let few = try makeLibrary(cards: 12)
        try few.db.queue.write { _ = try QuestionBank.create(mc("only one?"), deckId: few.deckId, db: $0) }
        let mixed = try run(few, flashcards: true, questions: true)
        #expect(mixed.questions.count == 10)
        #expect(mixed.questions.filter { $0.bankQuestionId != nil }.count == 1)
        // Questions on but none saved and no flashcards: nothing to ask.
        let empty = try makeLibrary(cards: 3)
        #expect(try run(empty, flashcards: false, questions: true).questions.isEmpty)
    }

    // MARK: Cards and history

    private func schedule(_ lib: Library) throws -> (Card, Int) {
        try lib.db.queue.read { db in
            (try #require(try Card.fetchOne(db, key: lib.cardId)),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review") ?? 0)
        }
    }

    @Test("a right answer to a linked question moves the meter and never the flashcard schedule")
    func linkedQuestionLeavesScheduleAlone() throws {
        let lib = try makeLibrary()
        try lib.db.queue.write { _ = try QuestionBank.create(mc(card: lib.cardId), deckId: lib.deckId, db: $0) }
        let (before, reviewsBefore) = try schedule(lib)
        let started = try run(lib, flashcards: false, questions: true)
        #expect(started.questions.count == 1)
        try lib.db.queue.write { db in
            try Study.submitTestAnswer(attemptId: started.attemptId, ordinal: 0, given: "B", isCorrect: true, db: db)
            _ = try Study.finishTest(attemptId: started.attemptId, db: db)
        }
        let (after, reviewsAfter) = try schedule(lib)
        #expect(after.due == before.due && after.stability == before.stability && after.difficulty == before.difficulty)
        #expect(after.reps == before.reps && after.lapses == before.lapses && after.schedulerState == before.schedulerState)
        #expect(after.lastReview == before.lastReview && after.elapsedDays == before.elapsedDays
                && after.scheduledDays == before.scheduledDays && after.updatedAt == before.updatedAt)
        #expect(reviewsAfter == reviewsBefore)
        // The meter did move.
        let level = try lib.db.queue.read { try LearnState.fetchOne($0, key: lib.cardId)?.level }
        #expect((level ?? 0) >= LearnEngine.Level.recognition.rawValue)
    }

    @Test("a corrected answer ('I was right') to a linked question still leaves the schedule alone")
    func overrideLeavesScheduleAlone() throws {
        let lib = try makeLibrary()
        try lib.db.queue.write { _ = try QuestionBank.create(mc(card: lib.cardId), deckId: lib.deckId, db: $0) }
        let (before, reviewsBefore) = try schedule(lib)
        let started = try run(lib, flashcards: false, questions: true)
        try lib.db.queue.write { db in
            try Study.submitTestAnswer(attemptId: started.attemptId, ordinal: 0, given: "A", isCorrect: false, db: db)
            _ = try Study.finishTest(attemptId: started.attemptId, db: db)
            try Study.overrideTestItemCorrect(attemptId: started.attemptId, ordinal: 0, cardId: nil, db: db)
        }
        let (after, reviewsAfter) = try schedule(lib)
        #expect(after.reps == before.reps && after.due == before.due && after.stability == before.stability)
        #expect(reviewsAfter == reviewsBefore)
    }

    @Test("today's card questions still grade the card's schedule when answered right")
    func cardQuestionsKeepBehavior() throws {
        let lib = try makeLibrary()
        let (before, _) = try schedule(lib)
        let started = try run(lib, flashcards: true, questions: false, count: 5)
        let ordinal = try #require(started.questions.firstIndex { $0.cardId == lib.cardId })
        try lib.db.queue.write { db in
            try Study.submitTestAnswer(attemptId: started.attemptId, ordinal: ordinal, given: "x", isCorrect: true, db: db)
            _ = try Study.finishTest(attemptId: started.attemptId, db: db)
        }
        let (after, reviews) = try schedule(lib)
        #expect(after.reps > before.reps && reviews == 1)
        let level = try lib.db.queue.read { try LearnState.fetchOne($0, key: lib.cardId)?.level }
        #expect((level ?? 0) >= LearnEngine.Level.recognition.rawValue)
    }

    @Test("an unlinked question moves no card, only its own history")
    func unlinkedMovesNothing() throws {
        let lib = try makeLibrary()
        let saved = try lib.db.queue.write { try QuestionBank.create(mc(), deckId: lib.deckId, db: $0) }
        let (before, reviewsBefore) = try schedule(lib)
        let started = try run(lib, flashcards: false, questions: true)
        try lib.db.queue.write { db in
            try Study.submitTestAnswer(attemptId: started.attemptId, ordinal: 0, given: "B", isCorrect: true, db: db)
            _ = try Study.finishTest(attemptId: started.attemptId, db: db)
        }
        let (after, reviewsAfter) = try schedule(lib)
        #expect(after.reps == before.reps && reviewsAfter == reviewsBefore)
        #expect(try lib.db.queue.read { try LearnState.fetchCount($0) } == 0)
        let history = try lib.db.queue.read { try QuestionBank.history(of: [saved.id], db: $0) }
        #expect(history[saved.id] == QuestionHistory(right: 1, of: 1))
    }

    @Test("history reads the last three answers, newest first, answered items only")
    func historyWindow() throws {
        let lib = try makeLibrary()
        let saved = try lib.db.queue.write { try QuestionBank.create(mc(), deckId: lib.deckId, db: $0) }
        let other = try lib.db.queue.write { try QuestionBank.create(mc("other?"), deckId: lib.deckId, db: $0) }
        #expect(try lib.db.queue.read { try QuestionBank.history(of: [saved.id], db: $0) }.isEmpty)
        let results: [Bool?] = [false, true, true, nil, true]   // oldest to newest; nil = unanswered
        try lib.db.queue.write { db in
            for (index, result) in results.enumerated() {
                let attempt = TestAttempt(deckId: lib.deckId, configJSON: "{}",
                                          startedAt: Date(timeIntervalSince1970: 1_000 + Double(index) * 100))
                try attempt.insert(db)
                try TestItem(attemptId: attempt.id, cardId: nil, ordinal: 0, questionType: "problem", promptText: "p",
                             isCorrect: result, questionId: saved.id).insert(db)
            }
        }
        let history = try lib.db.queue.read { try QuestionBank.history(of: [saved.id, other.id], db: $0) }
        // Answered, newest first: true, true, true, false; the last three are all right.
        #expect(history[saved.id] == QuestionHistory(right: 3, of: 3))
        #expect(history[saved.id]?.line == "Right 3 of the last 3")
        #expect(history[other.id] == nil)
        #expect(QuestionHistory(right: 2, of: 3).line == "Right 2 of the last 3")
        #expect(QuestionHistory(right: 0, of: 0).line == nil)
    }

    @Test("an unfinished test remembers which saved question each item was")
    func resumeKeepsLink() throws {
        let lib = try makeLibrary()
        let saved = try lib.db.queue.write { db in
            try QuestionBank.create(UserQuestionInput(kind: .written, prompt: "Define X", answer: "alpha",
                                                      accepted: ["first letter"], explanation: "Greek."),
                                    deckId: lib.deckId, db: db)
        }
        var config = TestBuilder.Config(questionCount: 5, allowMultipleChoice: false, allowWritten: true,
                                        allowTrueFalse: false, includeFlashcards: false)
        config.shuffle = false
        let started = try lib.db.queue.write { db -> (attemptId: String, questions: [LearnEngine.RoundQuestion]) in
            var rng = SystemRandomNumberGenerator()
            let picked = try CodeQuestionBank.pickRound(count: 5, inDecks: [lib.deckId], allowWritten: true,
                                                        allowMultipleChoice: false, using: &rng, db: db)
            return try Study.startTest(deckIds: [lib.deckId], config: config, aiQuestions: picked, using: &rng, db: db)
        }
        let resumed = try #require(try lib.db.queue.read { try Study.resumeTest(attemptId: started.attemptId, db: $0) })
        let question = try #require(resumed.questions.first)
        #expect(question.bankQuestionId == saved.id && question.bankSource == "yours")
        #expect(question.acceptedAnswers == ["first letter"] && question.explanation == "Greek.")
        #expect(question.correctAnswer == "alpha")
    }
}
