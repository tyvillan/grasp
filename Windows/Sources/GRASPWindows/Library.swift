import Foundation
import GRASPCore
import GRDB
import Observation

/// One deck as the deck column lists it.
struct DeckRow: Identifiable, Hashable {
    let id: String
    let courseId: String
    let courseName: String
    let name: String
    let total: Int
    let due: Int
    let drafts: Int
}

/// What a deck page shows: one deck, or a course's "All Cards" -- every
/// deck in it at once, as on the Mac.
struct DeckScope: Hashable {
    let id: String
    let title: String
    let courseName: String
    let deckIds: [String]
    let total: Int
    let due: Int
    let drafts: Int

    init(deck: DeckRow) {
        id = deck.id
        title = deck.name
        courseName = deck.courseName
        deckIds = [deck.id]
        total = deck.total
        due = deck.due
        drafts = deck.drafts
    }

    init(allCardsIn decks: [DeckRow], courseId: String, courseName: String) {
        id = "all:\(courseId)"
        title = "All Cards"
        self.courseName = courseName
        deckIds = decks.map(\.id)
        total = decks.reduce(0) { $0 + $1.total }
        due = decks.reduce(0) { $0 + $1.due }
        drafts = decks.reduce(0) { $0 + $1.drafts }
    }
}

/// The signed-in profile's library: what the screens show, and the
/// actions they take on it. The Windows counterpart of the Mac app's
/// `AppStore`, kept thin -- the study logic itself is GRASPCore's `Study`.
@Observable
final class Library {
    let database: GRASPDatabase
    /// Every live deck in a course that isn't archived, in each course's
    /// deck order (`sortIndex`, `chapter`, `name`, as the Mac orders them).
    private(set) var decks: [DeckRow] = []
    /// Oldest first, by `sortKey`; the sidebar shows them newest first.
    private(set) var semesters: [Semester] = []
    /// Courses that aren't archived, keyed by semester; `nil` is "No Timeline".
    private(set) var coursesBySemester: [String?: [Course]] = [:]
    /// The result of the last import, or why it failed.
    var status: String?
    private(set) var isImporting = false
    /// Sign-in and sync. Set up after the library loads, since it reloads
    /// the library when another device's changes arrive.
    private(set) var account: Account!
    /// The open profile (there's no profile picker yet, so the first).
    private(set) var profile: Profile
    /// This profile's preferences.
    let settings: AppSettings
    /// Archived courses, for Settings' "Hidden Courses".
    private(set) var archivedCourses: [Course] = []
    /// Vault folders imports skip, for Settings' "Excluded Folders".
    private(set) var excludedFolders: [String] = []
    /// Bumped by every reload. Screens that query the database directly
    /// (the calendar, Home's figures) read it so they redraw after an edit
    /// or a sync, the Mac's `AppStore.revision`.
    private(set) var revision = 0
    private let supportDirectory: URL

    init() throws {
        let support = try Self.supportDirectory()
        supportDirectory = support
        var profiles = try ProfileStore.loadOrMigrate(supportDirectory: support)
        // No profile picker or sign-in yet: a fresh install gets one profile.
        if profiles.isEmpty {
            profiles = [Profile(name: "Me")]
            try ProfileStore.save(profiles, supportDirectory: support)
        }
        profile = profiles[0]
        settings = AppSettings(file: profiles[0].databaseURL(supportDirectory: support)
            .deletingLastPathComponent().appendingPathComponent("settings.json"))
        database = try GRASPDatabase(path: profiles[0].databaseURL(supportDirectory: support))
        reload()
        account = Account(database: database, profile: profiles[0], supportDirectory: support) { [weak self] in
            self?.reload()
        }
    }

    /// Where the library lives. `GRASP_SUPPORT_DIR` overrides it -- on a
    /// Mac, trying this app would otherwise open the real Mac app's
    /// library, which uses the same folder.
    nonisolated static func supportDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["GRASP_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return try GRASPDatabase.supportDirectory()
    }

