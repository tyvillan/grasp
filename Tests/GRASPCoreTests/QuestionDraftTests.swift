import Foundation
import Testing
import GRDB
@testable import GRASPCore

/// A model that writes a fixed set: good questions, a repeat, a refusal, an
/// option-less "which of the following", and one the second pass disagrees with.
private final class DraftGenerator: CardGenerator, @unchecked Sendable {
    var available = true
    var problems: [GeneratedProblem] = []
    var written: [GeneratedTestQuestion] = []
    var solverDisagreesWith: String?
    var calls = 0
    /// When set, a problems call tells the test it has started, then waits
    /// until the run is cancelled. No clock is involved.
    var holdsUntilCancelled = false
    let started: AsyncStream<Void>
    private let startedSignal: AsyncStream<Void>.Continuation

    init() { (started, startedSignal) = AsyncStream.makeStream(of: Void.self) }

    var isAvailable: Bool { get async { available } }
    func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
    func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
    func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
    func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] {
        calls += 1; return written
    }
    func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation { ContextValidation(.valid) }
    func generateOverview(noteTitle: String, courseName: String, noteContext: String, includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
    func generateFigures(noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
    func generateProblems(deckName: String, courseName: String, noteContext: String, cardTerms: [String],
                          subject: ProblemSubject, kinds: [ProblemKind], count: Int) async -> [GeneratedProblem] {
        calls += 1
        if holdsUntilCancelled {
            startedSignal.yield()
            // Cancelling the run ends this sleep at once; the long length is only a backstop.
            try? await Task.sleep(for: .seconds(600))
        }
        return problems
    }
    func solveMultipleChoice(prompt: String, choices: [String]) async -> Int? {
        if let bad = solverDisagreesWith, prompt.contains(bad) { return (choices.count > 1) ? 1 : 0 }
        return 0
    }
}

@Suite("Question drafts")
struct QuestionDraftTests {
    private struct Library {
        var db: GRASPDatabase
        var deckId: String
        var courseId: String
        var materialId: String
        var cardId: String
    }

    private func makeLibrary() throws -> Library {
        let db = try GRASPDatabase.inMemory()
        return try db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Anthropology"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Module 1"); try deck.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/v/ch1.md", kind: .markdown, contentHash: "h1",
                                    title: "Module-01_Ch-01_What-is-Anthropology")
            try material.insert(conn)
            let text = "Anthropology studies what it means to be human. The field-based perspective collects data through direct contact. "
                + "Participant observation means taking part in social activities while observing them. Ethnography describes one society."
            try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 30, hasMath: false).insert(conn)
            let card = Card(materialId: material.id, front: "Ethnography", back: "Describes one society", origin: .parser, status: .active,
                            stability: 4, difficulty: 5, reps: 3)
            try card.insert(conn)
            try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            return Library(db: db, deckId: deck.id, courseId: course.id, materialId: material.id, cardId: card.id)
        }
    }

    private func mc(_ prompt: String, _ right: String = "Right answer", explanation: String? = "Because.") -> GeneratedProblem {
        GeneratedProblem(kind: .multipleChoice, prompt: prompt,
                         choices: [right, "A wrong option", "Another wrong option", "A third wrong option"], correct: 0, explanation: explanation)
    }

    private func run(_ lib: Library, _ generator: DraftGenerator, count: Int = 10, written: Bool = true) async -> DraftOutcome {
        await QuestionDrafter.generate(
            QuestionDrafter.Request(deckIds: [lib.deckId], count: count, multipleChoice: true, written: written),
            using: generator, executor: nil, database: lib.db)
    }

    // MARK: Writing drafts

    @Test("what the model writes lands as drafts from the AI, tied to their note, never active")
    func landsAsDrafts() async throws {
        let lib = try makeLibrary()
        let generator = DraftGenerator()
        generator.problems = [mc("Which perspective collects data through direct contact and full immersion?"),
                              mc("What does participant observation mean in fieldwork?")]
        generator.written = [GeneratedTestQuestion(prompt: "How does ethnography differ from ethnology?", correctAnswer: "Ethnography describes one society.")]
        let outcome = await run(lib, generator)
        #expect(outcome.saved == 3 && outcome.drops.isEmpty)
        let saved = try await lib.db.queue.read { try QuestionBank.listing(inDecks: [lib.deckId], db: $0) }
        #expect(saved.count == 3)
        #expect(saved.allSatisfy { $0.statusKind == .draft && $0.sourceKind == .ai && $0.materialId == lib.materialId && $0.cardId == nil })
        #expect(try await lib.db.queue.read { try QuestionBank.activeCount(inDecks: [lib.deckId], db: $0) } == 0)
        #expect(try await lib.db.queue.read { try QuestionBank.draftCount(inDecks: [lib.deckId], db: $0) } == 3)
    }

    @Test("repeats, refusals, option-less questions and failed second opinions are dropped and counted")
    func filtersAndCounts() async throws {
        let lib = try makeLibrary()
        // A question already saved in the deck.
        try await lib.db.queue.write {
            try QuestionBank.create(UserQuestionInput(kind: .written, prompt: "What does participant observation mean in fieldwork?", answer: "Taking part"),
                                    deckId: lib.deckId, db: $0)
        }
        let generator = DraftGenerator()
        generator.solverDisagreesWith = "unreliable"
        generator.problems = [
            mc("Which perspective collects data through direct contact and full immersion?"),            // kept
            mc("What does participant observation mean in fieldwork"),                                      // repeats the saved one
            mc("Which perspective collects data through direct contact and full immersion"),              // repeats the first
            mc("What does the term gene mean in this chapter?", "The notes do not define this term."),     // refusal
            mc("Name the unreliable perspective that the field uses most often in practice?"),             // second pass disagrees
        ]
        generator.written = [
            GeneratedTestQuestion(prompt: "Which of the following describes an adaptation?", correctAnswer: "A feature shaped by selection."), // no options
        ]
        let outcome = await run(lib, generator)
        #expect(outcome.saved == 1)
        let reasons = Dictionary(grouping: outcome.drops, by: \.reason).mapValues(\.count)
        #expect(reasons[.repeated] == 2)
        #expect(reasons[.unclear] == 2)
        #expect(reasons[.failedCheck] == 1)
        #expect(outcome.droppedSummary == "5 dropped: 2 repeats, 2 unclear, 1 failed a check")
        #expect(outcome.drops.allSatisfy { !$0.detail.isEmpty && !$0.text.isEmpty })
        // Dropped ones are not stored, in any state.
        #expect(try await lib.db.queue.read { try TestQuestion.fetchCount($0) } == 2)
    }

    @Test("the summary reads right for one drop and for none")
    func summaryWording() {
        var outcome = DraftOutcome()
        #expect(outcome.droppedSummary == nil)
        outcome.drops = [DraftDrop(text: "q", reason: .repeated, detail: "x")]
        #expect(outcome.droppedSummary == "1 dropped: 1 repeat")
    }

    @Test("an unreachable model writes nothing and says so; no notes says so too")
    func failures() async throws {
        let lib = try makeLibrary()
        let off = DraftGenerator(); off.available = false
        #expect(await run(lib, off).modelUnreachable)
        let empty = try GRASPDatabase.inMemory()
        let course = try await empty.queue.write { db -> Deck in
            let c = Course(semesterId: nil, name: "C"); try c.insert(db)
            let d = Deck(courseId: c.id, name: "D"); try d.insert(db); return d
        }
        let outcome = await QuestionDrafter.generate(QuestionDrafter.Request(deckIds: [course.id]), using: DraftGenerator(),
                                                     executor: nil, database: empty)
        #expect(outcome.noNotes)
    }

    @Test("code and math need the Mac's tools: with none, only a code request cannot run")
    func needsTools() async throws {
        let lib = try makeLibrary()
        let outcome = await QuestionDrafter.generate(
            QuestionDrafter.Request(deckIds: [lib.deckId], multipleChoice: false, written: false, codeKinds: [.predictOutput]),
            using: DraftGenerator(), executor: nil, database: lib.db)
        #expect(outcome.cannotRun && outcome.saved == 0)
    }

    @Test("a stopped run keeps nothing it hadn't finished and says it stopped")
    func cancelled() async throws {
        let lib = try makeLibrary()
        let generator = DraftGenerator()
        generator.problems = [mc("Which perspective collects data through direct contact and full immersion?")]
        generator.holdsUntilCancelled = true
        let task = Task { await run(lib, generator) }
        for await _ in generator.started { break }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.wasCancelled)
        // Nothing that came back after the stop was kept.
        #expect(outcome.saved == 0)
    }

    // MARK: Review

    @Test("drafts never upload; approving one makes it sync-eligible")
    func draftsStayLocalUntilApproved() async throws {
        let lib = try makeLibrary()
        let engine = SyncEngine(database: lib.db)
        try engine.enable(accountUserId: "u", uploadExisting: false)
        let generator = DraftGenerator()
        generator.problems = [mc("Which perspective collects data through direct contact and full immersion?")]
        _ = await run(lib, generator, written: false)
        func queued() async throws -> Int {
            try await lib.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncOutbox WHERE tableName = 'testQuestion'") ?? 0 }
        }
        #expect(try await queued() == 0)
        let draft = try #require(try await lib.db.queue.read { try QuestionBank.drafts(inDecks: [lib.deckId], db: $0) }.first)
        // Editing and soft deleting a draft leave no trace either.
        try await lib.db.queue.write { try CodeQuestionBank.delete(draft.id, db: $0) }
        #expect(try await queued() == 0)
        let again = DraftGenerator()
        again.problems = [mc("What does participant observation mean in fieldwork?")]
        _ = await run(lib, again, written: false)
        let second = try #require(try await lib.db.queue.read { try QuestionBank.drafts(inDecks: [lib.deckId], db: $0) }.first)
        #expect(try await lib.db.queue.write { try QuestionBank.approve(second.id, db: $0) } == nil)
        #expect(try await queued() == 1)
        #expect(try await lib.db.queue.read { try QuestionBank.activeCount(inDecks: [lib.deckId], db: $0) } == 1)
    }

    @Test("Approve all skips a draft that fails a check, and nothing approves it")
    func approveAllSkipsFailures() async throws {
        let lib = try makeLibrary()
        let ids = try await lib.db.queue.write { db -> [String] in
            func draft(_ problem: ProblemQuestion) throws -> String {
                let record = TestQuestion(courseId: lib.courseId, deckId: lib.deckId, materialId: lib.materialId, problem: problem,
                                          bodyJSON: problem.encoded() ?? "{}", verifiedBy: "test", source: .ai, status: .draft)
                try record.insert(db); return record.id
            }
            return [
                try draft(ProblemQuestion(kind: .multipleChoice, subject: .concepts, prompt: "Which perspective is based on direct contact with people?",
                                          choices: ["Field-based", "Holistic"], correct: 0)),
                // Edited into something that fails: an empty choice.
                try draft(ProblemQuestion(kind: .multipleChoice, subject: .concepts, prompt: "Which perspective integrates everything known about humans?",
                                          choices: ["Holistic", " "], correct: 0)),
                // A written answer that says the notes don't cover it.
                try draft(ProblemQuestion(kind: .written, subject: .concepts, prompt: "What does the term gene mean here?",
                                          answer: "The notes do not define this term.")),
            ]
        }
        let result = try await lib.db.queue.write { try QuestionBank.approveAll(inDecks: [lib.deckId], db: $0) }
        #expect(result.approved == 1 && result.skipped.count == 2)
        #expect(Set(result.skipped.map(\.id)) == Set(ids.dropFirst()))
        #expect(result.skipped.allSatisfy { !$0.reason.isEmpty })
        let statuses = try await lib.db.queue.read { db in try ids.map { try TestQuestion.fetchOne(db, key: $0)?.status } }
        #expect(statuses == ["active", "draft", "draft"])
        // Approving one by itself is refused the same way.
        let why = try await lib.db.queue.write { try QuestionBank.approve(ids[1], db: $0) }
        #expect(why != nil)
        #expect(try await lib.db.queue.read { try TestQuestion.fetchOne($0, key: ids[1])?.status } == "draft")
    }

    @Test("a row's own Approve refuses a failing draft with the same reason, keeps it, and works once it is edited")
    func rowApproveRefusesThenAcceptsAfterEdit() async throws {
        let lib = try makeLibrary()
        let problem = ProblemQuestion(kind: .written, subject: .concepts, prompt: "What is DNA?", answer: "The molecule that carries genes.")
        let record = TestQuestion(courseId: lib.courseId, deckId: lib.deckId, materialId: lib.materialId, problem: problem,
                                  bodyJSON: problem.encoded() ?? "{}", verifiedBy: "test", source: .ai, status: .draft)
        try await lib.db.queue.write { try record.insert($0) }
        let why = try await lib.db.queue.write { try QuestionBank.approve(record.id, db: $0) }
        #expect(why == "It is too short to be a clear question.")
        #expect(try await lib.db.queue.read { try TestQuestion.fetchOne($0, key: record.id)?.status } == "draft")
        // Editing keeps it a draft; once it passes, Approve works.
        let edited = UserQuestionInput(kind: .written, prompt: "What is DNA and what does it carry?",
                                       answer: "The molecule that carries genes.")
        try await lib.db.queue.write { try QuestionBank.update(record.id, with: edited, db: $0) }
        #expect(try await lib.db.queue.read { try TestQuestion.fetchOne($0, key: record.id)?.status } == "draft")
        #expect(try await lib.db.queue.write { try QuestionBank.approve(record.id, db: $0) } == nil)
        #expect(try await lib.db.queue.read { try TestQuestion.fetchOne($0, key: record.id)?.status } == "active")
    }

    @Test("a draft is never asked in a test until it is approved")
    func draftsAreNotAsked() async throws {
        let lib = try makeLibrary()
        let generator = DraftGenerator()
        generator.problems = [mc("Which perspective collects data through direct contact and full immersion?")]
        _ = await run(lib, generator, written: false)
        let picked = try await lib.db.queue.read { db -> Int in
            var rng = SystemRandomNumberGenerator()
            return try CodeQuestionBank.pickRound(count: 5, inDecks: [lib.deckId], allowWritten: true, allowMultipleChoice: true,
                                                  using: &rng, db: db).count
        }
        #expect(picked == 0)
    }

    // MARK: Cards, schedules, triage

    @Test("writing and approving drafts moves no card schedule and adds no card draft")
    func cardsUntouched() async throws {
        let lib = try makeLibrary()
        let before = try await lib.db.queue.read { try Card.fetchOne($0, key: lib.cardId) }
        let reviewsBefore = try await lib.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review") ?? 0 }
        let generator = DraftGenerator()
        generator.problems = [mc("Which perspective collects data through direct contact and full immersion?")]
        generator.written = [GeneratedTestQuestion(prompt: "How does ethnography differ from ethnology?", correctAnswer: "Ethnography describes one society.")]
        _ = await run(lib, generator)
        _ = try await lib.db.queue.write { try QuestionBank.approveAll(inDecks: [lib.deckId], db: $0) }
        let after = try await lib.db.queue.read { try Card.fetchOne($0, key: lib.cardId) }
        #expect(before?.due == after?.due && before?.stability == after?.stability && before?.reps == after?.reps
                && before?.updatedAt == after?.updatedAt)
        #expect(try await lib.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review") ?? 0 } == reviewsBefore)
        #expect(try await lib.db.queue.read { try LearnState.fetchCount($0) } == 0)
        // Card drafts are counted from cards alone: question drafts are not among them.
        #expect(try await lib.db.queue.read { try Card.filter(Column("status") == CardStatus.draft.rawValue).fetchCount($0) } == 0)
    }

    // MARK: Test availability

    @Test("Test is available with cards or saved questions, and says why when it is not")
    func testAvailability() {
        #expect(Study.testAvailability(activeCards: 3, activeQuestions: 0) == .cardsOnly)
        #expect(Study.testAvailability(activeCards: 3, activeQuestions: 2) == .cardsAndQuestions)
        #expect(Study.testAvailability(activeCards: 0, activeQuestions: 2) == .questionsOnly)
        let none = Study.testAvailability(activeCards: 0, activeQuestions: 0)
        #expect(!none.isAvailable)
        if case .unavailable(let why) = none { #expect(why == "Add cards or write questions to take a test.") }
        if case .unavailable(let why) = Study.testAvailability(activeCards: 0, activeQuestions: 0, draftCards: 4) {
            #expect(why == "Approve some cards, or write questions, to take a test.")
        }
    }

    @Test("a deck with only saved questions starts a questions-only test")
    func questionsOnlyStarts() async throws {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { db -> String in
            let course = Course(semesterId: nil, name: "C"); try course.insert(db)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(db)
            try QuestionBank.create(UserQuestionInput(kind: .trueFalse, prompt: "Ethnology compares several societies.", isTrue: true), deckId: deck.id, db: db)
            return deck.id
        }
        let started = try await db.queue.write { db -> (attemptId: String, questions: [LearnEngine.RoundQuestion]) in
            var rng = SystemRandomNumberGenerator()
            let saved = try CodeQuestionBank.pickRound(count: 5, inDecks: [deckId], allowWritten: false, allowMultipleChoice: false,
                                                       allowTrueFalse: true, using: &rng, db: db)
            return try Study.startTest(deckIds: [deckId], config: TestBuilder.Config(questionCount: 5, includeFlashcards: false),
                                       aiQuestions: saved, using: &rng, db: db)
        }
        #expect(started.questions.count == 1 && started.questions[0].bankQuestionId != nil)
    }
}
