import Foundation
import GRASPCore
import GRDB

/// Home's "Today's plan", ported from the Mac's app layer
/// (`Sources/GRASP/Shared/TodayPlan.swift`, `AppStore.examStanding`): two to
/// four steps for today, each with a time estimate, made of each upcoming
/// exam's `ExamPlan` steps and the deck in progress. Nothing is stored except
/// which steps were ticked off today (`AppSettings.todayPlanChecked`).
struct TodayPlan {
    struct Step: Equatable {
        enum Action: Equatable {
            /// Review these decks' due cards.
            case review(courseId: String, deckId: String?)
            /// Open an exam's study page.
            case openExam(eventId: String)
            /// Keep going through a deck.
            case continueDeck(courseId: String, deckId: String)
        }

        let id: String
        let title: String
        let subtitle: String
        let minutes: Int
        let action: Action
    }

    var steps: [Step]

    static let maxSteps = 4

    static func reviewTitle(due: Int, courseDue: Int, examNoun: String) -> String {
        if courseDue > due, due > 0 {
            return "Review \(due) of \(courseDue) due for the \(examNoun)"
        }
        return "Review \(due) due card\(due == 1 ? "" : "s")"
    }

    static func examNoun(title: String, kind: CalendarEventKind) -> String {
        let lower = title.lowercased()
        if lower.contains("midterm") { return "midterm" }
        if lower.contains("final") { return "final" }
        if lower.contains("quiz") || kind == .quiz { return "quiz" }
        return "exam"
    }

    static func estimate(cards: Int, secondsEach: Double) -> Int {
        max(1, Int((Double(cards) * secondsEach / 60).rounded(.up)))
    }
}

/// What Home reads once per library revision: the next exams, where each
/// stands, the plan and today's test count. Cached, since every redraw of
/// Home reads it and the standing queries touch several tables.
struct HomeSnapshot {
    var exams: [CalendarEvent]
    var standings: [String: ExamPlan.Standing]
    var plan: TodayPlan
    var testsToday: Int
}

extension Library {
    func homeSnapshot(now: Date = Date()) -> HomeSnapshot {
        let key = "\(revision)|\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)"
        if let cached = homeCache, cached.key == key { return cached.value }
        let exams = upcomingExams(within: 30, limit: 4)
        var standings: [String: ExamPlan.Standing] = [:]
        for event in exams {
            let ids = planDeckIds(for: event)
            if !ids.isEmpty { standings[event.id] = examStanding(deckIds: ids, now: now) }
        }
        let decks = dashboardDecks()
        let plan = todayPlan(exams: exams, standings: standings, decks: decks, now: now)
        let midnight = Calendar.current.startOfDay(for: now)
        let tests = (try? database.queue.read { db in
            try TestAttempt.filter(Column("finishedAt") >= midnight).fetchCount(db)
        }) ?? 0
        let value = HomeSnapshot(exams: exams, standings: standings, plan: plan, testsToday: tests)
        homeCache = (key, value)
        return value
    }

    /// The decks an exam is about: its study guide's lectures, else its own
    /// deck, else the whole course (the Mac's `planDeckIds`).
    func planDeckIds(for event: CalendarEvent) -> [String] {
        var ids = (try? database.queue.read { try StudyGuideActions.examDeckIds(examEventId: event.id, db: $0) }) ?? []
        if ids.isEmpty, let deckId = event.deckId { ids = [deckId] }
        if ids.isEmpty, let courseId = event.courseId { ids = decks(inCourse: courseId).map(\.id) }
        return ids
    }

    func examStanding(deckIds: [String], now: Date = Date()) -> ExamPlan.Standing {
        (try? database.queue.read { db in
            let active = try Study.learnCandidates(forDecks: deckIds, db: db).count
            let due = try Study.dueCards(inDecks: deckIds, now: now, db: db).count
            let weak = try Study.weakCardIds(forDecks: deckIds, db: db).count
            let problems = try CodeQuestionBank.count(inDecks: deckIds, db: db)
            let last = try Study.testHistory(forDecks: deckIds, limit: 1, db: db).last?.startedAt
            let since = last.flatMap { Calendar.current.dateComponents([.day], from: $0, to: now).day }
            return ExamPlan.Standing(dueCards: due, activeCards: active, weakCards: weak,
                                     savedProblems: problems, daysSinceTest: since)
        }) ?? ExamPlan.Standing(dueCards: 0, activeCards: 0, weakCards: 0, savedProblems: 0, daysSinceTest: nil)
    }

