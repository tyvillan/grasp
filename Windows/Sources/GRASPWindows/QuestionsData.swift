import Foundation
import GRASPCore
import GRDB

/// A deck's saved questions as the Questions tab draws them: each with its
/// recent history, its understanding meter and, for a draft, the title of
/// the note it was written from.
struct QuestionListing {
    var questions: [TestQuestion] = []
    var history: [String: QuestionHistory] = [:]
    var states: [String: UnderstandingState] = [:]
    var noteTitles: [String: String] = [:]
}

/// What the last "Generate test questions with AI" run did.
struct QuestionDraftRun: Equatable {
    let id = UUID()
    let deckIds: [String]
    let outcome: DraftOutcome
    /// Why nothing was written, in plain words, or nil.
    let failure: String?
}

/// The Questions tab's reads and writes, after the Mac's `QuestionStore` and
/// `QuestionDraftStore`. Saved questions belong to a deck like cards, and
/// sync once active; a draft stays on this device (the core's sync skips it).
extension Library {
    func questionListing(inDecks deckIds: [String]) -> QuestionListing {
        questionCache.value(revision: revision, key: "list:" + deckIds.joined(separator: ",")) {
            (try? database.queue.read { db -> QuestionListing in
                let questions = try QuestionBank.listing(inDecks: deckIds, db: db)
                let materials = Array(Set(questions.filter { $0.statusKind == .draft }.compactMap(\.materialId)))
                return QuestionListing(
                    questions: questions,
                    history: try QuestionBank.history(of: questions.map(\.id), db: db),
                    states: try QuestionUnderstanding.states(of: questions, db: db),
                    noteTitles: materials.isEmpty ? [:] : try Study.noteTitles(forMaterials: materials, db: db)
                )
            }) ?? QuestionListing()
        }
    }

    /// Active and draft question counts, for the tab label and Test. Two
    /// counting queries, cached, so the deck page never builds the listing.
    func questionCounts(inDecks deckIds: [String]) -> (active: Int, drafts: Int) {
        let key = deckIds.joined(separator: ",")
        let active = questionCountCache.value(revision: revision, key: "a:" + key) {
            (try? database.queue.read { try QuestionBank.activeCount(inDecks: deckIds, db: $0) }) ?? 0
        }
        let drafts = questionCountCache.value(revision: revision, key: "d:" + key) {
            (try? database.queue.read { try QuestionBank.draftCount(inDecks: deckIds, db: $0) }) ?? 0
        }
        return (active, drafts)
    }

    private func questionChange<T>(_ body: (Database) throws -> T) throws -> T {
        let result = try database.queue.write { try body($0) }
        reload()
        account?.noteLocalChange()
        return result
    }

    func saveQuestion(_ input: UserQuestionInput, deckId: String) throws {
        try questionChange { _ = try QuestionBank.create(input, deckId: deckId, db: $0) }
    }

    func updateQuestion(_ id: String, with input: UserQuestionInput) throws {
        try questionChange { try QuestionBank.update(id, with: input, db: $0) }
    }

    func setQuestionStatus(_ ids: [String], to status: QuestionStatus) {
        try? questionChange { try QuestionBank.setStatus(ids, to: status, db: $0) }
    }

    /// Nil when the deck is gone.
    func moveQuestions(_ ids: [String], toDeck deckId: String) -> QuestionBank.MoveResult? {
        try? questionChange { try QuestionBank.move(ids, toDeck: deckId, db: $0) }
    }

    /// Nil when the deck is gone.
    func copyQuestions(_ ids: [String], toDeck deckId: String) -> QuestionBank.MoveResult? {
        try? questionChange { try QuestionBank.copy(ids, toDeck: deckId, db: $0) }
    }

    /// Soft delete: past test results are kept.
    func deleteQuestions(_ ids: [String]) {
        try? questionChange { db in for id in ids { try CodeQuestionBank.delete(id, db: db) } }
    }

    /// Approves one draft; returns why it was not approved, or nil.
    func approveQuestion(_ id: String) -> String? {
        do { return try questionChange { try QuestionBank.approve(id, db: $0) } } catch { return "It couldn't be saved." }
    }

    func approveAllQuestions(inDecks deckIds: [String]) -> QuestionBank.ApproveAllResult {
        (try? questionChange { try QuestionBank.approveAll(inDecks: deckIds, db: $0) }) ?? QuestionBank.ApproveAllResult()
    }

    /// Active cards of these decks, for linking a question to one.
    func linkableCards(inDecks deckIds: [String]) -> [Card] {
        cards(inDecks: deckIds).filter { $0.status == .active }
    }

    func draftNotes(inDecks deckIds: [String]) -> [DraftNote] {
        (try? database.queue.read { try QuestionDrafter.notes(inDecks: deckIds, db: $0) }) ?? []
    }

