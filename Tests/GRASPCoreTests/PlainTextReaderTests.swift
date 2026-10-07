import Foundation
import GRDB
import Testing
@testable import GRASPCore

@Suite("PlainTextReader")
struct PlainTextReaderTests {
    private func write(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("plain text is read as it is")
    func plain() throws {
        let url = try write("a.txt", Data("Line one\nLine two".utf8))
        #expect(try PlainTextReader.read(url) == "Line one\nLine two")
    }

    @Test("text that isn't UTF-8 falls back to Windows-1252 instead of failing")
    func legacyEncoding() throws {
        let url = try write("a.txt", Data([0x63, 0x61, 0x66, 0xE9]))   // "café" in cp1252
        #expect(try PlainTextReader.read(url) == "café")
    }

    @Test("RTF keeps the words and paragraph breaks and drops the formatting")
    func rtf() {
        let rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\colortbl;\red0\green0\blue0;}\f0\fs24 \b Supply\b0  and demand\par Prices rise when demand \i grows\i0 .\par}"#
        #expect(PlainTextReader.rtfToText(rtf) == "Supply and demand\nPrices rise when demand grows.")
    }

    @Test("RTF escapes: hex bytes, unicode and literal braces")
    func rtfEscapes() {
        let backslash = "\\"
        let rtf = "{" + backslash + "rtf1" + backslash + "ansi caf" + backslash + "'e9 " + backslash + "u8211? "
            + backslash + "{x" + backslash + "}}"
        #expect(PlainTextReader.rtfToText(rtf) == "café – {x}")
    }

    @Test("an .rtf file is detected by extension and by header")
    func rtfFile() throws {
        let url = try write("n.rtf", Data(#"{\rtf1 Hello\par World}"#.utf8))
        #expect(try PlainTextReader.read(url) == "Hello\nWorld")
        let renamed = try write("n.txt", Data(#"{\rtf1 Hello}"#.utf8))
        #expect(try PlainTextReader.read(renamed) == "Hello")
    }
}

@Suite("Text and RTF import")
struct TextImportTests {
    @Test("a .txt and an .rtf chosen by name become notes; a folder scan skips them")
    func importsTextAndRtf() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = "Opportunity cost is the value of the next best alternative that you give up when you choose. "
            + "A production possibilities frontier shows the trade-offs an economy faces between two goods."
        let txt = dir.appendingPathComponent("Lecture 1.txt")
        try Data(body.utf8).write(to: txt)
        let rtf = dir.appendingPathComponent("Lecture 2.rtf")
        let backslash = "\\"
        try Data(("{" + backslash + "rtf1" + backslash + "ansi " + body + backslash + "par}").utf8).write(to: rtf)

        let db = try GRASPDatabase.inMemory()
        let courseId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "Econ")
            try course.insert(conn)
            return course.id
        }
        let summary = try await VaultScanner(database: db).importPaths([txt, rtf], intoCourse: courseId)
        #expect(summary.filesScanned == 2)
        // A folder scan leaves the same kind of files alone.
        let folder = try await VaultScanner(database: db).importPaths([dir], intoCourse: courseId)
        #expect(folder.filesScanned == 0)
        let titles = try await db.queue.read { conn in
            try Material.filter(Column("courseId") == courseId).fetchAll(conn).map(\.title).sorted()
        }
        #expect(titles.count == 2)
    }
}

@Suite("Refinable cards")
struct RefinableCardsTests {
    @Test("refining everything includes approved cards but never suspended or deleted ones")
    func refinableCardsScope() async throws {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            for (index, status) in [CardStatus.draft, .active, .suspended].enumerated() {
                let card = Card(materialId: nil, front: "f\(index)", back: "b\(index)", origin: .parser, status: status)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            }
            var gone = Card(materialId: nil, front: "gone", back: "b", origin: .parser, status: .active)
            gone.deletedAt = Date()
            try gone.insert(conn)
            try DeckCard(deckId: deck.id, cardId: gone.id).insert(conn)
            return deck.id
        }
        let drafts = await CardAI.refinableCards(inDecks: [deckId], includeApproved: false, database: db)
        let all = await CardAI.refinableCards(inDecks: [deckId], includeApproved: true, database: db)
        #expect(drafts.map(\.front) == ["f0"])
        #expect(all.map(\.front).sorted() == ["f0", "f1"])
    }
}
