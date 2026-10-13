import Foundation
import Testing
import GRDB
@testable import GRASPCore

/// A judge that says what the test tells it to, and counts how often it is asked.
private final class StubJudge: @unchecked Sendable {
    private let count = OSAllocatedCounter()
    let verdict: AIAnswerVerdict?
    let delay: Duration?
    init(_ verdict: AIAnswerVerdict?, delay: Duration? = nil) { self.verdict = verdict; self.delay = delay }
    var calls: Int { count.value }
    var judge: AnswerLadder.Judge {
        let count = count, verdict = verdict, delay = delay
        return { _, _, _ in
            count.increment()
            if let delay { try? await Task.sleep(for: delay) }
            return verdict
        }
    }
}

private final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

struct Pair: Sendable, CustomTestStringConvertible {
    var testDescription: String { "\(given) vs \(expected)" }
    var question: String = "What is it?"
    var expected: String
    var given: String
}

@Suite("Answer judging")
struct AnswerJudgeTests {
    // MARK: Tables the student can extend

    /// Answers that must be accepted (correct or close enough), with no AI.
    static let acceptedLocally: [Pair] = [
        Pair(expected: "enzymes speed up reactions", given: "enzyme speeds up reaction"),
        Pair(expected: "the mitochondria", given: "mitochondria"),
        Pair(expected: "An operating system", given: "operating system"),
        Pair(expected: "to make a copy", given: "to create a copy"),
        Pair(expected: "a large number of users", given: "a big number of users"),
        Pair(expected: "cache hit rate and miss rate", given: "miss rate and cache hit rate"),
        Pair(expected: "mitochondria", given: "mitocondria"),
        Pair(expected: "photosynthesis", given: "photosythesis"),
        Pair(expected: "the process by which plants convert light energy into chemical energy",
             given: "plants convert light energy into chemical energy"),
        Pair(expected: "a program to write code on", given: "program for writing code"),
        Pair(expected: "mitochondria", given: "the mitochondria is the powerhouse of the cell"),
    ]

    /// Answers that must be rejected, with no AI.
    static let rejectedLocally: [Pair] = [
        Pair(expected: "water boils at 100 degrees celsius", given: "water boils at 90 degrees celsius"),
        Pair(expected: "TCP uses a 3 way handshake", given: "TCP uses a 2 way handshake"),
        Pair(expected: "the value increases", given: "the value decreases"),
        Pair(expected: "the function returns a value", given: "the function does not return a value"),
        Pair(expected: "the function does not return a value", given: "the function returns a value"),
        Pair(expected: "mitochondria", given: "the French revolution began in 1789"),
        Pair(expected: "mitochondria", given: "nucleus"),
        Pair(expected: "Paris", given: "   "),
        Pair(question: "What is the capital of France?", expected: "Paris", given: "the capital of France"),
    ]

    @Test("the accepted table is accepted by the local step alone", arguments: acceptedLocally)
    func acceptedLocal(pair: Pair) async {
        let stub = StubJudge(nil)   // an unreachable judge: the local verdict stands
        let result = await AnswerLadder.judge(question: pair.question, expected: pair.expected, given: pair.given,
                                              judge: stub.judge)
        #expect(result.outcome.countsAsCorrect, "\(pair.given) should match \(pair.expected)")
    }

    @Test("the rejected table is rejected, and the AI is never asked about it", arguments: rejectedLocally)
    func rejectedLocal(pair: Pair) async {
        // Even a judge that says "correct" must not be able to rescue these:
        // they are decided before the AI is asked.
        let stub = StubJudge(AIAnswerVerdict(outcome: .correct, reason: "fine"))
        let result = await AnswerLadder.judge(question: pair.question, expected: pair.expected, given: pair.given,
                                              judge: stub.judge)
        #expect(result.outcome == .notQuite, "\(pair.given) should not match \(pair.expected)")
        #expect(stub.calls == 0)
    }

    // MARK: The example from the report

    @Test("'A program to write code on' for 'platform to write code on' is accepted")
    func platformProgram() async {
        let ai = StubJudge(AIAnswerVerdict(outcome: .closeEnough, reason: "Same idea: a place to write code."))
        let result = await AnswerLadder.judge(question: "What is an IDE?", expected: "platform to write code on",
                                              given: "A program to write code on", judge: ai.judge)
        #expect(result.outcome == .closeEnough)
        #expect(result.reason == "Same idea: a place to write code.")
        #expect(result.source == .ai)
        // And with no judge at all it still passes locally.
        let offline = await AnswerLadder.judge(question: "What is an IDE?", expected: "platform to write code on",
                                               given: "A program to write code on", judge: nil)
        #expect(offline.outcome == .closeEnough)
        #expect(offline.source == .localFallback)
    }

    @Test("the AI can reject a borderline answer that looks close")
    func aiRejects() async {
        let ai = StubJudge(AIAnswerVerdict(outcome: .notQuite, reason: "It names the wrong structure."))
        let result = await AnswerLadder.judge(question: "Which structure?", expected: "a queue holds items in order",
                                              given: "a stack holds items in order", judge: ai.judge)
        #expect(result.outcome == .notQuite)
        #expect(result.source == .ai)
        #expect(ai.calls == 1)
    }

    // MARK: When the AI is (not) asked