    /// "Generate test questions with AI": writes drafts in the background on
    /// the course's job strip, with Stop (drafts already written are kept).
    /// Windows has no compiler sandbox, so code and math kinds are never
    /// asked for (the sheet says so) and there is no executor.
    func draftQuestions(_ request: QuestionDrafter.Request, courseId: String?) {
        lastQuestionDraftRun = nil
        let deckIds = request.deckIds
        #if DEBUG
        let stub: (any CardGenerator)? = StubHooks.enabled("GRASP_STUB_QUESTIONS") ? StubQuestionGenerator() : nil
        #else
        let stub: (any CardGenerator)? = nil
        #endif
        startCardJob("Writing test questions from your notes\u{2026}", courseId: courseId, generator: stub) { [weak self] generator, database in
            let outcome = await QuestionDrafter.generate(request, using: generator, executor: nil, database: database)
            var failure: String?
            if outcome.modelUnreachable {
                failure = "No AI model is reachable right now. Settings has the setup."
            } else if outcome.noNotes {
                failure = "These decks have no notes to write questions from."
            } else if outcome.cannotRun {
                failure = "Code and math questions are written on the Mac, which checks them by running them."
            } else if outcome.saved == 0, !outcome.wasCancelled {
                failure = outcome.drops.isEmpty
                    ? "The model didn't write anything usable from these notes."
                    : "None of the questions the model wrote were kept."
            }
            await MainActor.run {
                self?.lastQuestionDraftRun = QuestionDraftRun(deckIds: deckIds, outcome: outcome, failure: failure)
                // The Questions tab's banner says what the run did, so the
                // job strip goes rather than repeat it.
                self?.dismissCardJob(forCourse: courseId)
            }
            if let failure { return failure }
            return "Wrote \(outcome.saved) draft question\(outcome.saved == 1 ? "" : "s"). They're under To review on the Questions tab."
        }
    }

    /// How many questions a test with these settings can really ask.
    func matchingTestQuestionCount(deckIds: [String], config: TestBuilder.Config, includeQuestions: Bool) -> Int {
        (try? database.queue.read {
            try Study.matchingTestQuestionCount(deckIds: deckIds, config: config, includeQuestions: includeQuestions, db: $0)
        }) ?? 0
    }

    /// The saved questions a test takes, as the Mac's `startTest` picks them:
    /// about a third of the test with flashcards on, all of it without, and
    /// understood questions held back unless they are needed.
    func savedQuestionsForTest(inDecks deckIds: [String], config: TestBuilder.Config) -> [LearnEngine.RoundQuestion] {
        let share = Study.savedQuestionShare(for: config.questionCount, withFlashcards: config.includeFlashcards)
        guard share > 0 else { return [] }
        return (try? database.queue.read { db -> [LearnEngine.RoundQuestion] in
            var rng = SystemRandomNumberGenerator()
            let pool = try CodeQuestionBank.pickRound(count: .max, inDecks: deckIds, allowWritten: config.allowWritten,
                                                      allowMultipleChoice: config.allowMultipleChoice,
                                                      allowTrueFalse: config.allowTrueFalse, using: &rng, db: db)
            let keys = Set(pool.map(QuestionUnderstanding.key(of:)))
            let understood = Set(try QuestionUnderstanding.states(forKeys: keys, db: db).filter { $0.value.isMastered }.keys)
            return QuestionPicking.favorUnlearned(pool, count: share,
                                                  isUnderstood: { understood.contains(QuestionUnderstanding.key(of: $0)) },
                                                  using: &rng)
        }) ?? []
    }
}

/// The Mac's `QuestionPicking`: understood questions make it into a test one
/// time in four, and fill in only when the rest run short.
enum QuestionPicking {
    static let understoodChance = 0.25

    static func favorUnlearned<T, R: RandomNumberGenerator>(_ items: [T], count: Int, isUnderstood: (T) -> Bool,
                                                           using rng: inout R) -> [T] {
        var first: [T] = [], heldBack: [T] = []
        for item in items {
            if isUnderstood(item), Double.random(in: 0..<1, using: &rng) >= understoodChance {
                heldBack.append(item)
            } else {
                first.append(item)
            }
        }
        return Array((first.shuffled(using: &rng) + heldBack.shuffled(using: &rng)).prefix(count))
    }
}

/// Canned AI for screenshots and demos, as on the Mac: debug builds only, and
/// only with the launch flag `-GRASPAllowStubs 1` as well, so an installed
/// release build can never act on them.
enum StubHooks {
    static func enabled(_ name: String) -> Bool {
        #if DEBUG
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "-GRASPAllowStubs"), flag + 1 < args.count, args[flag + 1] == "1" else {
            return false
        }
        return ProcessInfo.processInfo.environment[name] == "1"
        #else
        return false
        #endif
    }
}

