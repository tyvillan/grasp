import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// A guide's lettered practice questions as multiple choice: only the five
/// options (a) to (e) with a matching "(x) text" answer; multi-part and
/// classify questions stay typed.
@Suite("Guide multiple choice")
struct GuideChoiceTests {
    private let options = "(a) $20 million\n(b) $30 million\n(c) $90 million\n(d) $180 million\n(e) $540 million"

    @Test("five lettered options and a matching lettered answer are multiple choice, in the note's order")
    func recognised() throws {
        let item = try #require(GuideExamples.choiceItem(
            question: "Practice exam Q1. Lentils.\nrow 1: 80, 140\nWhat is the loss?\n" + options,
            answer: "(b) $30 million."))
        #expect(item.stem == "Practice exam Q1. Lentils.\nrow 1: 80, 140\nWhat is the loss?")
        #expect(item.options == ["$20 million", "$30 million", "$90 million", "$180 million", "$540 million"])
        #expect(item.correct == 1 && item.letter == "b" && item.correctText == "$30 million")
    }

    @Test("a multi-part question stays typed, even with an answer that starts with a letter")
    func multiPart() {
        let q = "A cap of $680.\n(a) How many cottages are rented?\n(b) What is the full price?\n(c) How much is lost?"
        #expect(GuideExamples.choiceItem(question: q, answer: "(a) 40 rented, 30 short. (b) $920. (c) $1,200 lost.") == nil)
    }

    @Test("a classify list with four items and no letter in the answer stays typed")
    func classify() {
        let q = "Classify each good:\n(a) a breakwater;\n(b) a website;\n(c) driftwood;\n(d) a sushi roll."
        #expect(GuideExamples.choiceItem(question: q, answer: "Pure public good, club good, common-pool resource, private good.") == nil)
    }

    @Test("every other way of not matching is refused")
    func refused() {
        let ok = "Which?\n" + options
        // A second marker in the answer.
        #expect(GuideExamples.choiceItem(question: ok, answer: "(b) $30 million. (c) $90 million") == nil)
        // The text is not option b's.
        #expect(GuideExamples.choiceItem(question: ok, answer: "(b) $90 million") == nil)
        // No letter, or a letter outside a to e.
        #expect(GuideExamples.choiceItem(question: ok, answer: "$30 million") == nil)
        #expect(GuideExamples.choiceItem(question: ok, answer: "(f) $30 million") == nil)
        // Four options, six options, options out of order, words after the options.
        #expect(GuideExamples.choiceItem(question: "Which?\n(a) 1\n(b) 2\n(c) 3\n(d) 4", answer: "(b) 2") == nil)
        #expect(GuideExamples.choiceItem(question: ok + "\n(f) $1", answer: "(b) $30 million") == nil)
        #expect(GuideExamples.choiceItem(question: "Which?\n(b) 2\n(a) 1\n(c) 3\n(d) 4\n(e) 5", answer: "(b) 2") == nil)
        #expect(GuideExamples.choiceItem(question: ok + "\nAssume no tips.", answer: "(b) $30 million") == nil)
        // Two options that read the same.
        #expect(GuideExamples.choiceItem(question: "Which?\n(a) 1\n(b) 2\n(c) 2.\n(d) 4\n(e) 5", answer: "(b) 2") == nil)
    }

    private func item(_ question: String, _ answer: String) -> StudyGuideDocument.Example {
        .init(label: nil, question: question, steps: [], answer: answer)
    }

    private func page(_ examples: [StudyGuideDocument.Example]) -> StudyGuideActions.ExamPage {
        let part = StudyGuideActions.PagePart(
            number: 1, title: "Practice", questionCount: nil, sources: [], deckIds: [], skills: [], traps: [],
            examples: examples.enumerated().map { .init(id: "e\($0.offset)", guideId: "g", example: $0.element) },
            terms: [], formulas: [], remember: [], notes: [])
        return StudyGuideActions.ExamPage(exam: CalendarEvent(title: "Exam 2", startsAt: Date()), guides: [],
                                          questionCount: nil, format: [], notes: [], parts: [part], unreadGuides: [],
                                          isPracticeSet: false)
    }

    @Test("a test shows the stem with five fixed-order choices, or the stem with its choices typed")
    func rounds() throws {
        let items = GuideExamples.items(from: page([item("Which?\n" + options, "(b) $30 million.")]))
        guard case .choice = items.first else { Issue.record("not a choice item"); return }
        var rng = SystemRandomNumberGenerator()

        let mc = GuideExamples.round(items, count: 5, allowWritten: true, allowMultipleChoice: true, using: &rng)
        let q = try #require(mc.first)
        #expect(q.type == .multipleChoice && q.prompt == "Which?" && q.correctAnswer == "$30 million")
        #expect(q.choices == ["$20 million", "$30 million", "$90 million", "$180 million", "$540 million"])

        let typed = try #require(GuideExamples.round(items, count: 5, allowWritten: true, allowMultipleChoice: false,
                                                     using: &rng).first)
        #expect(typed.type == .written && typed.prompt == "Which?\n" + options)
        #expect(typed.choices == nil && typed.correctAnswer == "$30 million")

        #expect(GuideExamples.round(items, count: 5, allowWritten: false, allowMultipleChoice: false, using: &rng).isEmpty)
    }

    @Test("typed, the letter, the letter in brackets, the words or both are right; another letter is not")
    func typedGrading() async throws {
        let items = GuideExamples.items(from: page([item("Which?\n" + options, "(b) $30 million.")]))
        var rng = SystemRandomNumberGenerator()
        let q = try #require(GuideExamples.round(items, count: 1, allowWritten: true, allowMultipleChoice: false,
                                                 using: &rng).first)
        func verdict(_ given: String) async -> AnswerOutcome {
            await AnswerLadder.judge(question: q.prompt, expected: q.correctAnswer, given: given,
                                     accepted: q.acceptedAnswers.map(AnswerGrading.normalize), judge: nil).outcome
        }
        for given in ["b", "B", "(b)", "$30 million", "30 million", "(b) $30 million", "b. $30 million"] {
            #expect(await verdict(given) == .correct, "\(given)")
        }
        for given in ["a", "(c)", "$20 million", "(c) $30 million", ""] {
            #expect(await verdict(given) != .correct, "\(given)")
        }
    }

    @Test("an unfinished typed test keeps the letters it accepts")
    func resumeKeepsAccepted() async throws {
        let db = try GRASPDatabase.inMemory()
        let items = GuideExamples.items(from: page([item("Which?\n" + options, "(b) $30 million.")]))
        var rng = SystemRandomNumberGenerator()
        let typed = GuideExamples.round(items, count: 1, allowWritten: true, allowMultipleChoice: false, using: &rng)
        let attempt = try await db.queue.write { try Study.startRetry(questions: typed, deckIds: [], scopeKey: "guide:x", db: $0) }
        let resumed = try await db.queue.read { try Study.resumeTest(attemptId: attempt, db: $0) }
        #expect(resumed.questions.first?.acceptedAnswers == typed.first?.acceptedAnswers)

        let mc = GuideExamples.round(items, count: 1, allowWritten: false, allowMultipleChoice: true, using: &rng)
        let attempt2 = try await db.queue.write { try Study.startRetry(questions: mc, deckIds: [], scopeKey: "guide:y", db: $0) }
        let back = try await db.queue.read { try Study.resumeTest(attemptId: attempt2, db: $0) }
        #expect(back.questions.first?.choices == mc.first?.choices && back.questions.first?.type == .multipleChoice)
    }
}

