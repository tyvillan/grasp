import Foundation
import GRDB

/// The study actions every GRASP app performs the same way -- what's due,
/// grading a card, approving drafts -- as database operations, so the Mac
/// and iPhone `AppStore` and the Windows app share one implementation
/// instead of each keeping a copy that could drift.
public enum Study {
    /// Every active, non-deleted card in these decks that is due now. In
    /// the final week before an exam on their course, order switches from
    /// plain due-date to weakest-retention-first, so cramming spends time
    /// where it matters most. Any one deck's course resolves the exam,
    /// since callers pass decks from a single course.
    public static func dueCards(inDecks deckIds: [String], now: Date = Date(), db: Database) throws -> [Card] {
        let cardIds = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
        guard !cardIds.isEmpty else { return [] }
        var cards = try Card
            .filter(cardIds.contains(Column("id")))
            .filter(Column("deletedAt") == nil)
            .filter(Column("status") == CardStatus.active.rawValue)
            .filter(Column("due") <= now)
            .order(Column("due"))
            .fetchAll(db)

        if let firstDeckId = deckIds.first,
           let deck = try Deck.fetchOne(db, key: firstDeckId),
           let exam = try nearestUpcomingExam(forCourseId: deck.courseId, now: now, db: db),
           ExamBias.isInFinalWeek(now: now, examDate: exam.startsAt) {
            cards.sort { a, b in
                let elapsedA = a.lastReview.map { max(0, now.timeIntervalSince($0) / 86400) } ?? 0
                let elapsedB = b.lastReview.map { max(0, now.timeIntervalSince($0) / 86400) } ?? 0
                let retrievabilityA = FSRS.retrievability(elapsedDays: elapsedA, stability: a.stability)
                let retrievabilityB = FSRS.retrievability(elapsedDays: elapsedB, stability: b.stability)
                return retrievabilityA < retrievabilityB
            }
        }
        return cards
    }

    /// Grades one card via FSRS, persists the new scheduler state, and logs
    /// a `review` row. `source` records which study mode produced the
    /// grade (flashcards, learn, test, ...) for later stats. If this
    /// card's course has an upcoming exam and FSRS would schedule its next
    /// review after that date, the interval is capped to land before it
    /// instead -- a review that lands after the test doesn't help for it.
    public static func grade(_ cardId: String, grade: FSRS.Grade, source: String,
                             now: Date = Date(), db: Database) throws {
        guard var card = try Card.fetchOne(db, key: cardId) else { return }
        let snapshot = FSRS.Snapshot(
            stability: card.stability, difficulty: card.difficulty, reps: card.reps,
            lapses: card.lapses, state: FSRS.CardState(rawValue: card.schedulerState) ?? .new,
            lastReview: card.lastReview
        )
        var result = FSRS.schedule(snapshot, grade: grade, now: now)
        // A parsed card's course comes from its source material; a
        // hand-typed one has no material at all (`materialId == nil`)
        // and must resolve the same way through its deck instead, or
        // it silently never gets exam-biased scheduling like every
        // other card in the same deck does.
        let courseId: String?
        if let materialId = card.materialId {
            courseId = try Material.fetchOne(db, key: materialId)?.courseId
        } else {
            courseId = try String.fetchOne(db, sql: """
                SELECT deck.courseId FROM deckCard
                JOIN deck ON deck.id = deckCard.deckId
                WHERE deckCard.cardId = ? LIMIT 1
                """, arguments: [cardId])
        }
        if let courseId, let exam = try nearestUpcomingExam(forCourseId: courseId, now: now, db: db) {
            result.due = ExamBias.capDue(result.due, examDate: exam.startsAt, now: now)
        }
        let dueBefore = card.due

        card.due = result.due
        card.stability = result.stability
        card.difficulty = result.difficulty
        card.elapsedDays = result.elapsedDays
        card.scheduledDays = result.scheduledDays
        card.reps = result.reps
        card.lapses = result.lapses
        card.schedulerState = result.state.rawValue
        card.lastReview = now
        card.updatedAt = now
        try card.save(db)

        try Review(
            cardId: cardId, reviewedAt: now, grade: grade.rawValue, source: source,
            dueBefore: dueBefore, dueAfter: result.due,
            stabilityAfter: result.stability, difficultyAfter: result.difficulty,
            schedulerVersion: "fsrs-5"
        ).save(db)
    }

    /// Makes every draft card in these decks study-eligible.
    public static func approveDrafts(inDecks deckIds: [String], now: Date = Date(), db: Database) throws {
        let cardIds = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
        try Card
            .filter(cardIds.contains(Column("id")))
            .filter(Column("status") == CardStatus.draft.rawValue)
            .filter(Column("deletedAt") == nil)
            .updateAll(db, Column("status").set(to: CardStatus.active.rawValue), Column("updatedAt").set(to: now))
    }

    /// The soonest exam still in the future for a course, or nil if none
    /// is set -- both `grade`'s interval capping and `dueCards`'s
    /// final-week reordering are no-ops without one. Deadlines and study
    /// blocks are deliberately excluded (see `CalendarEventKind.examLike`):
    /// they share the calendar, not the scheduler's notion of a deadline
    /// every card must be ready for.
    public static func nearestUpcomingExam(forCourseId courseId: String, now: Date, db: Database) throws -> CalendarEvent? {
        try CalendarEvent
            .filter(Column("courseId") == courseId)
            .filter(CalendarEventKind.examLike.map(\.rawValue).contains(Column("kind")))
            // Until the exam is over, not until it starts: an all-day exam
            // is stored at midnight with no end, and "starts >= now"
            // dropped it the moment its own day began.
            .filter(Column("startsAt") >= now.addingTimeInterval(-86400))
            .order(Column("startsAt"))
            .fetchAll(db)
            .first { event in
                let over = event.isAllDay
                    ? event.startsAt.addingTimeInterval(86400)
                    : (event.endsAt ?? event.startsAt)
                return over >= now
            }
    }
}
