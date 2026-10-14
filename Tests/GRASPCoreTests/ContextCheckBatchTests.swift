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

@Suite("Overview: one review over the whole lesson, parallel sections")
struct OverviewWholeReviewTests {
    @Test("a whole-lesson review reply is read per section and drops unknown section numbers")
    func parse() throws {
        let raw = """
        {"sections": [{"section": 2, "items": [{"original": "Threads share a stack.", "corrected": "Threads have their own stacks."}]},
                      {"section": 9, "items": [{"original": "x", "corrected": "y"}]},
                      {"section": 1, "items": []}]}
        """
        let out = try #require(OllamaGenerator.parseOverviewReview(raw, sectionCount: 3))
        #expect(out.count == 3)
        #expect(out[0].isEmpty && out[2].isEmpty)
        #expect(out[1].count == 1)
        #expect(out[1][0].original == "Threads share a stack.")
    }

    @Test("an unusable reply is nil so the composer reviews section by section")
    func unusable() {
        #expect(OllamaGenerator.parseOverviewReview("No problems found.", sectionCount: 3) == nil)
        #expect(OllamaGenerator.parseOverviewReview(#"{"items": []}"#, sectionCount: 3) == nil)
    }

    @Test("the prompt carries the note once and every section")
    func prompt() {
        let sections = (1...4).map { OverviewSection(heading: "Heading \($0)", paragraphs: ["Paragraph \($0)."]) }
        let p = OllamaGenerator.reviewOverviewPrompt(noteContext: "NOTE-MARKER body", sections: sections)
        #expect(p.components(separatedBy: "NOTE-MARKER").count == 2)
        for n in 1...4 { #expect(p.contains("Section \(n): Heading \(n)")) }
    }

    private final class Gen: CardGenerator, @unchecked Sendable {
        let lock = NSLock()
        var whole: Bool
        var wholeReply: [[OverviewFix]]?
        var sectionReviews = 0
        var wholeReviews = 0
        init(whole: Bool, wholeReply: [[OverviewFix]]? = nil) { self.whole = whole; self.wholeReply = wholeReply }
        var isAvailable: Bool { get async { true } }
        var overviewContextWordBudget: Int { 2_000 }
        var reviewsWholeOverview: Bool { whole }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation { ContextValidation(.valid) }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                              includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview {
            GeneratedOverview(document: OverviewDocument(title: "T", sections: (1...4).map {
                OverviewSection(heading: "Claim \($0)", paragraphs: ["Threads share a stack \($0)."])
            }))
        }
        func note(section: Bool) { lock.lock(); if section { sectionReviews += 1 } else { wholeReviews += 1 }; lock.unlock() }
        func reviewSection(noteContext: String, section: OverviewSection) async -> [OverviewFix] {
            note(section: true); return []
        }
        func reviewOverview(noteContext: String, sections: [OverviewSection]) async -> [[OverviewFix]]? {
            note(section: false); return wholeReply
        }
    }

    private func sampleNote() -> NoteText {
        let text = (0..<30).map { "Sentence number \($0) explains one idea about processes and threads in some detail." }
            .joined(separator: " ")
        return NoteText(materialId: "m", raw: text, reflowed: text, wordCount: text.split { $0.isWhitespace }.count, hasMath: false)
    }

    @Test("on the cloud, four sections are reviewed by one call, not four")
    func oneReviewCall() async {
        let g = Gen(whole: true, wholeReply: Array(repeating: [], count: 4))
        let outcome = await OverviewComposer.compose(using: g, noteTitle: "T", courseName: "OS", note: sampleNote())
        guard case .generated = outcome else { Issue.record("expected an overview"); return }
        #expect(g.wholeReviews == 1)
    }

    @Test("a generator that does not review the whole lesson is never asked to")
    func localNotAskedForWhole() async {
        let g = Gen(whole: false)
        _ = await OverviewComposer.compose(using: g, noteTitle: "T", courseName: "OS", note: sampleNote())
        #expect(g.wholeReviews == 0)
    }

    @Test("if the whole-lesson reply is unusable the overview still finishes")
    func unusableStillFinishes() async {
        let g = Gen(whole: true, wholeReply: nil)
        let outcome = await OverviewComposer.compose(using: g, noteTitle: "T", courseName: "OS", note: sampleNote())
        guard case .generated = outcome else { Issue.record("expected an overview"); return }
        #expect(g.wholeReviews == 1)
    }

    @Test("a correction from the whole-lesson review lands on its own section only")
    func fixLandsOnSection() async throws {
        var fixes = [[OverviewFix]](repeating: [], count: 4)
        fixes[2] = [OverviewFix(original: "Threads share a stack 3.", corrected: "Threads each have their own stack 3.")]
        let g = Gen(whole: true, wholeReply: fixes)
        let outcome = await OverviewComposer.compose(using: g, noteTitle: "T", courseName: "OS", note: sampleNote())
        guard case .generated(let result) = outcome else { Issue.record("expected an overview"); return }
        let texts = result.document.sections.map { $0.paragraphs.joined(separator: " ") }
        #expect(texts.contains { $0.contains("own stack 3") })
        #expect(texts.contains { $0.contains("share a stack 1") })
    }
}

@Suite("Overview: sections written in parallel keep the plan's order")
struct ParallelSectionsTests {
    /// Answers the plan, then each section after a delay that is longest
    /// for the first section, so completion order is the reverse of plan
    /// order.
    private final class Transport: ChatTransport, @unchecked Sendable {
        let lock = NSLock()
        var inFlight = 0
        var peak = 0
        func enter() { lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock() }
        func leave() { lock.lock(); inFlight -= 1; lock.unlock() }

