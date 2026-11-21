import Foundation

/// Which parts of a study guide the student is weakest on, for the "Where
/// you're weak" list on an exam's page. Built only from what GRASP already
/// keeps: the student's ratings of each skill and how well each worked
/// example is understood (which every test answer updates).
public enum WeakSpots {
    public struct Spot: Identifiable, Sendable, Equatable {
        public var id: String { partId }
        public let partId: String
        public let partNumber: Int?
        public let partTitle: String
        public let deckIds: [String]
        /// Skills rated "can't yet" first, then "shaky", worded as the guide has them.
        public let weakSkills: [String]
        /// Worked examples asked and missed, or never asked, out of `exampleCount`.
        public let missedExamples: Int
        public let untriedExamples: Int
        public let exampleCount: Int
        public let score: Double
    }

    /// The parts with something to work on, weakest first. A part everything
    /// is understood in does not appear.
    public static func rank(parts: [StudyGuideActions.PagePart], states: [String: UnderstandingState],
                            limit: Int = 5) -> [Spot] {
        var spots: [Spot] = []
        for part in parts {
            let cantYet = part.skills.filter { $0.rating == .cantYet }.map(\.text)
            let shaky = part.skills.filter { $0.rating == .shaky }.map(\.text)
            var missed = 0, untried = 0, total = 0
            for item in part.examples where item.example.answer?.isEmpty == false {
                total += 1
                let state = states[QuestionUnderstanding.key(of: item.example)]
                if state?.isMastered == true || state?.isSelfRated == true { continue }
                if state?.asked == true { missed += 1 } else { untried += 1 }
            }
            let score = 3 * Double(cantYet.count) + 1.5 * Double(shaky.count) + 2 * Double(missed) + 0.5 * Double(untried)
            guard score > 0 else { continue }
            spots.append(Spot(partId: part.id, partNumber: part.number, partTitle: part.title, deckIds: part.deckIds,
                              weakSkills: cantYet + shaky, missedExamples: missed, untriedExamples: untried,
                              exampleCount: total, score: score))
        }
        return Array(spots.sorted { $0.score > $1.score }.prefix(limit))
    }
}

extension StudyGuideActions.ExamPage {
    /// The same page with only some parts, so a test built from it asks about those.
    public func restricted(toParts partIds: Set<String>) -> StudyGuideActions.ExamPage {
        StudyGuideActions.ExamPage(
            exam: exam, guides: guides, questionCount: questionCount, format: format, notes: notes,
            parts: parts.filter { partIds.contains($0.id) }, unreadGuides: unreadGuides, isPracticeSet: isPracticeSet)
    }
}
