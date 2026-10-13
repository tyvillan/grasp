import Testing
import Foundation
@testable import GRASP

@Suite("Study flow polish")
struct StudyFlowTests {
    @Test("the finish screen's follow-on names how many cards were missed")
    func nextStepTitles() {
        #expect(StudyNextStep.learnMissed(["a"]).title == "Learn the 1 you missed")
        #expect(StudyNextStep.learnMissed(["a", "b", "c"]).title == "Learn the 3 you missed")
        #expect(StudyNextStep.test.title == "Take a test")
    }

    @Test("the calendar legend ranges match the bands the dots use")
    func legendMatchesBands() {
        #expect(WorkloadLevel(cardCount: 20) == .light && WorkloadLevel.light.rangeText == "1 to 20")
        #expect(WorkloadLevel(cardCount: 21) == .moderate && WorkloadLevel.moderate.rangeText == "21 to 50")
        #expect(WorkloadLevel(cardCount: 51) == .heavy && WorkloadLevel.heavy.rangeText == "Over 50")
    }
}
