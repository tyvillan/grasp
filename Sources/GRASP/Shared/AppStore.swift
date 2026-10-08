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
    /// overview's `generatedAt` (see `DeckOverviewReader`). Not observed:
    /// it's a memo, and filling it must never invalidate a view that is in
    /// the middle of reading from it.

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
        // The same guide imported twice (e.g. from the Desktop and again from
        // the vault) is one guide.
        _ = try? db.queue.write { try StudyGuideActions.mergeDuplicateGuides(db: $0) }
        reload()
        sync = SyncController(database: db, profile: profile) { [weak self] in self?.reload() }
        sync.start()
        observeCloudUsage()
        Task { await refreshGeneratorStatus() }
    }

    func refreshGeneratorStatus() async {
        let generator = await CardGenerators.select()
        isGeneratorAvailable = !(generator is NoGenerator)
        let keyState = AIKeyStore.state()
        hasCloudKey = keyState == .ready
        cloudKeyProblem = Self.describe(keyState)
        var status: String
        switch generator {
        case let cloud as CloudGenerator:
            status = "Gemini (\(cloud.modelName))"
            if let local = cloud.localModelName { status += ", falling back to \(local)" }
        case let automatic as FallbackGenerator:
            status = "Gemini (\(automatic.cloud.modelName)), falling back to Apple's on-device model"
        case let ollama as OllamaGenerator:
            status = "Ollama (\(ollama.modelName))"
            if aiMode == .automatic && !hasCloudKey { status += " -- add a Gemini key to use the cloud" }
        case is NoGenerator:
            status = aiMode == .cloud && !hasCloudKey
                ? "None -- add a Gemini API key to use the cloud"
                : "None -- cards come from the parser only"
        default:
            status = "Apple on-device model"
        }
        if aiMode.usesCloud, hasCloudKey, CloudUsage.shared.pausedUntil != nil {
            status += aiMode == .automatic
                ? " (cloud limit reached; local until midnight Pacific)"
                : " (cloud limit reached until midnight Pacific)"
        }
        generatorStatus = status
    }

    // MARK: - AI settings

    /// Mirrors `AIPreferences.mode`, which is machine-wide, so the AI tab
    /// and every status line update together.
    private(set) var aiMode: AIMode = AIPreferences.mode
    private(set) var hasCloudKey = false
    /// Set when a key is stored but unusable, so Settings can say why.
    private(set) var cloudKeyProblem: String?

    private static func describe(_ state: AIKeyStore.KeyState) -> String? {
        switch state {
        case .missing, .ready:
            return nil
        case .empty:
            return "A Gemini key entry exists in your Keychain, but it's empty. Paste your key below to replace it."
        case .unreadable(let code):
            return "A Gemini key is saved, but macOS wouldn't let GRASP read it (error \(code)). "
                + "Paste your key below to save it again, and choose Always Allow if macOS asks."
        }
    }
    private(set) var cloudCheck: CloudGenerator.ConnectionCheck?
    private(set) var isCheckingCloud = false
    /// The text models the key can use, best first; empty until checked.
    private(set) var cloudModels: [String] = []
    /// Bumped whenever `CloudUsage` changes, so views reading it redraw.
    private(set) var cloudUsageRevision = 0
    @ObservationIgnored private var cloudUsageObserver: NSObjectProtocol?

    func setAIMode(_ mode: AIMode) {
        AIPreferences.mode = mode
        aiMode = mode
        Task { await refreshGeneratorStatus() }
    }

    /// Stores the key and checks it at once, so a typo shows up here
    /// rather than as a silent failure in the middle of a job.
    func saveCloudKey(_ pasted: String) async {
        let (key, problem) = AIKeyStore.sanitize(pasted)
        if let problem {
            cloudKeyProblem = problem
            return
        }
        guard AIKeyStore.save(key) else {
            cloudKeyProblem = "macOS wouldn't let GRASP save the key to your Keychain."
            return
        }
        cloudKeyProblem = nil
        CloudUsage.shared.recordTransportError(nil)
        CloudUsage.shared.clearPause()
        cloudCheck = nil
        await testCloudConnection()
    }

    func removeCloudKey() async {
        AIKeyStore.delete()
        cloudCheck = nil
        cloudModels = []
        await refreshGeneratorStatus()
    }

    func testCloudConnection() async {
        guard let key = AIKeyStore.read() else {
            cloudCheck = .badKey
            await refreshGeneratorStatus()
            return
        }
        isCheckingCloud = true
        let report = await CloudGenerator.check(apiKey: key)
        cloudCheck = report.status
        if !report.models.isEmpty {
            cloudModels = report.models
            AIPreferences.cachedCloudModels = report.models
            if let best = report.models.first { AIPreferences.bestKnownCloudModel = best }
        }
        isCheckingCloud = false
        await refreshGeneratorStatus()
    }

    func setCloudModel(_ model: String) {
        AIPreferences.cloudModel = model
        Task { await refreshGeneratorStatus() }
    }

    private func observeCloudUsage() {
        cloudUsageObserver = NotificationCenter.default.addObserver(
            forName: CloudUsage.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloudUsageRevision += 1 }
        }
    }

    // MARK: - AI card actions
    //
    // GRASPCore's `CardAI` does the work, shared with Windows; the store
    // picks the generator and reloads afterwards.

    typealias ContextCheckEntry = CardAI.ContextCheckEntry
    typealias ContextCheckSummary = CardAI.ContextCheckSummary
    typealias RefineDeckSummary = CardAI.RefineDeckSummary
    typealias CardRefineOutcome = CardAI.CardRefineOutcome

    /// Rewords every draft in a deck, note by note. Returns how many changed;
    /// 0 is the expected outcome when no model is available.
    func refineDraftCards(inDeck deckId: String) async -> Int {
        await refineDraftCards(inDecks: [deckId])
    }

    func refineDraftCards(inDecks deckIds: [String]) async -> Int {
        let count = await CardAI.refineDraftCards(inDecks: deckIds, using: await CardGenerators.select(),
                                                  database: database)
        reload()
        return count
    }

    /// The draft-time context check: every still-unapproved card in scope,
    /// checked against its note before it's ever approved.
    func verifyCardContext(inDecks deckIds: [String]) async -> ContextCheckSummary {
        let drafts = await CardAI.draftCards(inDecks: deckIds, database: database)
        let summary = await CardAI.verifyContext(of: drafts, using: await CardGenerators.select(), database: database)
        reload()
        return summary
    }

    /// The one-time sweep: every live card in the library, approved or not,
    /// checked against its own note.
    func sweepAllCardsForContext() async -> ContextCheckSummary {
        let summary = await CardAI.sweepAllCards(using: await CardGenerators.select(), database: database)
        reload()
        return summary
    }

    /// "Refine Deck with AI": the context check on every draft first (which
    /// removes or rewrites what isn't a real definition), then wording
    /// cleanup on what survives -- in that order, so an off-topic card isn't
    /// just polished.
    func refineDeckWithAI(inDecks deckIds: [String], includeApproved: Bool = false) async -> RefineDeckSummary {
        let summary = await CardAI.refineDeck(inDecks: deckIds, includeApproved: includeApproved, using: await CardGenerators.select(),
                                              database: database)
        reload()
        return summary
    }

    /// "Refine with AI" on one card, draft or approved: the same two passes.
    @discardableResult
    func refineCard(_ cardId: String) async -> CardRefineOutcome {
        let outcome = await CardAI.refineCard(cardId, using: await CardGenerators.select(), database: database)
        reload()
        return outcome
    }

    /// New draft cards, marked AI-generated, for what a note implies but its
    /// cards miss -- grounded in that note's own text.
    func generateAdditionalCards(
        inDecks deckIds: [String], maxPerNote: Int = CardAI.defaultMaxGeneratedPerNote, topic: String? = nil
    ) async -> Int {
        let count = await CardAI.generateAdditionalCards(
            inDecks: deckIds, maxPerNote: maxPerNote, topic: topic,
            using: await CardGenerators.select(), database: database
        )
        reload()
        return count
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
        WidgetPublisher.shared.schedule(from: self)
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
    ///
    /// `.exam` is one exam's study set: the decks its study guides map
    /// their parts to (see `StudyGuideActions.examDeckIds`).
    enum DeckScope: Hashable, Sendable {
        case deck(String)
        case course(String)
        case exam(courseId: String, examEventId: String)
    }

    /// One group of two or more near-duplicate cards already sitting in a
    /// deck, for the "Remove Duplicates" review flow -- the backlog
    /// counterpart to `VaultScanner`'s import-time suppression, which only
    /// prevents *new* duplicates going forward.
    typealias DuplicateGroup = CardAI.DuplicateGroup

    func duplicateGroups(inDeck deckId: String) throws -> [DuplicateGroup] {
        try duplicateGroups(inDecks: [deckId])
    }

    func duplicateGroups(inDecks deckIds: [String]) throws -> [DuplicateGroup] {
        CardAI.duplicateGroups(try cards(inDecks: deckIds))
    }

    /// Within each course, across every course.
    func duplicateGroupsAcrossAllCourses() throws -> [DuplicateGroup] {
        try database.queue.read { db in try CardAI.duplicateGroupsAcrossAllCourses(db: db) }
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

    /// A deck's Home figures -- the core's `Dashboard.DeckSummary`.
    typealias DeckSummary = Dashboard.DeckSummary

    /// Every deck with its card/due counts, course name, and last-studied
    /// timestamp in one query -- the Home dashboard's entire data need,
    /// since it ranks across every course at once (see `Dashboard.decks`).
    func dashboardDecks(now: Date = Date()) throws -> [DeckSummary] {
        try database.queue.read { db in try Dashboard.decks(now: now, db: db) }
    }

    func deck(_ id: String) throws -> Deck? {
        try database.queue.read { db in try Deck.fetchOne(db, key: id) }
    }

    func course(_ id: String) throws -> Course? {
        try database.queue.read { db in try Course.fetchOne(db, key: id) }
    }

    /// In `Deck.ordered` order, so "Lecture 10" follows "Lecture 9". Every
    /// deck list and picker reads this, so they all agree.
    func decks(inCourse courseId: String) throws -> [Deck] {
        Deck.ordered(try database.queue.read { db in
            try Deck
                .filter(Column("courseId") == courseId)
                .filter(Column("deletedAt") == nil)
                .fetchAll(db)
        })
    }

    /// Each deck's lecture date (e.g. "AUG 27", or "AUG 27–29" / "AUG 30 –
    /// SEP 2" when its notes span several class days), for `DeckListView`'s
    /// sidebar rows -- just the date, not the full "LECTURE 2 · AUG 27"
    /// kicker the Overview tab and source-note viewers show, since the
    /// deck's own name already says which lecture it is. The range is the
    /// earliest-to-latest date across every note linked to the deck when
    /// that's extractable; else `deck.manualLessonDate`/`manualLessonDateEnd`,
    /// if the student set one; else none at all.
    func deckKickers(for decks: [Deck]) -> [String: String] {
        let extracted = (try? database.queue.read { db -> [String: (start: Date, end: Date)] in
            var result: [String: (start: Date, end: Date)] = [:]
            for deck in decks {
                let dates = try OverviewQueries.materials(forDecks: [deck.id], db: db).compactMap { material -> Date? in
                    let parsed = FilenameParsing.parse(fileNameWithoutExtension: material.title)
                    return material.noteDate ?? parsed.dateFromFilename
                }
                guard let start = dates.min(), let end = dates.max() else { continue }
                result[deck.id] = (start, end)
            }
            return result
        }) ?? [:]
        var result: [String: String] = [:]
        for deck in decks {
            if let range = extracted[deck.id] {
                result[deck.id] = Self.formatLessonDate(start: range.start, end: range.end)
            } else if let start = deck.manualLessonDate {
                result[deck.id] = Self.formatLessonDate(start: start, end: deck.manualLessonDateEnd)
            }
        }
        return result
    }

    /// "AUG 27" for a single date, "AUG 27–29" for a range within one
    /// month, "AUG 30 – SEP 2" for one crossing a month boundary.
    static func formatLessonDate(start: Date, end: Date?) -> String {
        let calendar = Calendar.current
        guard let end, !calendar.isDate(start, inSameDayAs: end) else {
            return start.formatted(.dateTime.month(.abbreviated).day()).uppercased()
        }
        let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
            && calendar.isDate(start, equalTo: end, toGranularity: .year)
        if sameMonth {
            let month = start.formatted(.dateTime.month(.abbreviated))
            let startDay = start.formatted(.dateTime.day())
            let endDay = end.formatted(.dateTime.day())
            return "\(month) \(startDay)–\(endDay)".uppercased()
        }
        let startStr = start.formatted(.dateTime.month(.abbreviated).day())
        let endStr = end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startStr) – \(endStr)".uppercased()
    }

    /// Sets or clears the lecture date (or range) the student assigned by
    /// hand, for a deck whose notes carry no extractable date. Never
    /// touches a date that *was* extracted -- `deckKickers` always prefers
    /// that one, so a manual date only ever fills in where extraction
    /// found nothing. `end` nil (or equal to `start`) means a single date,
    /// not a range.
    func setDeckManualLessonDate(_ deckId: String, start: Date?, end: Date? = nil) throws {
        try database.queue.write { db in
            guard var deck = try Deck.fetchOne(db, key: deckId) else { return }
            deck.manualLessonDate = start
            deck.manualLessonDateEnd = start == nil ? nil : end
            deck.updatedAt = Date()
            try deck.save(db)
        }
        reload()
    }

    func cards(inDeck deckId: String) throws -> [Card] {
        try cards(inDecks: [deckId])
    }

    /// The plural of the above -- the "All Cards" master category's entire
    /// data need is this fetch across every deck in a course, deck by deck.
    func cards(inDecks deckIds: [String]) throws -> [Card] {
        try database.queue.read { db in try CardActions.cards(inDecks: deckIds, db: db) }
    }

    /// The core's note-search hit; the name the views already use.
    typealias SearchResult = CardActions.NoteMatch

    /// Full-text search over every imported note (see `CardActions.searchNotes`).
    func searchNotes(query: String) throws -> [SearchResult] {
        try database.queue.read { db in try CardActions.searchNotes(query, db: db) }
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

    /// Saves an edit to a card's text -- and only its text. The row is
    /// re-read, so a review graded while the edit sheet was open survives
    /// (see `CardActions.updateText`).
    func updateCard(_ card: Card) throws {
        try database.queue.write { db in
            try CardActions.updateText(cardId: card.id, front: card.front, back: card.back, db: db)
        }
        reload()
    }

    /// Soft delete: the row stays, so review history survives for stats.
    func deleteCard(_ cardId: String) throws {
        try bulkDeleteCards([cardId])
    }

    /// Undoes one AI context-refinement; a no-op for a card never refined.
    func revertContextRefinement(_ cardId: String) throws {
        try database.queue.write { db in try CardActions.revertContextRefinement(cardId, db: db) }
        reload()
    }

    func setCardStatus(_ cardId: String, status: CardStatus) throws {
        try bulkSetStatus([cardId], status: status)
    }

    /// The plural of `setCardStatus`/`deleteCard`, for a multi-selected
    /// batch: one transaction and one `reload()` for the whole selection.
    func bulkSetStatus(_ cardIds: [String], status: CardStatus) throws {
        guard !cardIds.isEmpty else { return }
        try database.queue.write { db in try CardActions.setStatus(cardIds, to: status, db: db) }
        reload()
    }

    /// The plural of `deleteCard` -- same soft-delete semantics, batched.
    func bulkDeleteCards(_ cardIds: [String]) throws {
        guard !cardIds.isEmpty else { return }
        try database.queue.write { db in try CardActions.delete(cardIds, db: db) }
        reload()
    }

    /// One "keep this card, fold these into it" instruction from the
    /// Review Duplicates sheet -- the UI-facing mirror of
    /// `DuplicateDetector.Merge`, which does the actual work.
    struct DuplicateMerge {
        /// Nil: the student kept none of the group, so every card in
        /// `losingIds` is deleted.
        let survivorId: String?
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
        try database.queue.write { db in try CardActions.move(cardIds, toDeck: targetDeckId, db: db) }
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
        try database.queue.write { db in try Study.approveDrafts(inDecks: deckIds, db: db) }
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
        try database.queue.read { db in try Study.dueCards(inDecks: deckIds, now: now, db: db) }
    }

    /// Grades one card via FSRS, persists the new scheduler state, and logs
    /// a `review` row. `source` records which study mode produced the
    /// grade (flashcards, learn, test, ...) for later stats. If this
    /// card's course has an upcoming exam and FSRS would schedule its next
    /// review after that date, the interval is capped to land before it
    /// instead -- a review that lands after the test doesn't help for it.
    func gradeCard(_ cardId: String, grade: FSRS.Grade, source: String, now: Date = Date()) throws {
        try database.queue.write { db in
            try Study.grade(cardId, grade: grade, source: source, now: now, db: db)
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
            var rng = SystemRandomNumberGenerator()
            return try Study.learnRound(forDecks: deckIds, using: &rng, db: db)
        }
    }

    /// Records one Learn-mode answer: advances the card's ladder level and
    /// streak, independent of FSRS scheduling.
    func recordLearnAnswer(cardId: String, wasCorrect: Bool, now: Date = Date()) throws {
        try database.queue.write { db in
            try Study.recordLearnAnswer(cardId: cardId, wasCorrect: wasCorrect, now: now, db: db)
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
        try database.queue.read { db in try Study.mastery(forDecks: deckIds, db: db) }
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
        try database.queue.read { db in try Study.learnLevels(forDecks: deckIds, db: db) }
    }

    /// The Study screen's two-option grading: "Needs Review" or "I Know
    /// This" schedules the card (again / good) and moves its Learn level
    /// straight to its end state -- a flashcard verdict is a direct, final
    /// call, not an escalating quiz (see `Study.mark`).
    func markCard(_ cardId: String, understood: Bool, source: String = "flashcards", now: Date = Date()) throws {
        try database.queue.write { db in
            try Study.mark(cardId, understood: understood, source: source, now: now, db: db)
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

    /// What the last "New Study Guide" run did, for the Study Guide page.
    /// (Stored here: an extension can't hold it.)
    var lastStudyGuideRun: StudyGuideRunResult?
    struct StudyGuideRunResult: Equatable {
        var guideIds: [String]
        var skippedDecks: [String]
        var wasStopped: Bool
        var failure: String?
    }

    /// What the last code-question run did, for the bank sheet to report.
    var lastCodeQuestionRun: CodeQuestionRunResult?
    struct CodeQuestionRunResult: Equatable {
        var saved: Int
        var rejected: Int
        var wasStopped: Bool
        var failure: String?
        /// The most common reason drafts were dropped.
        var topReason: String?
    }

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
        aiTestQuestionsSkipped.set(true)
        aiTestQuestionTask?.cancel()
    }

    /// Read from GRASPCore's generation loop off the main actor, so it's a
    /// lock-guarded box rather than a plain property.
    @ObservationIgnored private let aiTestQuestionsSkipped = SkipFlag()

    /// The plural of the above, for a test run across every deck in a
    /// course. `testAttempt.deckId` is nullable precisely for this case --
    /// a course-wide attempt isn't attributable to any single deck, so it
    /// stores `nil` rather than picking one arbitrarily.
    func startTest(
        deckIds: [String], config: TestBuilder.Config
    ) async throws -> (attemptId: String, questions: [LearnEngine.RoundQuestion], aiWarning: String?) {
        aiTestQuestionsSkipped.set(false)

        // AI questions are always .written -- if Written is off, none
        // sneak in regardless of the toggle, and there's nothing to warn
        // about since the user didn't ask for any this time.
        // Its own task, so "Skip" can cancel just the AI questions and still
        // start the test -- cancelling the caller would also cancel the
        // database writes below that create the attempt.
        // Saved code questions come first: they were checked by running
        // them, which the one-line questions written on the spot weren't.
        var codeQuestions: [LearnEngine.RoundQuestion] = []
        var codeBudgetUsed = 0
        if isAITestQuestionsEnabled && config.allowWritten {
            let budget = Study.aiQuestionBudget(for: config.questionCount)
            codeQuestions = (try? await database.queue.read { db in
                var rng = SystemRandomNumberGenerator()
                return try CodeQuestionBank.pickRound(count: budget, inDecks: deckIds, using: &rng, db: db)
            }) ?? []
            codeBudgetUsed = codeQuestions.count
        }
        let aiResult: (questions: [LearnEngine.RoundQuestion], warning: String?)
        if config.allowWritten && isAITestQuestionsEnabled,
           Study.aiQuestionBudget(for: config.questionCount) - codeBudgetUsed > 0 {
            let budget = Study.aiQuestionBudget(for: config.questionCount) - codeBudgetUsed
            let database = database
            let skipped = aiTestQuestionsSkipped
            let task = Task {
                await CardAI.generateTestQuestions(
                    inDecks: deckIds, maxCount: budget, using: await CardGenerators.select(),
                    database: database, skipped: { skipped.value }
                )
            }
            aiTestQuestionTask = task
            aiResult = await task.value
            aiTestQuestionTask = nil
        } else {
            aiResult = ([], nil)
        }

        let aiQuestions = aiResult.questions + codeQuestions
        let started = try await database.queue.write { db in
            var rng = SystemRandomNumberGenerator()
            return try Study.startTest(deckIds: deckIds, config: config, aiQuestions: aiQuestions,
                                       using: &rng, db: db)
        }
        // Nothing to ask -- every card filtered out. Say so rather than
        // write an attempt nobody can take (`startTest` wrote none).
        guard !started.questions.isEmpty else { return ("", [], nil) }
        return (started.attemptId, started.questions, aiResult.warning)
    }

    /// A new test over just these questions (the ones missed last time).
    func startRetryTest(questions: [LearnEngine.RoundQuestion], deckIds: [String]) throws -> String {
        try database.queue.write { db in try Study.startRetry(questions: questions, deckIds: deckIds, db: db) }
    }

    /// Today's checklist for an exam. The decks are the study guide's, else
    /// the exam's own deck, else the whole course.
    func examPlan(for event: CalendarEvent, now: Date = Date()) -> [ExamPlan.Step] {
        let days = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                           to: Calendar.current.startOfDay(for: event.startsAt)).day ?? 0)
        guard days <= ExamPlan.horizonDays else { return [] }
        var ids = examDeckIds(examEventId: event.id)
        if ids.isEmpty, let deckId = event.deckId { ids = [deckId] }
        if ids.isEmpty, let courseId = event.courseId { ids = self.deckIds(in: .course(courseId)) }
        let deckIds = ids
        guard !deckIds.isEmpty else { return [] }
        let standing: ExamPlan.Standing = (try? database.queue.read { db in
            let active = try Study.learnCandidates(forDecks: deckIds, db: db).count
            let due = try Study.dueCards(inDecks: deckIds, now: now, db: db).count
            let weak = try Study.weakCardIds(forDecks: deckIds, db: db).count
            let problems = try CodeQuestionBank.count(inDecks: deckIds, db: db)
            let last = try Study.testHistory(forDecks: deckIds, limit: 1, db: db).last?.startedAt
            let since = last.flatMap { Calendar.current.dateComponents([.day], from: $0, to: now).day }
            return ExamPlan.Standing(dueCards: due, activeCards: active, weakCards: weak,
                                     savedProblems: problems, daysSinceTest: since)
        }) ?? ExamPlan.Standing(dueCards: 0, activeCards: 0, weakCards: 0, savedProblems: 0, daysSinceTest: nil)
        return ExamPlan.steps(daysAway: days, standing: standing)
    }

    func testHistory(forDecks deckIds: [String]) -> [Study.TestHistoryEntry] {
        (try? database.queue.read { db in try Study.testHistory(forDecks: deckIds, db: db) }) ?? []
    }

    func mostMissedCards(forDecks deckIds: [String]) -> [(front: String, misses: Int)] {
        (try? database.queue.read { db in try Study.mostMissed(forDecks: deckIds, db: db) }) ?? []
    }

    func weakSpotCount(forDecks deckIds: [String]) -> Int {
        (try? database.queue.read { db in try Study.weakCardIds(forDecks: deckIds, db: db).count }) ?? 0
    }

    /// Records one answer to a test item. Keyed by `ordinal` rather than
    /// `cardId` -- an AI-generated question has no `cardId` at all.
    func submitTestAnswer(attemptId: String, ordinal: Int, given: String, isCorrect: Bool) throws {
        try database.queue.write { db in
            try Study.submitTestAnswer(attemptId: attemptId, ordinal: ordinal, given: given,
                                       isCorrect: isCorrect, db: db)
        }
    }

    /// Scores a test and rewards every card you got right with a Good
    /// grade in FSRS, so a test also credits what you knew -- a miss isn't
    /// punished, so it doesn't also tighten the flashcard schedule.
    func finishTest(attemptId: String) throws -> (correct: Int, total: Int) {
        let result = try database.queue.write { db in try Study.finishTest(attemptId: attemptId, db: db) }
        reload()
        return result
    }

    /// "I was right" on a written answer fuzzy matching marked wrong. On a
    /// finished attempt this also corrects the score and grades the card
    /// Good -- `finishTest` never graded it (a miss gets no grade), so this
    /// is where it earns credit now that it's marked right. Idempotent.
    func overrideTestItemCorrect(attemptId: String, ordinal: Int, cardId: String?) throws {
        try database.queue.write { db in
            try Study.overrideTestItemCorrect(attemptId: attemptId, ordinal: ordinal, cardId: cardId, db: db)
        }
        reload()
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
    /// week columns and the agenda all read.
    func calendarEvents(from start: Date, to end: Date) throws -> [CalendarEvent] {
        try database.queue.read { db in try CalendarActions.events(from: start, to: end, db: db) }
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
    /// the Home dashboard's alert strip (see `CalendarActions.upcomingExams`).
    func upcomingExams(within days: Int = 30, limit: Int = 5, now: Date = Date()) throws -> [UpcomingEvent] {
        try database.queue.read { db in
            let events = try CalendarActions.upcomingExams(within: days, limit: limit, now: now, db: db)
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
        try database.queue.write { db in try CalendarActions.add(event, db: db) }
        reload()
    }

    func updateCalendarEvent(_ event: CalendarEvent) throws {
        try database.queue.write { db in try CalendarActions.update(event, db: db) }
        reload()
    }

    /// Takes any study plan generated for this exam with it.
    func deleteCalendarEvent(_ eventId: String) throws {
        try database.queue.write { db in try CalendarActions.delete(eventId, db: db) }
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

    typealias StudyPlanSummary = CalendarActions.PlanSummary

    /// How many cards a plan for this event would have to cover -- the
    /// linked deck's active cards, or the whole course's when no specific
    /// deck is set.
    func plannableCardCount(for event: CalendarEvent) -> Int {
        (try? database.queue.read { db in try CalendarActions.plannableCardCount(for: event, db: db) }) ?? 0
    }

    /// Lays a `StudyPlanner` plan onto the calendar as study blocks, each
    /// linked back to the exam so regenerating replaces exactly the blocks
    /// this made before and nothing else.
    @discardableResult
    func generateStudyPlan(for event: CalendarEvent, now: Date = Date()) throws -> StudyPlanSummary {
        let courseName = event.courseId.flatMap { courseName($0) }
        let summary = try database.queue.write { db in
            try CalendarActions.generateStudyPlan(for: event, courseName: courseName, now: now, db: db)
        }
        reload()
        return summary
    }

    func hasStudyPlan(for eventId: String) -> Bool {
        (try? database.queue.read { db in try CalendarActions.hasStudyPlan(for: eventId, db: db) }) ?? false
    }

    // MARK: - Streak and daily load

    typealias StudyStreak = StudyProgress.Streak

    /// Consecutive days studied, counting back from today; studying
    /// yesterday but not yet today keeps it alive (see `StudyProgress`).
    func studyStreak(now: Date = Date()) -> StudyStreak {
        (try? database.queue.read { db in try StudyProgress.streak(now: now, db: db) })
            ?? StudyStreak(days: 0, studiedToday: false, reviewsToday: 0)
    }

    /// Cards falling due on each day in a range, for the calendar's
    /// workload colouring; anything overdue lands on the first day.
    func dailyCardLoad(from start: Date, to end: Date) -> [Date: Int] {
        (try? database.queue.read { db in try CalendarActions.dailyCardLoad(from: start, to: end, db: db) }) ?? [:]
    }

    func materialCount(inCourse courseId: String) throws -> Int {
        try database.queue.read { db in try LibraryActions.materialCount(inCourse: courseId, db: db) }
    }

    func updateCourse(_ course: Course) throws {
        try database.queue.write { db in try LibraryActions.updateCourse(course, db: db) }
        reload()
    }

    /// Hides a course without touching its data. Reversible, and the
    /// scanner reuses the same (still archived) row on re-import rather
    /// than resurrecting it as a new course.
    func setCourseArchived(_ courseId: String, archived: Bool) throws {
        try database.queue.write { db in
            try LibraryActions.setCourseArchived(courseId, archived: archived, db: db)
        }
        reload()
    }

    /// What a delete would actually remove, so the confirmation can say it
    /// in numbers. Cards are counted by deck membership, which also reaches
    /// hand-typed cards (see `LibraryActions.courseDeletionImpact`).
    func courseDeletionImpact(_ courseId: String) throws -> (materials: Int, cards: Int, reviews: Int) {
        try database.queue.read { db in try LibraryActions.courseDeletionImpact(courseId, db: db) }
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
    /// removes the course and everything derived from it. There's
    /// deliberately no "delete but let it come back": a course silently
    /// resurrecting on the next import reads as a bug.
    func removeCourseAndExclude(_ courseId: String) throws {
        try database.queue.write { db in try LibraryActions.removeCourseAndExclude(courseId, db: db) }
        reload()
    }

    func addManualCourse(name: String, code: String?, semesterId: String? = nil) throws {
        try database.queue.write { db in
            try LibraryActions.addManualCourse(name: name, code: code, semesterId: semesterId, db: db)
        }
        reload()
    }

    /// A freeform timeline typed by hand ("Fall 2026", "Quarter 1"),
    /// reusing the vault's semester when the name matches one.
    @discardableResult
    func findOrCreateSemester(name: String) throws -> String {
        let id = try database.queue.write { db in try LibraryActions.findOrCreateSemester(name: name, db: db) }
        reload()
        return id
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

    /// Appends a hand-named deck after every parsed one in the course.
    @discardableResult
    func createDeck(courseId: String, name: String) throws -> String {
        let id = try database.queue.write { db in try LibraryActions.createDeck(courseId: courseId, name: name, db: db) }
        reload()
        return id
    }

    func renameDeck(_ deckId: String, name: String) throws {
        try database.queue.write { db in try LibraryActions.renameDeck(deckId, name: name, db: db) }
        reload()
    }

    /// Live cards in the deck, suspended ones included -- what a deletion
    /// confirmation should count.
    func deckCardCount(_ deckId: String) throws -> Int {
        try database.queue.read { db in try LibraryActions.deckCardCount(deckId, db: db) }
    }

    /// Removes a deck from view: its cards move to `migrateCardsTo`, or are
    /// soft-deleted when that's nil (never hard-deleted, which would take
    /// their study history with them).
    func deleteDeck(_ deckId: String, migrateCardsTo targetDeckId: String?) throws {
        try database.queue.write { db in
            try LibraryActions.deleteDeck(deckId, migrateCardsTo: targetDeckId, db: db)
        }
        reload()
    }

    /// Moves a card to the end of another deck. A card belongs to one deck
    /// by convention, so there's no source to look up; origin is untouched.
    func moveCard(_ cardId: String, toDeck targetDeckId: String) throws {
        try bulkMoveCards([cardId], toDeck: targetDeckId)
    }

    /// A card typed by hand: active, not a draft (see `CardActions.createManual`).
    @discardableResult
    func createManualCard(front: String, back: String, deckId: String) throws -> String {
        let id = try database.queue.write { db in
            try CardActions.createManual(front: front, back: back, deckId: deckId, db: db)
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

/// A flag GRASPCore's background loops can poll while the main actor sets
/// it -- Skip on AI test questions.
nonisolated final class SkipFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ newValue: Bool) { lock.lock(); flag = newValue; lock.unlock() }
}
