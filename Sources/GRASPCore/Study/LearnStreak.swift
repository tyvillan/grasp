import Foundation

/// The run of right answers in a row while learning. A streak is celebrated
/// from the third right answer and keeps counting until the first miss.
public struct LearnStreak: Equatable, Sendable {
    /// Right answers needed before the streak is shown.
    public static let threshold = 3

    public private(set) var count: Int

    public init(count: Int = 0) { self.count = max(0, count) }

    /// The streak after one more answer: right adds one, wrong ends it.
    public func after(correct: Bool) -> LearnStreak {
        LearnStreak(count: correct ? count + 1 : 0)
    }

    /// True once the run is long enough to celebrate.
    public var isOn: Bool { count >= Self.threshold }

    /// "3 correct in a row", read out and shown beside the flame.
    public var headline: String { "\(count) correct in a row" }

    /// Said when a miss ends a celebrated streak; nil if there was none.
    public func endedCaption(afterMiss: Bool) -> String? {
        guard afterMiss, isOn else { return nil }
        return "Streak ended at \(count). Start a new one."
    }
}

/// Keeps the streak between visits to Learn. On this device only (it is not
/// synced), so it needs no schema; it ends at the first miss, not at a clock.
public struct LearnStreakStore {
    private let defaults: UserDefaults
    private let key = "learnStreak.count"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> LearnStreak { LearnStreak(count: defaults.integer(forKey: key)) }
    public func save(_ streak: LearnStreak) { defaults.set(streak.count, forKey: key) }
}
