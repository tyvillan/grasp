import Foundation
import GRDB

/// One column's value, as it travels between devices. SQLite has exactly
/// these storage classes, so a row round-trips without knowing its schema.
public enum SyncValue: Codable, Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let v): self = .integer(v)
        case .double(let v): self = .real(v)
        case .string(let v): self = .text(v)
        case .blob(let v): self = .blob(v)
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .integer(let v): return v.databaseValue
        case .real(let v): return v.databaseValue
        case .text(let v): return v.databaseValue
        case .blob(let v): return v.databaseValue
        }
    }

    private struct BlobBox: Codable { let base64: String }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let int = try? container.decode(Int64.self) {
            self = .integer(int)
        } else if let double = try? container.decode(Double.self) {
            self = .real(double)
        } else if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            let box = try container.decode(BlobBox.self)
            self = .blob(Data(base64Encoded: box.base64) ?? Data())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .integer(let v): try container.encode(v)
        case .real(let v): try container.encode(v)
        case .text(let v): try container.encode(v)
        case .blob(let v): try container.encode(BlobBox(base64: v.base64EncodedString()))
        }
    }
}

/// One row's state on the server: its contents, or that it was deleted.
public struct SyncRecord: Codable, Sendable, Equatable {
    public var table: String
    public var rowKey: String
    /// Nil for a deletion.
    public var data: [String: SyncValue]?
    public var deleted: Bool
    /// Which device last wrote it, so a device can skip its own echo.
    public var deviceId: String?
    /// Set by the server. Pull asks for rows changed after the newest one
    /// it has seen.
    public var updatedAt: String?

    public init(table: String, rowKey: String, data: [String: SyncValue]?, deleted: Bool,
                deviceId: String?, updatedAt: String? = nil) {
        self.table = table
        self.rowKey = rowKey
        self.data = data
        self.deleted = deleted
        self.deviceId = deviceId
        self.updatedAt = updatedAt
    }
}

/// Wherever synced rows are kept. The app's is Supabase; tests use an
/// in-memory one.
public protocol SyncTransport: Sendable {
    func push(_ records: [SyncRecord]) async throws
    /// Rows changed after `since` (every row when nil), oldest first, in
    /// pages -- `offset` rows in, at most `limit` of them.
    func pull(since: String?, offset: Int, limit: Int) async throws -> [SyncRecord]
}

/// Moves changes between this device's database and a `SyncTransport`.
///
/// Push, then pull. Push sends every row the triggers noted as changed
/// since the last sync. Pull applies every row another device changed --
/// except rows this device has also changed and not yet pushed: those are
/// the newer edit, and they go up on the next sync. Otherwise the most
/// recent write wins, row by row. That's the right rule for study data,
/// which is almost all one person on one device at a time, and it needs
/// no merge logic that could get a card's schedule subtly wrong.
public struct SyncEngine: Sendable {
    public struct Status: Sendable, Equatable {
        public var enabled: Bool
        public var accountUserId: String?
        public var deviceId: String
        public var pendingChanges: Int
        public var lastSyncedAt: Date?
    }

    public struct Report: Sendable, Equatable {
        public var pushed = 0
        public var pulled = 0
    }

    private let database: GRASPDatabase
    static let pushBatchSize = 500
    static let pullPageSize = 1000

    public init(database: GRASPDatabase) {
        self.database = database
    }

