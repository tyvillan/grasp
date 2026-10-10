import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Multiple-choice versions")
struct ChoiceVersionTests {
    @Test("blank candidates flip operators and nudge numbers, never repeating an accepted answer")
    func blankCandidates() {
        let options = ChoiceVersions.blankCandidates(answer: "i <= 5", accepted: ["i <= 5", "i < 6"],
                                                     code: "for (int i = 0; [[1]]; i++) total += i;", otherAnswers: [])
        #expect(options.contains("i < 5"))
        #expect(options.contains("i <= 6"))
        #expect(!options.contains("i < 6"))
        #expect(!options.contains("i <= 5"))
    }

    @Test("output, number and matrix candidates are all wrong and distinct")
    func otherCandidates() {
        let outputs = ChoiceVersions.outputCandidates("1\n2\n3")
        #expect(outputs.count >= 3)
        #expect(!outputs.contains("1\n2\n3"))
        #expect(Set(outputs).count == outputs.count)

        let numbers = ChoiceVersions.numberCandidates(12, unit: "dollars")
        #expect(numbers.count >= 3)
        #expect(!numbers.contains("12 dollars"))
        #expect(numbers.contains("-12 dollars"))

        let matrices = ChoiceVersions.matrixCandidates([[1, 2], [3, 4]])
        #expect(matrices.count >= 3)
        #expect(matrices.contains("[ 1  3 ]\n[ 2  4 ]"))
        #expect(!matrices.contains("[ 1  2 ]\n[ 3  4 ]"))
    }

    @Test("a fill-in-the-blank question gets three wrong fills that really are wrong",
          .enabled(if: ProcessCodeExecutor().canRun(.python)))
    func runChecked() async {
        let question = CodeQuestion(kind: .codeBlanks, language: .python, prompt: "p",
                                    code: "total = 0\nfor i in range([[1]]):\n    total += i\nprint(total)",
                                    blanks: [["5"]], expectedOutput: "10")
        let upgraded = await CodeQuestionBuilder.addingChoices(to: question, using: ProcessCodeExecutor())
        #expect(upgraded.choiceBlank == 1)
        #expect(upgraded.choices?.count == 3)
        #expect(upgraded.choices?.contains("5") == false)

        var rng = SystemRandomNumberGenerator()
        let version = ChoiceVersions.codeVersion(upgraded, using: &rng)
        #expect(version?.type == .multipleChoice)
        #expect(version?.choices?.count == 4)
        #expect(version?.choices?.contains("5") == true)
        #expect(version?.correctAnswer == "5")
    }

    @Test("a multiple-choice-only test takes only questions that have a choice version")
    func pickRoundModes() async throws {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Math")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Ch 1")
            try deck.insert(conn)
            let number = ProblemQuestion(kind: .number, subject: .math, prompt: "2 + 2?", number: 4)
            try TestQuestion(courseId: course.id, deckId: deck.id, problem: number, bodyJSON: number.encoded()!,
                             verifiedBy: "script").insert(conn)
            let bug = CodeQuestion(kind: .findBug, language: .python, prompt: "p", code: "print(1)", buggyLine: 1)
            try TestQuestion(courseId: course.id, deckId: deck.id, kind: .findBug, language: .python,
                             bodyJSON: bug.encoded()!, verifiedBy: "run").insert(conn)
            return deck.id
        }
        let choiceOnly = try await db.queue.read { db in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: 5, inDecks: [deckId], allowWritten: false,
                                                  allowMultipleChoice: true, using: &rng, db: db)
        }
        #expect(choiceOnly.count == 1)
        #expect(choiceOnly.first?.type == .multipleChoice)
        #expect(choiceOnly.first?.choices?.contains("4") == true)

        let writtenOnly = try await db.queue.read { db in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: 5, inDecks: [deckId], allowWritten: true,
                                                  allowMultipleChoice: false, using: &rng, db: db)
        }
        #expect(writtenOnly.count == 2)
        #expect(writtenOnly.allSatisfy { $0.type == .written })
    }
}

@Suite("Unfinished tests")
struct UnfinishedTestTests {
    @Test("a test left halfway is found, rebuilt with its answers, and can be discarded")
    func resume() async throws {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Bio")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Cells")
            try deck.insert(conn)
            for (index, pair) in [("Mitochondria", "Makes ATP"), ("Ribosome", "Builds proteins"), ("Nucleus", "Holds DNA"),
                                  ("Golgi", "Packages"), ("Lysosome", "Digests")].enumerated() {
                let card = Card(materialId: nil, front: pair.0, back: pair.1, origin: .manual, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
            }
            return deck.id
        }
        let config = TestBuilder.Config(questionCount: 5, allowMultipleChoice: true, allowWritten: true,
                                        allowTrueFalse: true, shuffle: true)
        let (attemptId, questions) = try await db.queue.write { var rng = SystemRandomNumberGenerator()
            return try Study.startTest(deckIds: [deckId], config: config, using: &rng, db: $0) }
        try await db.queue.write { db in
            try Study.submitTestAnswer(attemptId: attemptId, ordinal: 0, given: "a", isCorrect: true, db: db)
            try Study.submitTestAnswer(attemptId: attemptId, ordinal: 1, given: "b", isCorrect: false, db: db)
        }
        let unfinished = try #require(try await db.queue.read { try Study.unfinishedTest(forDecks: [deckId], db: $0) })
        #expect(unfinished.attemptId == attemptId && unfinished.answered == 2 && unfinished.total == questions.count)

        let resumed = try await db.queue.read { try Study.resumeTest(attemptId: attemptId, db: $0) }
        #expect(resumed.questions.count == questions.count)
        #expect(resumed.answers.map(\.isCorrect) == [true, false])
        for (old, new) in zip(questions, resumed.questions) {
            #expect(old.type == new.type)
            #expect(old.prompt == new.prompt)
            #expect(old.correctAnswer == new.correctAnswer)
            #expect(old.statement == new.statement)
            #expect(Set(old.choices ?? []) == Set(new.choices ?? []))
        }

        try await db.queue.write { try Study.discardTest(attemptId: attemptId, db: $0) }
        #expect(try await db.queue.read { try Study.unfinishedTest(forDecks: [deckId], db: $0) } == nil)
    }
}

@Suite("Blank candidates from names")
struct BlankNameTests {
    @Test("text inside quotes is never offered as a name")
    func noStringContents() {
        let options = ChoiceVersions.blankCandidates(answer: "Room", accepted: ["Room"],
                                                     code: "class Room: pass\nclass House: pass\nx = [[1]](\"bedroom\")",
                                                     otherAnswers: [])
        #expect(options.contains("House"))
        #expect(!options.contains("bedroom"))
    }
}
