import Foundation

/// What the Home Screen / desktop widgets show, written by the app into
/// the App Group container they share.
///
/// Widgets can't open the library database -- it lives in the app's own
/// container, and a widget reading SQLite while the app writes it is a
/// locking problem nobody needs. So the app publishes this small summary
/// instead, whenever its data changes.
///
/// It carries *times*, not just counts, so a widget stays right between
/// publishes: a card due at 3pm is in `upcoming`, and the 4pm timeline entry
/// counts it without the app running. Likewise the streak is stored with
/// the day it was last extended, so it reads 0 the morning after a missed
/// day rather than showing yesterday's number forever.
///
/// This file is compiled into the widget extensions directly (they don't
/// link GRASPCore), so it must stay Foundation-only.
public nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var profileName: String
    public var dailyGoal: Int
    /// The streak as of `generatedAt`, and the day (start of day) it was
    /// last studied -- nil when there's no streak at all.
    public var streakDays: Int
    public var lastStudyDay: Date?
    /// Reviews done on `reviewsDay` (a start of day).
    public var reviewsToday: Int
    public var reviewsDay: Date
    /// Every active card due by the publish horizon, across all courses.
    public var due: DueTimes
    /// Decks with anything due by the horizon.
    public var decks: [Deck]
    /// Exams and quizzes coming up, soonest first.
    public var events: [Event]

    public nonisolated struct DueTimes: Codable, Equatable, Sendable {
        /// Cards already due when the snapshot was made.
        public var overdue: Int
        /// Due times after that, ascending, up to the horizon.
        public var upcoming: [Date]

        public init(overdue: Int, upcoming: [Date]) {
            self.overdue = overdue
            self.upcoming = upcoming.sorted()
        }

        public func count(at date: Date) -> Int {
            // `upcoming` is sorted, so this is a partition point.
            var low = 0, high = upcoming.count
            while low < high {
                let mid = (low + high) / 2
                if upcoming[mid] <= date { low = mid + 1 } else { high = mid }
            }
            return overdue + low
        }
    }

    public nonisolated struct Deck: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var courseName: String
        public var lastReviewedAt: Date?
        public var due: DueTimes

        public init(id: String, name: String, courseName: String, lastReviewedAt: Date?, due: DueTimes) {
            self.id = id
            self.name = name
            self.courseName = courseName
            self.lastReviewedAt = lastReviewedAt
            self.due = due
        }
    }

    public nonisolated struct Event: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// A `CalendarEventKind` raw value: exam, quiz, deadline, study.
        public var kind: String
        public var courseName: String?
        public var startsAt: Date
        public var isAllDay: Bool

        public init(id: String, title: String, kind: String, courseName: String?, startsAt: Date, isAllDay: Bool) {
            self.id = id
            self.title = title
            self.kind = kind
            self.courseName = courseName
            self.startsAt = startsAt
            self.isAllDay = isAllDay
        }
    }

    public init(
        generatedAt: Date, profileName: String, dailyGoal: Int,
        streakDays: Int, lastStudyDay: Date?, reviewsToday: Int, reviewsDay: Date,
        due: DueTimes, decks: [Deck], events: [Event]
    ) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.profileName = profileName
        self.dailyGoal = dailyGoal
        self.streakDays = streakDays
        self.lastStudyDay = lastStudyDay
        self.reviewsToday = reviewsToday
        self.reviewsDay = reviewsDay
        self.due = due
        self.decks = decks
        self.events = events
    }

    /// Whether two snapshots would draw the same widgets -- everything but
    /// the publish time. The app skips rewriting (and asking WidgetKit to
    /// reload) when nothing visible changed, which is most `reload()`s.
    public func sameContent(as other: WidgetSnapshot) -> Bool {
        var a = self, b = other
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }

    /// How far ahead publishes list due times. Widgets reload well inside
    /// this; past it they undercount until the app next runs.
    public static let horizon: TimeInterval = 48 * 3600
    /// A backstop on the file's size for a library with thousands of cards
    /// coming due at once.
    public static let maximumUpcoming = 2000
}

// MARK: - Reading it at a point in time

