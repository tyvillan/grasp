import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Proves the `noteFTS` join AppStore.searchNotes relies on actually works:
/// the FTS5 table's rowid mirrors `noteText`'s implicit integer rowid, not
/// its `materialId` text primary key, so the join has to go through that
/// rowid rather than directly to `material`. Worth verifying against real
/// content, not just trusting the SQL reads correctly -- GRDB's
/// synchronized-FTS5 rowid semantics are exactly the kind of thing that's
/// easy to get subtly wrong.
@Suite("SearchIntegration", .enabled(if: VaultFixture.vaultExists, "needs the real notes vault on the Mac"))
struct SearchIntegrationTests {
    private static let vaultRoot = URL(fileURLWithPath:
        "/Users/tyvillan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault")

    private func search(_ query: String, db: GRASPDatabase) throws -> [(materialId: String, title: String, snippet: String)] {
        let sanitized = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")
        guard !sanitized.isEmpty else { return [] }
        return try db.queue.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT material.id AS materialId, material.title AS title,
                       snippet(noteFTS, 0, '**', '**', '…', 12) AS snippet
                FROM noteFTS
                JOIN noteText ON noteText.rowid = noteFTS.rowid
                JOIN material ON material.id = noteText.materialId
                WHERE noteFTS MATCH ?
                ORDER BY rank
                LIMIT 40
                """, arguments: [sanitized])
                .map { row in (materialId: row["materialId"] as String, title: row["title"] as String, snippet: row["snippet"] as String) }
        }
    }

    @Test("searching a real, distinctive term finds its source note")
    func findsDistinctiveTerm() async throws {
        let db = try await VaultFixture.database()

        // "Permeability" is a real, distinctive Physical Geology term
        // confirmed present in the vault earlier in this project.
        let results = try search("permeability", db: db)
        #expect(!results.isEmpty)
        #expect(results.contains { $0.title.contains("Physical Geology") || $0.snippet.localizedCaseInsensitiveContains("permeability") })
    }

    @Test("an empty or punctuation-only query returns no results, not an error")
    func emptyQueryIsSafe() async throws {
        let db = try await VaultFixture.database()
        #expect(try search("", db: db).isEmpty)
        #expect(try search("???", db: db).isEmpty)
    }

    @Test("a nonsense query finds nothing, without throwing")
    func nonsenseQueryFindsNothing() async throws {
        let db = try await VaultFixture.database()
        let results = try search("zzqxxnonexistentterm", db: db)
        #expect(results.isEmpty)
    }
}