    func reload() {
        let now = Date()
        try? database.queue.read { db in
            // Same ordering as the Mac's AppStore.reload().
            semesters = try Semester.order(Column("sortKey")).fetchAll(db)
            let courses = try Course
                .filter(Column("isArchived") == false)
                .order(Column("sortIndex"), Column("name"))
                .fetchAll(db)
            coursesBySemester = Dictionary(grouping: courses, by: \.semesterId)
            decks = try Row.fetchAll(db, sql: """
                SELECT deck.id, deck.name, deck.courseId, course.name AS courseName,
                       COUNT(card.id) AS total,
                       COALESCE(SUM(CASE WHEN card.status = 'active' AND card.due <= ? THEN 1 ELSE 0 END), 0) AS due,
                       COALESCE(SUM(CASE WHEN card.status = 'draft' THEN 1 ELSE 0 END), 0) AS drafts
                FROM deck
                JOIN course ON course.id = deck.courseId
                LEFT JOIN deckCard ON deckCard.deckId = deck.id
                LEFT JOIN card ON card.id = deckCard.cardId
                     AND card.deletedAt IS NULL AND card.status != 'suspended'
                WHERE deck.deletedAt IS NULL AND course.isArchived = 0
                GROUP BY deck.id
                ORDER BY deck.sortIndex, deck.chapter, deck.name
                """, arguments: [now])
            .map { row in
                DeckRow(id: row["id"], courseId: row["courseId"], courseName: row["courseName"],
                        name: row["name"], total: row["total"], due: row["due"], drafts: row["drafts"])
            }
            archivedCourses = try Course
                .filter(Column("isArchived") == true)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
            excludedFolders = try ExcludedFolder
                .order(Column("excludedAt").desc)
                .fetchAll(db)
                .map(\.folderPath)
        }
        revision += 1
    }

    /// Runs a write, then reloads and schedules a sync, as every change does.
    private func change(_ body: (Database) throws -> Void) {
        try? database.queue.write { try body($0) }
        reload()
        account?.noteLocalChange()
    }

    /// A course's name, archived ones included (an exam keeps its label).
    func courseName(_ courseId: String) -> String? {
        course(courseId)?.name ?? archivedCourses.first { $0.id == courseId }?.name
    }

    /// Courses newest semester first, then "No Timeline", as the Mac's
    /// sidebar lists them. Semesters with no live course are left out.
    var courseSections: [(title: String, courses: [Course])] {
        var sections = semesters.reversed().compactMap { semester -> (String, [Course])? in
            guard let courses = coursesBySemester[semester.id], !courses.isEmpty else { return nil }
            return (semester.name, courses)
        }
        if let unfiled = coursesBySemester[nil], !unfiled.isEmpty {
            sections.append(("No Timeline", unfiled))
        }
        return sections
    }

