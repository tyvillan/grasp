import Foundation
import GRDB

/// The AI actions on cards: reword drafts, check cards against their note
/// (rewrite or remove ones that read like assignment text), refine one
/// card, write extra cards for gaps, and find duplicates. The Mac
/// `AppStore`'s versions, moved here with the generator passed in, so the
/// Mac and Windows apps change cards the same way.
///
/// Every action fails soft like the rest of GRASP's AI: no generator, no
/// note text, or a write error leaves cards as they were.
public enum CardAI {
    // MARK: - Summaries

    public struct ContextCheckEntry: Sendable, Identifiable, Equatable {
        public var id: String { cardId }
        public let cardId: String
        public let front: String
        public let courseName: String
    }

    public struct ContextCheckSummary: Sendable, Equatable {
        public var refined: [ContextCheckEntry] = []
        public var removed: [ContextCheckEntry] = []
        public var isEmpty: Bool { refined.isEmpty && removed.isEmpty }
        public init() {}
    }

    public struct RefineDeckSummary: Sendable, Equatable {
        public var wordingRefinedCount = 0
        public var context = ContextCheckSummary()
        public var isEmpty: Bool { wordingRefinedCount == 0 && context.isEmpty }
    }

    public enum CardRefineOutcome: Sendable, Equatable {
        case removed
        case refined
        case unavailable
    }

    public static let defaultMaxGeneratedPerNote = 3

    // MARK: - Reading

    private static func cardIds(inDecks deckIds: [String], database: GRASPDatabase) async throws -> [String] {
        try await database.queue.read { db in
            try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
        }
    }

    /// Live drafts in these decks.
    public static func draftCards(inDecks deckIds: [String], database: GRASPDatabase) async -> [Card] {
        do {
            let ids = try await cardIds(inDecks: deckIds, database: database)
            guard !ids.isEmpty else { return [] }
            return try await database.queue.read { db in
                try Card
                    .filter(ids.contains(Column("id")))
                    .filter(Column("status") == CardStatus.draft.rawValue)
                    // Deleted drafts keep their deck rows; without this they
                    // were sent to the model and rewritten.
                    .filter(Column("deletedAt") == nil)
                    .fetchAll(db)
            }
        } catch {
            return []
        }
    }

    private static func noteText(_ materialId: String, database: GRASPDatabase) async -> String? {
        (try? await database.queue.read { try NoteText.fetchOne($0, key: materialId) })?.reflowed
    }

    // MARK: - Rewording

    /// Rewords the drafts in these decks, note by note. Returns how many
    /// changed.
    public static func refineDraftCards(inDecks deckIds: [String], using generator: any CardGenerator,
                                        database: GRASPDatabase) async -> Int {
        await refineWording(of: draftCards(inDecks: deckIds, database: database), using: generator, database: database)
    }

    public static func refineWording(of cards: [Card], using generator: any CardGenerator,
                                     database: GRASPDatabase) async -> Int {
        guard await generator.isAvailable else { return 0 }
        let withNotes = cards.filter { $0.materialId != nil }
        guard !withNotes.isEmpty else { return 0 }
        let byMaterial = Dictionary(grouping: withNotes, by: { $0.materialId! })
        let progress = AIProgress.current
        var refinedCount = 0
        for (index, (materialId, materialCards)) in byMaterial.enumerated() {
            if Task.isCancelled { break }
            let context = await noteText(materialId, database: database) ?? ""
            let candidates = materialCards.map { CandidatePair(front: $0.front, back: $0.back, sourceLine: $0.sourceLine ?? 0) }
            progress?.begin("Rewording cards from note \(index + 1) of \(byMaterial.count)")
            let refined = await generator.refine(candidates, noteContext: context)
            progress?.advance()
            // A stopped request comes back as the unchanged originals --
            // saving those would stamp untouched cards as AI-refined.
            if Task.isCancelled { break }
            guard refined.count == materialCards.count else { continue }
            do {
                refinedCount += try await database.queue.write { db -> Int in
                    var changed = 0
                    for (card, result) in zip(materialCards, refined) {
                        // Re-fetched: a context pass just before may have
                        // rewritten this row, and this must land on top.
                        guard var updated = try Card.fetchOne(db, key: card.id), updated.deletedAt == nil else { continue }
                        let front = result.front.trimmingCharacters(in: .whitespacesAndNewlines)
                        let back = result.back.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Unchanged (or emptied) is not a refinement.
                        guard !front.isEmpty, !back.isEmpty, front != updated.front || back != updated.back else { continue }
                        updated.front = front
                        updated.back = back
                        // No longer the scanner's to replace on re-import.
                        // Status is untouched: refining isn't approving.
                        updated.origin = .ollama
                        updated.updatedAt = Date()
                        try updated.save(db)
                        changed += 1
                    }
                    return changed
                }
            } catch {
                continue
            }
        }
        return refinedCount
    }

    // MARK: - Context checks

