import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Runs each AI feature end to end against one small fixed sample note and
/// prints a timing table. Skipped unless `GRASP_TIMING_HARNESS=1`.
///
/// - Uses an in-memory library and a made-up note. Never the real library.
/// - The cloud key comes only from `GRASP_TIMING_GEMINI_KEY` in the
///   environment. It is never read from the Keychain, printed or written.
/// - Local runs use the Ollama server at 127.0.0.1:11434 when it answers.
/// - The table is written to `GRASP_TIMING_OUT` (default /tmp/cloud-speed-timing.txt).
@Suite("AI feature timing harness")
struct AIFeatureTimingHarness {
    static let note = """
    # Processes and threads

    A process is a program in execution. It has its own address space, its own open files and at least one thread. \
    The operating system keeps a process control block for every process, holding its state, its registers and its \
    memory limits.

    A thread is a unit of execution inside a process. Threads of one process share the address space and the open \
    files, but each thread has its own stack and its own registers. Creating a thread is cheaper than creating a \
    process, and switching between threads of the same process is faster than switching between processes.

    ## Scheduling

    The scheduler picks which ready thread runs next. Round robin gives each thread a fixed time slice, called a \
    quantum, and puts it at the back of the queue when the slice ends. A short quantum makes the system feel \
    responsive but wastes time in context switches. A long quantum wastes less time but makes interactive programs \
    feel slow. Shortest job first minimises the average waiting time, but it needs to know how long each job will \
    run and it can starve long jobs.

    ## Synchronisation

    When two threads change shared data, the result can depend on the order in which they run. That is a race \
    condition. A mutex lets only one thread at a time enter a critical section. A semaphore is a counter that \
    threads wait on and signal. A deadlock happens when each of several threads holds a lock another one needs, so \
    none can continue. The four conditions for deadlock are mutual exclusion, hold and wait, no preemption and \
    circular wait. Breaking any one of them prevents deadlock.

    ## Memory

    Virtual memory gives each process its own address space, divided into fixed-size pages. The page table maps \
    pages to frames in physical memory. A page fault happens when a process touches a page that is not in memory, \
    and the operating system loads it from disk. Thrashing is what happens when processes spend more time handling \
    page faults than running.
    """

    struct Row {
        var feature: String
        var backend: String
        var runs: Int
        var calls: Double
        var total: Double
        var pacer: Double
        var request: Double
        var firstResult: Double
        var promptTokens: Double
        var outputTokens: Double
        var model: String
        var failed: Double = 0
        var failureKinds = ""
        var firstByte: Double = 0
        var connect: Double = 0
        var reused: String = "-"
    }

