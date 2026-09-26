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

    init() throws {
        let support = try Self.supportDirectory()
        var profiles = try ProfileStore.loadOrMigrate(supportDirectory: support)
        // No profile picker or sign-in yet: a fresh install gets one profile.
        if profiles.isEmpty {
            profiles = [Profile(name: "Me")]
            try ProfileStore.save(profiles, supportDirectory: support)
        }
        database = try GRASPDatabase(path: profiles[0].databaseURL(supportDirectory: support))
        reload()
        account = Account(database: database, profile: profiles[0], supportDirectory: support) { [weak self] in
            self?.reload()
        }
    }

    /// Where the library lives. `GRASP_SUPPORT_DIR` overrides it -- on a
    /// Mac, trying this app would otherwise open the real Mac app's
    /// library, which uses the same folder.
    static func supportDirectory() throws -> URL {
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
        }
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

    // MARK: - Figures

    /// The first row reduction in these decks' notes, walked step by step.
    func rowReduction(inDecks deckIds: [String]) -> RowReductionSteps? {
        try? database.queue.read { db in
            for material in try OverviewQueries.materials(forDecks: deckIds, db: db) {
                guard let note = try NoteText.fetchOne(db, key: material.id) else { continue }
                for text in [note.raw, note.reflowed] {
                    if let walk = NoteMatrices.walkthroughs(in: text).first {
                        let walked = walk.start.walk(walk.steps)
                        return RowReductionSteps(states: walked.states, steps: walked.steps,
                                                 fromNote: walk.stepsFromNote)
                    }
                }
            }
            return nil
        }
    }
}

/// A row reduction ready to draw: `states[0]` is the starting matrix and
/// `steps[i]` turns `states[i]` into `states[i + 1]`.
struct RowReductionSteps {
    let states: [RationalMatrix]
    let steps: [RowOperation]
    let fromNote: Bool
}
