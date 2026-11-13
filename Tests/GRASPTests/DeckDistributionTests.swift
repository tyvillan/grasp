import Testing
import Foundation
import GRDB
import GRASPCore
@testable import GRASP

@Suite("Deck rows by stage")
struct DeckDistributionTests {
    @Test("each deck's active cards are counted by stage, and only active ones")
    func distributions() async throws {
        let db = try GRASPDatabase.inMemory()
        let deckId = try await db.queue.write { conn -> String in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            let other = Deck(courseId: course.id, name: "Other"); try other.insert(conn)
            func add(_ status: CardStatus, level: Int?, deck: Deck, deleted: Bool = false) throws {
                var card = Card(materialId: nil, front: UUID().uuidString, back: "b", origin: .manual, status: status)
                if deleted { card.deletedAt = Date() }
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
                if let level { try LearnState(cardId: card.id, level: level, consecutiveCorrect: 0, lastSeenAt: Date()).save(conn) }
            }
            try add(.active, level: nil, deck: deck)
            try add(.active, level: 0, deck: deck)
            try add(.active, level: 1, deck: deck)
            try add(.active, level: 2, deck: deck)
            try add(.active, level: 3, deck: deck)
            try add(.active, level: 3, deck: deck)
            try add(.active, level: 4, deck: deck)
            try add(.draft, level: 3, deck: deck)
            try add(.suspended, level: 3, deck: deck)
            try add(.active, level: 3, deck: deck, deleted: true)
            try add(.active, level: 2, deck: other)
            return deck.id
        }
        let result = try await db.queue.read { try AppStore.deckDistributions($0) }
        let d = try #require(result[deckId])
        #expect(d.notAsked == 2)
        #expect(d.recognition == 1)
        #expect(d.recall == 1)
        #expect(d.solid == 2)
        #expect(d.selfRated == 1)
        #expect(d.total == 7)
    }
}
