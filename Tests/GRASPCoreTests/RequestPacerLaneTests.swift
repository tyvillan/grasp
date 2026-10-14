import Testing
import Foundation
@testable import GRASPCore

private actor Log {
    var events: [String] = []
    func add(_ e: String) { events.append(e) }
}

@Suite("Request pacer: interactive lane and plan rate")
struct RequestPacerLaneTests {
    @Test("an interactive request does not wait behind queued background requests")
    func interactiveJumpsQueue() async throws {
        let pacer = RequestPacer(minimumInterval: 0.3)
        let log = Log()
        try await pacer.waitTurn(priority: .background)            // takes the first slot
        let background = Task {
            for i in 1...2 {
                try await pacer.waitTurn(priority: .background)
                await log.add("bg\(i)")
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        try await pacer.waitTurn(priority: .interactive)
        await log.add("interactive")
        #expect(Date().timeIntervalSince(started) < 0.15)
        try await background.value
        #expect(await log.events == ["interactive", "bg1", "bg2"])
    }

    @Test("an interactive request still counts: background requests after it keep their spacing")
    func interactiveCounts() async throws {
        let pacer = RequestPacer(minimumInterval: 0.25)
        try await pacer.waitTurn(priority: .background)
        try await pacer.waitTurn(priority: .interactive)
        let started = Date()
        try await pacer.waitTurn(priority: .background)
        #expect(Date().timeIntervalSince(started) >= 0.2)
    }

    @Test("background requests are served in arrival order")
    func backgroundIsFIFO() async throws {
        let pacer = RequestPacer(minimumInterval: 0.05)
        let log = Log()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(i) * 10_000_000)
                    try await pacer.waitTurn(priority: .background)
                    await log.add("\(i)")
                }
            }
            try await group.waitForAll()
        }
        #expect(await log.events == ["0", "1", "2", "3"])
    }

    @Test("a cancelled waiter leaves the queue and the next one proceeds")
    func cancelledWaiterLeaves() async throws {
        let pacer = RequestPacer(minimumInterval: 0.2)
        try await pacer.waitTurn(priority: .background)
        let doomed = Task { try await pacer.waitTurn(priority: .background) }
        try await Task.sleep(nanoseconds: 30_000_000)
        doomed.cancel()
        let started = Date()
        try await pacer.waitTurn(priority: .background)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test("the plan sets the pace: free 10 a minute and one call at a time, paid more and 4 at once")
    func planRates() {
        #expect(GeminiPlan.free.requestsPerMinute == 10)
        #expect(GeminiPlan.free.concurrency == 1)
        #expect(GeminiPlan.paid.requestsPerMinute > 10)
        #expect(GeminiPlan.paid.concurrency == 4)
    }

    @Test("the judge's clock starts when the request is sent, not when it was queued")
    func judgeClockStartsAtSend() async {
        // Queued for 0.4 s, then 0.2 s to answer: 0.6 s in all, limit 0.3 s.
        let result: String? = await AnswerLadder.withSendTimeout(.milliseconds(300)) {
            let gate = AIRequestContext.gate
            gate?.setQueued(true)
            try? await Task.sleep(nanoseconds: 400_000_000)
            gate?.setQueued(false)
            try? await Task.sleep(nanoseconds: 200_000_000)
            return "answer"
        }
        #expect(result == "answer")
    }

    @Test("once sent, a slow answer is still dropped at the limit")
    func judgeStillTimesOut() async {
        let result: String? = await AnswerLadder.withSendTimeout(.milliseconds(150)) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return "late"
        }
        #expect(result == nil)
    }
}
