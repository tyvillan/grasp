import Foundation
import GRDB

/// A deck packed into a file a classmate can open in GRASP: its approved
/// cards and, when asked, its saved text questions. No review history, no
/// scheduling, no ids of yours.
public struct SharedDeck: Codable, Sendable {
    public static let format = "grasp-deck"
    public static let currentVersion = 1

    public struct SharedCard: Codable, Sendable, Equatable {
        public var front: String
        public var back: String
        public var hasMath: Bool
    }

    public var format: String
    public var version: Int
    public var name: String
    public var courseName: String?
    public var exportedAt: Date
    public var cards: [SharedCard]
    /// Saved questions, as rows; everything that points at your library is cleared on import.
    public var questions: [TestQuestion]
}

public enum DeckShare {
    public enum ShareError: Error, Equatable, Sendable {
        case notADeckFile
        case newerVersion
        case deckMissing
        case courseMissing
    }

    public struct ImportResult: Sendable, Equatable {
        public let deckId: String
        public let cardsAdded: Int
        public let duplicatesSkipped: Int
        public let questionsAdded: Int
    }

    /// The deck's approved cards (and, with `includeQuestions`, its active
    /// questions that need no picture).
    public static func export(deckId: String, includeQuestions: Bool, now: Date = Date(),
                              db: Database) throws -> SharedDeck {
        guard let deck = try Deck.fetchOne(db, key: deckId), deck.deletedAt == nil else { throw ShareError.deckMissing }
        let cards = try Card.fetchAll(db, sql: """
            SELECT card.* FROM card JOIN deckCard ON deckCard.cardId = card.id
            WHERE deckCard.deckId = ? AND card.deletedAt IS NULL AND card.status = 'active'
            ORDER BY deckCard.sortIndex
            """, arguments: [deckId])
        var questions: [TestQuestion] = []
        if includeQuestions {
            questions = try TestQuestion.filter(
                Column("deckId") == deckId && Column("deletedAt") == nil && Column("status") == "active"
                    && Column("imageId") == nil).order(Column("createdAt")).fetchAll(db)
        }
        let courseName = try String.fetchOne(db, sql: "SELECT name FROM course WHERE id = ?", arguments: [deck.courseId])
        return SharedDeck(
            format: SharedDeck.format, version: SharedDeck.currentVersion, name: deck.name, courseName: courseName,
            exportedAt: now, cards: cards.map { .init(front: $0.front, back: $0.back, hasMath: $0.hasMath) },
            questions: questions)
    }

    public static func encode(_ deck: SharedDeck) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(deck)
    }

    public static func decode(_ data: Data) throws -> SharedDeck {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let deck = try? decoder.decode(SharedDeck.self, from: data), deck.format == SharedDeck.format else {
            throw ShareError.notADeckFile
        }
        guard deck.version <= SharedDeck.currentVersion else { throw ShareError.newerVersion }
        return deck
    }

    /// Makes a new deck in the course. Cards already in the course (the same
    /// or nearly the same wording) are skipped. They arrive approved, as
    /// hand-made cards with no study history.
    @discardableResult
    public static func importDeck(_ shared: SharedDeck, intoCourse courseId: String, now: Date = Date(),
                                  db: Database) throws -> ImportResult {
        guard try Course.fetchOne(db, key: courseId) != nil else { throw ShareError.courseMissing }
        let existing = try Card.fetchAll(db, sql: """
            SELECT card.* FROM card
            JOIN deckCard ON deckCard.cardId = card.id
            JOIN deck ON deck.id = deckCard.deckId AND deck.courseId = ? AND deck.deletedAt IS NULL
            WHERE card.deletedAt IS NULL
            """, arguments: [courseId])
        var index = DuplicateDetector.Index(existing)
        let nextSort = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deck WHERE courseId = ?",
                                         arguments: [courseId])) ?? 0
        let name = shared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = Deck(courseId: courseId, name: name.isEmpty ? "Shared deck" : name)
        var placed = deck
        placed.origin = "manual"
        placed.sortIndex = nextSort
        try placed.insert(db)

        var added = 0, skipped = 0
        for shared in shared.cards {
            let front = shared.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = shared.back.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty else { continue }
            if index.matchId(front: front, back: back, semantic: true) != nil { skipped += 1; continue }
            let card = Card(materialId: nil, front: front, back: back, hasMath: shared.hasMath,
                            origin: .manual, status: .active, createdAt: now, updatedAt: now)
            try card.insert(db)
            try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: added).insert(db)
            index.insert(id: card.id, front: front, back: back)
            added += 1
        }
        var questionsAdded = 0
        for var question in shared.questions where question.imageId == nil {
            question.id = UUID().uuidString
            question.courseId = courseId
            question.deckId = deck.id
            question.materialId = nil
            question.cardId = nil
            question.imageId = nil
            question.imageCrop = nil
            question.sourceContentHash = nil
            question.createdAt = now
            question.deletedAt = nil
            question.status = QuestionStatus.active.rawValue
            question.source = QuestionSource.yours.rawValue
            try question.insert(db)
            questionsAdded += 1
        }
        return ImportResult(deckId: deck.id, cardsAdded: added, duplicatesSkipped: skipped, questionsAdded: questionsAdded)
    }

    /// The deck as a printable document: a two-column table of fronts and backs.
    public static func document(for shared: SharedDeck) -> ExportDocument {
        var document = ExportDocument(
            title: shared.name,
            subtitle: [shared.courseName, "\(shared.cards.count) card\(shared.cards.count == 1 ? "" : "s")"]
                .compactMap { $0 }.joined(separator: " · "))
        if !shared.cards.isEmpty {
            document.blocks.append(.table(rows: [["Front", "Back"]] + shared.cards.map { [$0.front, $0.back] }, bar: nil))
        }
        return document
    }
}