/// The real Exam 2 guide (course material, so kept out of the repo like the
/// Exam 1 fixtures): `grasp-fixtures/eco-exam2-study-guide.md`.
@Suite("Exam 2 guide as multiple choice",
       .enabled(if: FileManager.default.fileExists(atPath: Exam2Fixture.file.path)))
struct Exam2GuideChoiceTests {
    static let key = "b,b,c,c,a,d,e,c,a,d,a,b,b,c,d,e,d,b,a,d,a,e,c,d,b,c,c,e,b,d,a,e,e,a,e,a,e,d,b,c"
        .split(separator: ",").map(String.init)

    @Test("Examples 20 to 59 are all five-option multiple choice with the key's answers; the rest stay typed")
    func practiceExam() async throws {
        let page = try await Exam2Fixture.page()
        let examples = page.parts.flatMap(\.examples).map(\.example)
        #expect(examples.count == 59)
        #expect(Self.key.count == 40)

        // The page lists examples under their parts, so go by the label.
        let numbers = examples.compactMap { $0.label.flatMap { Int($0.replacingOccurrences(of: "Example ", with: "")) } }
        #expect(Set(numbers) == Set(1...59))
        for example in examples {
            let number = Int((example.label ?? "").replacingOccurrences(of: "Example ", with: "")) ?? 0
            let item = GuideExamples.choiceItem(question: example.question, answer: example.answer ?? "")
            if number >= 20 {
                let choice = try #require(item, "Example \(number) is not multiple choice")
                #expect(choice.options.count == 5, "Example \(number)")
                #expect(choice.letter == Self.key[number - 20], "Example \(number): \(choice.letter)")
                #expect(!choice.stem.isEmpty && !choice.stem.contains("(a)"), "Example \(number)")
            } else {
                // Examples 1, 4, 5, 7, 8, 10, 11, 14 and 16 are multi-part; 9 is a classify list.
                #expect(item == nil, "Example \(number) must stay typed")
            }
        }

        let items = GuideExamples.items(from: page)
        #expect(items.count == 59)
        var rng = SystemRandomNumberGenerator()
        let round = GuideExamples.round(items, count: 59, allowWritten: false, allowMultipleChoice: true, using: &rng)
        #expect(round.count == 40)
        #expect(round.allSatisfy { $0.type == .multipleChoice && $0.choices?.count == 5 })
        #expect(round.allSatisfy { $0.choices?.contains($0.correctAnswer) == true })

        let typed = GuideExamples.round(items, count: 59, allowWritten: true, allowMultipleChoice: false, using: &rng)
        #expect(typed.count == 59)
    }

