import Foundation
import Observation
import GRASPCore
import GRDB

/// The app's single source of truth for everything the UI reads. Owns the
/// database and the scanner, and re-reads from GRDB after any write rather
/// than mutating view state by hand -- the store is small enough (a few
/// thousand rows) that a full reload per action is simpler than incremental
/// diffing and cheap enough not to matter.
@MainActor
@Observable
final class AppStore {
    private(set) var database: GRASPDatabase
    private let scanner: VaultScanner

    private(set) var semesters: [Semester] = []
    private(set) var coursesBySemester: [String?: [Course]] = [:]
    private(set) var deckCounts: [String: (cardCount: Int, dueCount: Int)] = [:]
    /// Which courses have at least one live deck -- computed for free from
    /// the same `decks` fetch `reload()` already does for `deckCounts`, so
    /// the layout can tell "no deck selected yet" apart from "this course
    /// structurally has none" without a second query.
    private(set) var coursesWithDecks: Set<String> = []
    /// Hidden from every normal view (`coursesBySemester` already excludes
    /// them at the query level) but not gone -- Settings' "Archived
    /// Courses" list is the one place they're still visible and
    /// reversible, since there's otherwise no way back to a course once
    /// it's archived from the sidebar or dashboard.
    private(set) var archivedCourses: [Course] = []
    /// Vault folders `scan(vaultRoot:)` must never walk into or turn back
    /// into a course -- see `ExcludedFolder`. Settings' "Excluded Folders"
    /// list is where these are surfaced and reversed.
    private(set) var excludedFolders: [String] = []

    /// Bumped at the end of every `reload()`. A view watching for change
    /// needs this rather than a proxy like `deckCounts.count` -- a deck
    /// rename or a card moving between decks changes no counts at all, so
    /// that proxy misses exactly the mutations this batch of features
    /// introduces.
    private(set) var revision = 0

    var vaultPath: String {
        didSet { UserDefaults.standard.set(vaultPath, forKey: Self.vaultPathKey(for: profile)) }
    }

    private(set) var lastImportSummary: ImportSummary?
    private(set) var isImporting = false
    private(set) var importError: String?

    /// Human-readable name of whichever generator `CardGenerators.select()`
    /// last resolved to, refreshed on demand (Settings, and before a
    /// refine action) rather than kept continuously up to date -- Ollama
    /// starting or stopping between checks is expected and fine to miss
    /// until the next check.
    private(set) var generatorStatus = "Checking..."
    private(set) var isGeneratorAvailable = false

    /// The Ollama server specifically, distinct from `generatorStatus`
    /// above (which answers "which generator will actually be used" --
    /// Ollama, Apple's on-device model, or none). Settings' "Ollama Local
    /// Server" section needs the narrower fact: is the server itself
    /// reachable right now, and what does it have pulled, so it can offer
    /// a setup path when the answer is no regardless of what
    /// `CardGenerators.select()` fell back to.
    struct OllamaStatus: Sendable, Equatable {
        var isRunning = false
        var models: [String] = []
    }
    private(set) var ollamaStatus = OllamaStatus()
    private(set) var isCheckingOllama = false

    /// Every check here keeps its own short, hard timeout (see
    /// `OllamaGenerator`), so this never blocks Settings from rendering
    /// even when nothing is listening on the port at all.
    func refreshOllamaStatus() async {
        isCheckingOllama = true
        let generator = OllamaGenerator()
        let isRunning = await generator.isAvailable
        let models = isRunning ? await generator.installedModels() : []
        ollamaStatus = OllamaStatus(isRunning: isRunning, models: models)
        isCheckingOllama = false
    }

    let profile: Profile

    private static let vaultPathKey = "vaultPath"
    static let defaultVaultPath =
        "/Users/tyvillan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault"

    /// Per-profile UserDefaults key so switching profiles doesn't leak
    /// one person's vault path into another's settings.
    private static func vaultPathKey(for profile: Profile) -> String { "\(vaultPathKey).\(profile.id)" }

    /// - Parameter profile: whose database this store opens. `.preview`
    ///   (an ephemeral in-memory profile) is used by SwiftUI previews and
    ///   the design-time default; real launches always pass a profile the
    ///   user picked or that migration produced.
    init(profile: Profile) {
        self.profile = profile
        let db: GRASPDatabase
        if profile.id == Profile.previewID {
            db = try! GRASPDatabase.inMemory()
        } else {
            let support = (try? GRASPDatabase.supportDirectory()) ?? FileManager.default.temporaryDirectory
            db = (try? GRASPDatabase(path: profile.databaseURL(supportDirectory: support)))
                ?? (try! GRASPDatabase.inMemory())
        }
        self.database = db
        self.scanner = VaultScanner(database: db)
        self.vaultPath = UserDefaults.standard.string(forKey: Self.vaultPathKey(for: profile)) ?? Self.defaultVaultPath
        reload()
        Task { await refreshGeneratorStatus() }
    }

    func refreshGeneratorStatus() async {
        let generator = await CardGenerators.select()
        isGeneratorAvailable = !(generator is NoGenerator)
        switch generator {
        case is OllamaGenerator: generatorStatus = "Ollama (local model)"
        case is NoGenerator: generatorStatus = "None -- cards come from the parser only"
        default: generatorStatus = "Apple on-device model"
        }
    }

    /// Refines every draft card in a deck (grouped by source note, so each
    /// batch gets that note's own text as context), if a generator is
    /// available. Returns how many cards were actually refined; 0 with no
    /// error is the expected outcome when nothing is available.
    func refineDraftCards(inDeck deckId: String) async -> Int {
        await refineDraftCards(inDecks: [deckId])
    }

    /// The plural of the above -- a course-wide "Refine with AI" groups
    /// drafts by source note exactly the same way regardless of which
    /// (possibly several) decks they currently sit in.
    func refineDraftCards(inDecks deckIds: [String]) async -> Int {
        let generator = await CardGenerators.select()
        guard await generator.isAvailable else { return 0 }

        let draftsByMaterial: [String: [Card]]
        do {
            let cardIds = try await database.queue.read { db in
                try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
            }
            guard !cardIds.isEmpty else { return 0 }
            let drafts = try await database.queue.read { db in
                try Card
                    .filter(cardIds.contains(Column("id")))
                    .filter(Column("status") == CardStatus.draft.rawValue)
                    .filter(Column("materialId") != nil)
                    .fetchAll(db)
            }
            draftsByMaterial = Dictionary(grouping: drafts, by: { $0.materialId! })
        } catch {
            return 0
        }

        var refinedCount = 0
        for (materialId, cards) in draftsByMaterial {
            let context = (try? noteText(forMaterial: materialId))?.reflowed ?? ""
            let candidates = cards.map { CandidatePair(front: $0.front, back: $0.back, sourceLine: $0.sourceLine ?? 0) }
            let refined = await generator.refine(candidates, noteContext: context)
            guard refined.count == cards.count else { continue }
            do {
                try await database.queue.write { db in
                    for (card, result) in zip(cards, refined) {
                        var updated = card
                        updated.front = result.front
                        updated.back = result.back
                        // Not "parser" anymore: protects it from the
                        // scanner's re-import cleanup, which only clears
                        // origin == .parser drafts. Still status == .draft
                        // -- refinement is not the same as approval.
                        updated.origin = .ollama
                        updated.updatedAt = Date()
                        try updated.save(db)
                    }
                }
                refinedCount += cards.count
            } catch {
                continue
            }
        }
        reload()
        return refinedCount
    }

