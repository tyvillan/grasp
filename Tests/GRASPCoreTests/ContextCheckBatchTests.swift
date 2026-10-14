import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Context check: batch parser")
struct ContextCheckBatchParserTests {
    @Test("a complete, valid reply gives one verdict per number")
    func complete() {
        let raw = """
        {"results": [{"id": "1", "verdict": "valid"},
                     {"id": "2", "verdict": "refine", "refinedBack": "A better definition."},
                     {"id": 3, "verdict": "reject"}]}
        """
        let out = OllamaGenerator.parseContextBatch(raw, count: 3)
        #expect(out[1] == ContextValidation(.valid))
        #expect(out[2] == ContextValidation(.refine(newBack: "A better definition.")))
        #expect(out[3] == ContextValidation(.reject))
    }

    @Test("a card the reply leaves out is missing, the others stand")
    func missingCard() {
        let out = OllamaGenerator.parseContextBatch(
            #"{"results": [{"id": "1", "verdict": "valid"}, {"id": "3", "verdict": "valid"}]}"#, count: 3)
        #expect(Set(out.keys) == [1, 3])
    }

    @Test("an id that was never sent makes the whole reply untrusted")
    func extraId() {
        let out = OllamaGenerator.parseContextBatch(
            #"{"results": [{"id": "1", "verdict": "valid"}, {"id": "7", "verdict": "reject"}]}"#, count: 3)
        #expect(out.isEmpty)
    }

    @Test("the same id twice makes the whole reply untrusted")
    func duplicateId() {
        let out = OllamaGenerator.parseContextBatch(
            #"{"results": [{"id": "1", "verdict": "valid"}, {"id": "1", "verdict": "reject"}]}"#, count: 3)
        #expect(out.isEmpty)
    }

    @Test("an unknown verdict, or a refine with no text, leaves that card missing")
    func badVerdicts() {
        let raw = """
        {"results": [{"id": "1", "verdict": "maybe"},
                     {"id": "2", "verdict": "refine"},
                     {"id": "3", "verdict": "refine", "refinedBack": "  "},
                     {"id": "4", "verdict": "valid"}]}
        """
        let out = OllamaGenerator.parseContextBatch(raw, count: 4)
        #expect(Set(out.keys) == [4])
    }

    @Test("garbage and a bare object are unusable")
    func garbage() {
        #expect(OllamaGenerator.parseContextBatch("I cannot help with that.", count: 3).isEmpty)
        #expect(OllamaGenerator.parseContextBatch(#"{"verdict": "valid"}"#, count: 3).isEmpty)
    }

    @Test("the prompt sends the note once however many cards there are")
    func noteOnce() {
        let items = (1...5).map { ContextCheckItem(id: "c\($0)", front: "Term \($0)", back: "Back \($0)") }
        let prompt = OllamaGenerator.validateContextBatchPrompt(
            items: items, noteContext: "UNIQUE-NOTE-MARKER the note text", courseName: "OS")
        #expect(prompt.components(separatedBy: "UNIQUE-NOTE-MARKER").count == 2)
        for n in 1...5 { #expect(prompt.contains("\(n). Term: Term \(n)")) }
    }
}

@Suite("Context check: batching, fallback and order")
struct ContextCheckBatchingTests {
    private final class Gen: CardGenerator, @unchecked Sendable {
        let lock = NSLock()
        var batchCalls = 0
        var singleCalls: [String] = []
        var batchSizes: [Int] = []
        /// What a batch reply contains: front -> verdict (absent = left out).
        var batchAnswers: [String: ContextValidation] = [:]
        var singleAnswers: [String: ContextValidation] = [:]
        var size = 5
        var width = 1
        var inFlight = 0
        var peak = 0
        var delay: UInt64 = 0

        var isAvailable: Bool { get async { true } }
        var overviewContextWordBudget: Int { 1_800 }
        var contextCheckBatchSize: Int { size }
        var maxConcurrentCalls: Int { width }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                              includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                             sectionHeadings: [String]) async -> [GeneratedFigure] { [] }

        func noteSingle(_ f: String) { lock.lock(); singleCalls.append(f); lock.unlock() }
        func noteBatch(_ n: Int) { lock.lock(); batchCalls += 1; batchSizes.append(n); lock.unlock() }
        func enter() { lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock() }
        func leave() { lock.lock(); inFlight -= 1; lock.unlock() }

        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
            enter(); defer { leave() }
            noteSingle(front)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return singleAnswers[front] ?? ContextValidation(.valid)
        }

        func validateContextBatch(items: [ContextCheckItem], noteContext: String, courseName: String) async -> [String: ContextValidation] {
            enter(); defer { leave() }
            noteBatch(items.count)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            var out: [String: ContextValidation] = [:]
            for item in items { if let v = batchAnswers[item.front] { out[item.id] = v } }
            return out
        }
    }

    private func makeLibrary(_ count: Int) async throws -> (GRASPDatabase, [Card]) {
        let db = try GRASPDatabase.inMemory()
        let cards = try await db.queue.write { conn -> [Card] in
            let course = Course(semesterId: nil, name: "OS"); try course.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/v/os.md", kind: .markdown, contentHash: "h", title: "OS")
            try material.insert(conn)
            try NoteText(materialId: material.id, raw: "A note about processes.", reflowed: "A note about processes.",
                         wordCount: 4, hasMath: false).insert(conn)
            return try (0..<count).map { i in
                let card = Card(materialId: material.id, front: "T\(i)", back: "B\(i)", origin: .parser, status: .draft)
                try card.insert(conn)
                return card
            }
        }
        return (db, cards)
    }

    @Test("five cards are one call, not five")
    func oneCallForFive() async throws {
        let (db, cards) = try await makeLibrary(5)
        let g = Gen()
        for c in cards { g.batchAnswers[c.front] = ContextValidation(.valid) }
        _ = await CardAI.verifyContext(of: cards, using: g, database: db)
        #expect(g.batchCalls == 1)
        #expect(g.singleCalls.isEmpty)
    }

    @Test("twelve cards go in batches of 5, 5 and 2")
    func batchSizes() async throws {
        let (db, cards) = try await makeLibrary(12)
        let g = Gen()
        for c in cards { g.batchAnswers[c.front] = ContextValidation(.valid) }
        _ = await CardAI.verifyContext(of: cards, using: g, database: db)
        #expect(g.batchSizes == [5, 5, 2])
        #expect(g.singleCalls.isEmpty)
    }

    @Test("cards a batch reply left out are asked one by one, and only those")
    func fallsBackPerMissingCard() async throws {
        let (db, cards) = try await makeLibrary(5)
        let g = Gen()
        for c in cards where c.front != "T1" && c.front != "T3" { g.batchAnswers[c.front] = ContextValidation(.valid) }
        g.singleAnswers["T3"] = ContextValidation(.reject)
        let summary = await CardAI.verifyContext(of: cards, using: g, database: db)
        #expect(g.batchCalls == 1)
        #expect(Set(g.singleCalls) == ["T1", "T3"])
        #expect(summary.removed.map(\.front) == ["T3"])
    }

    @Test("an unusable batch reply sends every card to its own call")
    func wholeBatchUnusable() async throws {
        let (db, cards) = try await makeLibrary(3)
        let g = Gen()
        _ = await CardAI.verifyContext(of: cards, using: g, database: db)
        #expect(g.batchCalls == 1)
        #expect(Set(g.singleCalls) == ["T0", "T1", "T2"])
    }

    @Test("a generator that does not batch is asked one card per call, as before")
    func sizeOne() async throws {
        let (db, cards) = try await makeLibrary(4)
        let g = Gen()
        g.size = 1
        _ = await CardAI.verifyContext(of: cards, using: g, database: db)
        #expect(g.batchCalls == 0)
        #expect(g.singleCalls.count == 4)
    }

    @Test("a batch's verdicts land on the right cards")
    func verdictsApplied() async throws {
        let (db, cards) = try await makeLibrary(5)
        let g = Gen()
        for c in cards { g.batchAnswers[c.front] = ContextValidation(.valid) }
        g.batchAnswers["T1"] = ContextValidation(.refine(newBack: "Better one."))
        g.batchAnswers["T4"] = ContextValidation(.reject)
        let summary = await CardAI.verifyContext(of: cards, using: g, database: db)
        #expect(summary.refined.map(\.front) == ["T1"])
        #expect(summary.removed.map(\.front) == ["T4"])
        let after = try await db.queue.read { try Card.fetchAll($0) }
        #expect(after.first { $0.front == "T1" }?.back == "Better one.")
        #expect(after.first { $0.front == "T4" }?.deletedAt != nil)
        #expect(after.first { $0.front == "T0" }?.back == "B0")
    }

    @Test("with a concurrency of 3 at most 3 batches run at once, and all of them run")
    func concurrencyLimit() async throws {
        let (db, cards) = try await makeLibrary(40)
        let g = Gen()
        g.width = 3
        g.delay = 60_000_000
        for c in cards { g.batchAnswers[c.front] = ContextValidation(.valid) }
        _ = await CardAI.verifyContext(of: cards, using: g, database: db)
        #expect(g.peak == 3)
        #expect(g.batchCalls == 8)
    }
}

@Suite("AI concurrency helper")
struct AIConcurrencyTests {
    @Test("results come back in the order given even when later items finish first")
    func ordered() async {
        let out = await AIConcurrency.map(Array(0..<8), limit: 4) { n -> Int in
            try? await Task.sleep(nanoseconds: UInt64(8 - n) * 15_000_000)
            return n * 10
        }
        #expect(out == (0..<8).map { Optional($0 * 10) })
    }

    @Test("never more than the limit in flight")
    func limit() async {
        let counter = Counter()
        _ = await AIConcurrency.map(Array(0..<12), limit: 4) { _ -> Int in
            await counter.enter()
            try? await Task.sleep(nanoseconds: 30_000_000)
            await counter.leave()
            return 0
        }
        #expect(await counter.peak == 4)
    }

    @Test("a limit of 1 is strictly sequential")
    func sequential() async {
        let counter = Counter()
        _ = await AIConcurrency.map(Array(0..<5), limit: 1) { _ -> Int in
            await counter.enter()
            try? await Task.sleep(nanoseconds: 10_000_000)
            await counter.leave()
            return 0
        }
        #expect(await counter.peak == 1)
    }
}

private actor Counter {
    var current = 0
    var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
