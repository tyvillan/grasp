import Foundation
import Testing
@testable import GRASPCore

@Suite struct LearnStreakTests {
    @Test func staysOffUntilThreeRightInARow() {
        var s = LearnStreak()
        s = s.after(correct: true); #expect(!s.isOn)
        s = s.after(correct: true); #expect(!s.isOn)
        s = s.after(correct: true); #expect(s.isOn)
        #expect(s.count == 3)
        #expect(s.headline == "3 correct in a row")
    }

    @Test func keepsCountingUntilAMiss() {
        var s = LearnStreak(count: 3)
        for _ in 0..<4 { s = s.after(correct: true) }
        #expect(s.count == 7 && s.isOn)
        s = s.after(correct: false)
        #expect(s.count == 0 && !s.isOn)
    }

    @Test func aMissBeforeThreeJustResets() {
        let s = LearnStreak(count: 2).after(correct: false)
        #expect(s.count == 0)
    }

    @Test func endedCaptionOnlyWhenAStreakWasOnAndMissed() {
        #expect(LearnStreak(count: 5).endedCaption(afterMiss: true) == "Streak ended at 5. Start a new one.")
        #expect(LearnStreak(count: 2).endedCaption(afterMiss: true) == nil)
        #expect(LearnStreak(count: 5).endedCaption(afterMiss: false) == nil)
    }

    @Test func negativeCountClampsToZero() {
        #expect(LearnStreak(count: -4).count == 0)
    }
}

@Suite struct LearnStreakStoreTests {
    private func fresh() -> UserDefaults {
        let name = "streak-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func startsAtZero() {
        #expect(LearnStreakStore(defaults: fresh()).load().count == 0)
    }

    @Test func survivesReopening() {
        let d = fresh()
        LearnStreakStore(defaults: d).save(LearnStreak(count: 6))
        #expect(LearnStreakStore(defaults: d).load() == LearnStreak(count: 6))
    }

    @Test func aMissClearsTheSavedStreak() {
        let d = fresh()
        let store = LearnStreakStore(defaults: d)
        store.save(LearnStreak(count: 6))
        store.save(store.load().after(correct: false))
        #expect(LearnStreakStore(defaults: d).load().count == 0)
    }
}
