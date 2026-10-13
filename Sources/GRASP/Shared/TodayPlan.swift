import Foundation
import GRASPCore

/// Home's "Today's plan": two to four steps for today, each with a time
/// estimate. Read-only and made of what the app already knows -- each
/// upcoming exam's `ExamPlan` steps (due reviews, weak spots, a practice
/// test, problems) and the deck you were last working through. Nothing is
/// scheduled or stored except which steps you ticked off today.
struct TodayPlan {
    struct Step: Identifiable, Equatable {
        enum Action: Equatable {
            /// Review these decks' due cards.
            case review(deckIds: [String], name: String)
            /// Open an exam's study page (weak spots, tests, problems).
            case openExam(eventId: String)
            /// Keep going through a deck.
            case continueDeck(courseId: String, deckId: String, name: String)
        }

        let id: String
        let title: String
        let subtitle: String
        let minutes: Int
        let action: Action
    }

    var steps: [Step]
    var minutes: Int { steps.reduce(0) { $0 + $1.minutes } }

    static let maxSteps = 4

    /// The review step's title. When the exam covers only some of the
    /// course's decks, it says so ("Review 139 of 155 due for the midterm");
    /// when everything due is in scope it is the plain "Review N due cards".
    static func reviewTitle(due: Int, courseDue: Int, examNoun: String) -> String {
        if courseDue > due, due > 0 {
            return "Review \(due) of \(courseDue) due for the \(examNoun)"
        }
        return "Review \(due) due card\(due == 1 ? "" : "s")"
    }

    /// "midterm", "final", "quiz" or "exam", from the event's own title.
    static func examNoun(title: String, kind: CalendarEventKind) -> String {
        let lower = title.lowercased()
        if lower.contains("midterm") { return "midterm" }
        if lower.contains("final") { return "final" }
        if lower.contains("quiz") || kind == .quiz { return "quiz" }
        return "exam"
    }

    /// Seconds per card, from what a review actually takes: about ten for
    /// a due card, a little longer for one still being learned.
    static func estimate(cards: Int, secondsEach: Double) -> Int {
        max(1, Int((Double(cards) * secondsEach / 60).rounded(.up)))
    }
}

extension AppStore {
    /// Today's plan over the next exams (within `ExamPlan.horizonDays`) and
    /// the deck in progress.
    func todayPlan(exams: [UpcomingEvent], decks: [DeckSummary], now: Date = Date()) -> TodayPlan {
        var steps: [TodayPlan.Step] = []
        var coveredDecks = Set<String>()

        for (rank, item) in exams.enumerated() where daysUntil(item.event, now: now) <= ExamPlan.horizonDays {
            let deckIds = planDeckIds(for: item.event)
            guard !deckIds.isEmpty else { continue }
            let standing = examStanding(deckIds: deckIds, now: now)
            let planned = ExamPlan.steps(daysAway: daysUntil(item.event, now: now), standing: standing)
            let course = item.courseName ?? item.event.title
            // The nearest exam gets up to two steps, later ones one each.
            for step in planned.prefix(rank == 0 ? 2 : 1) {
                let id = "\(item.event.id)#\(step.kind.rawValue)"
                switch step.kind {
                case .review:
                    let courseDue = decks.filter { $0.courseId == item.event.courseId }.reduce(0) { $0 + $1.dueCount }
                    let title = TodayPlan.reviewTitle(
                        due: standing.dueCards, courseDue: courseDue,
                        examNoun: TodayPlan.examNoun(title: item.event.title, kind: item.event.kind))
                    steps.append(.init(id: id, title: title, subtitle: course,
                                       minutes: TodayPlan.estimate(cards: standing.dueCards, secondsEach: 10),
                                       action: .review(deckIds: deckIds, name: item.event.title)))
                    coveredDecks.formUnion(deckIds)
                case .weakSpots:
                    steps.append(.init(id: id, title: step.text, subtitle: course,
                                       minutes: max(3, TodayPlan.estimate(cards: standing.weakCards, secondsEach: 48)),
                                       action: .openExam(eventId: item.event.id)))
                case .test, .learn:
                    steps.append(.init(id: id, title: step.text, subtitle: course, minutes: 10,
                                       action: .openExam(eventId: item.event.id)))
                case .problems:
                    steps.append(.init(id: id, title: step.text, subtitle: course, minutes: 15,
                                       action: .openExam(eventId: item.event.id)))
                case .rest:
                    steps.append(.init(id: id, title: step.text, subtitle: course, minutes: 5,
                                       action: .openExam(eventId: item.event.id)))
                }
            }
            if steps.count >= TodayPlan.maxSteps - 1 { break }
        }

        // The deck you were working through, if it still has cards waiting
        // and an exam step above doesn't already cover it.
        if let deck = Dashboard.jumpBackIn(decks), deck.dueCount > 0, !coveredDecks.contains(deck.deckId) {
            steps.append(.init(
                id: "deck#\(deck.deckId)",
                title: "Finish \(deck.deckName), \(deck.dueCount) card\(deck.dueCount == 1 ? "" : "s") left",
                subtitle: deck.courseName,
                minutes: TodayPlan.estimate(cards: deck.dueCount, secondsEach: 12),
                action: .continueDeck(courseId: deck.courseId, deckId: deck.deckId, name: deck.deckName)))
        }

        // No exams coming: the due queue is the plan.
        if steps.isEmpty {
            let due = decks.filter { $0.dueCount > 0 }.sorted { $0.dueCount > $1.dueCount }
            for deck in due.prefix(3) {
                steps.append(.init(
                    id: "due#\(deck.deckId)",
                    title: "Review \(deck.dueCount) due card\(deck.dueCount == 1 ? "" : "s") in \(deck.deckName)",
                    subtitle: deck.courseName,
                    minutes: TodayPlan.estimate(cards: deck.dueCount, secondsEach: 10),
                    action: .review(deckIds: [deck.deckId], name: deck.deckName)))
            }
        }
        return TodayPlan(steps: Array(steps.prefix(TodayPlan.maxSteps)))
    }
}
