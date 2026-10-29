import Testing
import GRASPCore
@testable import GRASP

/// A seeded generator, so a run is the same every time.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite("Understood questions come up less")
struct QuestionPickingTests {
    @Test("an understood question comes up about a quarter as often as one still being learned")
    func lessOften() {
        // 20 questions, 10 understood (odd numbers), tests of 10.
        let items = Array(0..<20)
        var rng = SplitMix(state: 7)
        var understoodAsked = 0, learningAsked = 0
        for _ in 0..<4000 {
            let picked = QuestionPicking.favorUnlearned(items, count: 10, isUnderstood: { $0 % 2 == 1 }, using: &rng)
            #expect(picked.count == 10 && Set(picked).count == 10)
            for n in picked {
                if n % 2 == 1 { understoodAsked += 1 } else { learningAsked += 1 }
            }
        }
        let ratio = Double(understoodAsked) / Double(learningAsked)
        #expect((0.18...0.32).contains(ratio), "ratio=\(ratio)")
    }

    @Test("a test bigger than the questions still being learned fills in with understood ones")
    func fillsIn() {
        let items = Array(0..<20)
        var rng = SplitMix(state: 11)
        for _ in 0..<500 {
            let picked = QuestionPicking.favorUnlearned(items, count: 19, isUnderstood: { $0 % 2 == 1 }, using: &rng)
            #expect(picked.count == 19)
            // Every one still being learned makes it in; understood ones fill the rest.
            #expect(picked.filter { $0 % 2 == 0 }.count == 10)
        }
    }

    @Test("when everything is understood, about a quarter come first and the test is still full")
    func allUnderstood() {
        let items = Array(0..<400)
        var rng = SplitMix(state: 3)
        let (first, heldBack) = QuestionPicking.split(items, isUnderstood: { _ in true }, using: &rng)
        #expect(first.count + heldBack.count == 400)
        #expect((70...130).contains(first.count), "first=\(first.count)")
        #expect(QuestionPicking.favorUnlearned(items, count: 30, isUnderstood: { _ in true }, using: &rng).count == 30)
    }

    @Test("a guide item's key matches the meter's key for the example")
    func itemKey() {
        let item = GuideExamples.choiceItem(question: "Which is it?\n(a) one\n(b) two\n(c) three\n(d) four\n(e) five",
                                            answer: "(b) two")!
        #expect(GuideExamples.Item.choice(item).understandingKey
                == QuestionUnderstanding.key("Which is it?\n(a) one\n(b) two\n(c) three\n(d) four\n(e) five"))
        #expect(GuideExamples.Item.recall(prompt: "What is a tax?", answer: "x").understandingKey
                == QuestionUnderstanding.key("what is a  tax?"))
    }
}
