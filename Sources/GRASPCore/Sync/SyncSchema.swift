import Foundation
import GRDB

/// Which tables sync between devices, and how a change to one is noticed.
///
/// Changes are captured by SQLite triggers, not by the app remembering to
/// report them. GRASP writes to these tables from dozens of places -- the
/// scanner, study sessions, AI passes, merges, cascading deletes -- and a
/// sync that depended on each of them calling "mark dirty" would miss
/// whichever one was written next. A trigger sees every insert, update and
/// delete, including rows removed by `ON DELETE CASCADE`.
///
/// Each trigger records only *which* row changed (its table and key) in
/// `syncOutbox`; the row itself is read when it's pushed, so ten edits to a
/// card between syncs send it once, as it is now.
public enum SyncSchema {
    public struct Table: Sendable {
        public let name: String
        public let primaryKey: [String]
    }

    /// In dependency order -- parents before children -- which is the
    /// order pulled rows are applied in. Deliberately absent: `importRun`
    /// (a local log) and the `noteFTS` search index, which is rebuilt from
    /// `noteText` by its own triggers wherever that lands.
    public static let tables: [Table] = [
        Table(name: "semester", primaryKey: ["id"]),
        Table(name: "course", primaryKey: ["id"]),
        Table(name: "material", primaryKey: ["id"]),
        Table(name: "materialLink", primaryKey: ["materialId", "linkedMaterialId", "kind"]),
        Table(name: "noteText", primaryKey: ["materialId"]),
        Table(name: "noteOverview", primaryKey: ["materialId"]),
        Table(name: "deck", primaryKey: ["id"]),
        Table(name: "card", primaryKey: ["id"]),
        Table(name: "deckCard", primaryKey: ["deckId", "cardId"]),
        Table(name: "review", primaryKey: ["id"]),
        Table(name: "learnState", primaryKey: ["cardId"]),
        Table(name: "testAttempt", primaryKey: ["id"]),
        Table(name: "testItem", primaryKey: ["id"]),
        Table(name: "calendarEvent", primaryKey: ["id"]),
        Table(name: "excludedFolder", primaryKey: ["folderPath"]),
    ]

    public static func table(named name: String) -> Table? {
        tables.first { $0.name == name }
    }

    /// Joins a composite key. Ids are UUIDs, so the separator can't occur
    /// inside one; a single-column key (a folder path) is never split.
    static let keySeparator = "|"

    /// The SQL expression for a row's key, given `NEW` or `OLD`.
    static func keyExpression(_ table: Table, row: String) -> String {
        table.primaryKey.map { "\(row).\"\($0)\"" }.joined(separator: " || '\(keySeparator)' || ")
    }

    /// Creates the sync bookkeeping tables. Called from the v8 migration.
    static func createTables(_ db: Database) throws {
        try db.create(table: "syncState") { t in
            t.column("id", .integer).primaryKey().check { $0 == 1 }
            // Off until the profile is linked to an account: a local-only
            // profile records nothing.
            t.column("enabled", .boolean).notNull().defaults(to: false)
            // On only while pulled rows are being applied, so applying a
            // change from another device doesn't queue it to be sent back.
            t.column("applyingRemote", .boolean).notNull().defaults(to: false)
            t.column("deviceId", .text).notNull()
            t.column("accountUserId", .text)
            // The server timestamp of the newest row pulled so far.
            t.column("pullCursor", .text)
            t.column("lastSyncedAt", .datetime)
        }
        try db.execute(
            sql: "INSERT INTO syncState (id, deviceId) VALUES (1, ?)",
            arguments: [UUID().uuidString]
        )
        try db.create(table: "syncOutbox") { t in
            t.column("tableName", .text).notNull()
            t.column("rowKey", .text).notNull()
            // Bumped on every change, so a push can tell whether a row
            // changed again while it was being sent.
            t.column("seq", .integer).notNull()
            t.primaryKey(["tableName", "rowKey"])
        }
        try installTriggers(db)
    }

    /// (Re)creates the change-capturing triggers for every synced table.
    /// A later migration that adds a column needs nothing; one that adds a
    /// synced table appends it to `tables` and calls this again.
    public static func installTriggers(_ db: Database) throws {
        let guardClause = "(SELECT enabled = 1 AND applyingRemote = 0 FROM syncState WHERE id = 1)"
        for table in tables {
            for (event, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
                let trigger = "sync_\(table.name)_\(event.lowercased())"
                try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
                try db.execute(sql: """
                    CREATE TRIGGER \(trigger) AFTER \(event) ON "\(table.name)"
                    WHEN \(guardClause)
                    BEGIN
                        INSERT OR REPLACE INTO syncOutbox (tableName, rowKey, seq)
                        VALUES ('\(table.name)', \(keyExpression(table, row: row)),
                                (SELECT COALESCE(MAX(seq), 0) + 1 FROM syncOutbox));
                    END
                    """)
            }
        }
    }
}
