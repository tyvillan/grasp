import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Regression guard for a real corpus finding: a full textbook PDF swept
/// into deterministic pair-parsing produced 364 cards that were almost
/// entirely table-of-contents entries and running headers (see
/// VaultScanner's `maxWordsForPairParsing` comment). This uses synthetic
/// fixtures on a temp directory tree, not the real vault, so it exercises
/// the size boundary itself rather than depending on ads.pdf existing.
@Suite("VaultScannerSizeGuard")
struct VaultScannerSizeGuardTests {
    private func makeFakeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lectern-size-guard-\(UUID().uuidString)", isDirectory: true)
        let courseDir = root
            .appendingPathComponent("College", isDirectory: true)
            .appendingPathComponent("Fall Semester 2025-2026", isDirectory: true)
            .appendingPathComponent("Test Course", isDirectory: true)
        try FileManager.default.createDirectory(at: courseDir, withIntermediateDirectories: true)

        // A normal-sized note: real term/definition pairs, well within the
        // word-count guard.
        let normalNote = """
        ---
        tags: [college, fall-2025, lecture]
        ---

        # Test Course 01.01.25

        Permeability
        The ability of a material to transmit fluids through pore spaces and fractures

        Porosity
        The percentage of open space within a rock or sediment sample
        """
        try normalNote.write(to: courseDir.appendingPathComponent("Test Course 01.01.25.md"), atomically: true, encoding: .utf8)

        // A synthetic "textbook": the same real pair repeated past the
        // guard's threshold, padded with filler so total word count
        // clears 8,000 -- structurally identical to what a real reference
        // document would trip.
        let repeatedPair = "Permeability\nThe ability of a material to transmit fluids through pore spaces and fractures\n\n"
        var bigBody = "---\ntags: [college, fall-2025, document]\n---\n\n# Textbook\n\n"
        while bigBody.split(separator: " ").count < 8500 {
            bigBody += repeatedPair
        }
        try bigBody.write(to: courseDir.appendingPathComponent("Textbook.md"), atomically: true, encoding: .utf8)

        return root
    }

    @Test("a document well past the word-count guard produces no cards, but its text is still kept")
    func oversizedDocumentSkipsCardGeneration() async throws {
        let vaultRoot = try makeFakeVault()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let db = try GRASPDatabase.inMemory()
        let summary = try await VaultScanner(database: db).scan(vaultRoot: vaultRoot)
        #expect(summary.errors.isEmpty)

        try await db.queue.read { conn in
            let textbook = try #require(try Material.filter(Column("title") == "Textbook").fetchOne(conn))
            #expect(textbook.extractionState == .ok)
            #expect(textbook.isStudyWorthy == false)
            let textbookCards = try Card.filter(Column("materialId") == textbook.id).fetchCount(conn)
            #expect(textbookCards == 0)
            // The text itself must still be there for search/viewing.
            let noteText = try #require(try NoteText.fetchOne(conn, key: textbook.id))
            #expect(!noteText.reflowed.isEmpty)

            let normal = try #require(try Material.filter(Column("title") == "Test Course 01.01.25").fetchOne(conn))
            #expect(normal.isStudyWorthy == true)
            let normalCards = try Card.filter(Column("materialId") == normal.id).fetchCount(conn)
            #expect(normalCards > 0)
        }
    }
}
