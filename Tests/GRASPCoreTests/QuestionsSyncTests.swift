import Foundation
import Testing
import GRDB
@testable import GRASPCore

@Suite("Questions and sync")
struct QuestionsSyncTests {
    private struct Device {
        let db: GRASPDatabase
        let engine: SyncEngine
        init() throws { db = try GRASPDatabase.inMemory(); engine = SyncEngine(database: db) }
    }

    private func seed(_ device: Device) throws -> (courseId: String, deckId: String) {
        try device.db.queue.write { db in
            let course = Course(semesterId: nil, name: "Anthropology"); try course.insert(db)
            let deck = Deck(courseId: course.id, name: "Module 1"); try deck.insert(db)
            return (course.id, deck.id)
        }
    }

    private func question(_ ids: (courseId: String, deckId: String), status: QuestionStatus,
                          source: QuestionSource = .yours, card: String? = nil) -> TestQuestion {
        let problem = ProblemQuestion(kind: .multipleChoice, subject: .concepts, prompt: "Which?", choices: ["A", "B"], correct: 0)
        return TestQuestion(courseId: ids.courseId, deckId: ids.deckId, problem: problem, bodyJSON: problem.encoded() ?? "{}",
                            verifiedBy: "by hand", source: source, status: status, cardId: card)
    }