nonisolated extension WidgetSnapshot {
    /// The numbers a widget draws for one timeline entry.
    public nonisolated struct State: Sendable {
        public let date: Date
        public let dueNow: Int
        public let streakDays: Int
        public let studiedToday: Bool
        public let reviewsToday: Int
        public let dailyGoal: Int
        /// Decks with cards due now, most due first.
        public let dueDecks: [(deck: Deck, dueCount: Int)]
        /// What to study next: the most recently studied deck with anything
        /// due, else the one with the most due -- the Today tab's rule.
        public let jumpBackIn: (deck: Deck, dueCount: Int)?
        /// Due now, per course, most first.
        public let dueByCourse: [(name: String, dueCount: Int)]
        /// Events from the start of today on, soonest first.
        public let upcomingEvents: [Event]
    }

    public func state(at date: Date, calendar: Calendar = .current) -> State {
        let today = calendar.startOfDay(for: date)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let studiedToday = lastStudyDay.map { calendar.isDate($0, inSameDayAs: today) } ?? false
        let streakAlive = studiedToday || (lastStudyDay.map { calendar.isDate($0, inSameDayAs: yesterday) } ?? false)

        let dueDecks = decks
            .map { (deck: $0, dueCount: $0.due.count(at: date)) }
            .filter { $0.dueCount > 0 }
            .sorted { $0.dueCount != $1.dueCount ? $0.dueCount > $1.dueCount : $0.deck.name < $1.deck.name }
        let recent = dueDecks
            .filter { $0.deck.lastReviewedAt != nil }
            .max { ($0.deck.lastReviewedAt ?? .distantPast) < ($1.deck.lastReviewedAt ?? .distantPast) }

        var byCourse: [String: Int] = [:]
        for entry in dueDecks { byCourse[entry.deck.courseName, default: 0] += entry.dueCount }

        return State(
            date: date,
            dueNow: due.count(at: date),
            streakDays: streakAlive ? streakDays : 0,
            studiedToday: studiedToday,
            reviewsToday: calendar.isDate(reviewsDay, inSameDayAs: today) ? reviewsToday : 0,
            dailyGoal: dailyGoal,
            dueDecks: dueDecks,
            jumpBackIn: recent ?? dueDecks.first,
            dueByCourse: byCourse.map { (name: $0.key, dueCount: $0.value) }
                .sorted { $0.dueCount != $1.dueCount ? $0.dueCount > $1.dueCount : $0.name < $1.name },
            upcomingEvents: events.filter { $0.startsAt >= today }.sorted { $0.startsAt < $1.startsAt }
        )
    }

    /// Whole days from `date` to an event, counted in calendar days -- an
    /// exam tomorrow morning is "1", not "0" because it's under 24 hours.
    public static func daysAway(_ event: Event, from date: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: event.startsAt)
        ).day ?? 0
    }

    /// When a widget's count next changes on its own: the next card due
    /// time and the next midnight (streaks and "reviewed today" roll over),
    /// whichever comes first. Timeline entries go at these moments.
    public func changeTimes(after start: Date, until end: Date, calendar: Calendar = .current) -> [Date] {
        var times = Set(due.upcoming.filter { $0 > start && $0 <= end })
        var midnight = calendar.startOfDay(for: start)
        while let next = calendar.date(byAdding: .day, value: 1, to: midnight), next <= end {
            times.insert(next)
            midnight = next
        }
        return times.sorted()
    }
}

// MARK: - The shared file

/// Where the snapshot lives in the App Group container.
public nonisolated enum WidgetSnapshotFile {
    /// The App Group both the app and its widgets are entitled to. macOS
    /// uses the team-prefixed form, which a Mac app signed by that team can
    /// use without a provisioning profile; iOS requires the `group.` form.
    #if os(macOS)
    public static let appGroup = "L6PBP46NZU.com.tyvillan.grasp"
    #else
    public static let appGroup = "group.com.tyvillan.grasp"
    #endif

    public static let fileName = "widget-snapshot.json"

    public static func url() -> URL? {
        #if canImport(Darwin)
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
        #else
        // No App Groups (or widgets) off Apple platforms.
        nil
        #endif
    }

    public static func read(from url: URL? = url()) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    public static func write(_ snapshot: WidgetSnapshot, to url: URL? = url()) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
