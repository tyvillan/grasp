import Foundation
import Testing
import GRDB
@testable import GRASPCore

/// Two devices syncing through a server that lives in memory -- the same
/// engine the app runs against Supabase, minus the network.
@Suite("Sync engine")
struct SyncEngineTests {

    /// Stores rows the way the real table does: one per (table, row key),
    /// stamped with an increasing server time on every write.
    actor MemoryServer: SyncTransport {
        private var rows: [String: SyncRecord] = [:]
        private var clock = 0

        func push(_ records: [SyncRecord]) async throws {
            for var record in records {
                clock += 1
                record.updatedAt = String(format: "%010d", clock)
                rows["\(record.table)|\(record.rowKey)"] = record
            }
        }

        func pull(since: String?, offset: Int, limit: Int) async throws -> [SyncRecord] {
            let matching = rows.values
                .filter { since == nil || ($0.updatedAt ?? "") > since! }
                .sorted { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }
            return Array(matching.dropFirst(offset).prefix(limit))
        }

        var count: Int { rows.count }
    }

    private struct Device {
        let db: GRASPDatabase
        let engine: SyncEngine
        init() throws {
            db = try GRASPDatabase.inMemory()
            engine = SyncEngine(database: db)
        }
    }

    /// A course with one deck holding one card, plus that card's Learn row.
    @discardableResult
    private func seedLibrary(_ device: Device) throws -> (course: Course, deck: Deck, card: Card) {
        try device.db.queue.write { db in
            let course = Course(semesterId: nil, name: "Matrix Theory")
            try course.insert(db)
            let deck = Deck(courseId: course.id, name: "Lecture 1")
            try deck.insert(db)
            let card = Card(materialId: nil, front: "Pivot", back: "A leading 1", origin: .manual, status: .active)
            try card.insert(db)
            try DeckCard(deckId: deck.id, cardId: card.id).insert(db)
            try LearnState(cardId: card.id, level: 2).insert(db)
            return (course, deck, card)
        }
    }

    @Test("a profile that isn't signed in records nothing")
    func localOnlyRecordsNothing() throws {
        let device = try Device()
        try seedLibrary(device)
        #expect(try device.engine.status().pendingChanges == 0)
        #expect(try device.engine.status().enabled == false)
    }

    @Test("the first device to sign in uploads its whole library")
    func firstDeviceUploadsEverything() async throws {
        let server = MemoryServer()
        let mac = try Device()
        try seedLibrary(mac)
        try mac.engine.enable(accountUserId: "user-1", uploadExisting: true)
        #expect(try mac.engine.status().pendingChanges == 5) // course, deck, card, deckCard, learnState
        let report = try await mac.engine.sync(using: server)
        #expect(report.pushed == 5)
        #expect(try mac.engine.status().pendingChanges == 0)
        #expect(await server.count == 5)
    }

    @Test("a second device joining the account receives everything")
    func secondDeviceDownloads() async throws {
        let server = MemoryServer()
        let mac = try Device()
        let seeded = try seedLibrary(mac)
        try mac.engine.enable(accountUserId: "user-1", uploadExisting: true)
        try await mac.engine.sync(using: server)

        let other = try Device()
        try other.engine.enable(accountUserId: "user-1", uploadExisting: false)
        let report = try await other.engine.sync(using: server)
        #expect(report.pulled == 5)
        let card = try await other.db.queue.read { db in try Card.fetchOne(db, key: seeded.card.id) }
        #expect(card?.front == "Pivot")
        let inDeck = try await other.db.queue.read { db in
            try DeckCard.filter(Column("cardId") == seeded.card.id).fetchCount(db)
        }
        #expect(inDeck == 1)
        // Applying another device's rows doesn't queue them to be sent back.
        #expect(try other.engine.status().pendingChanges == 0)
    }

