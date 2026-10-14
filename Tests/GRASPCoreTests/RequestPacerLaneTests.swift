import Testing
import Foundation
@testable import GRASPCore

/// A clock the test moves by hand. `sleep` parks until `advance` reaches its
/// deadline, so nothing here depends on how busy the machine is.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var waiters: [(id: UInt64, deadline: Instant, cont: CheckedContinuation<Void, Error>)] = []
    private var nextId: UInt64 = 0

    var now: Instant { lock.lock(); defer { lock.unlock() }; return current }
    var minimumResolution: Duration { .nanoseconds(1) }
    var waiterCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
    var seconds: Double { let d = now.offset; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id: UInt64 = { lock.lock(); defer { lock.unlock() }; nextId += 1; return nextId }()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if deadline <= current { lock.unlock(); cont.resume(); return }
                waiters.append((id, deadline, cont))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let hit = waiters.firstIndex { $0.id == id }.map { waiters.remove(at: $0) }
            lock.unlock()
            hit?.cont.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = waiters.filter { $0.deadline <= current }
        waiters.removeAll { $0.deadline <= current }
        lock.unlock()
        for waiter in due { waiter.cont.resume() }
    }

    func sleepSeconds(_ s: TimeInterval) async throws {
        try await sleep(until: now.advanced(by: .seconds(s)), tolerance: nil)
    }

    var date: Date { Date(timeIntervalSince1970: 1_000_000 + seconds) }

    /// Lets other tasks run until `condition` holds (a bounded number of turns).
    static func settle(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
    }
}

private actor Log {
    var events: [String] = []
    func add(_ e: String) { events.append(e) }
}

@Suite("Request pacer: interactive lane and plan rate")
struct RequestPacerLaneTests {
    private func pacer(_ interval: TimeInterval, _ clock: ManualClock) -> RequestPacer {
        RequestPacer(minimumInterval: interval, now: { clock.date }, sleep: { try await clock.sleepSeconds($0) })
    }

    @Test("an interactive request does not wait behind a queued background request")
    func interactiveJumpsQueue() async throws {
        let clock = ManualClock()
        let p = pacer(0.3, clock)
        let log = Log()
        try await p.waitTurn(priority: .background)                 // takes the first slot
        let background = Task {
            try await p.waitTurn(priority: .background)
            await log.add("bg")
        }
        await ManualClock.settle { clock.waiterCount == 1 }
        #expect(clock.waiterCount == 1)                             // parked, waiting its spacing
        // The interactive request is granted with the clock not moved at all.
        try await p.waitTurn(priority: .interactive)
        await log.add("interactive")
        #expect(clock.seconds == 0)
        clock.advance(by: .seconds(1))
        try await background.value
        #expect(await log.events == ["interactive", "bg"])
    }

    @Test("an interactive request still counts: the next background request keeps its spacing after it")
    func interactiveCounts() async throws {
        let clock = ManualClock()
        let p = pacer(0.25, clock)
        try await p.waitTurn(priority: .background)
        try await p.waitTurn(priority: .interactive)
        let next = Task { try await p.waitTurn(priority: .background) }
        await ManualClock.settle { clock.waiterCount == 1 }
        #expect(clock.waiterCount == 1)                              // it had to wait
        clock.advance(by: .seconds(0.3))
        try await next.value
    }

    @Test("background requests are served in arrival order")
    func backgroundIsFIFO() async throws {
        let clock = ManualClock()
        let p = pacer(0.05, clock)
        let log = Log()
        try await p.waitTurn(priority: .background)
        var tasks: [Task<Void, Error>] = []
        for i in 0..<4 {
            tasks.append(Task {
                try await p.waitTurn(priority: .background)
                await log.add("\(i)")
            })
            await ManualClock.settle { await p.waitingCount == i + 1 }
        }
        for _ in 0..<8 {
            clock.advance(by: .seconds(0.06))
            for _ in 0..<200 { await Task.yield() }
        }
        for t in tasks { try await t.value }
        #expect(await log.events == ["0", "1", "2", "3"])
    }

    @Test("a cancelled waiter leaves the queue and the next one proceeds")
    func cancelledWaiterLeaves() async throws {
        let clock = ManualClock()
        let p = pacer(0.2, clock)
        try await p.waitTurn(priority: .background)
        let doomed = Task { try await p.waitTurn(priority: .background) }
        await ManualClock.settle { await p.waitingCount == 1 }
        doomed.cancel()
        _ = try? await doomed.value
        await ManualClock.settle { await p.waitingCount == 0 }
        let after = Task { try await p.waitTurn(priority: .background) }
        await ManualClock.settle { await p.waitingCount == 1 }
        clock.advance(by: .seconds(0.5))
        try await after.value
    }