    private func queued(_ device: Device, table: String = "testQuestion") throws -> Int {
        try device.db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncOutbox WHERE tableName = ?", arguments: [table]) ?? 0
        }
    }

    @Test("a draft is never queued to sync, an active or suspended question is")
    func draftsStayLocal() throws {
        let device = try Device()
        let ids = try seed(device)
        try device.engine.enable(accountUserId: "u", uploadExisting: false)
        try device.db.queue.write { db in
            try question(ids, status: .draft, source: .ai).insert(db)
            try question(ids, status: .active).insert(db)
            try question(ids, status: .suspended).insert(db)
        }
        #expect(try queued(device) == 2)
    }

    @Test("approving a draft sends it; editing a draft sends nothing")
    func approvingSends() throws {
        let device = try Device()
        let ids = try seed(device)
        try device.engine.enable(accountUserId: "u", uploadExisting: false)
        let draft = question(ids, status: .draft, source: .ai)
        try device.db.queue.write { try draft.insert($0) }
        try device.db.queue.write { db in
            var edited = draft
            edited.bodyJSON = "{\"edited\":true}"
            try edited.save(db)
        }
        #expect(try queued(device) == 0)
        try device.db.queue.write { try QuestionBank.setStatus(draft.id, to: .active, db: $0) }
        #expect(try queued(device) == 1)
    }

    @Test("uploading an existing library leaves drafts behind")
    func uploadSkipsDrafts() throws {
        let device = try Device()
        let ids = try seed(device)
        try device.db.queue.write { db in
            try question(ids, status: .draft, source: .ai).insert(db)
            try question(ids, status: .active).insert(db)
        }
        try device.engine.enable(accountUserId: "u", uploadExisting: true)
        #expect(try queued(device) == 1)
    }

    @Test("a draft that reached the outbox some other way is still never sent")
    func pushDropsDrafts() async throws {
        let server = SyncEngineTests.MemoryServer()
        let device = try Device()
        let ids = try seed(device)
        try device.engine.enable(accountUserId: "u", uploadExisting: false)
        let draft = question(ids, status: .draft, source: .ai)
        try await device.db.queue.write { db in
            try draft.insert(db)
            try db.execute(sql: "INSERT OR REPLACE INTO syncOutbox (tableName, rowKey, seq) VALUES ('testQuestion', ?, 9999)",
                           arguments: [draft.id])
        }
        try await device.engine.sync(using: server)
        let rows = try await server.pull(since: nil, offset: 0, limit: 100)
        #expect(!rows.contains { $0.table == "testQuestion" })
        #expect(try queued(device) == 0)
    }

    @Test("a question round-trips between devices with its source, status and card link")
    func roundTrip() async throws {
        let server = SyncEngineTests.MemoryServer()
        let mac = try Device(), phone = try Device()
        let ids = try seed(mac)
        try mac.engine.enable(accountUserId: "u", uploadExisting: true)
        let saved = question(ids, status: .active, card: "card-1")
        try await mac.db.queue.write { try saved.insert($0) }
        try await mac.engine.sync(using: server)
        try phone.engine.enable(accountUserId: "u", uploadExisting: false)
        try await phone.engine.sync(using: server)
        let got = try #require(try await phone.db.queue.read { try TestQuestion.fetchOne($0, key: saved.id) })
        #expect(got.source == "yours" && got.status == "active" && got.cardId == "card-1")
        // Suspending on the phone reaches the Mac.
        try await phone.db.queue.write { try QuestionBank.setStatus(saved.id, to: .suspended, db: $0) }
        try await phone.engine.sync(using: server)
        try await mac.engine.sync(using: server)
        #expect(try await mac.db.queue.read { try TestQuestion.fetchOne($0, key: saved.id) }?.status == "suspended")
    }

    @Test("a row from an older app, with none of the new columns, lands with the defaults")
    func oldShapeRow() async throws {
        let server = SyncEngineTests.MemoryServer()
        let phone = try Device()
        let ids = try seed(phone)
        try phone.engine.enable(accountUserId: "u", uploadExisting: false)
        let old: [String: SyncValue] = [
            "id": .text("old-q"), "courseId": .text(ids.courseId), "deckId": .text(ids.deckId),
            "kind": .text("multipleChoice"), "language": .text("concepts"), "bodyJSON": .text("{}"),
            "verifiedBy": .text("a second pass agreed on the answer"), "createdAt": .text("2026-10-14 10:00:00.000"),
        ]
        try await server.push([SyncRecord(table: "testQuestion", rowKey: "old-q", data: old, deleted: false, deviceId: "old")])
        try await phone.engine.sync(using: server)
        let got = try #require(try await phone.db.queue.read { try TestQuestion.fetchOne($0, key: "old-q") })
        #expect(got.source == "ai" && got.status == "active" && got.cardId == nil)
    }

    @Test("a row from a newer app with columns this version lacks is still applied")
    func newerShapeRow() async throws {
        let server = SyncEngineTests.MemoryServer()
        let phone = try Device()
        let ids = try seed(phone)
        try phone.engine.enable(accountUserId: "u", uploadExisting: false)
        let future: [String: SyncValue] = [
            "id": .text("future-q"), "courseId": .text(ids.courseId), "deckId": .text(ids.deckId),
            "kind": .text("multipleChoice"), "language": .text("concepts"), "bodyJSON": .text("{}"),
            "verifiedBy": .text("by hand"), "createdAt": .text("2026-10-14 10:00:00.000"),
            "source": .text("yours"), "status": .text("active"), "somethingNew": .text("ignored"),
        ]
        try await server.push([SyncRecord(table: "testQuestion", rowKey: "future-q", data: future, deleted: false, deviceId: "x")])
        try await phone.engine.sync(using: server)
        #expect(try await phone.db.queue.read { try TestQuestion.fetchOne($0, key: "future-q") }?.source == "yours")
    }

    @Test("a test item's question link syncs with the item")
    func itemLinkSyncs() async throws {
        let server = SyncEngineTests.MemoryServer()
        let mac = try Device(), phone = try Device()
        let ids = try seed(mac)
        try mac.engine.enable(accountUserId: "u", uploadExisting: true)
        let saved = question(ids, status: .active)
        try await mac.db.queue.write { db in
            try saved.insert(db)
            let attempt = TestAttempt(deckId: ids.deckId, configJSON: "{}"); try attempt.insert(db)
            try TestItem(id: "item-1", attemptId: attempt.id, cardId: nil, ordinal: 0, questionType: "problem",
                         promptText: "p", isCorrect: true, questionId: saved.id).insert(db)
        }
        try await mac.engine.sync(using: server)
        try phone.engine.enable(accountUserId: "u", uploadExisting: false)
        try await phone.engine.sync(using: server)
        #expect(try await phone.db.queue.read { try TestItem.fetchOne($0, key: "item-1") }?.questionId == saved.id)
    }
}