    @Test("an exact or near-exact answer never reaches the AI")
    func exactSkipsAI() async {
        let ai = StubJudge(AIAnswerVerdict(outcome: .notQuite))
        for given in ["Cache hit", "cache hit.", "The cache  hit"] {
            let result = await AnswerLadder.judge(question: "q", expected: "cache hit", given: given, judge: ai.judge)
            #expect(result.outcome == .correct, "\(given)")
        }
        // One letter off on a short answer: still accepted, still no call.
        let typo = await AnswerLadder.judge(question: "q", expected: "cache hit", given: "cach hit", judge: ai.judge)
        #expect(typo.outcome.countsAsCorrect)
        #expect(ai.calls == 0)
    }

    @Test("the judge is asked only for a borderline answer")
    func borderlineAsks() async {
        let ai = StubJudge(AIAnswerVerdict(outcome: .closeEnough))
        _ = await AnswerLadder.judge(question: "q", expected: "platform to write code on",
                                     given: "program to write code on", judge: ai.judge)
        #expect(ai.calls == 1)
    }

    @Test("a judge slower than the limit is dropped and the local verdict stands")
    func timeoutFallsBack() async {
        let slow = StubJudge(AIAnswerVerdict(outcome: .notQuite, reason: "late"), delay: .seconds(5))
        let started = ContinuousClock.now
        let result = await AnswerLadder.judge(
            question: "What is an IDE?", expected: "platform to write code on", given: "program to write code on",
            judge: slow.judge, timeout: .milliseconds(150))
        #expect(ContinuousClock.now - started < .seconds(4))  // the judge sleeps 5 s; slack for a loaded runner
        #expect(result.source == .localFallback)
        #expect(result.outcome == .closeEnough)
    }

    @Test("an unreachable judge is silent: the local verdict is used, with no reason")
    func unreachable() async {
        let down = StubJudge(nil)
        let result = await AnswerLadder.judge(question: "q", expected: "platform to write code on",
                                              given: "program to write code on", judge: down.judge)
        #expect(result.reason == nil)
        #expect(result.source == .localFallback)
    }

    // MARK: Modes

    @Test("Local mode never builds a cloud generator, even with a key saved")
    func localModeStaysLocal() {
        // `select` is the one place a mode becomes a generator.
        let chosen = CardGenerators.select(mode: .local, cloudKey: "key", cloudModel: "m", local: NoGenerator())
        #expect(!(chosen is CloudGenerator))
        let cloud = CardGenerators.select(mode: .cloud, cloudKey: "key", cloudModel: "m", local: NoGenerator())
        #expect(cloud is CloudGenerator)
    }

    @Test("the judging prompt carries only the question, the card's answer and the student's answer")
    func promptContents() {
        let text = OllamaGenerator.judgeAnswerPrompt(question: "Q1", expected: "E1", given: "G1")
        #expect(text.contains("Question: Q1"))
        #expect(text.contains("Expected answer: E1"))
        #expect(text.contains("Student's answer: G1"))
        #expect(text.contains("lenient"))
        #expect(text.contains("strict"))
    }

    @Test("a judge reply is read leniently")
    func parsing() {
        #expect(OllamaGenerator.parseJudgement(#"{"verdict": "closeEnough", "reason": "Same idea."}"#)
                == AIAnswerVerdict(outcome: .closeEnough, reason: "Same idea."))
        #expect(OllamaGenerator.parseJudgement("```json\n{\"verdict\": \"notQuite\"}\n```")?.outcome == .notQuite)
        #expect(OllamaGenerator.parseJudgement(#"{"verdict": "Correct"}"#)?.outcome == .correct)
        #expect(OllamaGenerator.parseJudgement("I think it is fine") == nil)
    }

    // MARK: Remembered answers, score and Learn level

    @Test("an answer the student marked right before is accepted at once, with no AI")
    func remembered() async {
        let ai = StubJudge(AIAnswerVerdict(outcome: .notQuite))
        let result = await AnswerLadder.judge(
            question: "q", expected: "cell powerhouse", given: "Energy factory!",
            accepted: ["energy factory"], judge: ai.judge)
        #expect(result.outcome == .correct)
        #expect(result.source == .remembered)
        #expect(ai.calls == 0)
    }

    @Test("close enough counts as correct in a test's score and moves the card up in Learn")
    func closeEnoughCounts() async throws {
        let db = try GRASPDatabase.inMemory()
        let cardId = try await db.queue.write { conn -> String in
            let card = Card(materialId: nil, front: "IDE", back: "platform to write code on", origin: .manual, status: .active)
            try card.insert(conn)
            return card.id
        }
        let outcome = AnswerOutcome.closeEnough
        // Learn: one right answer climbs a rung.
        try await db.queue.write {
            try Study.recordLearnAnswer(cardId: cardId, wasCorrect: outcome.countsAsCorrect, db: $0)
        }
        let level = try await db.queue.read { try LearnState.fetchOne($0, key: cardId)?.level }
        #expect(level == LearnEngine.Level.recognition.rawValue)
        // Test: the answer is stored as correct and the score includes it.
        let question = LearnEngine.RoundQuestion(cardId: cardId, prompt: "IDE", correctAnswer: "platform to write code on",
                                                 type: .written)
        let attemptId = try await db.queue.write { try Study.startRetry(questions: [question], deckIds: [], db: $0) }
        try await db.queue.write {
            try Study.submitTestAnswer(attemptId: attemptId, ordinal: 0, given: "A program to write code on",
                                       isCorrect: outcome.countsAsCorrect, db: $0)
        }
        let score = try await db.queue.write { try Study.finishTest(attemptId: attemptId, db: $0) }
        #expect(score.correct == 1)
        #expect(score.total == 1)
    }
}
