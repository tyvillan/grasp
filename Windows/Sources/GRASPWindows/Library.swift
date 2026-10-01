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
    /// "AUG 27" or "AUG 27–29": the lecture date shown above the name.
    var kicker: String?
    /// The date or range the student set by hand, if any.
    var manualStart: Date?
    var manualEnd: Date?
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
    /// Set for All Cards and an exam, whose ids aren't a deck's.
    var courseId: String?

    init(deck: DeckRow) {
        id = deck.id
        courseId = deck.courseId
        title = deck.name
        courseName = deck.courseName
        deckIds = [deck.id]
        total = deck.total
        due = deck.due
        drafts = deck.drafts
    }

    init(allCardsIn decks: [DeckRow], courseId: String, courseName: String) {
        id = "all:\(courseId)"
        self.courseId = courseId
        title = "All Cards"
        self.courseName = courseName
        deckIds = decks.map(\.id)
        total = decks.reduce(0) { $0 + $1.total }
        due = decks.reduce(0) { $0 + $1.due }
        drafts = decks.reduce(0) { $0 + $1.drafts }
    }

    /// The decks an exam's study guides cover, for "Study for this exam".
    init(exam: CalendarEvent, decks: [DeckRow], courseId: String, courseName: String) {
        id = Self.examId(exam.id)
        self.courseId = courseId
        title = exam.title
        self.courseName = courseName
        deckIds = decks.map(\.id)
        total = decks.reduce(0) { $0 + $1.total }
        due = decks.reduce(0) { $0 + $1.due }
        drafts = decks.reduce(0) { $0 + $1.drafts }
    }

    /// An exam's row in the deck column shares the deck selection.
    static func examId(_ examEventId: String) -> String { "exam:\(examEventId)" }
    static func examEventId(fromId id: String?) -> String? {
        guard let id, id.hasPrefix("exam:") else { return nil }
        return String(id.dropFirst(5))
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
    /// Set while any import runs (the notes folder, or files into a course).
    var isImporting = false
    /// Sign-in and sync. Set up after the library loads, since it reloads
    /// the library when another device's changes arrive.
    private(set) var account: Account!
    /// The open profile, chosen in `ProfilePicker` (or the only one).
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

    init(profile: Profile) throws {
        let support = try Self.supportDirectory()
        supportDirectory = support
        self.profile = profile
        settings = AppSettings(file: profile.databaseURL(supportDirectory: support)
            .deletingLastPathComponent().appendingPathComponent("settings.json"))
        database = try GRASPDatabase(path: profile.databaseURL(supportDirectory: support))
        reload()
        account = Account(database: database, profile: profile, supportDirectory: support) { [weak self] in
            self?.reload()
        }
    }

    /// Leaving this profile for another: stop syncing and any AI runs, so
    /// nothing keeps writing to a library no longer on screen.
    func close() {
        account.stop()
        for job in overviewJobs.values { job.stop() }
        for job in cardJobs.values { job.stop() }
    }

    /// Every profile on this PC, making the first one on a fresh install.
    nonisolated static func profiles() throws -> [Profile] {
        let support = try supportDirectory()
        var profiles = try ProfileStore.loadOrMigrate(supportDirectory: support)
        if profiles.isEmpty {
            profiles = [Profile(name: "Me")]
            try ProfileStore.save(profiles, supportDirectory: support)
        }
        return profiles
    }

    nonisolated static func addProfile(_ profile: Profile) throws {
        let support = try supportDirectory()
        var profiles = try ProfileStore.loadOrMigrate(supportDirectory: support)
        profiles.append(profile)
        try ProfileStore.save(profiles, supportDirectory: support)
    }

    /// Sets, changes or (with nil) removes this profile's PIN.
    func setPIN(_ pin: String?) {
        profile.pinHash = pin.map(ProfileStore.hashPIN)
        try? ProfileStore.update(profile, supportDirectory: supportDirectory)
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
            let kickers = try LessonDates.kickers(db: db)
            decks = try Row.fetchAll(db, sql: """
                SELECT deck.id, deck.name, deck.courseId, course.name AS courseName,
                       COUNT(card.id) AS total,
                       COALESCE(SUM(CASE WHEN card.status = 'active' AND card.due <= ? THEN 1 ELSE 0 END), 0) AS due,
                       COALESCE(SUM(CASE WHEN card.status = 'draft' THEN 1 ELSE 0 END), 0) AS drafts,
                       deck.manualLessonDate AS manualStart, deck.manualLessonDateEnd AS manualEnd
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
                        name: row["name"], total: row["total"], due: row["due"], drafts: row["drafts"],
                        kicker: kickers[row["id"] as String], manualStart: row["manualStart"], manualEnd: row["manualEnd"])
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

    /// Sets, or with nil clears, the lecture date a deck shows when its notes
    /// carry none.
    func setLectureDate(_ deckId: String, start: Date?, end: Date?) {
        change { try LessonDates.setManual(deckId: deckId, start: start, end: end, db: $0) }
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

    /// iCloud files are stored under the Mac's paths, so importing here and
    /// on the Mac updates the same notes. Identity until the library holds
    /// a Mac path or when iCloud for Windows isn't set up.
    func vaultPaths() -> VaultPathMap {
        if let cachedVaultPaths { return cachedVaultPaths }
        var map = VaultPathMap.identity
        if FileManager.default.fileExists(atPath: Self.iCloudDrive.path),
           let home = (try? database.queue.read { try VaultPathMap.macHome(in: $0) }) ?? nil {
            map = VaultPathMap(macHome: home, iCloudDrive: Self.iCloudDrive.path)
            cachedVaultPaths = map
        }
        return map
    }

    @ObservationIgnored private var cachedVaultPaths: VaultPathMap?

    /// Imports a notes folder laid out as `College/<semester>/<course>/`.
    func importVault(at root: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let summary = try await VaultScanner(database: database, paths: vaultPaths()).scan(vaultRoot: root)
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

    // Answers during a session are saved at once but the library isn't
    // reloaded until the session ends (`finishSession`): a reload redraws the
    // deck page behind the session, which made every answer lag.

    /// Saves one answer and schedules a sync, without a reload.
    private func record(_ body: (Database) throws -> Void) {
        try? database.queue.write { try body($0) }
        account.noteLocalChange()
    }

    /// Home's per-deck figures, with when each was last studied.
    func dashboardDecks() -> [Dashboard.DeckSummary] {
        let key = "\(revision)"
        if let cached = dashboardCache, cached.key == key { return cached.value }
        let value = (try? database.queue.read { try Dashboard.decks(db: $0) }) ?? []
        dashboardCache = (key, value)
        return value
    }

    @ObservationIgnored private var dashboardCache: (key: String, value: [Dashboard.DeckSummary])?
    @ObservationIgnored var guidedExamsCache: (key: String, value: [CalendarEvent])?
    @ObservationIgnored var examPageCache: (key: String, value: StudyGuideActions.ExamPage?)?

    /// Home's "Continue" opens a deck straight into flashcards: the deck
    /// page takes this on arrival.
    @ObservationIgnored private var pendingStudyDeck: String?

    func requestStudy(deckId: String) { pendingStudyDeck = deckId }

    func takeStudyRequest(for scopeId: String) -> Bool {
        guard pendingStudyDeck == scopeId else { return false }
        pendingStudyDeck = nil
        return true
    }

    /// A study session ended: bring due counts, streak and mastery up to date.
    func finishSession() {
        reload()
    }

    /// "I Know This" / "Needs Review".
    func mark(_ cardId: String, understood: Bool) {
        record { try Study.mark(cardId, understood: understood, db: $0) }
    }

    func learnRound(inDecks deckIds: [String]) -> [LearnEngine.RoundQuestion] {
        var rng = SystemRandomNumberGenerator()
        return (try? database.queue.read { try Study.learnRound(forDecks: deckIds, using: &rng, db: $0) }) ?? []
    }

    func recordLearnAnswer(cardId: String, wasCorrect: Bool) {
        record { try Study.recordLearnAnswer(cardId: cardId, wasCorrect: wasCorrect, db: $0) }
    }

    func mastery(inDecks deckIds: [String]) -> (mastered: Int, total: Int) {
        (try? database.queue.read { try Study.mastery(forDecks: deckIds, db: $0) }) ?? (0, 0)
    }

    func learnLevels(inDecks deckIds: [String]) -> [String: LearnEngine.Level] {
        let key = "\(revision)|\(deckIds.joined(separator: ","))"
        if let cached = levelsCache, cached.key == key { return cached.value }
        let value = (try? database.queue.read { try Study.learnLevels(forDecks: deckIds, db: $0) }) ?? [:]
        levelsCache = (key, value)
        return value
    }

    @ObservationIgnored private var levelsCache: (key: String, value: [String: LearnEngine.Level])?

    /// Writes the attempt; nil when every card was filtered out.
    func startTest(inDecks deckIds: [String], config: TestBuilder.Config, aiQuestions: [LearnEngine.RoundQuestion] = [])
        -> (attemptId: String, questions: [LearnEngine.RoundQuestion])? {
        var rng = SystemRandomNumberGenerator()
        let result = try? database.queue.write {
            try Study.startTest(deckIds: deckIds, config: config, aiQuestions: aiQuestions, using: &rng, db: $0)
        }
        guard let result, !result.questions.isEmpty else { return nil }
        return result
    }

    func submitTestAnswer(attemptId: String, ordinal: Int, given: String, isCorrect: Bool) {
        record { try Study.submitTestAnswer(attemptId: attemptId, ordinal: ordinal, given: given, isCorrect: isCorrect, db: $0) }
    }

    func finishTest(attemptId: String) {
        record { _ = try Study.finishTest(attemptId: attemptId, db: $0) }
    }

    func overrideTestAnswer(attemptId: String, ordinal: Int, cardId: String?) {
        record { try Study.overrideTestItemCorrect(attemptId: attemptId, ordinal: ordinal, cardId: cardId, db: $0) }
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

    func card(_ id: String) -> Card? {
        try? database.queue.read { try Card.fetchOne($0, key: id) }
    }

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
    func note(_ materialId: String) -> (kicker: String?, title: String, text: String)? {
        try? database.queue.read { db in
            guard let material = try Material.fetchOne(db, key: materialId),
                  let note = try NoteText.fetchOne(db, key: materialId) else { return nil }
            let heading = DeckOverviewReader.lessonHeading(for: material)
            return (heading.kicker, heading.title, note.raw)
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

    /// Shows an archived course again.
    func unarchiveCourse(_ courseId: String) {
        setArchived(courseId, false)
    }

    // MARK: - Organising courses and decks

    func setArchived(_ courseId: String, _ archived: Bool) {
        change { try LibraryActions.setCourseArchived(courseId, archived: archived, db: $0) }
    }

    /// Saves an edited course, with its timeline typed as text ("Fall
    /// 2026"); an empty timeline files it under "No Timeline".
    func saveCourse(_ course: Course, timeline: String) {
        change { db in
            var updated = course
            updated.name = course.name.trimmingCharacters(in: .whitespaces)
            let trimmed = timeline.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.semesterId = trimmed.isEmpty ? nil : try LibraryActions.findOrCreateSemester(name: trimmed, db: db)
            try LibraryActions.updateCourse(updated, db: db)
        }
    }

    func addCourse(name: String, code: String?, timeline: String) -> String? {
        var id: String?
        change { db in
            let trimmed = timeline.trimmingCharacters(in: .whitespacesAndNewlines)
            let semesterId = trimmed.isEmpty ? nil : try LibraryActions.findOrCreateSemester(name: trimmed, db: db)
            id = try LibraryActions.addManualCourse(name: name.trimmingCharacters(in: .whitespaces),
                                                    code: code, semesterId: semesterId, db: db)
        }
        return id
    }

    func courseDeletionImpact(_ courseId: String) -> (materials: Int, cards: Int, reviews: Int)? {
        try? database.queue.read { try LibraryActions.courseDeletionImpact(courseId, db: $0) }
    }

    func deleteCourse(_ courseId: String) {
        change { try LibraryActions.removeCourseAndExclude(courseId, db: $0) }
    }

    func materialCount(inCourse courseId: String) -> Int {
        (try? database.queue.read { try LibraryActions.materialCount(inCourse: courseId, db: $0) }) ?? 0
    }

    func semesterName(_ semesterId: String?) -> String {
        semesters.first { $0.id == semesterId }?.name ?? ""
    }

    func createDeck(courseId: String, name: String) -> String? {
        var id: String?
        change { id = try LibraryActions.createDeck(courseId: courseId, name: name.trimmingCharacters(in: .whitespaces), db: $0) }
        return id
    }

    func renameDeck(_ deckId: String, to name: String) {
        change { try LibraryActions.renameDeck(deckId, name: name.trimmingCharacters(in: .whitespaces), db: $0) }
    }

    func deckCardCount(_ deckId: String) -> Int {
        (try? database.queue.read { try LibraryActions.deckCardCount(deckId, db: $0) }) ?? 0
    }

    func deleteDeck(_ deckId: String, movingCardsTo target: String?) {
        change { try LibraryActions.deleteDeck(deckId, migrateCardsTo: target, db: $0) }
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
            try DeckOverviewReader.read(deckIds: deckIds, db: db, cache: diagramCache)
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

    /// The card AI job for each course ("" for library-wide ones).
    private(set) var cardJobs: [String: CardAIJob] = [:]

    func cardJob(forCourse courseId: String?) -> CardAIJob? { cardJobs[courseId ?? ""] }

    func dismissCardJob(forCourse courseId: String?) { cardJobs[courseId ?? ""] = nil }

    /// One card AI job at a time per course.
    func startCardJob(_ headline: String, courseId: String?,
                      _ work: @escaping (any CardGenerator, GRASPDatabase) async -> String) {
        guard cardJob(forCourse: courseId).map(\.isFinished) ?? true else { return }
        let job = CardAIJob(headline: headline)
        cardJobs[courseId ?? ""] = job
        job.run(library: self, work)
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

}

/// A row reduction ready to draw: `states[0]` is the starting matrix and
/// `steps[i]` turns `states[i]` into `states[i + 1]`.
struct RowReductionSteps {
    let states: [RationalMatrix]
    let steps: [RowOperation]
    let fromNote: Bool
}