    func course(_ id: String) -> Course? {
        coursesBySemester.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    func decks(inCourse courseId: String) -> [DeckRow] {
        decks.filter { $0.courseId == courseId }
    }

    // MARK: - Importing

    /// Imports a notes folder laid out as `College/<semester>/<course>/`.
    func importVault(at root: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let summary = try await VaultScanner(database: database).scan(vaultRoot: root)
            if summary.courseCount == 0 {
                status = "No courses found. GRASP looks for College\\<semester>\\<course> folders inside \(root.lastPathComponent)."
            } else {
                status = "Imported \(summary.filesImportedOrUpdated) note(s) from \(summary.courseCount) course(s): "
                    + "\(summary.cardsCreated) new card(s)."
                    + (summary.errors.first.map { " First problem: \($0)" } ?? "")
            }
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
        reload()
        account.noteLocalChange()
    }

    /// Imports the built-in one-lecture Matrix Theory vault.
    func importSample() async {
        do {
            let root = try Self.supportDirectory().appendingPathComponent("Sample Notes", isDirectory: true)
            await importVault(at: try SampleVault.write(to: root))
        } catch {
            status = "Couldn't write the sample notes: \(error.localizedDescription)"
        }
    }

    // MARK: - Studying

    func dueCards(inDecks deckIds: [String]) -> [Card] {
        (try? database.queue.read { try Study.dueCards(inDecks: deckIds, db: $0) }) ?? []
    }

    func approveDrafts(inDecks deckIds: [String]) {
        try? database.queue.write { try Study.approveDrafts(inDecks: deckIds, db: $0) }
        reload()
        account.noteLocalChange()
    }

    func grade(_ card: Card, _ grade: FSRS.Grade) {
        try? database.queue.write { try Study.grade(card.id, grade: grade, source: "flashcards", db: $0) }
        reload()
        account.noteLocalChange()
    }

    // MARK: - Cards

    func cards(inDecks deckIds: [String]) -> [Card] {
        let key = "\(revision)|\(deckIds.joined(separator: ","))"
        if let cached = cardsCache, cached.key == key { return cached.value }
        let value = (try? database.queue.read { try CardActions.cards(inDecks: deckIds, db: $0) }) ?? []
        cardsCache = (key, value)
        return value
    }

    /// The last card list read, for the same reason as `overviewCache`.
    @ObservationIgnored private var cardsCache: (key: String, value: [Card])?

    func editCard(_ cardId: String, front: String, back: String) {
        change { _ = try CardActions.updateText(cardId: cardId, front: front, back: back, db: $0) }
    }

    func setStatus(_ cardIds: [String], to status: CardStatus) {
        change { try CardActions.setStatus(cardIds, to: status, db: $0) }
    }

    func deleteCards(_ cardIds: [String]) {
        change { try CardActions.delete(cardIds, db: $0) }
    }

    func moveCards(_ cardIds: [String], toDeck deckId: String) {
        change { try CardActions.move(cardIds, toDeck: deckId, db: $0) }
    }

    func revertContextRefinement(_ cardId: String) {
        change { try CardActions.revertContextRefinement(cardId, db: $0) }
    }

    func createCard(front: String, back: String, deckId: String) {
        change { _ = try CardActions.createManual(front: front, back: back, deckId: deckId, db: $0) }
    }

    // MARK: - Search

    func searchNotes(_ query: String) -> [CardActions.NoteMatch] {
        (try? database.queue.read { try CardActions.searchNotes(query, db: $0) }) ?? []
    }

    func searchCards(_ query: String) -> [CardActions.CardMatch] {
        (try? database.queue.read { try CardActions.searchCards(query, db: $0) }) ?? []
    }

    /// A note's text, for reading a search hit in full.
    func note(_ materialId: String) -> (title: String, text: String)? {
        try? database.queue.read { db in
            guard let material = try Material.fetchOne(db, key: materialId),
                  let note = try NoteText.fetchOne(db, key: materialId) else { return nil }
            return (DeckOverviewReader.lessonHeading(for: material).title, note.raw)
        }
    }

    // MARK: - Calendar

    func calendarEvents(from start: Date, to end: Date) -> [CalendarEvent] {
        (try? database.queue.read { try CalendarActions.events(from: start, to: end, db: $0) }) ?? []
    }

    func upcomingExams(within days: Int = 30, limit: Int = 3) -> [CalendarEvent] {
        (try? database.queue.read { try CalendarActions.upcomingExams(within: days, limit: limit, db: $0) }) ?? []
    }

    func dailyCardLoad(from start: Date, to end: Date, calendar: Calendar) -> [Date: Int] {
        (try? database.queue.read {
            try CalendarActions.dailyCardLoad(from: start, to: end, calendar: calendar, db: $0)
        }) ?? [:]
    }

    func addEvent(_ event: CalendarEvent) { change { try CalendarActions.add(event, db: $0) } }
    func updateEvent(_ event: CalendarEvent) { change { try CalendarActions.update(event, db: $0) } }
    func deleteEvent(_ eventId: String) { change { try CalendarActions.delete(eventId, db: $0) } }

    func plannableCardCount(for event: CalendarEvent) -> Int {
        (try? database.queue.read { try CalendarActions.plannableCardCount(for: event, db: $0) }) ?? 0
    }

    func hasStudyPlan(for eventId: String) -> Bool {
        (try? database.queue.read { try CalendarActions.hasStudyPlan(for: eventId, db: $0) }) ?? false
    }

    func generateStudyPlan(for event: CalendarEvent) {
        let courseName = event.courseId.flatMap { courseName($0) }
        change { try CalendarActions.generateStudyPlan(for: event, courseName: courseName, db: $0) }
    }

    // MARK: - Progress

    func studyStreak() -> StudyProgress.Streak {
        (try? database.queue.read { try StudyProgress.streak(db: $0) })
            ?? StudyProgress.Streak(days: 0, studiedToday: false, reviewsToday: 0)
    }

    // MARK: - Settings

    func renameProfile(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        profile.name = trimmed
        try? ProfileStore.update(profile, supportDirectory: supportDirectory)
    }

    /// Shows an archived course again (the Mac's `setCourseArchived`).
    func unarchiveCourse(_ courseId: String) {
        change { db in
            guard var course = try Course.fetchOne(db, key: courseId) else { return }
            course.isArchived = false
            course.updatedAt = Date()
            try course.save(db)
        }
    }

    /// Lets imports walk a folder again (the Mac's `includeFolder`).
    func includeFolder(_ path: String) {
        change { _ = try ExcludedFolder.deleteOne($0, key: path) }
    }

    /// Where this profile's library and log live, for Settings.
    var libraryFolder: URL { supportDirectory }

    // MARK: - Overviews

    /// The lessons behind these decks, one per note, as the Mac's Overview
    /// tab reads them. Overviews are written on the Mac (or later, here via
    /// Ollama) and arrive with sync.
    func deckOverview(inDecks deckIds: [String]) -> DeckOverview? {
        let key = "\(revision)|\(deckIds.joined(separator: ","))"
        if let cached = overviewCache, cached.key == key { return cached.value }
        let value = try? database.queue.read { db in
            try DeckOverviewReader.read(deckIds: deckIds, db: db, metrics: Self.diagramMetrics, cache: diagramCache)
        }
        overviewCache = (key, value)
        return value
    }

    /// The last overview read. A deck's page redraws on every click inside
    /// it, and assembling a course's lessons (clean-up, card links, figures)
    /// is the heaviest read in the app; it only changes with `revision`.
    @ObservationIgnored private var overviewCache: (key: String, value: DeckOverview?)?
    @ObservationIgnored private let diagramCache = DiagramLayoutCache()

    /// The overview run for each course, if one has started.
    private(set) var overviewJobs: [String: OverviewJob] = [:]

    func overviewJob(forCourse courseId: String?) -> OverviewJob? {
        overviewJobs[courseId ?? ""]
    }

    /// Starts writing overviews for these notes with the local model.
    func writeOverviews(_ notes: [(materialId: String, title: String)], courseId: String?) {
        guard overviewJob(forCourse: courseId).map({ $0.isFinished }) ?? true else { return }
        let job = OverviewJob(courseId: courseId, headline: "Starting the local model…")
        overviewJobs[courseId ?? ""] = job
        job.run(notes, library: self)
    }

    func dismissOverviewJob(forCourse courseId: String?) {
        overviewJobs[courseId ?? ""] = nil
    }

    /// A lesson was just saved: show it, and sync it to the Mac.
    func overviewsChanged() {
        reload()
        account.noteLocalChange()
    }

    /// Whether the local model is up, and which one GRASP would use.
    func localModel() async -> String? {
        let probe = OllamaGenerator()
        guard await probe.isAvailable else { return nil }
        return OllamaModelChoice.resolve(
            preferred: UserDefaults.standard.string(forKey: OllamaModelChoice.defaultsKey),
            installed: await probe.installedModels())
    }

    /// Concept-map labels at 12 pt Segoe UI: about 6.6 pt a character on
    /// average, rounded up so a label never clips.
    private static let diagramMetrics: DiagramMetrics = {
        var metrics = DiagramMetrics()
        metrics.characterWidth = 7
        metrics.lineHeight = 16
        return metrics
    }()
}

/// A row reduction ready to draw: `states[0]` is the starting matrix and
/// `steps[i]` turns `states[i]` into `states[i + 1]`.
struct RowReductionSteps {
    let states: [RationalMatrix]
    let steps: [RowOperation]
    let fromNote: Bool
}