    @Test("typed, every practice question accepts its letter and its words")
    func typedPractice() async throws {
        let page = try await Exam2Fixture.page()
        var rng = SystemRandomNumberGenerator()
        let typed = GuideExamples.round(GuideExamples.items(from: page), count: 59, allowWritten: true,
                                        allowMultipleChoice: false, using: &rng).filter { !$0.acceptedAnswers.isEmpty }
        #expect(typed.count == 40)
        for q in typed {
            let letter = q.acceptedAnswers[0]
            for given in [letter, "(\(letter))", q.correctAnswer, "(\(letter)) \(q.correctAnswer)"] {
                let outcome = await AnswerLadder.judge(question: q.prompt, expected: q.correctAnswer, given: given,
                                                       accepted: q.acceptedAnswers.map(AnswerGrading.normalize), judge: nil).outcome
                #expect(outcome == .correct, "\(given) for \(q.correctAnswer)")
            }
        }
    }
}

enum Exam2Fixture {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/grasp-fixtures/eco-exam2-study-guide.md")

    /// The guide imported the way the app does it (through the vault scanner)
    /// into a throwaway in-memory database.
    static func page() async throws -> StudyGuideActions.ExamPage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exam2-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("College/Fall Semester 2026-2027/Microeconomic Principles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("ECO 2023 - Exam 2 Study Guide.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try GRASPDatabase.inMemory()
        _ = try await VaultScanner(database: db).scan(vaultRoot: root)
        let guideId = try #require(try await db.queue.read { try StudyGuide.fetchOne($0)?.id })
        return try #require(try await db.queue.read { try StudyGuideActions.practicePage(guideId: guideId, db: $0) })
    }
}