    public func status() throws -> Status {
        try database.queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM syncState WHERE id = 1")
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOutbox") ?? 0
            return Status(
                enabled: row?["enabled"] ?? false,
                accountUserId: row?["accountUserId"],
                deviceId: row?["deviceId"] ?? "",
                pendingChanges: pending,
                lastSyncedAt: row?["lastSyncedAt"]
            )
        }
    }

    /// Links this database to an account and starts recording changes.
    /// With `uploadExisting`, everything already here is queued to go up --
    /// the first device to sign in brings its library with it. A device
    /// joining an account that already has data starts empty and pulls.
    public func enable(accountUserId: String, uploadExisting: Bool) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE syncState SET enabled = 1, accountUserId = ?, pullCursor = NULL WHERE id = 1",
                arguments: [accountUserId]
            )
            guard uploadExisting else { return }
            for table in SyncSchema.tables {
                let base = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM syncOutbox") ?? 0
                try db.execute(sql: """
                    INSERT OR REPLACE INTO syncOutbox (tableName, rowKey, seq)
                    SELECT ?, \(SyncSchema.keyExpression(table, row: "\"\(table.name)\"")),
                           ? + ROW_NUMBER() OVER ()
                    FROM "\(table.name)"
                    """, arguments: [table.name, base])
            }
        }
    }

    /// Stops syncing. The local library stays exactly as it is.
    public func disable() throws {
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE syncState SET enabled = 0, accountUserId = NULL, pullCursor = NULL WHERE id = 1
                """)
            try db.execute(sql: "DELETE FROM syncOutbox")
        }
    }

    @discardableResult
    public func sync(using transport: some SyncTransport) async throws -> Report {
        var report = Report()
        guard try status().enabled else { return report }
        report.pushed = try await push(using: transport)
        report.pulled = try await pull(using: transport)
        try await database.queue.write { db in
            try db.execute(sql: "UPDATE syncState SET lastSyncedAt = ? WHERE id = 1", arguments: [Date()])
        }
        return report
    }

    // MARK: - Push

    private func push(using transport: some SyncTransport) async throws -> Int {
        var pushed = 0
        // Bounded, so a row that fails to send can't spin forever; what's
        // left goes on the next sync.
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (batch, sent) = try await database.queue.read { db -> ([SyncRecord], [(String, String, Int64)]) in
                let deviceId = try String.fetchOne(db, sql: "SELECT deviceId FROM syncState WHERE id = 1")
                let entries = try Row.fetchAll(db, sql: """
                    SELECT tableName, rowKey, seq FROM syncOutbox ORDER BY seq LIMIT ?
                    """, arguments: [Self.pushBatchSize])
                var records: [SyncRecord] = []
                var sent: [(String, String, Int64)] = []
                for entry in entries {
                    let tableName: String = entry["tableName"]
                    let rowKey: String = entry["rowKey"]
                    sent.append((tableName, rowKey, entry["seq"]))
                    guard let table = SyncSchema.table(named: tableName) else { continue }
                    records.append(SyncRecord(
                        table: tableName, rowKey: rowKey,
                        data: try Self.rowData(table, key: rowKey, db: db),
                        deleted: false, deviceId: deviceId
                    ))
                    if records[records.count - 1].data == nil { records[records.count - 1].deleted = true }
                }
                return (records, sent)
            }
            guard !sent.isEmpty else { break }
            if !batch.isEmpty { try await transport.push(batch) }
            try await database.queue.write { db in
                // Only entries that haven't changed again since they were
                // read: a newer edit made mid-push stays queued.
                for (table, key, seq) in sent {
                    try db.execute(
                        sql: "DELETE FROM syncOutbox WHERE tableName = ? AND rowKey = ? AND seq = ?",
                        arguments: [table, key, seq]
                    )
                }
            }
            pushed += batch.count
        }
        return pushed
    }

    /// The row's current contents, or nil when it no longer exists.
    static func rowData(_ table: SyncSchema.Table, key: String, db: Database) throws -> [String: SyncValue]? {
        let values = splitKey(key, into: table.primaryKey.count)
        guard values.count == table.primaryKey.count else { return nil }
        let condition = table.primaryKey.map { "\"\($0)\" = ?" }.joined(separator: " AND ")
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM \"\(table.name)\" WHERE \(condition)",
            arguments: StatementArguments(values)
        ) else { return nil }
        var data: [String: SyncValue] = [:]
        for (column, value) in row {
            data[column] = SyncValue(value)
        }
        return data
    }

    static func splitKey(_ key: String, into count: Int) -> [String] {
        guard count > 1 else { return [key] }
        return key.split(separator: Character(SyncSchema.keySeparator), maxSplits: count - 1,
                         omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Pull

    private func pull(using transport: some SyncTransport) async throws -> Int {
        let (cursor, deviceId) = try await database.queue.read { db in
            (try String.fetchOne(db, sql: "SELECT pullCursor FROM syncState WHERE id = 1"),
             try String.fetchOne(db, sql: "SELECT deviceId FROM syncState WHERE id = 1") ?? "")
        }
        var incoming: [SyncRecord] = []
        let since = cursor.map(Self.withOverlap)
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await transport.pull(since: since, offset: offset, limit: Self.pullPageSize)
            incoming += page
            if page.count < Self.pullPageSize { break }
            offset += page.count
        }
        guard !incoming.isEmpty else { return 0 }
        let newCursor = incoming.compactMap(\.updatedAt).max() ?? cursor
        return try await apply(incoming, deviceId: deviceId, newCursor: newCursor)
    }

    /// Pulls re-read the last minute before the cursor. Rows committed
    /// out of order on the server can carry a timestamp just before one
    /// already seen; re-applying a row is harmless, missing one isn't.
    static func withOverlap(_ cursor: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = formatter.date(from: cursor) ?? plain.date(from: cursor) else { return cursor }
        return formatter.string(from: date.addingTimeInterval(-60))
    }

    /// Applies pulled rows in one transaction, parents before children.
    ///
    /// Foreign keys are off while it runs: rows arrive grouped by table, not
    /// by relationship, and a card can land a moment before the deck it
    /// belongs to. Every query in the app joins rather than trusting a
    /// reference, so a dangling one mid-sync (or from a device that never
    /// synced a parent) degrades to "not shown", never a crash.
    func apply(_ records: [SyncRecord], deviceId: String, newCursor: String?) async throws -> Int {
        try await database.queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
            var applied = 0
            try db.inTransaction {
                try db.execute(sql: "UPDATE syncState SET applyingRemote = 1 WHERE id = 1")
                let pending = Set(try Row.fetchAll(db, sql: "SELECT tableName, rowKey FROM syncOutbox")
                    .map { "\($0["tableName"] as String)\u{1F}\($0["rowKey"] as String)" })
                let order = Dictionary(uniqueKeysWithValues: SyncSchema.tables.enumerated().map { ($1.name, $0) })
                let relevant = records.filter { record in
                    order[record.table] != nil
                        && record.deviceId != deviceId
                        && !pending.contains("\(record.table)\u{1F}\(record.rowKey)")
                }
                // Latest version of each row only.
                var latest: [String: SyncRecord] = [:]
                for record in relevant {
                    let id = "\(record.table)\u{1F}\(record.rowKey)"
                    if let seen = latest[id], (seen.updatedAt ?? "") > (record.updatedAt ?? "") { continue }
                    latest[id] = record
                }
                let upserts = latest.values.filter { !$0.deleted && $0.data != nil }
                    .sorted { order[$0.table]! < order[$1.table]! }
                let deletes = latest.values.filter { $0.deleted || $0.data == nil }
                    .sorted { order[$0.table]! > order[$1.table]! }
                var columnsByTable: [String: Set<String>] = [:]
                for record in upserts {
                    guard let table = SyncSchema.table(named: record.table), let data = record.data else { continue }
                    let columns = try columnsByTable[table.name] ?? Set(db.columns(in: table.name).map(\.name))
                    columnsByTable[table.name] = columns
                    try Self.upsert(table, data: data, knownColumns: columns, db: db)
                    applied += 1
                }
                for record in deletes {
                    guard let table = SyncSchema.table(named: record.table) else { continue }
                    let values = Self.splitKey(record.rowKey, into: table.primaryKey.count)
                    guard values.count == table.primaryKey.count else { continue }
                    let condition = table.primaryKey.map { "\"\($0)\" = ?" }.joined(separator: " AND ")
                    try db.execute(sql: "DELETE FROM \"\(table.name)\" WHERE \(condition)",
                                   arguments: StatementArguments(values))
                    applied += 1
                }
                try db.execute(
                    sql: "UPDATE syncState SET applyingRemote = 0, pullCursor = ? WHERE id = 1",
                    arguments: [newCursor]
                )
                return .commit
            }
            return applied
        }
    }

    /// Insert-or-update, never delete-and-reinsert: SQLite's REPLACE
    /// deletes the old row first, which would cascade away a card's deck
    /// membership and Learn progress every time the card synced. Columns
    /// this device doesn't have (a newer version's) are ignored; ones it
    /// has that the row lacks keep their current value or default.
    static func upsert(_ table: SyncSchema.Table, data: [String: SyncValue], knownColumns: Set<String>,
                       db: Database) throws {
        let columns = data.keys.filter { knownColumns.contains($0) }.sorted()
        guard table.primaryKey.allSatisfy(columns.contains) else { return }
        let quoted = columns.map { "\"\($0)\"" }
        let updates = columns.filter { !table.primaryKey.contains($0) }
            .map { "\"\($0)\" = excluded.\"\($0)\"" }
        let conflict = updates.isEmpty ? "DO NOTHING" : "DO UPDATE SET " + updates.joined(separator: ", ")
        try db.execute(
            sql: """
                INSERT INTO "\(table.name)" (\(quoted.joined(separator: ", ")))
                VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
                ON CONFLICT (\(table.primaryKey.map { "\"\($0)\"" }.joined(separator: ", "))) \(conflict)
                """,
            arguments: StatementArguments(columns.map { data[$0]!.databaseValue })
        )
    }
}
