import Foundation

/// What to do today to be ready for an exam: a short, honest checklist
/// built from how close it is and where the student stands, not a
/// schedule to fall behind on.
public enum ExamPlan {
    public struct Step: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case review, learn, test, weakSpots, problems, rest }
        public var kind: Kind
        public var text: String
        public var id: String { kind.rawValue }
    }

    public struct Standing: Sendable {
        public var dueCards: Int
        public var activeCards: Int
        public var weakCards: Int
        public var savedProblems: Int
        /// Days since the last finished test over these decks, nil if never.
        public var daysSinceTest: Int?

        public init(dueCards: Int, activeCards: Int, weakCards: Int, savedProblems: Int, daysSinceTest: Int?) {
            self.dueCards = dueCards; self.activeCards = activeCards; self.weakCards = weakCards
            self.savedProblems = savedProblems; self.daysSinceTest = daysSinceTest
        }
    }

    /// Plans only start two weeks out; earlier than that the due queue is
    /// the whole job.
    public static let horizonDays = 14

    public static func steps(daysAway: Int, standing s: Standing) -> [Step] {
        guard daysAway <= horizonDays, s.activeCards > 0 else { return [] }
        var steps: [Step] = []
        if daysAway <= 0 { return [Step(kind: .rest, text: "Exam day: skim your weak spots, then stop.")] }
        if s.dueCards > 0 {
            steps.append(Step(kind: .review, text: "Review \(s.dueCards) due card\(s.dueCards == 1 ? "" : "s")"))
        } else if daysAway > 7 {
            steps.append(Step(kind: .learn, text: "Nothing due: run a Learn round on new cards"))
        }
        if daysAway <= 7 {
            if s.weakCards > 0 {
                steps.append(Step(kind: .weakSpots, text: "Drill \(s.weakCards) weak spot\(s.weakCards == 1 ? "" : "s") in a test"))
            } else if s.daysSinceTest == nil || (s.daysSinceTest ?? 0) >= 2 {
                steps.append(Step(kind: .test, text: s.daysSinceTest == nil ? "Take a first practice test" : "Take a practice test"))
            }
        }
        if daysAway <= 3, s.savedProblems > 0 {
            steps.append(Step(kind: .problems, text: "Work through some of the \(s.savedProblems) practice problems"))
        }
        if daysAway == 1 {
            steps.append(Step(kind: .rest, text: "Keep it light tonight and get sleep"))
        }
        return steps
    }
}