#if DEBUG
/// The Mac's `StubQuestionGenerator`: a canned question writer, so a
/// screenshot run never calls a model (`GRASP_STUB_QUESTIONS=1` with
/// `-GRASPAllowStubs 1`). Good questions, one repeat, one the notes don't
/// define, one with no real options and one whose second opinion disagrees,
/// so every kind of dropped item shows up.
struct StubQuestionGenerator: CardGenerator {
    var isAvailable: Bool { get async { true } }

    func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        candidates.map { GeneratedCard(front: $0.front, back: $0.back) }
    }

    func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }

    func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }

    func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
        ContextValidation(.valid)
    }

    func generateOverview(noteTitle: String, courseName: String, noteContext: String, includeFormulas: Bool,
                          partLabel: String?) async -> GeneratedOverview { .empty }

    func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                         sectionHeadings: [String]) async -> [GeneratedFigure] { [] }

    private func isEvolution(_ context: String) -> Bool { context.lowercased().contains("evolution") }

    func generateProblems(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        subject: ProblemSubject, kinds: [ProblemKind], count: Int
    ) async -> [GeneratedProblem] {
        if let text = ProcessInfo.processInfo.environment["GRASP_STUB_DELAY"], let seconds = Double(text), seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        guard kinds.contains(.multipleChoice) else { return [] }
        if isEvolution(noteContext) {
            return [
                GeneratedProblem(kind: .multipleChoice, prompt: "Which idea says that traits gained during a lifetime are passed to offspring?",
                                 choices: ["Natural selection", "Inheritance of acquired characteristics", "Uniformitarianism", "Catastrophism"], correct: 1,
                                 explanation: "That is Lamarck's inheritance of acquired characteristics. Darwin's mechanism works on variation, not on traits gained in life."),
                GeneratedProblem(kind: .multipleChoice, prompt: "What does fitness measure in evolutionary theory?",
                                 choices: ["Strength", "Reproductive success", "Intelligence", "Size"], correct: 1,
                                 explanation: "Fitness is an individual's reproductive success, the number of surviving offspring."),
                GeneratedProblem(kind: .multipleChoice, prompt: "What does the term gene mean in this chapter?",
                                 choices: ["It is not defined in the notes", "A unit of heredity", "A protein", "A trait"], correct: 0),
                GeneratedProblem(kind: .multipleChoice, prompt: "Which of the following describes heterozygous organisms in the notes?",
                                 choices: ["Same alleles from each parent", "Different alleles from each parent", "Two copies of a dominant trait", "No alleles"], correct: 0),
            ]
        }
        return [
            GeneratedProblem(kind: .multipleChoice, prompt: "Which perspective is based on collecting data through direct contact and full immersion?",
                             choices: ["Field-based", "Holistic", "Comparative", "Evolutionary"], correct: 0,
                             explanation: "Field-based work means being there."),
            GeneratedProblem(kind: .multipleChoice, prompt: "Which subfield examines human and primate evolution through fossils?",
                             choices: ["Paleoanthropology", "Ethnology", "Sociolinguistics", "Medical anthropology"], correct: 0,
                             explanation: "Paleoanthropology reads evolution from fossilized remains."),
            GeneratedProblem(kind: .multipleChoice, prompt: "How do anthropologists define material culture?",
                             choices: ["Objects people make and give meaning to", "Money and trade", "Language", "Fossils"], correct: 0,
                             explanation: "Material culture is made or shaped by people and given meaning by cultural practice."),
        ]
    }

    func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] {
        if isEvolution(noteContext) {
            return [
                GeneratedTestQuestion(prompt: "In one sentence, why did Darwin treat variation as the starting condition of life?",
                                      correctAnswer: "Because individuals differ, and different variants leave different numbers of offspring.",
                                      explanation: "Variation gives selection something to act on."),
                GeneratedTestQuestion(prompt: "What did Mendel's pea experiments show about inheritance?",
                                      correctAnswer: "That inheritance is particulate rather than blending."),
                GeneratedTestQuestion(prompt: "Which of the following describes an adaptation?", correctAnswer: "A useful feature shaped by selection for its current function."),
            ]
        }
        return [
            GeneratedTestQuestion(prompt: "What is the difference between ethnography and ethnology?",
                                  correctAnswer: "Ethnography describes one society from fieldwork; ethnology compares societies.",
                                  explanation: "One describes, the other compares."),
            GeneratedTestQuestion(prompt: "What does an informant do in fieldwork?",
                                  correctAnswer: "Helps the anthropologist explain the society from the inside."),
        ]
    }

    /// The second opinion agrees with the key, except for one question, so
    /// one draft fails its check.
    func solveMultipleChoice(prompt: String, choices: [String]) async -> Int? {
        if prompt.contains("fitness") { return 0 }
        if prompt.contains("heterozygous") { return choices.firstIndex(of: "Different alleles from each parent") }
        return choices.firstIndex(of: choices.first { c in
            ["Field-based", "Paleoanthropology", "Objects people make and give meaning to",
             "Inheritance of acquired characteristics", "Reproductive success", "It is not defined in the notes"].contains(c)
        } ?? "")
    }
}
#endif
