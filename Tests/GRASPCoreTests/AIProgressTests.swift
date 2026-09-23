import Foundation
import Testing
@testable import GRASPCore

/// The step counter behind every AI progress bar, and the time-left
/// estimate read off it.
@Suite("AI progress")
struct AIProgressTests {

    @Test("counts steps against what was expected")
    func countsSteps() {
        let progress = AIProgress(expected: 4)
        progress.advance()
        #expect(progress.snapshot.completed == 1)
        #expect(progress.snapshot.fraction == 0.25)
    }

    @Test("never shows a full bar while the run is still going")
    func neverFullEarly() {
        let progress = AIProgress(expected: 2)
        progress.advance(5)
        #expect(progress.snapshot.fraction < 1)
        // An undercount grows the expectation rather than overflowing it.
        #expect(progress.snapshot.expected == 5)
    }

    @Test("a revised estimate never drops below the work already done")
    func expectationFloor() {
        let progress = AIProgress(expected: 6)
        progress.advance(3)
        progress.expect(-10)
        #expect(progress.snapshot.expected == 3)
    }

    @Test("an empty run reads as zero, not NaN")
    func emptyRun() {
        #expect(AIProgress().snapshot.fraction == 0)
    }

    @Test("every change is numbered, so a late update can be told apart")
    func sequenceIncreases() {
        let seen = Recorder()
        let progress = AIProgress(expected: 3) { seen.append($0) }
        progress.begin("Planning the lesson")
        progress.advance()
        progress.setPart("Part 1 of 2")
        let sequences = seen.snapshots.map(\.sequence)
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == 3)
        #expect(seen.snapshots.last?.step == "Planning the lesson")
        #expect(seen.snapshots.last?.part == "Part 1 of 2")
    }

    @Test("reaches code several calls down through the task-local")
    func taskLocalReachesCallees() async {
        let progress = AIProgress(expected: 1)
        func deepCall() async { AIProgress.current?.advance() }
        await AIProgress.$current.withValue(progress) { await deepCall() }
        #expect(progress.snapshot.completed == 1)
        // Outside the scope nothing is watching, and nothing breaks.
        await deepCall()
        #expect(progress.snapshot.completed == 1)
    }

    // MARK: - Time left

    @Test("says nothing until there's enough to go on")
    func noEarlyEstimate() {
        #expect(AIProgressEstimate.remaining(fraction: 0.02, elapsed: 60) == nil)
        #expect(AIProgressEstimate.remaining(fraction: 0.5, elapsed: 5) == nil)
        #expect(AIProgressEstimate.describe(nil) == nil)
    }

    @Test("extrapolates in a straight line from elapsed time")
    func straightLine() {
        // A quarter done in two minutes: six more to go.
        #expect(AIProgressEstimate.remaining(fraction: 0.25, elapsed: 120) == 360)
    }

    @Test("describes time left the way a person would say it")
    func describes() {
        #expect(AIProgressEstimate.describe(20) == "less than a minute left")
        #expect(AIProgressEstimate.describe(70) == "about 1 min left")
        #expect(AIProgressEstimate.describe(250) == "about 4 min left")
        #expect(AIProgressEstimate.describe(3_600) == "about 1 hr left")
        #expect(AIProgressEstimate.describe(4_500) == "about 1 hr 15 min left")
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AIProgress.Snapshot] = []
        func append(_ snapshot: AIProgress.Snapshot) {
            lock.lock(); stored.append(snapshot); lock.unlock()
        }
        var snapshots: [AIProgress.Snapshot] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }
}
