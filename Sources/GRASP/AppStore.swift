import Foundation
import Observation
import EventKit
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


    /// Parsed and laid-out diagrams, keyed on material id plus the
    /// overview's `generatedAt` -- see `laidOutDiagram(for:source:)`.
    /// Not observed: it's a memo, and mutating it must never invalidate a
    /// view that is in the middle of reading from it.
    @ObservationIgnored var diagramCache: [String: DiagramCacheEntry] = [:]

    var vaultPath: String {
        didSet { UserDefaults.standard.set(vaultPath, forKey: Self.vaultPathKey(for: profile)) }
    }

    /// Global, per-profile: when on, `startTest` mixes a few ephemeral,
    /// AI-generated written questions in alongside a test's real cards.
    /// Defaults off -- a new AI-mixing behavior shouldn't silently turn on
    /// for existing users.
    var isAITestQuestionsEnabled: Bool {
        didSet { UserDefaults.standard.set(isAITestQuestionsEnabled, forKey: Self.aiTestQuestionsKey(for: profile)) }
    }

    private(set) var lastImportSummary: ImportSummary?
    private(set) var isImporting = false
    private(set) var importError: String?

    /// Populated automatically after every import/rescan (`runImport`,
    /// `importFiles`) by a vault-wide duplicate scan -- continuous, not
    /// something you have to remember to trigger by hand in Settings. The
    /// UI (`ContentView`) presents the same `DuplicateReviewSheet` as the
    /// manual scan whenever this is non-empty, then clears it via
    /// `clearPendingDuplicates()` so it doesn't reappear until the next
    /// import actually changes something.
    private(set) var pendingDuplicateGroups: [DuplicateGroup] = []

    func clearPendingDuplicates() {
        markDuplicateGroupsSeen(pendingDuplicateGroups)
        pendingDuplicateGroups = []
    }

    /// Offers the review sheet only when the import turned up a group the
    /// student hasn't already been shown. It used to reappear after every
    /// import with the same groups -- including ones deliberately kept.
    private func scanForDuplicatesAfterImport() {
        let groups = (try? duplicateGroupsAcrossAllCourses()) ?? []
        let seen = Set(UserDefaults.standard.stringArray(forKey: seenDuplicatesKey) ?? [])
        let fresh = groups.filter { !seen.contains(Self.signature(of: $0)) }
        pendingDuplicateGroups = fresh.isEmpty ? [] : groups
    }

    /// Records the groups on screen as seen, whatever was decided about them.
    func markDuplicateGroupsSeen(_ groups: [DuplicateGroup]) {
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenDuplicatesKey) ?? [])
        seen.formUnion(groups.map(Self.signature))
        UserDefaults.standard.set(Array(seen), forKey: seenDuplicatesKey)
    }

    private var seenDuplicatesKey: String { "seenDuplicateGroups.\(profile.id)" }

    private static func signature(of group: DuplicateGroup) -> String {
        group.cards.map(\.id).sorted().joined(separator: ",")
    }

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
    /// Set when the profile's database couldn't be opened and the app is
    /// running on a throwaway in-memory one instead.
    let databaseOpenError: String?

    /// Sync with the profile's account, when it has one. Set at the end of
    /// `init` because it calls back into the store.
    private(set) var sync: SyncController!

    /// This profile's own preferences, which every `@AppStorage` under the
    /// profile's window reads (see `GRASPApp`). They used to live in the
    /// shared defaults, so one person's daily goal, focus timer and sort
    /// order were everyone's.
    let preferences: UserDefaults

    private static let perProfilePreferenceKeys = [
        "dailyCardGoal", "focusWorkMinutes", "focusBreakMinutes", "focusCardTarget",
        "deckSortOption", "cardSortOption", "deckListCollapsed",
    ]

    private static func preferences(for profile: Profile) -> UserDefaults {
        guard profile.id != Profile.previewID,
              let suite = UserDefaults(suiteName: "com.tyvillan.grasp.profile.\(profile.id)")
        else { return .standard }
        // Once: a profile that was already in use keeps the settings it had
        // when they were shared. A brand-new profile starts from defaults.
        if !suite.bool(forKey: "migratedSharedPreferences") {
            let shared = UserDefaults.standard
            if shared.object(forKey: vaultPathKey(for: profile)) != nil {
                for key in perProfilePreferenceKeys {
                    if let value = shared.object(forKey: key) { suite.set(value, forKey: key) }
                }
            }
            suite.set(true, forKey: "migratedSharedPreferences")
        }
        return suite
    }

    private static let vaultPathKey = "vaultPath"

    /// Per-profile UserDefaults key so switching profiles doesn't leak
    /// one person's vault path into another's settings.
    private static func vaultPathKey(for profile: Profile) -> String { "\(vaultPathKey).\(profile.id)" }

    private static let aiTestQuestionsKey = "aiTestQuestionsEnabled"
    private static func aiTestQuestionsKey(for profile: Profile) -> String { "\(aiTestQuestionsKey).\(profile.id)" }

    /// - Parameter profile: whose database this store opens. `.preview`
    ///   (an ephemeral in-memory profile) is used by SwiftUI previews and
    ///   the design-time default; real launches always pass a profile the
    ///   user picked or that migration produced.
    init(profile: Profile) {
        self.profile = profile
        let db: GRASPDatabase
        var openError: String?
        if profile.id == Profile.previewID {
            db = try! GRASPDatabase.inMemory()
        } else {
            let support = (try? GRASPDatabase.supportDirectory()) ?? FileManager.default.temporaryDirectory
            do {
                db = try GRASPDatabase(path: profile.databaseURL(supportDirectory: support))
            } catch {
                // Still falls back so the app can open at all, but says so:
                // silently studying into a scratch database meant every
                // import and review was thrown away on quit.
                db = try! GRASPDatabase.inMemory()
                openError = "GRASP couldn't open this profile's library (\(error.localizedDescription)). "
                    + "Nothing you do now will be saved -- quit and reopen, or switch profiles."
            }
        }
        self.database = db
        self.databaseOpenError = openError
        self.preferences = Self.preferences(for: profile)
        self.scanner = VaultScanner(database: db)
        // A new profile starts with no vault. Defaulting to this Mac owner's
        // vault meant a second person's first Import pulled the owner's
        // notes into their profile -- the mixing profiles exist to prevent.
        self.vaultPath = UserDefaults.standard.string(forKey: Self.vaultPathKey(for: profile)) ?? ""
        self.isAITestQuestionsEnabled = UserDefaults.standard.bool(forKey: Self.aiTestQuestionsKey(for: profile))
        reload()
        sync = SyncController(database: db, profile: profile) { [weak self] in self?.reload() }
        sync.start()
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
        let drafts: [Card]
        do {
            let cardIds = try await database.queue.read { db in
                try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
            }
            guard !cardIds.isEmpty else { return 0 }
            drafts = try await database.queue.read { db in
                try Card
                    .filter(cardIds.contains(Column("id")))
                    .filter(Column("status") == CardStatus.draft.rawValue)
                    // Deleted drafts keep their deck rows; without this they
                    // were sent to the model and rewritten -- including ones
                    // the context check had removed a moment before.
                    .filter(Column("deletedAt") == nil)
                    .fetchAll(db)
            }
        } catch {
            return 0
        }
        return await refineWording(of: drafts)
    }

    /// Wording cleanup (parsing artifacts, awkward phrasing) for exactly
    /// these cards, grouped by source note for context -- the shared
    /// engine behind `refineDraftCards` (draft-only, deck-scoped) and
    /// `refineCard` (any single card, any status). No status filter here
    /// at all: which cards are even offered to it is entirely the
    /// caller's job. Cards with no `materialId` are dropped -- there's no
    /// note to ground a rewrite in. Fails soft, same as every other
    /// generator-backed flow: no generator, no note text, or a mid-batch
    /// DB error just leaves that batch of cards untouched rather than
    /// throwing.
    private func refineWording(of cards: [Card]) async -> Int {
        let generator = await CardGenerators.select()
        guard await generator.isAvailable else { return 0 }
        let withNotes = cards.filter { $0.materialId != nil }
        guard !withNotes.isEmpty else { return 0 }
        let byMaterial = Dictionary(grouping: withNotes, by: { $0.materialId! })

        let progress = AIProgress.current
        var refinedCount = 0
        for (index, (materialId, materialCards)) in byMaterial.enumerated() {
            if Task.isCancelled { break }
            let context = (try? noteText(forMaterial: materialId))?.reflowed ?? ""
            let candidates = materialCards.map {
                CandidatePair(front: $0.front, back: $0.back, sourceLine: $0.sourceLine ?? 0)
            }
            progress?.begin("Rewording cards from note \(index + 1) of \(byMaterial.count)")
            let refined = await generator.refine(candidates, noteContext: context)
            progress?.advance()
            // A stopped request comes back as the unchanged originals --
            // saving those would stamp untouched cards as AI-refined.
            if Task.isCancelled { break }
            guard refined.count == materialCards.count else { continue }
            do {
                let changed = try await database.queue.write { db -> Int in
                    var changed = 0
                    for (card, result) in zip(materialCards, refined) {
                        // Re-fetched rather than mutating the passed-in
                        // `card` in place: the context-check pass a caller
                        // like `refineCard` runs first may have just
                        // rewritten this same row, and this write must
                        // land on top of that, not silently undo it.
                        guard var updated = try Card.fetchOne(db, key: card.id),
                              updated.deletedAt == nil
                        else { continue }
                        let front = result.front.trimmingCharacters(in: .whitespacesAndNewlines)
                        let back = result.back.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Unchanged (or emptied) is not a refinement. Saving
                        // it anyway stamped cards "refined by AI" that the
                        // model never touched -- every card, whenever a
                        // call failed and passed its input back.
                        guard !front.isEmpty, !back.isEmpty,
                              front != updated.front || back != updated.back
                        else { continue }
                        updated.front = front
                        updated.back = back
                        // Not "parser" anymore: protects it from the
                        // scanner's re-import cleanup, which only clears
                        // origin == .parser drafts. Doesn't touch
                        // `status` -- refinement is not the same as
                        // approval, for a draft or an already-active card.
                        updated.origin = .ollama
                        updated.updatedAt = Date()
                        try updated.save(db)
                        changed += 1
                    }
                    return changed
                }
                refinedCount += changed
            } catch {
                continue
            }
        }
        reload()
        return refinedCount
    }

    /// One card's outcome from a context-verification pass, kept only for
    /// the summary the caller shows/logs afterward -- see `verifyContext`.
    struct ContextCheckEntry: Sendable, Identifiable {
        var id: String { cardId }
        let cardId: String
        let front: String
        let courseName: String
    }

    struct ContextCheckSummary: Sendable {
        var refined: [ContextCheckEntry] = []
        var removed: [ContextCheckEntry] = []
        var isEmpty: Bool { refined.isEmpty && removed.isEmpty }
    }

    /// Checks a card's own recorded pieces of context validation against
    /// its source note and course -- flagging assignment instructions,
    /// submission logistics, or a vague fragment that the deterministic
    /// parser's own filters (see `PairParser.isAssignmentMetaText`) didn't
    /// catch. Shared by two callers with different scopes: the draft-time
    /// check on a fresh import (`verifyCardContext`, still-unapproved
    /// cards only) and the one-time sweep over cards already approved
    /// long ago (`sweepAllCardsForContext`). Cards with no `materialId`
    /// (hand-typed, no source note to check against) are skipped
    /// entirely -- there's nothing here for them to be checked against.
    ///
    /// A `.refine` verdict rewrites the card's `back` in place (keeping
    /// the original in `originalBack` for the review UI's revert
    /// option); a `.reject` verdict soft-deletes it, same as any other
    /// card removal in this app. Fails soft at every step -- no generator
    /// available, no source text for a note, a DB error mid-pass -- by
    /// simply leaving the remaining cards untouched rather than throwing,
    /// consistent with every other `CardGenerator`-backed flow.
    private func verifyContext(of cards: [Card]) async -> ContextCheckSummary {
        var summary = ContextCheckSummary()
        let candidates = cards.filter { $0.materialId != nil }
        guard !candidates.isEmpty else { return summary }

        let generator = await CardGenerators.select()
        guard await generator.isAvailable else { return summary }

        let materialIds = Set(candidates.map { $0.materialId! })
        let courseNameByMaterial: [String: String]
        do {
            courseNameByMaterial = try await database.queue.read { db -> [String: String] in
                let materials = try Material.filter(materialIds.contains(Column("id"))).fetchAll(db)
                let courseIds = Set(materials.map(\.courseId))
                let courses = try Course.filter(courseIds.contains(Column("id"))).fetchAll(db)
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
            guard let context = (try? noteText(forMaterial: materialId))?.reflowed, !context.isEmpty else {
                // No call made, but still counted so the bar reaches the end.
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
                    front: card.front, back: card.back, noteContext: context, courseName: courseName
                )
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
        reload()
        return summary
    }

    /// The draft-time context check: runs over every still-unapproved
    /// card in scope, right where "Refine with AI" already runs, so a bad
    /// extraction can be caught before it's ever approved into real study
    /// material. `topic`-less, deck-scoped exactly like `refineDraftCards`.
    func verifyCardContext(inDecks deckIds: [String]) async -> ContextCheckSummary {
        await verifyContext(of: draftCards(inDecks: deckIds))
    }

    /// Every live draft in these decks. Empty on a read error, which every
    /// caller treats as "nothing to do".
    private func draftCards(inDecks deckIds: [String]) async -> [Card] {
        do {
            let cardIds = try await database.queue.read { db in
                try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
            }
            guard !cardIds.isEmpty else { return [] }
            return try await database.queue.read { db in
                try Card
                    .filter(cardIds.contains(Column("id")))
                    .filter(Column("status") == CardStatus.draft.rawValue)
                    .filter(Column("deletedAt") == nil)
                    .fetchAll(db)
            }
        } catch {
            return []
        }
    }

    /// The one-time sweep: every live card in the whole vault, approved or
    /// not, checked against its own source note -- the only way to catch
    /// an off-topic card that was approved long before this feature
    /// existed. Deliberately vault-wide rather than deck/course-scoped
    /// (unlike `verifyCardContext`): a first pass over already-curated
    /// content is exactly the kind of thing worth doing everywhere at
    /// once rather than course by course.
    func sweepAllCardsForContext() async -> ContextCheckSummary {
        let liveCards: [Card]
        do {
            liveCards = try await database.queue.read { db in
                try Card.filter(Column("deletedAt") == nil).fetchAll(db)
            }
        } catch {
            return ContextCheckSummary()
        }
        AIProgress.current?.expect(liveCards.filter { $0.materialId != nil }.count)
        return await verifyContext(of: liveCards)
    }

    /// The combined result of "Refine Deck with AI" -- the single button
    /// that replaced the separate "Refine with AI" and "Check for
    /// Off-Topic Cards" actions.
    struct RefineDeckSummary: Sendable {
        var wordingRefinedCount = 0
        var context = ContextCheckSummary()
        var isEmpty: Bool { wordingRefinedCount == 0 && context.isEmpty }
    }

    /// "Refine Deck with AI": one action, two passes, always in this
    /// order. Pass 1 (`verifyCardContext`) prunes or rewrites drafts that
    /// aren't real definitions at all -- assignment text, off-topic
    /// fragments. Pass 2 (`refineDraftCards`) then cleans up wording
    /// (parsing artifacts, awkward phrasing) on whatever drafts survive.
    /// Doing it in this order, not the reverse or a single mixed pass, is
    /// what fixes the bug where a genuinely off-topic card used to just
    /// come out of "Refine with AI" more smoothly worded but still
    /// wrong -- that wording-cleanup prompt's whole job is to preserve
    /// meaning, so handing it a bad card early meant it dutifully
    /// polished the wrong meaning instead of replacing it. By the time
    /// pass 2 runs now, anything genuinely off-topic is already gone or
    /// already rewritten from scratch in pass 1.
    func refineDeckWithAI(inDecks deckIds: [String]) async -> RefineDeckSummary {
        // Counted up front for both passes -- one call per draft card, then
        // one per source note -- so the bar runs once from start to end
        // instead of filling for pass 1 and then jumping backwards.
        if let progress = AIProgress.current {
            let drafts = await draftCards(inDecks: deckIds).filter { $0.materialId != nil }
            progress.expect(drafts.count + Set(drafts.compactMap(\.materialId)).count)
        }
        let context = await verifyCardContext(inDecks: deckIds)
        if Task.isCancelled { return RefineDeckSummary(context: context) }
        let wordingRefinedCount = await refineDraftCards(inDecks: deckIds)
        return RefineDeckSummary(wordingRefinedCount: wordingRefinedCount, context: context)
    }

    enum CardRefineOutcome: Sendable {
        /// Looked off-topic against its own note and was soft-deleted.
        case removed
        /// The context check rewrote it, the wording pass cleaned it up,
        /// or both -- any real change counts, since the caller only needs
        /// to know whether to say "done" or "nothing to do here."
        case refined
        /// No generator, no source note, or a hand-typed card with
        /// nothing to check it against.
        case unavailable
    }

    /// The single-card "Refine with AI" action -- available from a card's
    /// own menu whether it's still a draft or was approved months ago,
    /// unlike "Refine Deck with AI" (drafts only). Runs the exact same
    /// two-stage pipeline as that deck-wide action, just scoped to one
    /// card: the context check first (which can rewrite a bad definition
    /// or remove an off-topic one outright), then wording cleanup on
    /// whatever survives -- an approved card sitting in the deck for
    /// months has just as much chance of being clumsily worded or quietly
    /// off-topic as a fresh draft does, and there was previously no way to
    /// ask for a second look at just that one card.
    @discardableResult
    func refineCard(_ cardId: String) async -> CardRefineOutcome {
        guard let card = try? await database.queue.read({ db in try Card.fetchOne(db, key: cardId) }),
              card.materialId != nil
        else { return .unavailable }

        let generator = await CardGenerators.select()
        guard await generator.isAvailable else { return .unavailable }

        let contextResult = await verifyContext(of: [card])
        if !contextResult.removed.isEmpty { return .removed }

        // Re-fetched: the context pass above may have just rewritten
        // `back` in the database, and the wording pass needs to clean up
        // whatever text is live now, not the pre-refinement copy still
        // held in `card`.
        guard let current = try? await database.queue.read({ db in try Card.fetchOne(db, key: cardId) })
        else { return contextResult.refined.isEmpty ? .unavailable : .refined }

        let wordingRefinedCount = await refineWording(of: [current])
        return (wordingRefinedCount > 0 || !contextResult.refined.isEmpty) ? .refined : .unavailable
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
        let progress = AIProgress.current
        progress?.expect(existingByMaterial.count)

        for (index, (materialId, existing)) in existingByMaterial.enumerated() {
            if Task.isCancelled { break }
            guard let context = (try? noteText(forMaterial: materialId))?.reflowed, !context.isEmpty,
                  let deckId = existing.first.flatMap({ deckOfCard[$0.id] })
            else { progress?.advance(); continue }
            let candidates = existing.map { CandidatePair(front: $0.front, back: $0.back, sourceLine: $0.sourceLine ?? 0) }
            progress?.begin("Reading note \(index + 1) of \(existingByMaterial.count)")
            let proposed = await generator.generateAdditional(
                existing: candidates, noteContext: context, maxCount: maxPerNote, topic: topic
            )
            progress?.advance()
            if Task.isCancelled { break }
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
                // One grouped query. This runs after every card graded or
                // edited, and it used to be two queries per deck -- over a
                // hundred for this vault -- loading full card rows each time.
                var counts = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, (0, 0)) })
                let rows = try Row.fetchAll(db, sql: """
                    SELECT deckCard.deckId AS deckId,
                           COUNT(*) AS cards,
                           SUM(CASE WHEN card.status = ? AND card.due <= ? THEN 1 ELSE 0 END) AS due
                    FROM deckCard
                    JOIN card ON card.id = deckCard.cardId
                    WHERE card.deletedAt IS NULL AND card.status != ?
                    GROUP BY deckCard.deckId
                    """, arguments: [CardStatus.active.rawValue, Date(), CardStatus.suspended.rawValue])
                for row in rows {
                    let deckId: String = row["deckId"]
                    guard counts[deckId] != nil else { continue }
                    counts[deckId] = (row["cards"], row["due"])
                }
                deckCounts = counts
            }
        } catch {
            importError = "Failed to read database: \(error)"
        }
        revision += 1
        // Every local change comes through here; sync pushes it shortly.
        sync?.noteLocalChange()
    }

    /// A course's display name straight from the already-loaded in-memory
    /// lists -- no query, since the callers are rendering one row each and
    /// a fetch per row is exactly the pattern `dashboardDecks` exists to
    /// avoid. Archived courses are included: an exam on the calendar
    /// shouldn't lose its course label just because the course was filed
    /// away.
    func courseName(_ courseId: String) -> String? {
        coursesBySemester.values.joined().first { $0.id == courseId }?.name
            ?? archivedCourses.first { $0.id == courseId }?.name
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
        Self.buildDuplicateGroups(try cards(inDecks: deckIds))
    }

    /// A deliberate, manually-triggered sweep across *every* course at
    /// once -- the counterpart to `duplicateGroups(inDecks:)`'s per-course
    /// scope, for a duplicate that scope structurally can't see (e.g. the
    /// same lecture PDF imported under two different course folders,
    /// which import-time suppression and the per-course review sheet both
    /// only ever compare within, never across).
    /// Duplicate groups in every course -- found course by course, never
    /// across courses.
    ///
    /// The detector treats two cards with the same term as duplicates even
    /// when their definitions differ, which is right inside one course (a
    /// term defined twice) and wrong across two: run over the whole vault
    /// it merged Anthropology's "Class" (a social stratum) into Software
    /// Design's "Class" (a blueprint), Geology's "Composition" into OOP
    /// composition, and about two dozen more homonyms, deleting one side of
    /// each.
    func duplicateGroupsAcrossAllCourses() throws -> [DuplicateGroup] {
        let byCourse = try database.queue.read { db -> [String: [Card]] in
            let cards = try Card.filter(Column("deletedAt") == nil).fetchAll(db)
            let courseOfMaterial = try Material.fetchAll(db)
                .reduce(into: [String: String]()) { $0[$1.id] = $1.courseId }
            let rows = try Row.fetchAll(db, sql: """
                SELECT deckCard.cardId AS cardId, deck.courseId AS courseId
                FROM deckCard JOIN deck ON deck.id = deckCard.deckId
                """)
            let courseOfCard = rows.reduce(into: [String: String]()) { map, row in
                map[row["cardId"]] = row["courseId"]
            }
            return Dictionary(grouping: cards) { card in
                card.materialId.flatMap { courseOfMaterial[$0] } ?? courseOfCard[card.id] ?? ""
            }
        }
        return byCourse.values.flatMap { Self.buildDuplicateGroups($0) }
    }

    private static func buildDuplicateGroups(_ cards: [Card]) -> [DuplicateGroup] {
        DuplicateDetector.groups(cards).map { group in
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
                -- Archived courses are hidden everywhere else; counting them
                -- here made Home's totals disagree with the course list.
                WHERE deck.deletedAt IS NULL AND course.isArchived = 0
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
            // `cardIds` is built from `DeckCard` rows, one per membership --
            // normally a card belongs to exactly one deck within a course,
            // but that's a convention this table doesn't itself enforce,
            // so a card that ends up in two of the requested decks would
            // appear twice here. `uniquingKeysWith` (keep the first,
            // i.e. earliest by deck/sortIndex order) keeps this from
            // crashing on a duplicate key if that ever happens, rather
            // than assuming it never will.
            let order = Dictionary(
                cardIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }
            )
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
            // Quoted: bare, an uppercase AND, OR or NOT is FTS5 syntax, and
            // "TCP OR UDP" or "AND gate" was a syntax error that showed up
            // as "No matches". A quoted prefix still matches the same words.
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
        guard !sanitized.isEmpty else { return [] }

        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT material.id AS materialId, material.title AS title,
                       snippet(noteFTS, 0, char(2), char(3), '…', 12) AS snippet
                FROM noteFTS
                JOIN noteText ON noteText.rowid = noteFTS.rowid
                JOIN material ON material.id = noteText.materialId
                WHERE noteFTS MATCH ? AND material.deletedAt IS NULL
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

    func card(_ id: String) throws -> Card? {
        try database.queue.read { db in try Card.fetchOne(db, key: id) }
    }

    /// Saves an edit to a card's text -- and only its text.
    ///
    /// Edit sheets hold a copy of the card from when they opened. Saving
    /// that whole copy wrote back every column as it was then: a review
    /// graded meanwhile lost its new due date, and a card an AI pass had
    /// removed or rewritten while the sheet was open came back as it was.
    /// So the row is re-read and only front and back change, and only when
    /// they actually did.
    func updateCard(_ card: Card) throws {
        let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !back.isEmpty else { return }
        try database.queue.write { db in
            guard var current = try Card.fetchOne(db, key: card.id), current.deletedAt == nil,
                  current.front != front || current.back != back
            else { return }
            current.front = front
            current.back = back
            // Hand-edited parser cards stop being the scanner's to replace
            // on re-import. AI-generated ones keep their origin, so their
            // "worth double-checking" badge survives a typo fix.
            if current.origin == .parser { current.origin = .manual }
            current.updatedAt = Date()
            try current.save(db)
        }
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

    /// Undoes one AI context-refinement: restores `back` from
    /// `originalBack` and clears both refinement fields. A no-op if the
    /// card was never refined (`originalBack == nil`), so this is always
    /// safe to call from a "Revert" button without checking first.
    func revertContextRefinement(_ cardId: String) throws {
        try database.queue.write { db in
            guard var card = try Card.fetchOne(db, key: cardId), let original = card.originalBack else { return }
            card.back = original
            card.originalBack = nil
            card.isContextRefined = false
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

    /// One "keep this card, fold these into it" instruction from the
    /// Review Duplicates sheet -- the UI-facing mirror of
    /// `DuplicateDetector.Merge`, which does the actual work.
    struct DuplicateMerge {
        let survivorId: String
        let losingIds: [String]
    }

    /// Folds duplicate cards into their group's survivor instead of just
    /// deleting the losers outright, preserving review history and Learn
    /// progress where possible. See `DuplicateDetector.applyMerges` for
    /// the full behavioral contract -- this just translates the UI's
    /// instruction type, wraps every group's merge in one write
    /// transaction, and refreshes derived store state afterward.
    func mergeDuplicates(_ merges: [DuplicateMerge]) throws {
        guard !merges.isEmpty else { return }
        try database.queue.write { db in
            try DuplicateDetector.applyMerges(
                merges.map { DuplicateDetector.Merge(survivorId: $0.survivorId, losingIds: $0.losingIds) }, db: db
            )
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
            // Cards already in the target stay where they are. Moving them
            // "into" their own deck pushed them to the end of it -- easy to
            // do from All Cards, whose targets include every deck.
            let alreadyThere = Set(try String.fetchAll(db, sql:
                "SELECT cardId FROM deckCard WHERE deckId = ?", arguments: [targetDeckId]))
            let cardIds = cardIds.filter { !alreadyThere.contains($0) }
            guard !cardIds.isEmpty else { return }
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
                .filter(Column("deletedAt") == nil)
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
               ExamBias.isInFinalWeek(now: now, examDate: exam.startsAt) {
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
                result.due = ExamBias.capDue(result.due, examDate: exam.startsAt, now: now)
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

    nonisolated private static func learnCandidates(
        forDeck deckId: String, db: Database
    ) throws -> [(candidate: LearnEngine.Candidate, lastSeenAt: Date?)] {
        try learnCandidates(forDecks: [deckId], db: db)
    }

    /// `nonisolated` (unlike most of this class) so it can run inside a
    /// GRDB `@Sendable` read closure called from an `async` context (see
    /// `startTest`) without hopping back to the main actor -- it only ever
    /// touches the `Database` connection it's handed, no store state.
    nonisolated private static func learnCandidates(
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
    /// attempt id and in-memory questions the UI drives from, plus a
    /// user-facing warning when AI test questions were requested but
    /// couldn't actually be produced (see `generateAITestQuestions`).
    func startTest(deckId: String, config: TestBuilder.Config) async throws -> (attemptId: String, questions: [LearnEngine.RoundQuestion], aiWarning: String?) {
        try await startTest(deckIds: [deckId], config: config)
    }

    /// A test still reads as "mostly the deck's own cards" even with AI
    /// generation on -- roughly a third of the requested count, capped
    /// absolutely, regardless of how many notes are in scope.
    // MARK: - Long-running AI jobs

    /// A job the app is running, with the progress its strip shows.
    struct AIJob {
        let activity: AIActivity
        let task: Task<Void, Never>
    }

    /// Running jobs, keyed by what they work on. They live here rather than
    /// in the view that started them: a view's task outlived the view (a
    /// tab switch, closing Settings) and kept going with no Stop button,
    /// while the fresh view offered to start a second run over the same
    /// cards.
    private(set) var aiJobs: [String: AIJob] = [:]

    func aiJob(_ key: String) -> AIJob? { aiJobs[key] }

    /// Starts `work` under `key` unless a job with that key is already
    /// running. Returns whether it started.
    @discardableResult
    func runAIJob(_ key: String, activity: AIActivity, _ work: @escaping (AIActivity) async -> Void) -> Bool {
        guard aiJobs[key] == nil else { return false }
        let task = Task { [weak self] in
            await work(activity)
            activity.finish()
            self?.aiJobs[key] = nil
        }
        aiJobs[key] = AIJob(activity: activity, task: task)
        return true
    }

    func stopAIJob(_ key: String) {
        aiJobs[key]?.activity.stopRequested = true
        aiJobs[key]?.task.cancel()
    }

    /// One deck-wide card job per course at a time -- Refine Deck and Add
    /// More Cards both work through the same drafts, and "All Cards" covers
    /// every deck.
    func cardJobKey(courseId: String?) -> String { "cards:\(courseId ?? "none")" }
    func overviewJobKey(courseId: String?) -> String { "overview:\(courseId ?? "none")" }
    static let sweepJobKey = "sweep"

    @ObservationIgnored private var aiTestQuestionTask: Task<(questions: [LearnEngine.RoundQuestion], warning: String?), Never>?

    /// Stops writing AI test questions and lets the test start with any
    /// already written.
    func skipAITestQuestions() {
        // A flag as well as the cancel: Skip can be pressed before the task
        // exists (it's created after the first database read), and a cancel
        // of nothing was simply lost.
        aiTestQuestionsSkipped = true
        aiTestQuestionTask?.cancel()
    }

    @ObservationIgnored private var aiTestQuestionsSkipped = false

    private static func aiQuestionBudget(for questionCount: Int) -> Int { max(0, min(questionCount / 3, 10)) }

    /// The default cap on how many AI test questions a single note can
    /// contribute, mirroring `defaultMaxGeneratedPerNote`'s "keep one
    /// chatty response from dominating" reasoning.
    private static let aiTestQuestionsPerNote = 2

    /// Proposes a handful of ephemeral, AI-generated written questions
    /// grounded in the notes behind `deckIds` -- never saved as a `Card`,
    /// never entering the review queue. Unlike `generateAdditionalCards`
    /// (where an empty result is *always* a normal outcome, silently),
    /// this feature is behind an explicit user-facing toggle -- so when it's
    /// on and nothing came back, that's worth telling the user about rather
    /// than letting the test quietly look like the toggle does nothing.
    /// The `warning` is nil whenever there's nothing worth surfacing:
    /// either this deck has no note-backed cards to ground a question in
    /// (a structural non-applicability, not a failure), or generation
    /// actually produced something.
    private func generateAITestQuestions(
        inDecks deckIds: [String], maxCount: Int
    ) async -> (questions: [LearnEngine.RoundQuestion], warning: String?) {
        guard maxCount > 0 else { return ([], nil) }
        let generator = await CardGenerators.select()
        guard await generator.isAvailable else {
            return ([], "AI test questions are on in Settings, but no local AI model is reachable right now (Ollama isn't running, and no on-device model is available). This test uses your cards only.")
        }

        let existingByMaterial: [String: [Card]]
        do {
            let cards = try await database.queue.read { db -> [Card] in
                let cardIds = try DeckCard.filter(deckIds.contains(Column("deckId"))).fetchAll(db).map(\.cardId)
                guard !cardIds.isEmpty else { return [] }
                return try Card
                    .filter(cardIds.contains(Column("id")))
                    .filter(Column("deletedAt") == nil)
                    .filter(Column("materialId") != nil)
                    .fetchAll(db)
            }
            guard !cards.isEmpty else { return ([], nil) } // no note-backed cards here -- nothing to ground on, not a failure
            existingByMaterial = Dictionary(grouping: cards, by: { $0.materialId! })
        } catch {
            return ([], "AI test questions couldn't be generated (a database error occurred while reading your notes). This test uses your cards only.")
        }

        var results: [LearnEngine.RoundQuestion] = []
        var attemptedAnyNote = false
        // The run ends as soon as the budget is met, so the likely number of
        // notes is the budget over what one note gives -- grown one at a time
        // if notes come back thinner than that.
        let progress = AIProgress.current
        let perNote = Self.aiTestQuestionsPerNote
        let notes = existingByMaterial.shuffled()
        progress?.expect(min(notes.count, (maxCount + perNote - 1) / perNote))
        for (index, (materialId, existing)) in notes.enumerated() {
            // Skipped by the student: start the test with what's ready.
            if Task.isCancelled || aiTestQuestionsSkipped { break }
            guard results.count < maxCount,
                  let context = (try? noteText(forMaterial: materialId))?.reflowed, !context.isEmpty
            else { continue }
            attemptedAnyNote = true
            let candidates = existing.map { CandidatePair(front: $0.front, back: $0.back, sourceLine: $0.sourceLine ?? 0) }
            progress?.begin("Writing questions from note \(index + 1)")
            let proposed = await generator.generateTestQuestions(
                existing: candidates, noteContext: context,
                maxCount: min(perNote, maxCount - results.count)
            )
            results += proposed.map {
                LearnEngine.RoundQuestion(cardId: nil, prompt: $0.prompt, correctAnswer: $0.correctAnswer, type: .written)
            }
            if let progress, results.count < maxCount, index + 1 < notes.count,
               progress.snapshot.completed + 1 >= progress.snapshot.expected {
                progress.expect(1)
            }
            progress?.advance()
        }

        let warning: String? = (attemptedAnyNote && results.isEmpty && !Task.isCancelled)
            ? "AI test questions are on in Settings, but the AI didn't return any usable questions for this test's notes. This test uses your cards only."
            : nil
        return (Array(results.prefix(maxCount)), warning)
    }

    /// The plural of the above, for a test run across every deck in a
    /// course. `testAttempt.deckId` is nullable precisely for this case --
    /// a course-wide attempt isn't attributable to any single deck, so it
    /// stores `nil` rather than picking one arbitrarily.
    func startTest(
        deckIds: [String], config: TestBuilder.Config
    ) async throws -> (attemptId: String, questions: [LearnEngine.RoundQuestion], aiWarning: String?) {
        aiTestQuestionsSkipped = false
        var cards = try await database.queue.read { db in try Self.learnCandidates(forDecks: deckIds, db: db).map(\.candidate) }
        if config.excludeMastered {
            cards = cards.filter { $0.level != .mastered }
        }

        // AI questions are always .written -- if Written is off, none
        // sneak in regardless of the toggle, and there's nothing to warn
        // about since the user didn't ask for any this time.
        // Its own task, so "Skip" can cancel just the AI questions and still
        // start the test -- cancelling the caller would also cancel the
        // database writes below that create the attempt.
        let aiResult: (questions: [LearnEngine.RoundQuestion], warning: String?)
        if config.allowWritten && isAITestQuestionsEnabled {
            let budget = Self.aiQuestionBudget(for: config.questionCount)
            let task = Task { await generateAITestQuestions(inDecks: deckIds, maxCount: budget) }
            aiTestQuestionTask = task
            aiResult = await task.value
            aiTestQuestionTask = nil
        } else {
            aiResult = ([], nil)
        }
        let aiQuestions = aiResult.questions

        var rng = SystemRandomNumberGenerator()
        let pool = cards.map { (cardId: $0.cardId, front: $0.front, back: $0.back) }
        var cardConfig = config
        cardConfig.questionCount = max(0, config.questionCount - aiQuestions.count)
        var mutableQuestions = TestBuilder.build(from: pool, config: cardConfig, using: &rng) + aiQuestions
        if config.shuffle { mutableQuestions.shuffle(using: &rng) }
        let questions = mutableQuestions
        // Nothing to ask -- every card filtered out. Say so rather than write
        // an attempt nobody can take.
        guard !questions.isEmpty else { return ("", [], nil) }

        let attemptId = try await database.queue.write { db -> String in
            let attempt = TestAttempt(
                deckId: deckIds.count == 1 ? deckIds.first : nil, configJSON: "{}", startedAt: Date()
            )
            try attempt.insert(db)
            for (index, question) in questions.enumerated() {
                try TestItem(
                    id: question.id + "-" + attempt.id, attemptId: attempt.id, cardId: question.cardId,
                    ordinal: index, questionType: question.type.rawValue, promptText: question.prompt,
                    choicesJSON: question.choices.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) },
                    correctAnswer: question.correctAnswer, isAIGenerated: question.cardId == nil
                ).insert(db)
            }
            return attempt.id
        }
        return (attemptId, questions, aiResult.warning)
    }

    /// Records one answer to a test item, and grades it immediately so the
    /// results screen never has to re-derive correctness. Keyed by
    /// `ordinal` (unique per attempt by construction) rather than `cardId`
    /// -- an AI-generated question has no `cardId` at all, and more than
    /// one such question can exist in the same attempt.
    func submitTestAnswer(attemptId: String, ordinal: Int, given: String, isCorrect: Bool) throws {
        try database.queue.write { db in
            guard var item = try TestItem
                .filter(Column("attemptId") == attemptId)
                .filter(Column("ordinal") == ordinal)
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

    /// The user says a written question judged "incorrect" by fuzzy text
    /// matching was actually right -- exact/fuzzy comparison is a poor
    /// judge of a long or loaded free-response answer, and this is the
    /// override valve for that. Idempotent: a question already marked
    /// correct is left untouched, so a duplicate call (or a UI race)
    /// can't double-count the score or double-apply the FSRS correction
    /// below.
    ///
    /// If the attempt hadn't finished yet (the override happened mid-quiz,
    /// in `TestRunView`), flipping the stored `TestItem` is all that's
    /// needed -- `finishTest` hasn't scored anything or touched FSRS yet,
    /// so it will simply score this item correctly when it does. If the
    /// attempt had already finished (the override happened from
    /// `TestResultsView`, which only ever shows after `finishTest` already
    /// ran), this also corrects the attempt's stored score and, for a
    /// card-backed question, re-grades the card "Good" to counteract the
    /// "Again" grade `finishTest` already applied for that miss. That's a
    /// best-effort correction, not a perfect undo -- FSRS state isn't
    /// reversible -- but it's truer than leaving a card penalized for an
    /// answer that was actually right.
    func overrideTestItemCorrect(attemptId: String, ordinal: Int, cardId: String?) throws {
        let correctedAFinishedAttempt = try database.queue.write { db -> Bool in
            guard var item = try TestItem
                .filter(Column("attemptId") == attemptId)
                .filter(Column("ordinal") == ordinal)
                .fetchOne(db),
                item.isCorrect != true
            else { return false }
            item.isCorrect = true
            try item.save(db)

            guard var attempt = try TestAttempt.fetchOne(db, key: attemptId), attempt.finishedAt != nil else {
                return false
            }
            attempt.scoreNumerator = min((attempt.scoreNumerator ?? 0) + 1, attempt.scoreDenominator ?? .max)
            try attempt.save(db)
            return true
        }
        if correctedAFinishedAttempt, let cardId {
            // `gradeCard` opens its own write transaction, same as every
            // other grading call site -- kept outside this one rather than
            // nested inside it.
            try? gradeCard(cardId, grade: .good, source: "test-override")
        }
    }

    /// The soonest exam still in the future for a course, or nil if none
    /// is set -- both `gradeCard`'s interval capping and `dueCards`'s
    /// final-week reordering are no-ops without one. Deadlines and study
    /// blocks are deliberately excluded (see `CalendarEventKind.examLike`):
    /// they share the calendar, not the scheduler's notion of a deadline
    /// every card must be ready for.
    private static func nearestUpcomingExam(
        forCourseId courseId: String, now: Date, db: Database
    ) throws -> CalendarEvent? {
        try CalendarEvent
            .filter(Column("courseId") == courseId)
            .filter(CalendarEventKind.examLike.map(\.rawValue).contains(Column("kind")))
            // Until the exam is over, not until it starts: an all-day exam
            // is stored at midnight with no end, and "starts >= now"
            // dropped it the moment its own day began.
            .filter(Column("startsAt") >= now.addingTimeInterval(-86400))
            .order(Column("startsAt"))
            .fetchAll(db)
            .first { event in
                let over = event.isAllDay
                    ? event.startsAt.addingTimeInterval(86400)
                    : (event.endsAt ?? event.startsAt)
                return over >= now
            }
    }

    func calendarEvents(forCourse courseId: String) throws -> [CalendarEvent] {
        try database.queue.read { db in
            try CalendarEvent
                .filter(Column("courseId") == courseId)
                .order(Column("startsAt"))
                .fetchAll(db)
        }
    }

    /// Every event overlapping a date range -- what the month grid, the
    /// week columns and the agenda all read, each just asking for a
    /// different span.
    func calendarEvents(from start: Date, to end: Date) throws -> [CalendarEvent] {
        try database.queue.read { db in
            try CalendarEvent
                .filter(Column("startsAt") >= start && Column("startsAt") < end)
                .order(Column("startsAt"))
                .fetchAll(db)
        }
    }

    /// One upcoming event with the course name already resolved, so a
    /// caller rendering a list of them doesn't fetch a course per row.
    struct UpcomingEvent: Identifiable, Sendable {
        let event: CalendarEvent
        let courseName: String?
        var id: String { event.id }

        func daysAway(from now: Date, calendar: Calendar = .current) -> Int {
            event.daysAway(from: now, calendar: calendar)
        }
    }

    /// Exams and quizzes coming up across every course, soonest first --
    /// the Home dashboard's alert strip. Events earlier today still count
    /// as upcoming (an exam at 2pm shouldn't vanish from the alert at
    /// 2:01pm on the day it matters most), so the window starts at the
    /// beginning of today rather than at `now`.
    func upcomingExams(within days: Int = 30, limit: Int = 5, now: Date = Date()) throws -> [UpcomingEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        return try database.queue.read { db in
            let events = try CalendarEvent
                .filter(CalendarEventKind.examLike.map(\.rawValue).contains(Column("kind")))
                .filter(Column("startsAt") >= start && Column("startsAt") < end)
                .order(Column("startsAt"))
                .limit(limit)
                .fetchAll(db)
            let courseNames = try Self.courseNames(for: events, db: db)
            return events.map {
                UpcomingEvent(event: $0, courseName: $0.courseId.flatMap { courseNames[$0] })
            }
        }
    }

    private static func courseNames(for events: [CalendarEvent], db: Database) throws -> [String: String] {
        let ids = Set(events.compactMap(\.courseId))
        guard !ids.isEmpty else { return [:] }
        return try Course.filter(ids.contains(Column("id")))
            .fetchAll(db)
            .reduce(into: [:]) { $0[$1.id] = $1.name }
    }

    func addCalendarEvent(_ event: CalendarEvent) throws {
        try database.queue.write { db in try event.insert(db) }
        reload()
    }

    func updateCalendarEvent(_ event: CalendarEvent) throws {
        var updated = event
        updated.updatedAt = Date()
        try database.queue.write { db in try updated.update(db) }
        reload()
    }

    func deleteCalendarEvent(_ eventId: String) throws {
        try database.queue.write { db in
            // Take any study plan generated for this exam with it -- blocks
            // for an exam that no longer exists are just clutter nobody
            // would think to go and clean up.
            try CalendarEvent.filter(Column("parentEventId") == eventId).deleteAll(db)
            _ = try CalendarEvent.deleteOne(db, key: eventId)
        }
        reload()
    }

    // MARK: - Calendar sync

    /// Mirrors exam dates from the Mac's Calendar into GRASP. One-way by
    /// design (see `CalendarSync`): nothing here writes to the system
    /// calendar, and an event you typed into GRASP yourself is never
    /// touched, since only rows carrying a `sourceEventId` are considered
    /// for update.
    func syncSystemCalendar(withinDays days: Int = 180) async -> Result<CalendarSync.Summary, Error> {
        let eventStore = EKEventStore()
        do {
            guard try await CalendarSync.requestAccess(store: eventStore) else {
                return .failure(CalendarSync.SyncError.accessDenied)
            }
        } catch {
            return .failure(error)
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        let courseTuples = coursesBySemester.values.joined().map { (id: $0.id, name: $0.name, code: $0.code) }
        let found = CalendarSync.scan(store: eventStore, courses: Array(courseTuples), from: start, to: end)

        var summary = CalendarSync.Summary()
        summary.calendarsScanned = CalendarSync.calendarCount(store: eventStore)
        do {
            let written = try await database.queue.write { db -> (imported: [String], updated: [String], unmatched: [String]) in
                var imported: [String] = []
                var updated: [String] = []
                var unmatched: [String] = []
                for scanned in found {
                    if var existing = try CalendarEvent
                        .filter(Column("sourceEventId") == scanned.sourceEventId)
                        .fetchOne(db) {
                        // Only the fields the system calendar is the
                        // authority on. A deck linked by hand in GRASP, and
                        // a course corrected by hand after a bad match,
                        // both survive a re-sync -- overwriting them would
                        // undo the user's own work every time this runs.
                        // One exception: an event that matched no course
                        // when first seen gets matched now if it can be --
                        // a course code added since, or a better matcher.
                        // Never overwrites a course that's already set.
                        let newlyMatched = existing.courseId == nil && scanned.courseId != nil
                        guard existing.startsAt != scanned.startsAt
                            || existing.endsAt != scanned.endsAt
                            || existing.title != scanned.title
                            || existing.isAllDay != scanned.isAllDay
                            || newlyMatched
                        else { continue }
                        if newlyMatched { existing.courseId = scanned.courseId }
                        existing.title = scanned.title
                        existing.startsAt = scanned.startsAt
                        existing.endsAt = scanned.endsAt
                        existing.isAllDay = scanned.isAllDay
                        existing.updatedAt = Date()
                        try existing.update(db)
                        updated.append(scanned.title)
                    } else {
                        try CalendarEvent(
                            courseId: scanned.courseId, kind: scanned.kind, title: scanned.title,
                            startsAt: scanned.startsAt, endsAt: scanned.endsAt,
                            isAllDay: scanned.isAllDay, sourceEventId: scanned.sourceEventId
                        ).insert(db)
                        imported.append(scanned.title)
                        if scanned.courseId == nil { unmatched.append(scanned.title) }
                    }
                }
                return (imported, updated, unmatched)
            }
            summary.imported = written.imported
            summary.updated = written.updated
            summary.unmatched = written.unmatched
        } catch {
            return .failure(error)
        }
        reload()
        return .success(summary)
    }

    // MARK: - Study plans

    struct StudyPlanSummary: Sendable {
        let blocksCreated: Int
        let cardsCovered: Int
        let replacedExisting: Bool
        let firstDay: Date?
    }

    /// How many cards a plan for this event would have to cover -- the
    /// linked deck's active cards, or the whole course's when no specific
    /// deck is set.
    func plannableCardCount(for event: CalendarEvent) -> Int {
        let deckIds: [String]
        if let deckId = event.deckId {
            deckIds = [deckId]
        } else if let courseId = event.courseId {
            deckIds = (try? decks(inCourse: courseId))?.map(\.id) ?? []
        } else {
            deckIds = []
        }
        guard !deckIds.isEmpty else { return 0 }
        return ((try? cards(inDecks: deckIds)) ?? []).filter { $0.status == .active }.count
    }

    /// Lays a `StudyPlanner` plan onto the calendar as study blocks, each
    /// linked back to the exam so regenerating replaces exactly the blocks
    /// this made before and nothing else.
    @discardableResult
    func generateStudyPlan(for event: CalendarEvent, now: Date = Date()) throws -> StudyPlanSummary {
        let cardCount = plannableCardCount(for: event)
        let blocks = StudyPlanner.plan(cardCount: cardCount, from: now, examDate: event.startsAt)
        let courseName = event.courseId.flatMap { courseName($0) }

        var replaced = false
        try database.queue.write { db in
            let existing = try CalendarEvent.filter(Column("parentEventId") == event.id).deleteAll(db)
            replaced = existing > 0
            for block in blocks {
                try CalendarEvent(
                    courseId: event.courseId, deckId: event.deckId, kind: .study,
                    title: StudyPlanner.blockTitle(courseName: courseName, block: block),
                    startsAt: block.day, isAllDay: true, parentEventId: event.id
                ).insert(db)
            }
        }
        reload()
        return StudyPlanSummary(
            blocksCreated: blocks.count, cardsCovered: cardCount,
            replacedExisting: replaced, firstDay: blocks.first?.day
        )
    }

    func hasStudyPlan(for eventId: String) -> Bool {
        ((try? database.queue.read { db in
            try CalendarEvent.filter(Column("parentEventId") == eventId).fetchCount(db)
        }) ?? 0) > 0
    }

    // MARK: - Streak and daily load

    /// Distinct days with at least one review, most recent first -- the
    /// raw material for both the streak and the "did I study today" dot.
    private func reviewDays(since: Date) throws -> Set<Date> {
        let calendar = Calendar.current
        return try database.queue.read { db in
            let dates = try Date.fetchAll(
                db, sql: "SELECT DISTINCT reviewedAt FROM review WHERE reviewedAt >= ?", arguments: [since]
            )
            return Set(dates.map { calendar.startOfDay(for: $0) })
        }
    }

    struct StudyStreak: Sendable {
        let days: Int
        let studiedToday: Bool
        let reviewsToday: Int
    }

    /// Consecutive days studied, counting back from today. Studying
    /// yesterday but not yet today keeps the streak alive -- it only
    /// breaks once a whole day passes with nothing, which is what makes
    /// the number safe to show in the morning.
    func studyStreak(now: Date = Date()) -> StudyStreak {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: -365, to: today) ?? today
        let days = (try? reviewDays(since: horizon)) ?? []
        let studiedToday = days.contains(today)

        var streak = 0
        var cursor = studiedToday ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        let reviewsToday = (try? database.queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM review WHERE reviewedAt >= ?", arguments: [today]
            ) ?? 0
        }) ?? 0
        return StudyStreak(days: streak, studiedToday: studiedToday, reviewsToday: reviewsToday)
    }

    /// Cards falling due on each day in a range, for the calendar's
    /// workload colouring. Everything already overdue lands on the first
    /// day of the range, which is where it will actually be waiting.
    func dailyCardLoad(from start: Date, to end: Date) -> [Date: Int] {
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: start)
        let rows = (try? database.queue.read { db in
            try Date.fetchAll(
                db,
                sql: "SELECT due FROM card WHERE deletedAt IS NULL AND status = 'active' AND due < ?",
                arguments: [end]
            )
        }) ?? []
        return rows.reduce(into: [:]) { counts, due in
            let day = max(calendar.startOfDay(for: due), firstDay)
            counts[day, default: 0] += 1
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
            // Live cards only: deleted ones still have deck rows, and
            // counting them made the warning claim more than the student
            // has.
            let cards = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM card WHERE deletedAt IS NULL AND id IN (
                    SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                )
                """, arguments: [courseId]) ?? 0
            let reviews = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM review WHERE cardId IN (
                    SELECT id FROM card WHERE deletedAt IS NULL AND id IN (
                        SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                    )
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
            // Also every card made from this course's notes, deck or no
            // deck: deleting a deck drops its deck rows, and those cards
            // were otherwise left behind as permanent orphans once the
            // notes cascaded away.
            try db.execute(sql: """
                DELETE FROM card WHERE id IN (
                    SELECT cardId FROM deckCard WHERE deckId IN (SELECT id FROM deck WHERE courseId = ?)
                ) OR materialId IN (SELECT id FROM material WHERE courseId = ?)
                """, arguments: [courseId, courseId])
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
            // Decks are soft-deleted, so the calendar's ON DELETE SET NULL
            // never fires: an exam kept pointing at the deleted deck, with a
            // Study button leading nowhere.
            try db.execute(sql: "UPDATE calendarEvent SET deckId = NULL WHERE deckId = ?", arguments: [deckId])
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
        guard !vaultPath.isEmpty else {
            importError = "Choose your notes folder in Settings first."
            return
        }
        let root = URL(fileURLWithPath: vaultPath)
        do {
            let summary = try await scanner.scan(vaultRoot: root)
            lastImportSummary = summary
            if !summary.errors.isEmpty {
                importError = summary.errors.first
            }
            scanForDuplicatesAfterImport()
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
            scanForDuplicatesAfterImport()
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
