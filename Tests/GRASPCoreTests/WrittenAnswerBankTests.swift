import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Saved questions with a written answer")
struct WrittenAnswerBankTests {
    private func makeBank(writtenAnswer: String?) async throws -> (GRASPDatabase, String) {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Software Design")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Week 1")
            try deck.insert(conn)
            let problem = ProblemQuestion(
                kind: .multipleChoice, subject: .concepts,
                prompt: "Which layer holds the database?",
                choices: ["Presentation layer", "Business layer", "Data layer", "Network layer"], correct: 2,
                explanation: "The data layer stores and retrieves data.", writtenAnswer: writtenAnswer)
            try TestQuestion(courseId: course.id, deckId: deck.id, problem: problem, bodyJSON: problem.encoded()!,
                             verifiedBy: "written by hand").insert(conn)
            return deck.id
        }
        return (db, deckId)
    }

    private func pick(_ db: GRASPDatabase, _ deckId: String, written: Bool, choice: Bool) async throws
        -> [LearnEngine.RoundQuestion] {
        try await db.queue.read { conn in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: 5, inDecks: [deckId], allowWritten: written,
                                                  allowMultipleChoice: choice, using: &rng, db: conn)
        }
    }

    @Test("with only Written on, the question is asked as a written one and graded against the model answer")
    func writtenOnly() async throws {
        let (db, deckId) = try await makeBank(writtenAnswer: "The data layer.")
        let questions = try await pick(db, deckId, written: true, choice: false)
        #expect(questions.count == 1)
        #expect(questions[0].type == .written)
        #expect(questions[0].correctAnswer == "The data layer.")
        #expect(questions[0].choices == nil)
        #expect(questions[0].whyText == "The data layer stores and retrieves data.")
        #expect(questions[0].allowsMarkCorrect)
    }

    @Test("with only Multiple choice on, it shows its four options with the right one among them")
    func choiceOnly() async throws {
        let (db, deckId) = try await makeBank(writtenAnswer: "The data layer.")
        let questions = try await pick(db, deckId, written: false, choice: true)
        #expect(questions.count == 1)
        #expect(questions[0].type == .multipleChoice)
        #expect(Set(questions[0].choices ?? []).count == 4)
        #expect(questions[0].correctAnswer == "Data layer")
        #expect(questions[0].choices?.contains("Data layer") == true)
    }

    @Test("with both on, each question is one or the other, across many draws both turn up")
    func both() async throws {
        let (db, deckId) = try await makeBank(writtenAnswer: "The data layer.")
        var kinds = Set<String>()
        for _ in 0..<60 {
            let questions = try await pick(db, deckId, written: true, choice: true)
            #expect(questions.count == 1)
            kinds.insert(questions[0].type == .written ? "written" : "choice")
        }
        #expect(kinds == ["written", "choice"])
    }

    @Test("a question saved without a written answer is multiple choice in any test, as before")
    func legacy() async throws {
        let (db, deckId) = try await makeBank(writtenAnswer: nil)
        for (written, choice) in [(true, false), (false, true), (true, true)] {
            let questions = try await pick(db, deckId, written: written, choice: choice)
            #expect(questions.count == 1)
            #expect(questions[0].type == .multipleChoice)
        }
    }

    @Test("an older build's JSON, with no written answer key, still decodes")
    func decodesWithoutKey() {
        let json = #"{"kind":"multipleChoice","subject":"concepts","prompt":"p","choices":["a","b"],"correct":0}"#
        let problem = ProblemQuestion.decode(json)
        #expect(problem?.writtenAnswer == nil)
        #expect(problem?.answerText == "a")
    }
}