    @Test("an edit on one device reaches the other, without disturbing what hangs off the row")
    func editsTravel() async throws {
        let server = MemoryServer()
        let mac = try Device()
        let seeded = try seedLibrary(mac)
        try mac.engine.enable(accountUserId: "user-1", uploadExisting: true)
        try await mac.engine.sync(using: server)
        let other = try Device()
        try other.engine.enable(accountUserId: "user-1", uploadExisting: false)
        try await other.engine.sync(using: server)

        // Graded on the second device.
        try await other.db.queue.write { db in
            var card = try #require(try Card.fetchOne(db, key: seeded.card.id))
            card.reps = 3
            card.back = "The first nonzero entry in a row"
            try card.update(db)
        }
        try await other.engine.sync(using: server)
        try await mac.engine.sync(using: server)

        let onMac = try await mac.db.queue.read { db in try Card.fetchOne(db, key: seeded.card.id) }
        #expect(onMac?.reps == 3)
        #expect(onMac?.back == "The first nonzero entry in a row")
        // An upsert, not delete-and-reinsert: the card's deck membership
        // and Learn progress survive the update arriving.
        let (inDeck, learn) = try await mac.db.queue.read { db in
            (try DeckCard.filter(Column("cardId") == seeded.card.id).fetchCount(db),
             try LearnState.fetchOne(db, key: seeded.card.id))
        }
        #expect(inDeck == 1)
        #expect(learn?.level == 2)
    }

    @Test("a deletion travels, including rows removed by a cascade")
    func deletionsTravel() async throws {
        let server = MemoryServer()
        let mac = try Device()
        let seeded = try seedLibrary(mac)
        try mac.engine.enable(accountUserId: "user-1", uploadExisting: true)
        try await mac.engine.sync(using: server)
        let other = try Device()
        try other.engine.enable(accountUserId: "user-1", uploadExisting: false)
        try await other.engine.sync(using: server)

        // Hard-deleting the card cascades to its deck row and Learn row.
        try await mac.db.queue.write { db in _ = try Card.deleteOne(db, key: seeded.card.id) }
        #expect(try mac.engine.status().pendingChanges == 3)
        try await mac.engine.sync(using: server)
        try await other.engine.sync(using: server)

        let (card, inDeck) = try await other.db.queue.read { db in
            (try Card.fetchOne(db, key: seeded.card.id),
             try DeckCard.filter(Column("cardId") == seeded.card.id).fetchCount(db))
        }
        #expect(card == nil)
        #expect(inDeck == 0)
    }

    @Test("a local edit not yet pushed wins over an older one pulled from elsewhere")
    func pendingLocalEditWins() async throws {
        let server = MemoryServer()
        let mac = try Device()
        let seeded = try seedLibrary(mac)
        try mac.engine.enable(accountUserId: "user-1", uploadExisting: true)
        try await mac.engine.sync(using: server)
        let other = try Device()
        try other.engine.enable(accountUserId: "user-1", uploadExisting: false)
        try await other.engine.sync(using: server)

        // Both edit the same card; the other device syncs first.
        try await other.db.queue.write { db in
            try db.execute(sql: "UPDATE card SET back = 'from other' WHERE id = ?", arguments: [seeded.card.id])
        }
        try await other.engine.sync(using: server)
        try await mac.db.queue.write { db in
            try db.execute(sql: "UPDATE card SET back = 'from mac' WHERE id = ?", arguments: [seeded.card.id])
        }
        try await mac.engine.sync(using: server)
        try await other.engine.sync(using: server)

        // The Mac's edit was the later one: it kept it, and it reached the other.
        let onMac = try await mac.db.queue.read { db in try Card.fetchOne(db, key: seeded.card.id) }
        let onOther = try await other.db.queue.read { db in try Card.fetchOne(db, key: seeded.card.id) }
        #expect(onMac?.back == "from mac")
        #expect(onOther?.back == "from mac")
    }

    @Test("signing out stops recording and forgets what was queued")
    func disableStopsRecording() throws {
        let device = try Device()
        try device.engine.enable(accountUserId: "user-1", uploadExisting: false)
        try seedLibrary(device)
        #expect(try device.engine.status().pendingChanges > 0)
        try device.engine.disable()
        #expect(try device.engine.status().pendingChanges == 0)
        try seedLibrary(device)
        #expect(try device.engine.status().pendingChanges == 0)
    }

    @Test("splits a composite key back into its columns")
    func splitsKeys() {
        #expect(SyncEngine.splitKey("deck-1|card-2", into: 2) == ["deck-1", "card-2"])
        #expect(SyncEngine.splitKey("/a|b/path", into: 1) == ["/a|b/path"])
    }

    @Test("every value type survives the trip through JSON")
    func valuesRoundTrip() throws {
        let data: [String: SyncValue] = [
            "n": .null, "i": .integer(42), "r": .real(2.5), "t": .text("hi"), "b": .blob(Data([1, 2, 3])),
        ]
        let decoded = try JSONDecoder().decode([String: SyncValue].self, from: JSONEncoder().encode(data))
        #expect(decoded == data)
    }
}
