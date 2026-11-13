import Foundation
import GRASPCore

/// Questions already understood come up less in a test. Each one makes it
/// into a test only one time in four; the rest of the room goes to
/// questions still being learned. When those run short, understood ones
/// fill the test, so a test is never smaller for it.
enum QuestionPicking {
    static let understoodChance = 0.25

    /// `items` split in two: the ones a test should pick from first, and
    /// the understood ones held back this time, to fill in only if needed.
    static func split<T, R: RandomNumberGenerator>(_ items: [T], isUnderstood: (T) -> Bool,
                                                   using rng: inout R) -> (first: [T], heldBack: [T]) {
        var first: [T] = [], heldBack: [T] = []
        for item in items {
            if isUnderstood(item), Double.random(in: 0..<1, using: &rng) >= understoodChance {
                heldBack.append(item)
            } else {
                first.append(item)
            }
        }
        return (first, heldBack)
    }

    /// Up to `count` of `items`, held-back understood ones only after the rest.
    static func favorUnlearned<T, R: RandomNumberGenerator>(_ items: [T], count: Int, isUnderstood: (T) -> Bool,
                                                           using rng: inout R) -> [T] {
        let (first, heldBack) = split(items, isUnderstood: isUnderstood, using: &rng)
        return Array((first.shuffled(using: &rng) + heldBack.shuffled(using: &rng)).prefix(count))
    }
}

extension GuideExamples.Item {
    /// The question's key for its understanding meter, as a test asks it.
    var understandingKey: String {
        switch self {
        case .code(let question):
            return QuestionUnderstanding.key(question.kind == .predictOutput ? question.prompt + "\n" + question.code
                                                                            : question.prompt)
        case .choice(let item): return QuestionUnderstanding.key(item.stem)
        case .recall(let prompt, _): return QuestionUnderstanding.key(prompt)
        }
    }
}
