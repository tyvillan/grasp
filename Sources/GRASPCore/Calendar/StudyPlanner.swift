import Foundation

/// Turns "120 cards and an exam two weeks out" into a day-by-day plan.
///
/// The shape of the plan is the opinion here, and it's front-loaded on
/// purpose: spacing works because material is seen early and then again
/// later, so a plan that leaves half the deck untouched until the last two
/// days is cramming with extra steps. Each day covers its own share plus
/// revisits what came before, and the final day before the exam is a light
/// pass over everything rather than a wall of new cards.
public enum StudyPlanner {

    public struct Block: Equatable, Sendable {
        public let day: Date
        /// How many cards this block is for -- new material for that day,
        /// which the review load on top of it is deliberately not counted
        /// into (that's what FSRS's own due queue is for).
        public let cardCount: Int
        /// True for the last block before the exam: a sweep of everything
        /// rather than a slice of new material.
        public let isFinalReview: Bool

        public init(day: Date, cardCount: Int, isFinalReview: Bool) {
            self.day = day; self.cardCount = cardCount; self.isFinalReview = isFinalReview
        }
    }

    /// Nobody keeps a 200-card day, and a plan that asks for one gets
    /// abandoned on day two. Past this the plan stops spreading and simply
    /// admits the deck is bigger than the time left.
    public static let maxCardsPerDay = 60
    /// Below this, splitting across days produces a plan of trivia ("4
    /// cards today") rather than a study session worth opening the app for.
    public static let minCardsPerDay = 5

    /// One block per study day between `from` and the day before `examDate`.
    ///
    /// Returns an empty plan rather than a bad one when there's no room to
    /// schedule: an exam today or in the past, or no cards to cover.
    public static func plan(
        cardCount: Int, from start: Date, examDate: Date,
        calendar: Calendar = .current, maxPerDay: Int = maxCardsPerDay
    ) -> [Block] {
        guard cardCount > 0 else { return [] }
        let firstDay = calendar.startOfDay(for: start)
        let examDay = calendar.startOfDay(for: examDate)
        guard let daysAvailable = calendar.dateComponents([.day], from: firstDay, to: examDay).day,
              daysAvailable >= 1
        else { return [] }

        // The last day before the exam is the final review pass, so new
        // material has to fit in the days before it -- unless the exam is
        // tomorrow, in which case that one day is all there is and it
        // carries the deck.
        let studyDays = max(1, daysAvailable - 1)
        let perDay = min(maxPerDay, max(minCardsPerDay, Int(ceil(Double(cardCount) / Double(studyDays)))))

        var blocks: [Block] = []
        var remaining = cardCount
        for offset in 0..<studyDays {
            guard remaining > 0, let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { break }
            // The last study day absorbs whatever `perDay` couldn't fit
            // rather than capping at it too -- every card has to land
            // somewhere, and a fixed number of days for a deck bigger than
            // `maxPerDay * studyDays` means that day runs long, not that
            // the rest of the deck quietly never gets introduced at all.
            let isLastStudyDay = offset == studyDays - 1
            let count = isLastStudyDay ? remaining : min(perDay, remaining)
            blocks.append(Block(day: day, cardCount: count, isFinalReview: false))
            remaining -= count
        }

        if daysAvailable >= 2, let finalDay = calendar.date(byAdding: .day, value: daysAvailable - 1, to: firstDay) {
            blocks.append(Block(day: finalDay, cardCount: cardCount, isFinalReview: true))
        }
        return blocks
    }

    /// What a generated block is called on the calendar. Kept here so the
    /// plan and anything later reading it back agree on the wording.
    public static func blockTitle(courseName: String?, block: Block) -> String {
        let subject = courseName ?? "Study"
        if block.isFinalReview { return "\(subject): final review" }
        return "\(subject): \(block.cardCount) cards"
    }
}
