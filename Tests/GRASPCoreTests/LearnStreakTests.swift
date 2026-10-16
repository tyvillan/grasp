import Foundation
import GRDB
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

@Suite struct LearnStreakSavedTests {
    @Test func startsAtZero() throws {
        let db = try GRASPDatabase.inMemory()
        #expect(try db.queue.read { try Study.learnStreak(db: $0) }.count == 0)
    }

    @Test func savesAndReloads() throws {
        let db = try GRASPDatabase.inMemory()
        try db.queue.write { try Study.saveLearnStreak(LearnStreak(count: 6), db: $0) }
        #expect(try db.queue.read { try Study.learnStreak(db: $0) } == LearnStreak(count: 6))
    }

    @Test func aMissClearsIt() throws {
        let db = try GRASPDatabase.inMemory()
        try db.queue.write { try Study.saveLearnStreak(LearnStreak(count: 6), db: $0) }
        try db.queue.write { try Study.saveLearnStreak(LearnStreak(count: 6).after(correct: false), db: $0) }
        #expect(try db.queue.read { try Study.learnStreak(db: $0) }.count == 0)
    }

    @Test func zeroOnAnEmptyLibraryWritesNothing() throws {
        let db = try GRASPDatabase.inMemory()
        try db.queue.write { try Study.saveLearnStreak(LearnStreak(count: 0), db: $0) }
        #expect(try db.queue.read { try LearnStreakRow.fetchCount($0) } == 0)
    }

    @Test func theStreakIsASyncedTable() {
        #expect(SyncSchema.table(named: "learnStreak")?.primaryKey == ["id"])
    }

    @Test func theStreakReachesTheOtherDevice() async throws {
        let server = SyncEngineTests.MemoryServer()
        let mac = try GRASPDatabase.inMemory(), phone = try GRASPDatabase.inMemory()
        let macSync = SyncEngine(database: mac), phoneSync = SyncEngine(database: phone)
        try macSync.enable(accountUserId: "u", uploadExisting: true)
        try phoneSync.enable(accountUserId: "u", uploadExisting: false)

        try await mac.queue.write { try Study.saveLearnStreak(LearnStreak(count: 4), db: $0) }
        try await macSync.sync(using: server)
        try await phoneSync.sync(using: server)
        #expect(try await phone.queue.read { try Study.learnStreak(db: $0) }.count == 4)

        // The phone carries on, then a miss there ends it on the Mac too.
        try await phone.queue.write { try Study.saveLearnStreak(LearnStreak(count: 5), db: $0) }
        try await phone.queue.write { try Study.saveLearnStreak(LearnStreak(count: 5).after(correct: false), db: $0) }
        try await phoneSync.sync(using: server)
        try await macSync.sync(using: server)
        #expect(try await mac.queue.read { try Study.learnStreak(db: $0) }.count == 0)
    }
}
