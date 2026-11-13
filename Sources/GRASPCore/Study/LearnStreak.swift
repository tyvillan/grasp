import Foundation
import GRDB

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

/// The streak as stored: one row per library, synced like the rest of it so
/// the Mac and the iPhone share one run. Newest write wins.
public struct LearnStreakRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "learnStreak"
    public static let rowId = "current"
    public var id: String
    public var count: Int
    public var updatedAt: Date

    public init(count: Int, updatedAt: Date = Date()) {
        self.id = Self.rowId; self.count = count; self.updatedAt = updatedAt
    }
}

extension Study {
    /// The saved streak; zero when none has been recorded.
    public static func learnStreak(db: Database) throws -> LearnStreak {
        LearnStreak(count: try LearnStreakRow.fetchOne(db, key: LearnStreakRow.rowId)?.count ?? 0)
    }

    /// Saves the streak. Skips the write when nothing changed, so a miss at
    /// zero does not send a sync row.
    public static func saveLearnStreak(_ streak: LearnStreak, now: Date = Date(), db: Database) throws {
        if let existing = try LearnStreakRow.fetchOne(db, key: LearnStreakRow.rowId), existing.count == streak.count { return }
        if try LearnStreakRow.fetchOne(db, key: LearnStreakRow.rowId) == nil, streak.count == 0 { return }
        try LearnStreakRow(count: streak.count, updatedAt: now).save(db)
    }
}
