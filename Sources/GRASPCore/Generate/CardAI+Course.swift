import Foundation
import GRDB

/// Writing cards for a deck that has none yet. `generateAdditionalCards`
/// only works from notes a deck's cards already point at, so an empty deck
/// has nothing to read; this one starts from the course's own notes.
extension CardAI {
    public enum CourseGenerationOutcome: Equatable, Sendable {
        /// The course has no notes to read. Not a failure: the caller shows
        /// "add files" rather than a retry.
        case noMaterials
        /// The run finished. `created == 0` here genuinely means the model
        /// found nothing worth a card; anything that broke throws instead.
        case generated(created: Int, notesRead: Int, notesWithoutText: Int)
    }

    public enum CourseGenerationError: Error, Equatable, Sendable {
        /// No model is reachable right now.
        case generatorUnavailable
        /// The course has notes, but none of them has any readable text.
        case noReadableNotes
        /// The deck to write into is gone.
        case deckMissing
        /// A write failed partway. Cards from the notes before it are kept;
        /// `created` says how many.
        case writeFailed(created: Int, reason: String)
    }

    /// Reads the course's notes one at a time, asks the generator for new
    /// cards for each, and writes them as AI-generated drafts into
    /// `deckId` as each note finishes -- so a caller watching the database
    /// sees them arrive, and a failure or stop keeps everything before it.
    ///
    /// Progress is reported per note, like `generateAdditionalCards`.
    /// Cancellation stops after the current note and returns what was
    /// written. Cards that duplicate one already in the course are skipped.
    public static func generateCards(
        fromCourse courseId: String, intoDeck deckId: String,
        maxPerNote: Int = defaultMaxGeneratedPerNote, topic: String? = nil,
        using generator: any CardGenerator, database: GRASPDatabase
    ) async throws -> CourseGenerationOutcome {
        struct Source: Sendable { let id: String; let text: String }
        let sources: [Source]
        let withoutText: Int
        var duplicateIndex: DuplicateDetector.Index
        do {
            let loaded = try await database.queue.read { db -> (materials: [Source], noText: Int, cards: [Card], deckExists: Bool) in
                let deckExists = try Deck.filter(Column("id") == deckId && Column("deletedAt") == nil).fetchCount(db) > 0
                let materials = try Material
                    .filter(Column("courseId") == courseId && Column("deletedAt") == nil)
                    .order(sql: "noteDate IS NULL, noteDate, title")
                    .fetchAll(db)
                var withText: [Source] = []
                var noText = 0
                for material in materials {
                    let text = try NoteText.fetchOne(db, key: material.id)?.reflowed ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { noText += 1 }
                    else { withText.append(Source(id: material.id, text: text)) }
                }
                let cards = try Card.fetchAll(db, sql: """
                    SELECT card.* FROM card
                    JOIN deckCard ON deckCard.cardId = card.id
                    JOIN deck ON deck.id = deckCard.deckId AND deck.courseId = ? AND deck.deletedAt IS NULL
                    WHERE card.deletedAt IS NULL
                    """, arguments: [courseId])
                return (withText, noText, cards, deckExists)
            }
            guard loaded.deckExists else { throw CourseGenerationError.deckMissing }
            if loaded.materials.isEmpty && loaded.noText == 0 { return .noMaterials }
            if loaded.materials.isEmpty { throw CourseGenerationError.noReadableNotes }
            sources = loaded.materials
            withoutText = loaded.noText
            duplicateIndex = DuplicateDetector.Index(loaded.cards)
        } catch let error as CourseGenerationError {
            throw error
        } catch {
            throw CourseGenerationError.writeFailed(created: 0, reason: error.localizedDescription)
        }

        guard await generator.isAvailable else { throw CourseGenerationError.generatorUnavailable }

        var created = 0
        var notesRead = 0
        let progress = AIProgress.current
        progress?.expect(sources.count)
        for (index, source) in sources.enumerated() {
            if Task.isCancelled { break }
            progress?.begin("Reading note \(index + 1) of \(sources.count)")
            let proposed = await generator.generateAdditional(
                existing: [], noteContext: source.text, maxCount: maxPerNote, topic: topic)
            progress?.advance()
            notesRead += 1
            if Task.isCancelled { break }
            guard !proposed.isEmpty else { continue }
            let snapshot = duplicateIndex
            do {
                let inserted = try await database.queue.write { db -> [(id: String, front: String, back: String)] in
                    var local = snapshot
                    var next = try Int.fetchOne(db, sql:
                        "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                        arguments: [deckId]) ?? 0
                    var inserted: [(id: String, front: String, back: String)] = []
                    for generated in proposed {
                        guard CardQuality.problem(front: generated.front, back: generated.back) == nil,
                              local.matchId(front: generated.front, back: generated.back, semantic: true) == nil
                        else { continue }
                        let card = Card(materialId: source.id, front: generated.front, back: generated.back,
                                        origin: .aiGenerated, status: .draft)
                        try card.save(db)
                        try DeckCard(deckId: deckId, cardId: card.id, sortIndex: next).save(db)
                        local.insert(id: card.id, front: generated.front, back: generated.back)
                        inserted.append((card.id, generated.front, generated.back))
                        next += 1
                    }
                    return inserted
                }
                for item in inserted { duplicateIndex.insert(id: item.id, front: item.front, back: item.back) }
                created += inserted.count
            } catch {
                throw CourseGenerationError.writeFailed(created: created, reason: error.localizedDescription)
            }
        }
        return .generated(created: created, notesRead: notesRead, notesWithoutText: withoutText)
    }
}