    /// The default cap on how many additional cards a single note can
    /// contribute per run -- a note the parser already covered well should
    /// yield few or none; this just keeps one unusually chatty response
    /// from flooding a deck.
    private static let defaultMaxGeneratedPerNote = 3

    /// Proposes new cards for concepts a note's own text implies but the
    /// parser's fixed extraction shapes didn't happen to capture -- e.g. a
    /// term used in passing but never given its own definition line. Grouped
    /// by source note exactly like `refineDraftCards`, since the model's
    /// only source of truth is that note's own text, not general knowledge.
    /// Every new card lands as `origin: .aiGenerated, status: .draft`: gated
    /// behind the same review queue as everything else, and permanently
    /// distinguishable afterward (unlike `.ollama`, this origin is never
    /// reassigned on approval) so it stays clear which cards came straight
    /// from the student's notes and which the AI filled in.
    func generateAdditionalCards(
        inDecks deckIds: [String], maxPerNote: Int = defaultMaxGeneratedPerNote, topic: String? = nil
    ) async -> Int {
        let generator = await CardGenerators.select()
        guard await generator.isAvailable else { return 0 }

        let existingByMaterial: [String: [Card]]
        let deckOfCard: [String: String]
        do {
            let (cards, deckCards) = try await database.queue.read { db -> ([Card], [DeckCard]) in
                let deckCards = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db)
                let cardIds = deckCards.map(\.cardId)
                guard !cardIds.isEmpty else { return ([], []) }
                let cards = try Card
                    .filter(cardIds.contains(Column("id")))
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

        // Seeded across every note in scope up front, not rebuilt per note,
        // so a proposal that duplicates a card from a *different* source
        // note in the same deck is still caught, exactly like import-time
        // suppression already does across a whole deck.
        var duplicateIndex = DuplicateDetector.Index(existingByMaterial.values.flatMap { $0 })
        var createdCount = 0

        for (materialId, existing) in existingByMaterial {
            guard let context = (try? noteText(forMaterial: materialId))?.reflowed, !context.isEmpty,
                  let deckId = existing.first.flatMap({ deckOfCard[$0.id] })
            else { continue }
            let candidates = existing.map { CandidatePair(front: $0.front, back: $0.back, sourceLine: $0.sourceLine ?? 0) }
            let proposed = await generator.generateAdditional(
                existing: candidates, noteContext: context, maxCount: maxPerNote, topic: topic
            )
            guard !proposed.isEmpty else { continue }

            // `duplicateIndex` is only ever read/mutated back on this
            // (non-concurrent) loop, never inside the `write` closure
            // itself -- a snapshot goes in, a fresh local copy does the
            // work under the closure's own isolation, and the actually-
            // inserted rows come back out to fold into the real index.
            let indexSnapshot = duplicateIndex
            do {
                let inserted = try await database.queue.write { db -> [(id: String, front: String, back: String)] in
                    var localIndex = indexSnapshot
                    var next = try Int.fetchOne(db, sql:
                        "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                        arguments: [deckId]
                    ) ?? 0
                    var inserted: [(id: String, front: String, back: String)] = []
                    for generated in proposed {
                        guard localIndex.matchId(front: generated.front, back: generated.back) == nil else { continue }
                        let card = Card(
                            materialId: materialId, front: generated.front, back: generated.back,
                            origin: .aiGenerated, status: .draft
                        )
                        try card.save(db)
                        try DeckCard(deckId: deckId, cardId: card.id, sortIndex: next).save(db)
                        localIndex.insert(id: card.id, front: generated.front, back: generated.back)
                        inserted.append((card.id, generated.front, generated.back))
                        next += 1
                    }
                    return inserted
                }
                for item in inserted {
                    duplicateIndex.insert(id: item.id, front: item.front, back: item.back)
                }
                createdCount += inserted.count
            } catch {
                continue
            }
        }
        reload()
        return createdCount
    }

    func reload() {
        do {
            try database.queue.read { db in
                semesters = try Semester.order(Column("sortKey")).fetchAll(db)
                let courses = try Course
                    .filter(Column("isArchived") == false)
                    .order(Column("sortIndex"), Column("name"))
                    .fetchAll(db)
                coursesBySemester = Dictionary(grouping: courses, by: \.semesterId)
                archivedCourses = try Course
                    .filter(Column("isArchived") == true)
                    .order(Column("updatedAt").desc)
                    .fetchAll(db)
                excludedFolders = try ExcludedFolder
                    .order(Column("excludedAt").desc)
                    .fetchAll(db)
                    .map(\.folderPath)

                let decks = try Deck.filter(Column("deletedAt") == nil).fetchAll(db)
                coursesWithDecks = Set(decks.map(\.courseId))
                var counts: [String: (Int, Int)] = [:]
                let now = Date()
                for deck in decks {
                    let cardIds = try DeckCard.filter(Column("deckId") == deck.id).fetchAll(db).map(\.cardId)
                    guard !cardIds.isEmpty else { counts[deck.id] = (0, 0); continue }
                    let cards = try Card
                        .filter(cardIds.contains(Column("id")))
                        .filter(Column("deletedAt") == nil)
                        .filter(Column("status") != CardStatus.suspended.rawValue)
                        .fetchAll(db)
                    let due = cards.filter { $0.status == .active && $0.due <= now }.count
                    counts[deck.id] = (cards.count, due)
                }
                deckCounts = counts
            }
        } catch {
            importError = "Failed to read database: \(error)"
        }
        revision += 1
    }

    func hasDecks(inCourse courseId: String) -> Bool {
        coursesWithDecks.contains(courseId)
    }

    /// What `DeckDetailView` and the study/learn/test flows are scoped to:
    /// one real deck, or the "All Cards" master category spanning every
    /// deck in a course. The plural `AppStore` methods above
    /// (`cards(inDecks:)`, `dueCards(inDecks:)`, etc.) are what make the
    /// `.course` case possible without a parallel set of course-wide
    /// models -- it's the same data, just queried across more decks.
    enum DeckScope: Hashable, Sendable {
        case deck(String)
        case course(String)
    }

    /// One group of two or more near-duplicate cards already sitting in a
    /// deck, for the "Remove Duplicates" review flow -- the backlog
    /// counterpart to `VaultScanner`'s import-time suppression, which only
    /// prevents *new* duplicates going forward.
    struct DuplicateGroup: Identifiable {
        var id: String { cards[0].id }
        let cards: [Card]
        let suggestedKeepId: String
        /// True when two or more cards in the group each carry real review
        /// history -- deleting either would throw away real study data, so
        /// the review sheet defaults this group to "keep both" rather than
        /// guessing which history to discard.
        let hasCompetingHistory: Bool
    }

    func duplicateGroups(inDeck deckId: String) throws -> [DuplicateGroup] {
        try duplicateGroups(inDecks: [deckId])
    }

    /// The plural of the above -- run across every deck in a course at
    /// once, so a duplicate that crept in via two different decks (not
    /// just two notes in the same one) shows up too.
    func duplicateGroups(inDecks deckIds: [String]) throws -> [DuplicateGroup] {
        let deckCards = try cards(inDecks: deckIds)
        return DuplicateDetector.groups(deckCards).map { group in
            let withHistory = group.filter { $0.reps > 0 }
            let keeper = group.max { lhs, rhs in
                Self.duplicateKeepRank(lhs).lexicographicallyPrecedes(Self.duplicateKeepRank(rhs))
            }
            return DuplicateGroup(
                cards: group,
                suggestedKeepId: keeper?.id ?? group[0].id,
                hasCompetingHistory: withHistory.count >= 2
            )
        }
    }

    /// Higher wins. Real review history first (deleting it loses study
    /// data a history-free twin doesn't have), then a hand-edited card
    /// over parsed output, then active over draft over suspended (keeping
    /// a suspended twin would silently pull the concept out of study),
    /// then the fuller definition, then simply the older row.
    private static func duplicateKeepRank(_ card: Card) -> [Int] {
        let statusRank: Int
        switch card.status {
        case .active: statusRank = 2
        case .draft: statusRank = 1
        case .suspended: statusRank = 0
        }
        return [
            card.reps > 0 ? 1 : 0,
            card.origin == .manual ? 1 : 0,
            statusRank,
            card.back.count,
            Int(-card.createdAt.timeIntervalSince1970),
        ]
    }

    func courses(inSemester semesterId: String?) -> [Course] {
        coursesBySemester[semesterId] ?? []
    }

    /// Every course with no timeline assigned, vault-imported or manually
    /// added alike -- the explicit "No Timeline" destination, not a
    /// leftover bucket for manually-added courses only. A folder-backed
    /// course with no semester used to be filtered out of this list even
    /// though it still showed on the dashboard, which made it invisible in
    /// the sidebar entirely; this keeps the two views in agreement.
    var unfiledCourses: [Course] {
        coursesBySemester[nil] ?? []
    }

    struct DeckSummary: Identifiable, Sendable {
        var id: String { deckId }
        let deckId: String
        let deckName: String
        let courseId: String
        let courseName: String
        let cardCount: Int
        let dueCount: Int
        /// Cards with at least one review, for the "N/M cards reviewed"
        /// progress a deck shows on the dashboard.
        let reviewedCount: Int
        let lastReviewedAt: Date?
    }

    /// Every deck with its card/due counts, course name, and last-studied
    /// timestamp in one query -- the Home dashboard's entire data need,
    /// since it has to rank across every course at once (which deck to
    /// "jump back into", which courses have cards due) rather than one
    /// course at a time like the rest of the app.
    func dashboardDecks(now: Date = Date()) throws -> [DeckSummary] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT deck.id AS deckId, deck.name AS deckName, course.id AS courseId, course.name AS courseName,
                       COUNT(DISTINCT CASE WHEN card.deletedAt IS NULL AND card.status != 'suspended' THEN card.id END) AS cardCount,
                       COUNT(DISTINCT CASE WHEN card.deletedAt IS NULL AND card.status = 'active' AND card.due <= ? THEN card.id END) AS dueCount,
                       COUNT(DISTINCT CASE WHEN card.deletedAt IS NULL AND card.reps > 0 THEN card.id END) AS reviewedCount,
                       MAX(review.reviewedAt) AS lastReviewedAt
                FROM deck
                JOIN course ON course.id = deck.courseId
                LEFT JOIN deckCard ON deckCard.deckId = deck.id
                LEFT JOIN card ON card.id = deckCard.cardId
                LEFT JOIN review ON review.cardId = card.id
                WHERE deck.deletedAt IS NULL
                GROUP BY deck.id
                """, arguments: [now])
                .map { row in
                    DeckSummary(
                        deckId: row["deckId"], deckName: row["deckName"], courseId: row["courseId"],
                        courseName: row["courseName"], cardCount: row["cardCount"], dueCount: row["dueCount"],
                        reviewedCount: row["reviewedCount"], lastReviewedAt: row["lastReviewedAt"]
                    )
                }
        }
    }

    func deck(_ id: String) throws -> Deck? {
        try database.queue.read { db in try Deck.fetchOne(db, key: id) }
    }

    func course(_ id: String) throws -> Course? {
        try database.queue.read { db in try Course.fetchOne(db, key: id) }
    }

    func decks(inCourse courseId: String) throws -> [Deck] {
        try database.queue.read { db in
            try Deck
                .filter(Column("courseId") == courseId)
                .filter(Column("deletedAt") == nil)
                .order(Column("sortIndex"), Column("chapter"), Column("name"))
                .fetchAll(db)
        }
    }

    func cards(inDeck deckId: String) throws -> [Card] {
        try cards(inDecks: [deckId])
    }

    /// The plural of the above -- the "All Cards" master category's entire
    /// data need is this fetch across every deck in a course instead of
    /// one, ordered deck-by-deck (each deck's own `sortIndex` order kept
    /// intact) rather than interleaved by raw index value.
    func cards(inDecks deckIds: [String]) throws -> [Card] {
        try database.queue.read { db in
            let cardIds = try DeckCard
                .filter(deckIds.contains(Column("deckId")))
                .order(Column("deckId"), Column("sortIndex"))
                .fetchAll(db)
                .map(\.cardId)
            guard !cardIds.isEmpty else { return [] }
            var cards = try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .fetchAll(db)
            let order = Dictionary(uniqueKeysWithValues: cardIds.enumerated().map { ($1, $0) })
            cards.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            return cards
        }
    }

    struct SearchResult: Identifiable, Sendable {
        var id: String { materialId }
        let materialId: String
        let title: String
        let snippet: String
    }

    /// Full-text search over every imported note's reflowed body via the
    /// `noteFTS` table (FTS5, synchronized with `noteText`). The FTS
    /// table's rowid mirrors `noteText`'s implicit integer rowid, not its
    /// `materialId` text primary key, so the join goes through that rowid
    /// rather than directly to `material`.
    func searchNotes(query: String) throws -> [SearchResult] {
        let sanitized = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { "\($0)*" }
            .joined(separator: " ")
        guard !sanitized.isEmpty else { return [] }

        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT material.id AS materialId, material.title AS title,
                       snippet(noteFTS, 0, '**', '**', '…', 12) AS snippet
                FROM noteFTS
                JOIN noteText ON noteText.rowid = noteFTS.rowid
                JOIN material ON material.id = noteText.materialId
                WHERE noteFTS MATCH ?
                ORDER BY rank
                LIMIT 40
                """, arguments: [sanitized])
                .map { row in
                    SearchResult(materialId: row["materialId"], title: row["title"], snippet: row["snippet"])
                }
        }
    }

    func material(_ id: String) throws -> Material? {
        try database.queue.read { db in try Material.fetchOne(db, key: id) }
    }

    func noteText(forMaterial materialId: String) throws -> NoteText? {
        try database.queue.read { db in try NoteText.fetchOne(db, key: materialId) }
    }

    func updateCard(_ card: Card) throws {
        try database.queue.write { db in try card.save(db) }
        reload()
    }

    /// Soft delete: sets `deletedAt` rather than removing the row, so a
    /// card's review history stays intact for stats even after removal
    /// from every deck view.
    func deleteCard(_ cardId: String) throws {
        try database.queue.write { db in
            guard var card = try Card.fetchOne(db, key: cardId) else { return }
            card.deletedAt = Date()
            card.updatedAt = Date()
            try card.save(db)
        }
        reload()
    }

    func setCardStatus(_ cardId: String, status: CardStatus) throws {
        try database.queue.write { db in
            guard var card = try Card.fetchOne(db, key: cardId) else { return }
            card.status = status
            card.updatedAt = Date()
            try card.save(db)
        }
        reload()
    }

    /// SQLite's `IN (...)` caps at a few hundred bound parameters on some
    /// builds -- unreachable at today's deck sizes, but a "select all in a
    /// huge deck" is a real enough path to guard cheaply rather than trust.
    private static let sqlVariableChunkSize = 500

    /// The plural of `setCardStatus`/`deleteCard`, for a multi-selected
    /// batch: one transaction and one `reload()` for the whole selection,
    /// not N of each.
    func bulkSetStatus(_ cardIds: [String], status: CardStatus) throws {
        guard !cardIds.isEmpty else { return }
        try database.queue.write { db in
            let now = Date()
            for chunk in cardIds.chunked(into: Self.sqlVariableChunkSize) {
                try Card
                    .filter(chunk.contains(Column("id")))
                    .filter(Column("deletedAt") == nil)
                    .updateAll(db, Column("status").set(to: status.rawValue), Column("updatedAt").set(to: now))
            }
        }
        reload()
    }

    /// The plural of `deleteCard` -- same soft-delete semantics, batched.
    func bulkDeleteCards(_ cardIds: [String]) throws {
        guard !cardIds.isEmpty else { return }
        try database.queue.write { db in
            let now = Date()
            for chunk in cardIds.chunked(into: Self.sqlVariableChunkSize) {
                try Card
                    .filter(chunk.contains(Column("id")))
                    .filter(Column("deletedAt") == nil)
                    .updateAll(db, Column("deletedAt").set(to: now), Column("updatedAt").set(to: now))
            }
        }
        reload()
    }

    /// The plural of `moveCard`. `cardIds` must already be in display
    /// order -- a `Set`'s iteration order is unspecified and would
    /// scramble the destination deck's `sortIndex`.
    func bulkMoveCards(_ cardIds: [String], toDeck targetDeckId: String) throws {
        guard !cardIds.isEmpty else { return }
        try database.queue.write { db in
            guard let target = try Deck.fetchOne(db, key: targetDeckId), target.deletedAt == nil else { return }
            for chunk in cardIds.chunked(into: Self.sqlVariableChunkSize) {
                try DeckCard.filter(chunk.contains(Column("cardId"))).deleteAll(db)
            }
            var next = try Int.fetchOne(db, sql:
                "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                arguments: [targetDeckId]
            ) ?? 0
            for cardId in cardIds {
                try DeckCard(deckId: targetDeckId, cardId: cardId, sortIndex: next).insert(db)
                next += 1
            }
        }
        reload()
    }

    /// Bulk-promotes every draft card in a deck to active, so a deck the
    /// parser filled with good pairs can be studied without clicking
    /// through each card one at a time.
    func approveAllDrafts(inDeck deckId: String) throws {
        try approveAllDrafts(inDecks: [deckId])
    }

    /// The plural of the above, for the "All Cards" master category's own
    /// "Approve all drafts" action across every deck in the course at once.
    func approveAllDrafts(inDecks deckIds: [String]) throws {
        try database.queue.write { db in
            let cardIds = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
            try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("status") == CardStatus.draft.rawValue)
                .updateAll(db, Column("status").set(to: CardStatus.active.rawValue), Column("updatedAt").set(to: Date()))
        }
        reload()
    }

    /// Every active, non-deleted card in a deck that is due now -- the
    /// queue a flashcard session studies. Snapshotted once at session
    /// start; newly-due cards during the session wait for the next one.
    /// In the final week before an exam on this deck's course, order
    /// switches from plain due-date to weakest-retention-first, so
    /// cramming spends time where it matters most.
    func dueCards(inDeck deckId: String, now: Date = Date()) throws -> [Card] {
        try dueCards(inDecks: [deckId], now: now)
    }

    /// The plural of the above -- every decks' worth of any set of decks
    /// sharing one course, exam-biased the same way (any one deck's
    /// `courseId` resolves the exam, since a course-wide caller always
    /// passes decks from a single course).
    func dueCards(inDecks deckIds: [String], now: Date = Date()) throws -> [Card] {
        try database.queue.read { db in
            let cardIds = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
            guard !cardIds.isEmpty else { return [] }
            var cards = try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .filter(Column("status") == CardStatus.active.rawValue)
                .filter(Column("due") <= now)
                .order(Column("due"))
                .fetchAll(db)

            if let firstDeckId = deckIds.first,
               let deck = try Deck.fetchOne(db, key: firstDeckId),
               let exam = try Self.nearestUpcomingExam(forCourseId: deck.courseId, now: now, db: db),
               ExamBias.isInFinalWeek(now: now, examDate: exam.examDate) {
                cards.sort { a, b in
                    let elapsedA = a.lastReview.map { max(0, now.timeIntervalSince($0) / 86400) } ?? 0
                    let elapsedB = b.lastReview.map { max(0, now.timeIntervalSince($0) / 86400) } ?? 0
                    let retrievabilityA = FSRS.retrievability(elapsedDays: elapsedA, stability: a.stability)
                    let retrievabilityB = FSRS.retrievability(elapsedDays: elapsedB, stability: b.stability)
                    return retrievabilityA < retrievabilityB
                }
            }
            return cards
        }
    }

    /// Grades one card via FSRS, persists the new scheduler state, and logs
    /// a `review` row. `source` records which study mode produced the
    /// grade (flashcards, learn, test, ...) for later stats. If this
    /// card's course has an upcoming exam and FSRS would schedule its next
    /// review after that date, the interval is capped to land before it
    /// instead -- a review that lands after the test doesn't help for it.
    func gradeCard(_ cardId: String, grade: FSRS.Grade, source: String, now: Date = Date()) throws {
        try database.queue.write { db in
            guard var card = try Card.fetchOne(db, key: cardId) else { return }
            let snapshot = FSRS.Snapshot(
                stability: card.stability, difficulty: card.difficulty, reps: card.reps,
                lapses: card.lapses, state: FSRS.CardState(rawValue: card.schedulerState) ?? .new,
                lastReview: card.lastReview
            )
            var result = FSRS.schedule(snapshot, grade: grade, now: now)
            // A parsed card's course comes from its source material; a
            // hand-typed one has no material at all (`materialId == nil`)
            // and must resolve the same way through its deck instead, or
            // it silently never gets exam-biased scheduling like every
            // other card in the same deck does.
            let courseId: String?
            if let materialId = card.materialId {
                courseId = try Material.fetchOne(db, key: materialId)?.courseId
            } else {
                courseId = try String.fetchOne(db, sql: """
                    SELECT deck.courseId FROM deckCard
                    JOIN deck ON deck.id = deckCard.deckId
                    WHERE deckCard.cardId = ? LIMIT 1
                    """, arguments: [cardId])
            }
            if let courseId, let exam = try Self.nearestUpcomingExam(forCourseId: courseId, now: now, db: db) {
                result.due = ExamBias.capDue(result.due, examDate: exam.examDate)
            }
            let dueBefore = card.due

            card.due = result.due
            card.stability = result.stability
            card.difficulty = result.difficulty
            card.elapsedDays = result.elapsedDays
            card.scheduledDays = result.scheduledDays
            card.reps = result.reps
            card.lapses = result.lapses
            card.schedulerState = result.state.rawValue
            card.lastReview = now
            card.updatedAt = now
            try card.save(db)

            try Review(
                cardId: cardId, reviewedAt: now, grade: grade.rawValue, source: source,
                dueBefore: dueBefore, dueAfter: result.due,
                stabilityAfter: result.stability, difficultyAfter: result.difficulty,
                schedulerVersion: "fsrs-5"
            ).save(db)
        }
        reload()
    }

    /// Builds one Learn round for a deck: cards not yet mastered,
    /// least-recently-seen first, escalating question type per card via
    /// `LearnEngine` -- and once most of the deck is mastered, the round
    /// switches to a random reinforcement sample of the whole deck rather
    /// than being stuck cycling the last few stragglers forever (see
    /// `LearnEngine.buildRound`).
    func learnRound(deckId: String) throws -> [LearnEngine.RoundQuestion] {
        try learnRound(deckIds: [deckId])
    }

    /// The plural of the above -- a course-wide Learn round draws its
    /// ladder candidates from every deck in the course at once.
    func learnRound(deckIds: [String]) throws -> [LearnEngine.RoundQuestion] {
        try database.queue.read { db in
            let candidates = try Self.learnCandidates(forDecks: deckIds, db: db)
                .sorted { a, b in
                    a.lastSeenAt ?? .distantPast < b.lastSeenAt ?? .distantPast
                }
                .map(\.candidate)
            var rng = SystemRandomNumberGenerator()
            return LearnEngine.buildRound(from: candidates, using: &rng)
        }
    }

    private static func learnCandidates(
        forDeck deckId: String, db: Database
    ) throws -> [(candidate: LearnEngine.Candidate, lastSeenAt: Date?)] {
        try learnCandidates(forDecks: [deckId], db: db)
    }

    private static func learnCandidates(
        forDecks deckIds: [String], db: Database
    ) throws -> [(candidate: LearnEngine.Candidate, lastSeenAt: Date?)] {
        let cardIds = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
        guard !cardIds.isEmpty else { return [] }
        let cards = try Card
            .filter(cardIds.contains(Column("id")))
            .filter(Column("deletedAt") == nil)
            .filter(Column("status") == CardStatus.active.rawValue)
            .fetchAll(db)
        let states = try LearnState.filter(cardIds.contains(Column("cardId"))).fetchAll(db)
        let stateByCard = Dictionary(uniqueKeysWithValues: states.map { ($0.cardId, $0) })

        return cards.map { card in
            let state = stateByCard[card.id]
            let level = LearnEngine.Level(rawValue: state?.level ?? 0) ?? .new
            let candidate = LearnEngine.Candidate(cardId: card.id, front: card.front, back: card.back, level: level)
            return (candidate, state?.lastSeenAt)
        }
    }

    /// Records one Learn-mode answer: advances the card's ladder level and
    /// streak, independent of FSRS scheduling.
    func recordLearnAnswer(cardId: String, wasCorrect: Bool, now: Date = Date()) throws {
        try database.queue.write { db in
            let existing = try LearnState.fetchOne(db, key: cardId)
            let currentLevel = LearnEngine.Level(rawValue: existing?.level ?? 0) ?? .new
            let (nextLevel, streak) = LearnEngine.advance(
                level: currentLevel, consecutiveCorrect: existing?.consecutiveCorrect ?? 0, wasCorrect: wasCorrect
            )
            try LearnState(cardId: cardId, level: nextLevel.rawValue, consecutiveCorrect: streak, lastSeenAt: now)
                .save(db)
        }
        reload()
    }

    /// How much of a deck has been proven understood -- the same
    /// `learnState.level == mastered` signal `markCard`, Learn mode, and
    /// test filtering all share, surfaced here for progress bars.
    func deckMastery(deckId: String) throws -> (mastered: Int, total: Int) {
        try deckMastery(deckIds: [deckId])
    }

    /// The plural of the above, for Learn mode's mastery bar when run
    /// across every deck in a course.
    func deckMastery(deckIds: [String]) throws -> (mastered: Int, total: Int) {
        try database.queue.read { db in
            let candidates = try Self.learnCandidates(forDecks: deckIds, db: db).map(\.candidate)
            let mastered = candidates.filter { $0.level == .mastered }.count
            return (mastered, candidates.count)
        }
    }

    /// Every card in a deck's current Learn ladder level, for the review
    /// queue's "Needs Review" / "Understood" badges. A card absent from
    /// the result has no `learnState` row yet, i.e. level 0 / new.
    func learnLevels(forDeck deckId: String) throws -> [String: LearnEngine.Level] {
        try learnLevels(forDecks: [deckId])
    }

    /// The plural of the above, for the "All Cards" master category's own
    /// mastery badges across every deck in the course.
    func learnLevels(forDecks deckIds: [String]) throws -> [String: LearnEngine.Level] {
        try database.queue.read { db in
            let candidates = try Self.learnCandidates(forDecks: deckIds, db: db)
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0.candidate.cardId, $0.candidate.level) })
        }
    }

    /// The Study screen's simplified two-option grading: "Needs Review" or
    /// "I Know This" stands in for FSRS's four-grade scale in the UI, but
    /// FSRS still schedules under the hood (mapped to Again/Good) so due
    /// dates stay meaningful. The mastery signal itself -- shared with
    /// Learn mode and test filtering via `learnState.level` -- moves
    /// straight to its end state (mastered, or reset to new) rather than
    /// Learn mode's gradual step-by-step ladder: a flashcard swipe is a
    /// direct, final call the user is making, not an escalating quiz.
    func markCard(_ cardId: String, understood: Bool, source: String = "flashcards", now: Date = Date()) throws {
        try gradeCard(cardId, grade: understood ? .good : .again, source: source, now: now)
        try database.queue.write { db in
            try LearnState(
                cardId: cardId,
                level: understood ? LearnEngine.Level.mastered.rawValue : LearnEngine.Level.new.rawValue,
                consecutiveCorrect: understood ? 1 : 0, lastSeenAt: now
            ).save(db)
        }
        reload()
    }

    /// Starts a test: builds questions from every active card in the deck,
    /// writes the `testAttempt` and one `testItem` row per question up
    /// front (answers filled in as the user submits them), and returns the
    /// attempt id alongside the in-memory questions the UI drives from.
    func startTest(deckId: String, config: TestBuilder.Config) throws -> (attemptId: String, questions: [LearnEngine.RoundQuestion]) {
        try startTest(deckIds: [deckId], config: config)
    }

    /// The plural of the above, for a test run across every deck in a
    /// course. `testAttempt.deckId` is nullable precisely for this case --
    /// a course-wide attempt isn't attributable to any single deck, so it
    /// stores `nil` rather than picking one arbitrarily.
    func startTest(
        deckIds: [String], config: TestBuilder.Config
    ) throws -> (attemptId: String, questions: [LearnEngine.RoundQuestion]) {
        try database.queue.write { db in
            var cards = try Self.learnCandidates(forDecks: deckIds, db: db).map(\.candidate)
            if config.excludeMastered {
                cards = cards.filter { $0.level != .mastered }
            }
            var rng = SystemRandomNumberGenerator()
            let pool = cards.map { (cardId: $0.cardId, front: $0.front, back: $0.back) }
            let questions = TestBuilder.build(from: pool, config: config, using: &rng)

            let attempt = TestAttempt(
                deckId: deckIds.count == 1 ? deckIds.first : nil, configJSON: "{}", startedAt: Date()
            )
            try attempt.insert(db)
            for (index, question) in questions.enumerated() {
                try TestItem(
                    id: question.cardId + "-" + attempt.id, attemptId: attempt.id, cardId: question.cardId,
                    ordinal: index, questionType: question.type.rawValue, promptText: question.prompt,
                    choicesJSON: question.choices.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) },
                    correctAnswer: question.correctAnswer
                ).insert(db)
            }
            return (attempt.id, questions)
        }
    }

    /// Records one answer to a test item, and grades it immediately so the
    /// results screen never has to re-derive correctness.
    func submitTestAnswer(attemptId: String, cardId: String, given: String, isCorrect: Bool) throws {
        try database.queue.write { db in
            guard var item = try TestItem
                .filter(Column("attemptId") == attemptId)
                .filter(Column("cardId") == cardId)
                .fetchOne(db)
            else { return }
            item.givenAnswer = given
            item.isCorrect = isCorrect
            try item.save(db)
        }
    }

    /// Finishes a test: scores it from the recorded items, and feeds every
    /// miss back into FSRS as an "Again" grade so a test session also
    /// tightens the flashcard schedule, not just reports a score.
    func finishTest(attemptId: String) throws -> (correct: Int, total: Int) {
        let result = try database.queue.write { db -> (Int, Int) in
            let items = try TestItem.filter(Column("attemptId") == attemptId).fetchAll(db)
            let correct = items.filter { $0.isCorrect == true }.count

            guard var attempt = try TestAttempt.fetchOne(db, key: attemptId) else {
                return (correct, items.count)
            }
            attempt.finishedAt = Date()
            attempt.scoreNumerator = correct
            attempt.scoreDenominator = items.count
            try attempt.save(db)
            return (correct, items.count)
        }
        try gradeMissedTestItems(attemptId: attemptId)
        return result
    }

    private func gradeMissedTestItems(attemptId: String) throws {
        let missedCardIds = try database.queue.read { db in
            try TestItem
                .filter(Column("attemptId") == attemptId)
                .filter(Column("isCorrect") == false)
                .fetchAll(db)
                .compactMap(\.cardId)
        }
        for cardId in missedCardIds {
            try gradeCard(cardId, grade: .again, source: "test")
        }
    }

    /// The soonest exam still in the future for a course, or nil if none
    /// is set -- both `gradeCard`'s interval capping and `dueCards`'s
    /// final-week reordering are no-ops without one.
    private static func nearestUpcomingExam(forCourseId courseId: String, now: Date, db: Database) throws -> Exam? {
        try Exam
            .filter(Column("courseId") == courseId)
            .filter(Column("examDate") >= now)
            .order(Column("examDate"))
            .fetchOne(db)
    }

    func exams(forCourse courseId: String) throws -> [Exam] {
        try database.queue.read { db in
            try Exam.filter(Column("courseId") == courseId).order(Column("examDate")).fetchAll(db)
        }
    }

    func addExam(courseId: String, name: String, date: Date) throws {
        try database.queue.write { db in
            try Exam(courseId: courseId, name: name, examDate: date).insert(db)
        }
    }

    func deleteExam(_ examId: String) throws {
        try database.queue.write { db in
            _ = try Exam.deleteOne(db, key: examId)
        }
    }

    func materialCount(inCourse courseId: String) throws -> Int {
        try database.queue.read { db in
            try Material.filter(Column("courseId") == courseId).fetchCount(db)
        }
    }

    func updateCourse(_ course: Course) throws {
        var updated = course
        updated.updatedAt = Date()
        try database.queue.write { db in try updated.save(db) }
        reload()
    }

    /// Hides a course without touching its data. Reversible, and the
    /// scanner reuses the same (still archived) row on re-import rather
    /// than resurrecting it as a new course.
    func setCourseArchived(_ courseId: String, archived: Bool) throws {
        try database.queue.write { db in
            guard var course = try Course.fetchOne(db, key: courseId) else { return }
            course.isArchived = archived
            course.updatedAt = Date()
            try course.save(db)
        }
        reload()
    }

    /// What a delete would actually remove -- so the confirmation can say
    /// it in numbers instead of asking the user to take it on faith.
    /// Cards are counted by current deck membership (`deckCard` -> `deck`
    /// -> `courseId`), not `card.materialId` -> `material.courseId`: the
    /// latter only reaches parser-derived cards and silently excludes every
    /// hand-typed one (`materialId` is nil for those), and would also
    /// disagree with reality for a card that started life in this course's
    /// notes but has since been moved to a different course's deck.
    func courseDeletionImpact(_ courseId: String) throws -> (materials: Int, cards: Int, reviews: Int) {
        try database.queue.read { db in
            let materials = try Material.filter(Column("courseId") == courseId).fetchCount(db)
            let cards = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM card WHERE id IN (
                    SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                )
                """, arguments: [courseId]) ?? 0
            let reviews = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM review WHERE cardId IN (
                    SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                )
                """, arguments: [courseId]) ?? 0
            return (materials, cards, reviews)
        }
    }

    /// Removes a course and everything derived from it. Notes in the vault
    /// are never touched -- this only clears what GRASP built from them,
    /// Marks a vault folder as never-to-be-imported: the next
    /// `scan(vaultRoot:)` skips it before it ever creates a `Material` or
    /// `Course` row for it, rather than merely hiding one that already
    /// exists (`setCourseArchived`) or deleting one that a plain rescan
    /// would just recreate.
    func excludeFolder(_ path: String) throws {
        try database.queue.write { db in
            try ExcludedFolder(folderPath: path).insert(db, onConflict: .ignore)
        }
        reload()
    }

    /// Reverses `excludeFolder` -- the folder is fair game again on the
    /// next scan. Reachable two ways: explicitly, from Settings' "Excluded
    /// Folders" list, or implicitly, by manually adding files back to that
    /// same folder (see `VaultScanner.importPaths`'s own un-exclude step) --
    /// deliberately choosing to bring content back in is as clear a signal
    /// as clicking a button for it.
    func includeFolder(_ path: String) throws {
        try database.queue.write { db in
            _ = try ExcludedFolder.deleteOne(db, key: path)
        }
        reload()
    }

    /// The only way a course is deleted: excludes its vault folder first
    /// (if it has one), so the next scan can never recreate it, then
    /// removes the course and everything derived from it. A
    /// manually-created course has no folder to exclude, so for those
    /// this is just a plain delete -- there's nothing a rescan could ever
    /// recreate in the first place. There's deliberately no separate
    /// "delete but let it come back" option: a course silently
    /// resurrecting on the next import reads as a bug, not a feature
    /// worth a second button.
    func removeCourseAndExclude(_ courseId: String) throws {
        try database.queue.write { db in
            if let folderPath = try Course.fetchOne(db, key: courseId)?.folderPath {
                try ExcludedFolder(folderPath: folderPath).insert(db, onConflict: .ignore)
            }
            // `card.materialId` is ON DELETE SET NULL, so cascading from
            // the course alone would strand its cards instead of removing
            // them -- deleted explicitly first, and by current deck
            // membership rather than `materialId` so a hand-typed card
            // (materialId is nil for those) doesn't survive the delete:
            // its only link to this course is which deck it currently
            // sits in, same as `courseDeletionImpact` above.
            try db.execute(sql: """
                DELETE FROM card WHERE id IN (
                    SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                )
                """, arguments: [courseId])
            _ = try Course.deleteOne(db, key: courseId)
        }
        reload()
    }

    func addManualCourse(name: String, code: String?, semesterId: String? = nil) throws {
        try database.queue.write { db in
            let course = Course(semesterId: semesterId, name: name, code: code)
            try course.insert(db)
        }
        reload()
    }

    /// The manual counterpart to the vault scanner's own private
    /// `findOrCreateSemester`, for a freeform timeline typed by hand
    /// ("Fall 2026", "2026-2027", "Quarter 1") rather than picked from a
    /// fixed term+year dropdown. Slugified the same way the vault
    /// importer's tag format looks ("Fall 2026" -> "fall-2026"), so typing
    /// the exact name of a semester the vault already created reuses that
    /// same row instead of racing it to create a duplicate; anything that
    /// doesn't happen to match that shape still slugifies deterministically
    /// and dedups against itself. New rows sort after every existing one --
    /// there's no reliable way to place arbitrary text chronologically the
    /// way a real term/year can be.
    @discardableResult
    func findOrCreateSemester(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.slugify(trimmed)
        let id = try database.queue.write { db -> String in
            if let existing = try Semester.filter(Column("slug") == slug).fetchOne(db) {
                return existing.id
            }
            let nextSortKey = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortKey), 0) + 1 FROM semester")) ?? 1
            let semester = Semester(name: trimmed, slug: slug, sortKey: nextSortKey)
            try semester.insert(db)
            return semester.id
        }
        reload()
        return id
    }

    /// Falls back to the lowercased text itself, not a fresh random UUID --
    /// a timeline made entirely of characters outside a-z0-9 (any
    /// non-Latin script, or pure punctuation) would otherwise slugify to
    /// "", and a random per-call UUID there would mean typing the exact
    /// same such name twice never dedupes, defeating the whole point of
    /// keying this on a slug in the first place.
    private static func slugify(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(
            of: "[^a-z0-9]+", with: "-", options: .regularExpression
        )
        let trimmed = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? text.lowercased() : trimmed
    }

    /// Courses grouped by semester (newest first) then unfiled, matching
    /// the exact order `SidebarView` already shows -- shared by every
    /// sheet that has to ask "which course?" without the sidebar visible.
    func coursePickerGroups() -> [(title: String, courses: [Course])] {
        var groups: [(title: String, courses: [Course])] = []
        for semester in semesters.reversed() {
            let courses = coursesBySemester[semester.id] ?? []
            if !courses.isEmpty { groups.append((semester.name, courses)) }
        }
        if !unfiledCourses.isEmpty {
            groups.append(("No Timeline", unfiledCourses))
        }
        return groups
    }

    // MARK: - Decks (modules/units)

    /// Appends a hand-named deck to the end of a course's deck ordering.
    /// Auto decks from the vault scanner all carry `sortIndex` 0 (it never
    /// sets one), so `MAX + 1` reliably lands manual decks after every
    /// parsed chapter rather than in front of them.
    @discardableResult
    func createDeck(courseId: String, name: String) throws -> String {
        let id = try database.queue.write { db -> String in
            let next = try Int.fetchOne(db, sql:
                "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deck WHERE courseId = ? AND deletedAt IS NULL",
                arguments: [courseId]
            ) ?? 0
            let deck = Deck(courseId: courseId, name: name, chapter: nil, origin: "manual", sortIndex: next)
            try deck.insert(db)
            return deck.id
        }
        reload()
        return id
    }

    func renameDeck(_ deckId: String, name: String) throws {
        try database.queue.write { db in
            guard var deck = try Deck.fetchOne(db, key: deckId) else { return }
            deck.name = name
            deck.updatedAt = Date()
            try deck.save(db)
        }
        reload()
    }

    /// Active, non-deleted cards only -- what a deletion confirmation
    /// should actually count, not the study-facing `deckCounts` map
    /// (which also excludes suspended cards and would understate what's
    /// about to be touched).
    func deckCardCount(_ deckId: String) throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM deckCard
                JOIN card ON card.id = deckCard.cardId
                WHERE deckCard.deckId = ? AND card.deletedAt IS NULL
                """, arguments: [deckId]) ?? 0
        }
    }

    /// Removes a deck from view. With `migrateCardsTo` given, every card
    /// keeps existing -- only its deck membership moves. With `nil`, the
    /// deck's own cards are soft-deleted (never a hard `DELETE`: `review`
    /// rows cascade from `card`, and a hard delete would take real study
    /// history down with a deck that was just reorganized away).
    func deleteDeck(_ deckId: String, migrateCardsTo targetDeckId: String?) throws {
        try database.queue.write { db in
            guard var deck = try Deck.fetchOne(db, key: deckId) else { return }
            let now = Date()

            if let targetDeckId, targetDeckId != deckId,
               let target = try Deck.fetchOne(db, key: targetDeckId), target.deletedAt == nil {
                // A plain `UPDATE deckCard SET deckId = ?` would abort the
                // whole write the moment a card already sits in both
                // decks (deckCard's primary key is (deckId, cardId)) --
                // insert-or-ignore into the target first, then drop the
                // source rows, so an already-shared card just loses its
                // duplicate membership instead of failing the migration.
                let base = try Int.fetchOne(db, sql:
                    "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                    arguments: [targetDeckId]
                ) ?? 0
                try db.execute(sql: """
                    INSERT OR IGNORE INTO deckCard (deckId, cardId, sortIndex)
                    SELECT ?, cardId, ? + (ROW_NUMBER() OVER (ORDER BY sortIndex) - 1)
                    FROM deckCard WHERE deckId = ?
                    """, arguments: [targetDeckId, base, deckId])
            } else {
                // Only cards whose *sole* membership is this deck --
                // guards against soft-deleting a card that drag-and-drop
                // has already placed in another deck as well.
                try db.execute(sql: """
                    UPDATE card SET deletedAt = ?, updatedAt = ?
                    WHERE id IN (SELECT cardId FROM deckCard WHERE deckId = ?)
                      AND id NOT IN (SELECT cardId FROM deckCard WHERE deckId != ?)
                    """, arguments: [now, now, deckId, deckId])
            }

            try db.execute(sql: "DELETE FROM deckCard WHERE deckId = ?", arguments: [deckId])
            deck.deletedAt = now
            deck.updatedAt = now
            try deck.save(db)
        }
        reload()
    }

    /// Moves a card's deck membership. `moveCard` rather than
    /// `moveCard(from:to:)` -- a card belongs to exactly one deck by
    /// convention, so there's no source to look up, and nothing can go
    /// stale between a drag starting and finishing. Origin is untouched:
    /// which deck a card sits in says nothing about where its text came
    /// from.
    func moveCard(_ cardId: String, toDeck targetDeckId: String) throws {
        try database.queue.write { db in
            guard let target = try Deck.fetchOne(db, key: targetDeckId), target.deletedAt == nil else { return }
            let existing = try DeckCard.filter(Column("cardId") == cardId).fetchAll(db)
            if existing.count == 1, existing[0].deckId == targetDeckId { return }
            try DeckCard.filter(Column("cardId") == cardId).deleteAll(db)
            let next = try Int.fetchOne(db, sql:
                "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                arguments: [targetDeckId]
            ) ?? 0
            try DeckCard(deckId: targetDeckId, cardId: cardId, sortIndex: next).insert(db)
        }
        reload()
    }

    /// A card typed by hand rather than parsed. Status is `.active`, not
    /// `.draft`: the draft/review gate exists to catch parser noise, and a
    /// card someone just wrote by hand has already had the human glance
    /// that gate is there to force -- making them re-approve their own
    /// just-typed card is pure friction.
    @discardableResult
    func createManualCard(front: String, back: String, deckId: String) throws -> String {
        let id = try database.queue.write { db -> String in
            let card = Card(
                materialId: nil, front: front, back: back,
                hasMath: back.contains("\\(") || back.contains("\\["),
                origin: .manual, status: .active
            )
            try card.insert(db)
            let next = try Int.fetchOne(db, sql:
                "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?",
                arguments: [deckId]
            ) ?? 0
            try DeckCard(deckId: deckId, cardId: card.id, sortIndex: next).insert(db)
            return card.id
        }
        reload()
        return id
    }

    func runImport() async {
        guard !isImporting else { return }
        isImporting = true
        importError = nil
        defer { isImporting = false }
        let root = URL(fileURLWithPath: vaultPath)
        do {
            let summary = try await scanner.scan(vaultRoot: root)
            lastImportSummary = summary
            if !summary.errors.isEmpty {
                importError = summary.errors.first
            }
        } catch {
            importError = "Import failed: \(error)"
        }
        reload()
    }

    /// The manual counterpart to `runImport()`: files or folders the user
    /// picked by hand -- anywhere on disk, not necessarily under the vault
    /// -- imported straight into one course. This is what makes a
    /// manually-created course (no vault folder for `runImport()` to ever
    /// find) actually usable, and lets any course pick up a one-off file
    /// that never lived in Obsidian.
    @discardableResult
    func importFiles(_ urls: [URL], intoCourse courseId: String) async -> ImportSummary {
        guard !isImporting else { return ImportSummary() }
        isImporting = true
        importError = nil
        defer { isImporting = false }
        let summary: ImportSummary
        do {
            summary = try await scanner.importPaths(urls, intoCourse: courseId)
            lastImportSummary = summary
            if !summary.errors.isEmpty {
                importError = summary.errors.first
            }
        } catch {
            summary = ImportSummary()
            importError = "Import failed: \(error)"
        }
        reload()
        return summary
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard count > size else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