    /// Checks each card against its own note: fine as it is, rewritten from
    /// the note (the original kept, so it can be reverted), or removed.
    public static func verifyContext(of cards: [Card], using generator: any CardGenerator,
                                     database: GRASPDatabase) async -> ContextCheckSummary {
        var summary = ContextCheckSummary()
        let candidates = cards.filter { $0.materialId != nil }
        guard !candidates.isEmpty, await generator.isAvailable else { return summary }
        let materialIds = Set(candidates.map { $0.materialId! })
        let courseNameByMaterial: [String: String]
        do {
            courseNameByMaterial = try await database.queue.read { db -> [String: String] in
                let materials = try Material.filter(materialIds.contains(Column("id"))).fetchAll(db)
                let courses = try Course.filter(Set(materials.map(\.courseId)).contains(Column("id"))).fetchAll(db)
                let courseById = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, $0) })
                return Dictionary(uniqueKeysWithValues: materials.map { ($0.id, courseById[$0.courseId]?.name ?? "") })
            }
        } catch {
            return summary
        }

        let progress = AIProgress.current
        var checked = 0
        let byMaterial = Dictionary(grouping: candidates, by: { $0.materialId! })
        noteLoop: for (materialId, materialCards) in byMaterial {
            guard let context = await noteText(materialId, database: database), !context.isEmpty else {
                // No call made, but counted so the bar reaches the end.
                checked += materialCards.count
                progress?.advance(materialCards.count)
                continue
            }
            let courseName = courseNameByMaterial[materialId] ?? ""
            for card in materialCards {
                if Task.isCancelled { break noteLoop }
                checked += 1
                progress?.begin("Checking card \(checked) of \(candidates.count)")
                let result = await generator.validateContext(
                    front: card.front, back: card.back, noteContext: context, courseName: courseName)
                progress?.advance()
                if Task.isCancelled { break noteLoop }
                do {
                    switch result.verdict {
                    case .valid:
                        continue
                    case .refine(let newBack):
                        try await database.queue.write { db in
                            guard var updated = try Card.fetchOne(db, key: card.id) else { return }
                            if updated.originalBack == nil { updated.originalBack = updated.back }
                            updated.back = newBack
                            updated.isContextRefined = true
                            updated.updatedAt = Date()
                            try updated.save(db)
                        }
                        summary.refined.append(.init(cardId: card.id, front: card.front, courseName: courseName))
                    case .reject:
                        try await database.queue.write { db in
                            guard var updated = try Card.fetchOne(db, key: card.id) else { return }
                            updated.deletedAt = Date()
                            updated.updatedAt = Date()
                            try updated.save(db)
                        }
                        summary.removed.append(.init(cardId: card.id, front: card.front, courseName: courseName))
                    }
                } catch {
                    continue
                }
            }
        }
        return summary
    }

    /// Every live card in the library, checked against its note -- the
    /// one-time sweep in Settings.
    public static func sweepAllCards(using generator: any CardGenerator, database: GRASPDatabase) async -> ContextCheckSummary {
        guard let live = try? await database.queue.read({ try Card.filter(Column("deletedAt") == nil).fetchAll($0) })
        else { return ContextCheckSummary() }
        AIProgress.current?.expect(live.filter { $0.materialId != nil }.count)
        return await verifyContext(of: live, using: generator, database: database)
    }

    /// "Refine Deck with AI": the context check on every draft, then the
    /// rewording pass on what's left.
    public static func refineDeck(inDecks deckIds: [String], using generator: any CardGenerator,
                                  database: GRASPDatabase) async -> RefineDeckSummary {
        let drafts = await draftCards(inDecks: deckIds, database: database)
        // Counted up front for both passes -- a call per draft, then one per
        // note -- so the bar runs once from start to end.
        if let progress = AIProgress.current {
            let noted = drafts.filter { $0.materialId != nil }
            progress.expect(noted.count + Set(noted.compactMap(\.materialId)).count)
        }
        let context = await verifyContext(of: drafts, using: generator, database: database)
        if Task.isCancelled { return RefineDeckSummary(context: context) }
        let reworded = await refineDraftCards(inDecks: deckIds, using: generator, database: database)
        return RefineDeckSummary(wordingRefinedCount: reworded, context: context)
    }

    /// "Refine with AI" on one card: the context check, then rewording.
    @discardableResult
    public static func refineCard(_ cardId: String, using generator: any CardGenerator,
                                  database: GRASPDatabase) async -> CardRefineOutcome {
        guard let card = try? await database.queue.read({ try Card.fetchOne($0, key: cardId) }),
              card.materialId != nil, await generator.isAvailable
        else { return .unavailable }
        let context = await verifyContext(of: [card], using: generator, database: database)
        if !context.removed.isEmpty { return .removed }
        // Re-fetched: the context pass may have just rewritten `back`.
        guard let current = try? await database.queue.read({ try Card.fetchOne($0, key: cardId) }) ?? nil
        else { return context.refined.isEmpty ? .unavailable : .refined }
        let reworded = await refineWording(of: [current], using: generator, database: database)
        return (reworded > 0 || !context.refined.isEmpty) ? .refined : .unavailable
    }

    // MARK: - Filling gaps

    /// Writes up to `maxPerNote` new cards per note for what the existing
    /// cards miss, as drafts marked AI-generated, skipping any that
    /// duplicate a card already in scope. Returns how many were added.
    public static func generateAdditionalCards(
        inDecks deckIds: [String], maxPerNote: Int = defaultMaxGeneratedPerNote, topic: String? = nil,
        using generator: any CardGenerator, database: GRASPDatabase
    ) async -> Int {
        guard await generator.isAvailable else { return 0 }
        let existingByMaterial: [String: [Card]]
        let deckOfCard: [String: String]
        do {
            let (cards, deckCards) = try await database.queue.read { db -> ([Card], [DeckCard]) in
                let deckCards = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db)
                let ids = deckCards.map(\.cardId)
                guard !ids.isEmpty else { return ([], []) }
                let cards = try Card
                    .filter(ids.contains(Column("id")))
                    .filter(Column("deletedAt") == nil)
                    .filter(Column("materialId") != nil)
                    .fetchAll(db)
                return (cards, deckCards)
            }
            guard !cards.isEmpty else { return 0 }
            existingByMaterial = Dictionary(grouping: cards, by: { $0.materialId! })
            deckOfCard = Dictionary(deckCards.map { ($0.cardId, $0.deckId) }, uniquingKeysWith: { first, _ in first })
        } catch {
            return 0
        }

        // Seeded across every note up front, so a proposal duplicating a
        // card from a different note in the same deck is still caught.
        var duplicateIndex = DuplicateDetector.Index(existingByMaterial.values.flatMap { $0 })
        var createdCount = 0
        let progress = AIProgress.current
        progress?.expect(existingByMaterial.count)
        for (index, (materialId, existing)) in existingByMaterial.enumerated() {
            if Task.isCancelled { break }
            guard let context = await noteText(materialId, database: database), !context.isEmpty,
                  let deckId = existing.first.flatMap({ deckOfCard[$0.id] })
            else { progress?.advance(); continue }
            let candidates = existing.map { CandidatePair(front: $0.front, back: $0.back, sourceLine: $0.sourceLine ?? 0) }
            progress?.begin("Reading note \(index + 1) of \(existingByMaterial.count)")
            let proposed = await generator.generateAdditional(
                existing: candidates, noteContext: context, maxCount: maxPerNote, topic: topic)
            progress?.advance()
            if Task.isCancelled { break }
            guard !proposed.isEmpty else { continue }
            let snapshot = duplicateIndex
            do {
                let inserted = try await database.queue.write { db -> [(id: String, front: String, back: String)] in
                    var localIndex = snapshot
                    var next = try Int.fetchOne(db, sql:
                        "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                        arguments: [deckId]) ?? 0
                    var inserted: [(id: String, front: String, back: String)] = []
                    for generated in proposed {
                        guard localIndex.matchId(front: generated.front, back: generated.back) == nil else { continue }
                        let card = Card(materialId: materialId, front: generated.front, back: generated.back,
                                        origin: .aiGenerated, status: .draft)
                        try card.save(db)
                        try DeckCard(deckId: deckId, cardId: card.id, sortIndex: next).save(db)
                        localIndex.insert(id: card.id, front: generated.front, back: generated.back)
                        inserted.append((card.id, generated.front, generated.back))
                        next += 1
                    }
                    return inserted
                }
                for item in inserted { duplicateIndex.insert(id: item.id, front: item.front, back: item.back) }
                createdCount += inserted.count
            } catch {
                continue
            }
        }
        return createdCount
    }

    // MARK: - Duplicates

    public struct DuplicateGroup: Identifiable, Sendable {
        public var id: String { cards[0].id }
        public let cards: [Card]
        /// The card the review sheet preselects to keep.
        public let suggestedKeepId: String
        /// Two or more of the cards have review history, so a merge can't
        /// keep both histories intact -- the sheet says so.
        public let hasCompetingHistory: Bool
    }

    /// Groups of near-identical cards among these.
    public static func duplicateGroups(_ cards: [Card]) -> [DuplicateGroup] {
        DuplicateDetector.groups(cards).map { group in
            let keeper = group.max { keepRank($0).lexicographicallyPrecedes(keepRank($1)) }
            return DuplicateGroup(cards: group, suggestedKeepId: keeper?.id ?? group[0].id,
                                  hasCompetingHistory: group.filter { $0.reps > 0 }.count >= 2)
        }
    }

    /// Higher wins: review history first (deleting it loses study data),
    /// then a hand-edited card, then active over draft over suspended, then
    /// the fuller definition, then the older row.
    static func keepRank(_ card: Card) -> [Int] {
        let statusRank: Int
        switch card.status {
        case .active: statusRank = 2
        case .draft: statusRank = 1
        case .suspended: statusRank = 0
        }
        return [card.reps > 0 ? 1 : 0, card.origin == .manual ? 1 : 0, statusRank, card.back.count,
                Int(-card.createdAt.timeIntervalSince1970)]
    }
}
