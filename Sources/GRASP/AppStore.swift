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
        let generator = await CardGenerators.select()
        guard await generator.isAvailable else { return 0 }

        let draftsByMaterial: [String: [Card]]
        do {
            let cardIds = try await database.queue.read { db in
                try DeckCard.filter(Column("deckId") == deckId).fetchAll(db).map(\.cardId)
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

    func reload() {
        do {
            try database.queue.read { db in
                semesters = try Semester.order(Column("sortKey")).fetchAll(db)
                let courses = try Course
                    .filter(Column("isArchived") == false)
                    .order(Column("sortIndex"), Column("name"))
                    .fetchAll(db)
                coursesBySemester = Dictionary(grouping: courses, by: \.semesterId)

                let decks = try Deck.filter(Column("deletedAt") == nil).fetchAll(db)
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
    }

    func courses(inSemester semesterId: String?) -> [Course] {
        coursesBySemester[semesterId] ?? []
    }

    /// Courses with no vault folder and no semester link -- manually added
    /// current-semester shells live here until they get real material.
    var unfiledCourses: [Course] {
        (coursesBySemester[nil] ?? []).filter { $0.folderPath == nil }
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
        try database.queue.read { db in
            let cardIds = try DeckCard
                .filter(Column("deckId") == deckId)
                .order(Column("sortIndex"))
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

    /// Bulk-promotes every draft card in a deck to active, so a deck the
    /// parser filled with good pairs can be studied without clicking
    /// through each card one at a time.
    func approveAllDrafts(inDeck deckId: String) throws {
        try database.queue.write { db in
            let cardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(db).map(\.cardId)
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
        try database.queue.read { db in
            let cardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(db).map(\.cardId)
            guard !cardIds.isEmpty else { return [] }
            var cards = try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .filter(Column("status") == CardStatus.active.rawValue)
                .filter(Column("due") <= now)
                .order(Column("due"))
                .fetchAll(db)

            if let deck = try Deck.fetchOne(db, key: deckId),
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
            if let materialId = card.materialId,
               let material = try Material.fetchOne(db, key: materialId),
               let exam = try Self.nearestUpcomingExam(forCourseId: material.courseId, now: now, db: db) {
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

    /// Builds one Learn round for a deck: every active card not yet
    /// mastered, least-recently-seen first, escalating question type per
    /// card via `LearnEngine`.
    func learnRound(deckId: String) throws -> [LearnEngine.RoundQuestion] {
        try database.queue.read { db in
            let cardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(db).map(\.cardId)
            guard !cardIds.isEmpty else { return [] }
            let cards = try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .filter(Column("status") == CardStatus.active.rawValue)
                .fetchAll(db)
            let states = try LearnState
                .filter(cardIds.contains(Column("cardId")))
                .fetchAll(db)
            let stateByCard = Dictionary(uniqueKeysWithValues: states.map { ($0.cardId, $0) })

            let candidates = cards
                .map { card -> LearnEngine.Candidate in
                    let state = stateByCard[card.id]
                    let level = LearnEngine.Level(rawValue: state?.level ?? 0) ?? .new
                    return LearnEngine.Candidate(cardId: card.id, front: card.front, back: card.back, level: level)
                }
                .sorted { a, b in
                    let seenA = stateByCard[a.cardId]?.lastSeenAt ?? .distantPast
                    let seenB = stateByCard[b.cardId]?.lastSeenAt ?? .distantPast
                    return seenA < seenB
                }

            var rng = SystemRandomNumberGenerator()
            return LearnEngine.buildRound(from: candidates, using: &rng)
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
    }

    /// Starts a test: builds questions from every active card in the deck,
    /// writes the `testAttempt` and one `testItem` row per question up
    /// front (answers filled in as the user submits them), and returns the
    /// attempt id alongside the in-memory questions the UI drives from.
    func startTest(deckId: String, config: TestBuilder.Config) throws -> (attemptId: String, questions: [LearnEngine.RoundQuestion]) {
        try database.queue.write { db in
            let cardIds = try DeckCard.filter(Column("deckId") == deckId).fetchAll(db).map(\.cardId)
            let cards = cardIds.isEmpty ? [] : try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .filter(Column("status") == CardStatus.active.rawValue)
                .fetchAll(db)
            var rng = SystemRandomNumberGenerator()
            let pool = cards.map { (cardId: $0.id, front: $0.front, back: $0.back) }
            let questions = TestBuilder.build(from: pool, config: config, using: &rng)

            let attempt = TestAttempt(deckId: deckId, configJSON: "{}", startedAt: Date())
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
    func courseDeletionImpact(_ courseId: String) throws -> (materials: Int, cards: Int, reviews: Int) {
        try database.queue.read { db in
            let materials = try Material.filter(Column("courseId") == courseId).fetchCount(db)
            let cards = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?)
                """, arguments: [courseId]) ?? 0
            let reviews = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM review WHERE cardId IN (
                    SELECT id FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?)
                )
                """, arguments: [courseId]) ?? 0
            return (materials, cards, reviews)
        }
    }

    /// Removes a course and everything derived from it. Notes in the vault
    /// are never touched -- this only clears what GRASP built from them,
    /// so a re-import of a vault-backed course brings it back.
    func deleteCourse(_ courseId: String) throws {
        try database.queue.write { db in
            // `card.materialId` is ON DELETE SET NULL, so cascading from
            // the course would strand its cards instead of removing them.
            // Delete those explicitly first; their reviews, learn state,
            // and deck membership cascade from the card rows.
            try db.execute(sql: """
                DELETE FROM card WHERE materialId IN (SELECT id FROM material WHERE courseId = ?)
                """, arguments: [courseId])
            _ = try Course.deleteOne(db, key: courseId)
        }
        reload()
    }

    func addManualCourse(name: String, code: String?) throws {
        try database.queue.write { db in
            let course = Course(semesterId: nil, name: name, code: code)
            try course.insert(db)
        }
        reload()
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
}
