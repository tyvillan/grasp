import SwiftUI
import WidgetKit

/// GRASP's Home Screen and desktop widgets. The same code builds the iPhone
/// extension and the Mac one; both read the snapshot the app publishes into
/// their shared App Group (see `WidgetSnapshot`).
@main
struct GRASPWidgets: WidgetBundle {
    var body: some Widget {
        DueWidget()
        JumpBackInWidget()
        NextExamWidget()
    }
}

// MARK: - Timeline

nonisolated struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// nil until the app has published once -- the widget says to open it.
    let state: WidgetSnapshot.State?
}

/// One timeline for all three widgets: an entry now, then one at each
/// moment a number changes on its own (a card falling due, midnight), for
/// the next day. The app asks for a reload whenever it changes anything,
/// so this only has to cover the time the app isn't running.
nonisolated struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, state: WidgetSnapshot.sample.state(at: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // The widget gallery shows sample numbers until there's real data.
        let snapshot = WidgetSnapshotFile.read() ?? (context.isPreview ? .sample : nil)
        completion(SnapshotEntry(date: .now, state: snapshot?.state(at: .now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        guard let snapshot = WidgetSnapshotFile.read() else {
            completion(Timeline(entries: [SnapshotEntry(date: now, state: nil)], policy: .after(now.addingTimeInterval(3600))))
            return
        }
        let end = now.addingTimeInterval(24 * 3600)
        let entries = ([now] + Self.coalesced(snapshot.changeTimes(after: now, until: end)))
            .map { SnapshotEntry(date: $0, state: snapshot.state(at: $0)) }
        completion(Timeline(entries: entries, policy: .after(end)))
    }

    /// Cards often fall due seconds apart; a widget doesn't need an entry
    /// for each. Rounds up to the next quarter hour (so a count is never
    /// shown early) and keeps the timeline to a sensible length.
    static func coalesced(_ times: [Date]) -> [Date] {
        let step: TimeInterval = 15 * 60
        let rounded = times.map { Date(timeIntervalSinceReferenceDate: ($0.timeIntervalSinceReferenceDate / step).rounded(.up) * step) }
        return Array(Array(Set(rounded)).sorted().prefix(96))
    }
}

extension WidgetSnapshot {
    /// What the widget gallery shows before the app has published.
    nonisolated static var sample: WidgetSnapshot {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        return WidgetSnapshot(
            generatedAt: now, profileName: "You", dailyGoal: 20,
            streakDays: 6, lastStudyDay: today, reviewsToday: 14, reviewsDay: today,
            due: .init(overdue: 23, upcoming: []),
            decks: [
                .init(id: "sample-1", name: "Lecture 4 -- Eigenvalues", courseName: "Matrix Theory",
                      lastReviewedAt: now.addingTimeInterval(-3600), due: .init(overdue: 12, upcoming: [])),
                .init(id: "sample-2", name: "Design Patterns", courseName: "Software Design",
                      lastReviewedAt: nil, due: .init(overdue: 8, upcoming: [])),
                .init(id: "sample-3", name: "Cell Biology", courseName: "Biology",
                      lastReviewedAt: nil, due: .init(overdue: 3, upcoming: [])),
            ],
            events: [
                .init(id: "sample-e1", title: "Midterm 1", kind: "exam", courseName: "Matrix Theory",
                      startsAt: today.addingTimeInterval(5 * 86400 + 10 * 3600), isAllDay: false),
                .init(id: "sample-e2", title: "Quiz 3", kind: "quiz", courseName: "Software Design",
                      startsAt: today.addingTimeInterval(9 * 86400), isAllDay: true),
            ]
        )
    }
}