    /// Whole days from today to the event (0 on the day).
    func daysUntil(_ event: CalendarEvent, now: Date = Date()) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                               to: Calendar.current.startOfDay(for: event.startsAt)).day ?? 0)
    }

    private func todayPlan(exams: [CalendarEvent], standings: [String: ExamPlan.Standing],
                           decks: [Dashboard.DeckSummary], now: Date) -> TodayPlan {
        var steps: [TodayPlan.Step] = []
        var coveredDecks = Set<String>()

        for (rank, event) in exams.enumerated() where daysUntil(event, now: now) <= ExamPlan.horizonDays {
            let deckIds = planDeckIds(for: event)
            guard !deckIds.isEmpty, let standing = standings[event.id] else { continue }
            let planned = ExamPlan.steps(daysAway: daysUntil(event, now: now), standing: standing)
            let course = event.courseId.flatMap { courseName($0) } ?? event.title
            // The nearest exam gets up to two steps, later ones one each.
            for step in planned.prefix(rank == 0 ? 2 : 1) {
                let id = "\(event.id)#\(step.kind.rawValue)"
                switch step.kind {
                case .review:
                    let courseDue = decks.filter { $0.courseId == event.courseId }.reduce(0) { $0 + $1.dueCount }
                    let title = TodayPlan.reviewTitle(
                        due: standing.dueCards, courseDue: courseDue,
                        examNoun: TodayPlan.examNoun(title: event.title, kind: event.kind))
                    steps.append(.init(id: id, title: title, subtitle: course,
                                       minutes: TodayPlan.estimate(cards: standing.dueCards, secondsEach: 10),
                                       action: .review(courseId: event.courseId ?? "", deckId: studyTarget(for: event))))
                    coveredDecks.formUnion(deckIds)
                case .weakSpots:
                    steps.append(.init(id: id, title: step.text, subtitle: course,
                                       minutes: max(3, TodayPlan.estimate(cards: standing.weakCards, secondsEach: 48)),
                                       action: .openExam(eventId: event.id)))
                case .test, .learn:
                    steps.append(.init(id: id, title: step.text, subtitle: course, minutes: 10,
                                       action: .openExam(eventId: event.id)))
                case .problems:
                    steps.append(.init(id: id, title: step.text, subtitle: course, minutes: 15,
                                       action: .openExam(eventId: event.id)))
                case .rest:
                    steps.append(.init(id: id, title: step.text, subtitle: course, minutes: 5,
                                       action: .openExam(eventId: event.id)))
                }
            }
            if steps.count >= TodayPlan.maxSteps - 1 { break }
        }

        if let deck = Dashboard.jumpBackIn(decks), deck.dueCount > 0, !coveredDecks.contains(deck.deckId) {
            steps.append(.init(
                id: "deck#\(deck.deckId)",
                title: "Finish \(deck.deckName), \(deck.dueCount) card\(deck.dueCount == 1 ? "" : "s") left",
                subtitle: deck.courseName,
                minutes: TodayPlan.estimate(cards: deck.dueCount, secondsEach: 12),
                action: .continueDeck(courseId: deck.courseId, deckId: deck.deckId)))
        }

        if steps.isEmpty {
            let due = decks.filter { $0.dueCount > 0 }.sorted { $0.dueCount > $1.dueCount }
            for deck in due.prefix(3) {
                steps.append(.init(
                    id: "due#\(deck.deckId)",
                    title: "Review \(deck.dueCount) due card\(deck.dueCount == 1 ? "" : "s") in \(deck.deckName)",
                    subtitle: deck.courseName,
                    minutes: TodayPlan.estimate(cards: deck.dueCount, secondsEach: 10),
                    action: .continueDeck(courseId: deck.courseId, deckId: deck.deckId)))
            }
        }
        return TodayPlan(steps: Array(steps.prefix(TodayPlan.maxSteps)))
    }
}