    @Test("the plan sets the pace: free 10 a minute and one call at a time, paid more and 4 at once")
    func planRates() {
        #expect(GeminiPlan.free.requestsPerMinute == 10)
        #expect(GeminiPlan.free.concurrency == 1)
        #expect(GeminiPlan.paid.requestsPerMinute > 10)
        #expect(GeminiPlan.paid.concurrency == 4)
    }

    /// Moves the clock one tick at a time and lets the timer run between.
    private func run(_ clock: ManualClock, ticks: Int, tick: Duration = .milliseconds(20)) async {
        for _ in 0..<ticks {
            await ManualClock.settle { clock.waiterCount >= 1 }
            clock.advance(by: tick)
            for _ in 0..<20 { await Task.yield() }
        }
    }

    @Test("the judge's clock starts when the request is sent: five seconds queued, then an answer, still counts")
    func judgeClockStartsAtSend() async {
        let clock = ManualClock()
        let release = AsyncGate()
        let job = Task { () -> String? in
            await AnswerLadder.withSendTimeout(.seconds(1), ceiling: .seconds(60), clock: clock, tick: .milliseconds(20)) {
                let gate = AIRequestContext.gate
                gate?.setQueued(true)
                await release.wait()
                gate?.setQueued(false)
                return "answer"
            }
        }
        await run(clock, ticks: 250)          // 5 s on the clock, all of it queued
        await release.open()
        #expect(await job.value == "answer")
    }

    @Test("once sent, an answer slower than the limit is dropped")
    func judgeStillTimesOut() async {
        let clock = ManualClock()
        let never = AsyncGate()
        let job = Task { () -> String? in
            await AnswerLadder.withSendTimeout(.milliseconds(500), ceiling: .seconds(60), clock: clock, tick: .milliseconds(20)) {
                await never.wait()
                return "late"
            }
        }
        await run(clock, ticks: 40)           // 0.8 s with nothing queued
        await never.open()                    // lets the abandoned work end; the clock already won
        #expect(await job.value == nil)
    }
}

/// One-shot gate: `wait` suspends until `open`.
actor AsyncGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        for w in waiting { w.resume() }
        waiting = []
    }
}

@Suite("Cloud: stopping, slow notes and failure wording")
struct CloudStopAndNotesTests {
    private final class Hanging: @unchecked Sendable {
        let lock = NSLock()
        var sent = 0
        func note() { lock.lock(); sent += 1; lock.unlock() }
    }

    @Test("stopping a call that is waiting on Google ends it at once as a cancellation, with no retry")
    func cancelInFlight() async throws {
        let hanging = Hanging()
        let transport = GeminiTransport(
            apiKey: "k", model: "m", usage: CloudUsage(defaults: UserDefaults(suiteName: "t.\(UUID())")!),
            pacer: RequestPacer(minimumInterval: 0),
            send: { _ in
                hanging.note()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw URLError(.timedOut)
            })
        let task = Task { try await transport.complete(prompt: "hi", json: false, maxTokens: nil) }
        while hanging.sent == 0 { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(hanging.sent == 1)
    }

    @Test("a note appears when a call runs long and goes away when it ends")
    func slowNoteShowsAndClears() async {
        let seen = NoteLog()
        let progress = AIProgress { snapshot in seen.add(snapshot.note) }
        await AIProgress.$current.withValue(progress) {
            let task = GeminiTransport.notify(after: 0.05, "slow now")
            // Wait for it however busy the machine is; it must appear, not appear by a deadline.
            for _ in 0..<2_000 where progress.snapshot.note != "slow now" {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(progress.snapshot.note == "slow now")
            task.cancel()
            _ = await task.value
        }
        #expect(progress.snapshot.note == nil)
    }

    @Test("finished sections are listed in the order they landed")
    func finishedList() {
        let progress = AIProgress()
        progress.addFinished("Scheduling")
        progress.addFinished("  ")
        progress.addFinished("Memory")
        #expect(progress.snapshot.finished == ["Scheduling", "Memory"])
    }

    @Test("each failure reads as a sentence with something to do, and none uses a double hyphen")
    func failureWording() {
        let all: [AIBackendError] = [.unreachable, .overloaded(status: 503), .rateLimited(retryAfter: nil),
                                     .quotaExhausted, .unauthorized, .badResponse("x")]
        for error in all {
            let text = CloudFailureText.text(for: error)
            #expect(text.hasSuffix("."))
            #expect(!text.contains(" -- "))
        }
        #expect(CloudProvider.slowNote.contains("still waiting"))
        #expect(!CloudProvider.pacingNote.contains(" -- "))
    }
}

private final class NoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String?] = []
    func add(_ n: String?) { lock.lock(); notes.append(n); lock.unlock() }
}
