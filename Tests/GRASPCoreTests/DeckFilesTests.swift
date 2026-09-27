import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Deck files")
struct DeckFilesTests {
    @Test("files are counted by their live cards in the deck, and hand-typed cards separately")
    func counts() async throws {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Biology")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Cells")
            try deck.insert(conn)
            let note = Material(courseId: course.id, relativePath: "College/Fall/Biology/cells.md", kind: .markdown,
                                contentHash: "h", title: "Cells")
            try note.insert(conn)
            let rows: [(String?, CardStatus, Bool)] = [(note.id, .draft, false), (note.id, .active, false),
                                                       (note.id, .active, true), (nil, .active, false)]
            for (index, (materialId, status, deleted)) in rows.enumerated() {
                let card = Card(materialId: materialId, front: "Q\(index)", back: "A", origin: .parser, status: status,
                                deletedAt: deleted ? Date() : nil)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: index).insert(conn)
            }
            return deck.id
        }
        let result = try await db.queue.read { try DeckFiles.list(inDecks: [deckId], db: $0) }
        #expect(result.files.count == 1)
        #expect(result.files.first?.cardCount == 2)
        #expect(result.files.first?.draftCount == 1)
        #expect(result.handTypedCardCount == 1)
    }

    @Test("a vault note resolves against the vault; a full path stays as it is")
    func urls() {
        let vault = URL(fileURLWithPath: "/notes")
        let relative = Material(courseId: "c", relativePath: "College/a.md", kind: .markdown, contentHash: nil, title: "a")
        #expect(DeckFiles.url(for: relative, vaultRoot: vault)?.path.hasSuffix("notes/College/a.md") == true)
        #expect(DeckFiles.url(for: relative, vaultRoot: nil) == nil)
        let absolute = Material(courseId: "c", relativePath: "/elsewhere/b.pdf", kind: .pdf, contentHash: nil, title: "b")
        #expect(DeckFiles.url(for: absolute, vaultRoot: nil)?.lastPathComponent == "b.pdf")
    }
}
