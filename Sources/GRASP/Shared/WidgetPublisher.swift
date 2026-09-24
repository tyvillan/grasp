import Foundation
import Observation
import WidgetKit
import GRDB
import GRASPCore

/// Keeps the widgets' snapshot current: rebuilt shortly after each
/// `reload()` (they come in bursts while studying), written only when
/// something a widget draws actually changed, and followed by a WidgetKit
/// reload so the Home Screen catches up now rather than at its next slot.
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private var pending: Task<Void, Never>?
    private var lastPublished: WidgetSnapshot?

    func schedule(from store: AppStore) {
        guard store.profile.id != Profile.previewID else { return }
        pending?.cancel()
        pending = Task { [weak store] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let store else { return }
            self.publish(from: store)
        }
    }

    /// Right away -- for moments the app may not get another chance, like
    /// heading into the background.
    func publish(from store: AppStore) {
        guard store.profile.id != Profile.previewID,
              let snapshot = try? store.widgetSnapshot() else { return }
        if let lastPublished, lastPublished.sameContent(as: snapshot) { return }
        do {
            try WidgetSnapshotFile.write(snapshot)
            lastPublished = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // No App Group container (an unsigned dev build): the widgets
            // just keep their placeholder. Nothing for the user to act on.
        }
    }
}

/// A widget tap waiting for the app's UI to act on it. The scene's
/// `onOpenURL` sets it; whichever root view is showing the library
/// consumes it -- possibly later, after the profile is picked.
@Observable
final class WidgetRouter {
    static let shared = WidgetRouter()
    var pending: WidgetLink?

    func consume() -> WidgetLink? {
        defer { pending = nil }
        return pending
    }
}

extension AppStore {
    /// Everything the widgets draw, read in one go.
    func widgetSnapshot(now: Date = Date()) throws -> WidgetSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let horizon = now.addingTimeInterval(WidgetSnapshot.horizon)

        // Same scope as the dashboard: live decks in courses that aren't
        // archived, active cards only.
        let dueRows = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT deckCard.deckId AS deckId, card.id AS cardId, card.due AS due
                FROM deckCard
                JOIN card ON card.id = deckCard.cardId
                JOIN deck ON deck.id = deckCard.deckId
                JOIN course ON course.id = deck.courseId
                WHERE card.deletedAt IS NULL AND card.status = 'active' AND card.due <= ?
                  AND deck.deletedAt IS NULL AND course.isArchived = 0
                """, arguments: [horizon])
        }

        func dueTimes(_ dates: [Date]) -> WidgetSnapshot.DueTimes {
            let upcoming = dates.filter { $0 > now }.sorted().prefix(WidgetSnapshot.maximumUpcoming)
            return .init(overdue: dates.count { $0 <= now }, upcoming: Array(upcoming))
        }

        // A card in two decks counts once in the total.
        var dueByCard: [String: Date] = [:]
        var dueByDeck: [String: [Date]] = [:]
        for row in dueRows {
            let due: Date = row["due"]
            dueByCard[row["cardId"]] = due
            dueByDeck[row["deckId"], default: []].append(due)
        }

        let summaries = try dashboardDecks(now: now)
        let decks = summaries.compactMap { summary -> WidgetSnapshot.Deck? in
            guard let dates = dueByDeck[summary.deckId] else { return nil }
            return .init(id: summary.deckId, name: summary.deckName, courseName: summary.courseName,
                         lastReviewedAt: summary.lastReviewedAt, due: dueTimes(dates))
        }

        let events = try upcomingExams(within: 60, limit: 5, now: now).map {
            WidgetSnapshot.Event(id: $0.event.id, title: $0.event.title, kind: $0.event.kind.rawValue,
                                 courseName: $0.courseName, startsAt: $0.event.startsAt, isAllDay: $0.event.isAllDay)
        }

        let streak = studyStreak(now: now)
        let lastStudyDay: Date? = streak.studiedToday ? today
            : streak.days > 0 ? calendar.date(byAdding: .day, value: -1, to: today) : nil
        let goal = preferences.object(forKey: "dailyCardGoal") as? Int ?? 20

        return WidgetSnapshot(
            generatedAt: now, profileName: profile.name, dailyGoal: goal,
            streakDays: streak.days, lastStudyDay: lastStudyDay,
            reviewsToday: streak.reviewsToday, reviewsDay: today,
            due: dueTimes(Array(dueByCard.values)), decks: decks, events: events
        )
    }
}