        func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String {
            enter(); defer { leave() }
            for n in 1...6 where prompt.contains("HEADING-\(n)") && prompt.contains("covers-\(n)") && maxTokens == 1_800 {
                try await Task.sleep(nanoseconds: UInt64(7 - n) * 20_000_000)
                return #"{"paragraphs": ["Body of section \#(n)."]}"#
            }
            if maxTokens == 900 {
                let sections = (1...6).map { #"{"heading": "HEADING-\#($0)", "covers": "covers-\#($0)"}"# }.joined(separator: ",")
                return #"{"title": "Lesson", "sections": [\#(sections)]}"#
            }
            return "{}"
        }
    }

    @Test("six sections with a limit of 3: at most 3 at once, written in plan order")
    func orderAndLimit() async {
        let t = Transport()
        let g = OllamaGenerator(transport: t, model: "m", wordBudget: 2_000, concurrency: { 3 })
        let result = await g.generateOverview(noteTitle: "T", courseName: "C", noteContext: "A note about things.",
                                              includeFormulas: false, partLabel: nil)
        let headings = result.document.sections.map(\.heading)
        #expect(headings == (1...6).map { "HEADING-\($0)" })
        #expect(t.peak >= 2 && t.peak <= 3)
    }

    @Test("a limit of 1 stays one at a time")
    func sequential() async {
        let t = Transport()
        let g = OllamaGenerator(transport: t, model: "m", wordBudget: 2_000, concurrency: { 1 })
        _ = await g.generateOverview(noteTitle: "T", courseName: "C", noteContext: "A note about things.",
                                     includeFormulas: false, partLabel: nil)
        #expect(t.peak == 1)
    }
}

@Suite("Card generation across notes in parallel")
struct ParallelGenerationTests {
    private final class Gen: CardGenerator, @unchecked Sendable {
        let lock = NSLock()
        var width: Int
        var inFlight = 0
        var peak = 0
        init(width: Int) { self.width = width }
        var isAvailable: Bool { get async { true } }
        var overviewContextWordBudget: Int { 1_800 }
        var maxConcurrentCalls: Int { width }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation { ContextValidation(.valid) }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                              includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
        func begin() { lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock() }
        func end() { lock.lock(); inFlight -= 1; lock.unlock() }
        func generateAdditionalResult(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> AdditionalNoteResult {
            begin(); defer { end() }
            try? await Task.sleep(nanoseconds: 40_000_000)
            let names = ["note0": ("Quantum", "a discrete slice of processor time"), "note1": ("Mutex", "a lock one thread holds at a time"),
                         "note2": ("Semaphore", "a counter threads wait on and signal"), "note3": ("Deadlock", "threads each holding what another needs"),
                         "note4": ("Thrashing", "more time paging than running"), "note5": ("Frame", "a fixed block of physical memory")]
            let entry = names[noteContext] ?? ("Other", "something else")
            return .cards([GeneratedCard(front: entry.0, back: "It is \(entry.1).")])
        }
    }

    private func library() async throws -> (GRASPDatabase, String) {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "OS"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            for i in 0..<6 {
                let m = Material(courseId: course.id, relativePath: "/v/n\(i).md", kind: .markdown, contentHash: "h\(i)", title: "N\(i)")
                try m.insert(conn)
                try NoteText(materialId: m.id, raw: "note\(i)", reflowed: "note\(i)", wordCount: 1, hasMath: false).insert(conn)
                let c = Card(materialId: m.id, front: "Seed \(i)", back: "Seed answer \(i)", origin: .parser, status: .draft)
                try c.insert(conn)
                try DeckCard(deckId: deck.id, cardId: c.id, sortIndex: i).insert(conn)
            }
            return deck.id
        }
        return (db, deckId)
    }

    @Test("six notes with a limit of 3 are asked 3 at a time and every card lands once")
    func parallelNotes() async throws {
        let (db, deckId) = try await library()
        let g = Gen(width: 3)
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: g, database: db)
        #expect(outcome == .added(6))
        #expect(g.peak == 3)
        let cards = try await db.queue.read { try Card.fetchAll($0).filter { $0.origin == .aiGenerated } }
        #expect(Set(cards.map(\.front)).count == 6)
    }

    @Test("a limit of 1 asks one note at a time and adds the same cards")
    func sequentialNotes() async throws {
        let (db, deckId) = try await library()
        let g = Gen(width: 1)
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: g, database: db)
        #expect(outcome == .added(6))
        #expect(g.peak == 1)
    }
}
