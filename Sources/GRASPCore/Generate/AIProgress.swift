import Foundation

/// How far along a run of model calls is, reported from wherever the calls
/// actually happen.
///
/// Reached through a task-local rather than a parameter: the calls that
/// matter are several layers down (a view's loop → the store → the
/// composer → one generator's section loop), and threading a reporter
/// through every `CardGenerator` method would change a protocol with two
/// conformers and a test stub for what is purely a side channel. Code that
/// isn't being watched pays nothing -- `current` is nil and every call below
/// is a no-op.
///
/// The unit is one *step*, almost always one model call. Whoever starts a
/// run says how many steps it expects; code further down can revise that
/// with `expect(_:)` once it knows more (a lesson plan comes back with four
/// sections, not the five assumed). Steps are the right unit because on a
/// local model each one takes roughly the same 20-60 seconds, which is what
/// makes a time-left estimate from them honest.
public final class AIProgress: @unchecked Sendable {
    @TaskLocal public static var current: AIProgress?

    public struct Snapshot: Sendable, Equatable {
        /// What's happening right now, in the student's terms: "Writing
        /// section 2 of 5". Nil until the first step starts.
        public var step: String?
        /// Which piece of a long note is being worked on ("Part 1 of 2"),
        /// or nil when the note is being read in one go.
        public var part: String?
        public var completed: Int
        public var expected: Int
        /// Increases on every change, so a consumer that receives snapshots
        /// out of order (each one hops to the main actor separately) can
        /// drop a stale one.
        public var sequence: Int

        public static let empty = Snapshot(step: nil, part: nil, completed: 0, expected: 0, sequence: 0)

        /// 0...1, never NaN. Held just short of 1 until the run says it's
        /// done: an estimate that undercounted must not show a full bar
        /// with work still going.
        public var fraction: Double {
            guard expected > 0 else { return 0 }
            return min(0.99, Double(completed) / Double(expected))
        }
    }

    private let lock = NSLock()
    private var state = Snapshot.empty
    private let onChange: @Sendable (Snapshot) -> Void

    public init(expected: Int = 0, onChange: @escaping @Sendable (Snapshot) -> Void = { _ in }) {
        state.expected = max(0, expected)
        self.onChange = onChange
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Adds to (or, negative, takes from) the number of steps expected.
    /// Never drops below what's already been done.
    public func expect(_ additional: Int) {
        update { $0.expected = max($0.completed, $0.expected + additional) }
    }

    /// Names the step about to run.
    public func begin(_ step: String) {
        update { $0.step = step }
    }

    /// Names the piece of a long note that the next steps belong to.
    public func setPart(_ part: String?) {
        update { $0.part = part }
    }

    /// Marks steps done -- including ones skipped without a call, so the bar
    /// still reaches the end when a note turns out to need less work.
    public func advance(_ count: Int = 1) {
        guard count > 0 else { return }
        update {
            $0.completed += count
            $0.expected = max($0.expected, $0.completed)
        }
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        change(&state)
        state.sequence += 1
        let snapshot = state
        lock.unlock()
        // Outside the lock: the callback hops actors, and holding a lock
        // across that invites a deadlock for no benefit.
        onChange(snapshot)
    }
}

/// Turns progress so far into "about 4 min left".
///
/// Straight-line extrapolation from elapsed time. Anything cleverer would
/// be modelling noise: steps on a local model are close enough to equal in
/// length that the simple estimate is right to within a minute or two once
/// a few have finished -- and before that it says nothing rather than
/// guess.
public enum AIProgressEstimate {
    /// Seconds left, or nil while there's too little to go on.
    public static func remaining(fraction: Double, elapsed: TimeInterval) -> TimeInterval? {
        // The first step includes loading the model into memory, which can
        // take longer than the step itself; extrapolating from it alone
        // would open with a wildly pessimistic number.
        guard fraction >= 0.05, fraction < 1, elapsed >= 15 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }

    /// "about 4 min left", or nil when there's no estimate yet.
    public static func describe(_ remaining: TimeInterval?) -> String? {
        guard let remaining, remaining.isFinite, remaining >= 0 else { return nil }
        if remaining < 45 { return "less than a minute left" }
        let minutes = Int((remaining / 60).rounded())
        if minutes < 60 { return "about \(max(1, minutes)) min left" }
        let hours = minutes / 60
        let rest = minutes % 60
        // Past an hour, five-minute precision is already more than the
        // estimate is worth.
        let roundedRest = (rest / 5) * 5
        return roundedRest == 0 ? "about \(hours) hr left" : "about \(hours) hr \(roundedRest) min left"
    }
}