    private func makeDeck() async throws -> (GRASPDatabase, deckId: String, cards: [Card], note: NoteText) {
        let db = try GRASPDatabase.inMemory()
        let made = try await db.queue.write { conn -> (String, [Card], NoteText) in
            let course = Course(semesterId: nil, name: "Operating Systems")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Processes")
            try deck.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/v/os.md", kind: .markdown, contentHash: "h", title: "Processes and threads")
            try material.insert(conn)
            let text = Self.note
            let words = text.split { $0.isWhitespace }.count
            let noteText = NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: words, hasMath: false)
            try noteText.insert(conn)
            let pairs = [("Process", "A program in execution with its own address space."),
                         ("Thread", "A unit of execution inside a process that shares its address space."),
                         ("Quantum", "The fixed time slice round robin gives each thread."),
                         ("Race condition", "A result that depends on the order in which threads run."),
                         ("Deadlock", "Threads each holding a lock another needs, so none can continue."),
                         ("Page fault", "Touching a page that is not in memory.")]
            var cards: [Card] = []
            for (index, pair) in pairs.enumerated() {
                let card = Card(materialId: material.id, front: pair.0, back: pair.1, origin: .parser, status: .draft)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
                cards.append(card)
            }
            return (deck.id, cards, noteText)
        }
        return (db, made.0, made.1, made.2)
    }

    private func measure(_ feature: String, backend: String, model: String, runs: Int,
                         body: @escaping @Sendable (Int) async -> Void) async -> Row {
        var totals: [Double] = [], calls: [[AITiming.Call]] = []
        var firsts: [Double] = []
        for run in 0..<runs {
            _ = AITiming.drain()
            let started = Date()
            await AITiming.$feature.withValue(feature) { await body(run) }
            totals.append(Date().timeIntervalSince(started))
            let recorded = AITiming.drain()
            calls.append(recorded)
            firsts.append(recorded.first.map { $0.pacerWait + $0.request } ?? .nan)
        }
        let flat = calls.flatMap { $0 }
        let n = Double(max(runs, 1))
        func avg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        let good = flat.filter { $0.failure == nil }
        let bad = flat.filter { $0.failure != nil }
        let kinds = Dictionary(grouping: bad, by: { $0.failure ?? "" }).map { "\($0.key) x\($0.value.count)" }.sorted()
        let reuse = good.compactMap(\.reusedConnection)
        return Row(feature: feature, backend: backend, runs: runs, calls: Double(good.count) / n,
                   total: avg(totals), pacer: flat.map(\.pacerWait).reduce(0, +) / n,
                   request: flat.map(\.request).reduce(0, +) / n, firstResult: avg(firsts.filter { !$0.isNaN }),
                   promptTokens: avg(good.map { Double($0.promptChars) / 4 }),
                   outputTokens: avg(good.map { Double($0.outputChars) / 4 }), model: model,
                   failed: Double(bad.count) / n, failureKinds: kinds.joined(separator: ", "),
                   firstByte: avg(good.compactMap(\.firstByte)), connect: avg(good.compactMap(\.connect)),
                   reused: reuse.isEmpty ? "-" : "\(reuse.filter { $0 }.count)/\(reuse.count)")
    }

    @Test("time every feature on the sample note",
          .enabled(if: ProcessInfo.processInfo.environment["GRASP_TIMING_HARNESS"] == "1"))
    func table() async throws {
        let env = ProcessInfo.processInfo.environment
        var generators: [(String, String, any CardGenerator, Int)] = []
        if let key = env["GRASP_TIMING_GEMINI_KEY"], !key.isEmpty {
            let model = env["GRASP_TIMING_MODEL"] ?? CloudProvider.fallbackModel
            generators.append(("Cloud", model, CloudGenerator(apiKey: key, model: model), Int(env["GRASP_TIMING_RUNS"] ?? "3") ?? 3))
        }
        if env["GRASP_TIMING_LOCAL"] == "1" {
            let local = OllamaGenerator(model: env["GRASP_TIMING_LOCAL_MODEL"] ?? "qwen3.5:9b")
            if await local.isAvailable { generators.append(("Local", local.modelName, local, 1)) }
        }
        if let plan = env["GRASP_TIMING_PLAN"].flatMap(GeminiPlan.init(rawValue:)) { AIPreferences.geminiPlan = plan }
        var rows: [Row] = []
        var agreement = ""
        for (backend, model, generator, runs) in generators {
            let (db, deckId, cards, note) = try await makeDeck()
            let g = generator
            rows.append(await measure("Generate cards", backend: backend, model: model, runs: runs) { _ in
                _ = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], maxPerNote: 3, using: g, database: db)
            })
            rows.append(await measure("Refine pass (6 cards)", backend: backend, model: model, runs: runs) { _ in
                _ = await CardAI.refineWording(of: cards, using: g, database: db)
            })
            rows.append(await measure("Context check (4 cards)", backend: backend, model: model, runs: runs) { _ in
                _ = await CardAI.verifyContext(of: Array(cards.prefix(4)), using: g, database: db)
            })
            if backend == "Cloud" {
                // The same cards asked one per call and in batches of five:
                // do the verdict kinds (valid / refine / reject) agree?
                let items = cards.map { ContextCheckItem(id: $0.id, front: $0.front, back: $0.back) }
                var batched: [String: ContextValidation] = [:]
                for start in stride(from: 0, to: items.count, by: 5) {
                    let chunk = Array(items[start..<min(start + 5, items.count)])
                    batched.merge(await g.validateContextBatch(items: chunk, noteContext: Self.note, courseName: "Operating Systems")) { a, _ in a }
                }
                var single: [String: ContextValidation] = [:]
                for card in cards {
                    single[card.id] = await g.validateContext(front: card.front, back: card.back, noteContext: Self.note, courseName: "Operating Systems")
                }
                func kind(_ v: ContextValidation) -> String {
                    switch v.verdict { case .valid: return "valid"; case .refine: return "refine"; case .reject: return "reject" }
                }
                let answered = cards.filter { batched[$0.id] != nil }
                let same = answered.filter { kind(batched[$0.id]!) == kind(single[$0.id]!) }
                agreement = "batched answered \(answered.count)/\(cards.count) cards; verdict kind agrees on \(same.count)/\(answered.count)\n"
            }
            rows.append(await measure("Test questions (2)", backend: backend, model: model, runs: runs) { _ in
                _ = await CardAI.generateTestQuestions(inDecks: [deckId], maxCount: 2, using: g, database: db)
            })
            rows.append(await measure("Overview", backend: backend, model: model, runs: runs) { _ in
                _ = await OverviewComposer.compose(using: g, noteTitle: "Processes and threads", courseName: "Operating Systems", note: note)
            })
            rows.append(await measure("Explain a wrong answer", backend: backend, model: model, runs: runs) { _ in
                _ = await g.explainWrongAnswer(prompt: "What is a race condition?",
                                               correctAnswer: "A result that depends on the order in which threads run.",
                                               givenAnswer: "Two threads that run at the same speed.", context: Self.note)
            })
            rows.append(await measure("AI judge (one answer)", backend: backend, model: model, runs: runs) { _ in
                _ = await g.judgeAnswer(question: "What is a thread?", expected: "A unit of execution inside a process",
                                        given: "A part of a program that runs on its own inside a process")
            })
            rows.append(await measure("Study guide part", backend: backend, model: model, runs: runs) { _ in
                _ = await g.generateStudyGuidePart(deckName: "Processes", courseName: "Operating Systems",
                                                   noteContext: Self.note, cardTerms: cards.map(\.front), problemCount: 3)
            })
        }
        var out = "feature | backend | runs | ok calls | failed calls | total s | pacer wait s | request s | first byte s | connect s | reused | first result s | prompt tok | output tok | model | failures\n"
        for r in rows {
            out += String(format: "%@ | %@ | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %.2f | %.2f | %@ | %.1f | %.0f | %.0f | %@ | %@\n",
                          r.feature, r.backend, r.runs, r.calls, r.failed, r.total, r.pacer, r.request, r.firstByte,
                          r.connect, r.reused, r.firstResult, r.promptTokens, r.outputTokens, r.model,
                          r.failureKinds.isEmpty ? "-" : r.failureKinds)
        }
        out += agreement
        for event in AITiming.drainEvents() { out += "event: \(event)\n" }
        out += "plan: \(AIPreferences.geminiPlan.rawValue), pace \(CloudProvider.requestsPerMinute) per minute\n"
        try out.write(toFile: env["GRASP_TIMING_OUT"] ?? "/tmp/cloud-speed-timing.txt", atomically: true, encoding: .utf8)
        #expect(!rows.isEmpty)
    }
}
