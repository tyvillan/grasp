import Foundation
import GRDB
import GRASPCore

/// Study guides for the Mac and iPhone apps: thin wrappers over GRASPCore's
/// `StudyGuideActions`, which the Windows app shares.
extension AppStore {
    // MARK: - Scopes

    /// The course a scope belongs to.
    func courseId(of scope: DeckScope) -> String? {
        switch scope {
        case .deck(let id): return (try? deck(id))??.courseId
        case .course(let id): return id
        case .exam(let courseId, _): return courseId
        }
    }

    /// The decks a scope studies, re-derived on every call so a deck added
    /// to the course, or to an exam's guide, is picked up right away.
    func deckIds(in scope: DeckScope) -> [String] {
        switch scope {
        case .deck(let id): return [id]
        case .course(let id): return (try? decks(inCourse: id))?.map(\.id) ?? []
        case .exam(_, let examEventId): return examDeckIds(examEventId: examEventId)
        }
    }

    // MARK: - Reading

    func calendarEvent(_ id: String) -> CalendarEvent? {
        (try? database.queue.read { db in try CalendarEvent.fetchOne(db, key: id) }) ?? nil
    }

    /// Exams in a course with at least one study guide, from yesterday on,
    /// so a guide is still there the day of the exam.
    func guidedExams(courseId: String, now: Date = Date()) -> [CalendarEvent] {
        let since = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now)) ?? now
        return (try? database.queue.read { db in
            try StudyGuideActions.guidedExams(courseId: courseId, since: since, db: db)
        }) ?? []
    }

    func hasStudyGuide(examEventId: String) -> Bool {
        ((try? database.queue.read { db in
            try StudyGuide.filter(Column("examEventId") == examEventId).fetchCount(db)
        }) ?? 0) > 0
    }

    func examDeckIds(examEventId: String) -> [String] {
        (try? database.queue.read { db in
            try StudyGuideActions.examDeckIds(examEventId: examEventId, db: db)
        }) ?? []
    }

    func examPage(examEventId: String) -> StudyGuideActions.ExamPage? {
        try? database.queue.read { db in
            try StudyGuideActions.examPage(examEventId: examEventId, db: db)
        }
    }

    /// Every course's guides for the Study Guide page, past exams included.
    func studyGuideHub(now: Date = Date()) -> [StudyGuideActions.HubCourse] {
        (try? database.queue.read { db in try StudyGuideActions.hub(now: now, db: db) }) ?? []
    }

    /// A guide with no exam, as a page of its own.
    func practicePage(guideId: String) -> StudyGuideActions.ExamPage? {
        try? database.queue.read { db in try StudyGuideActions.practicePage(guideId: guideId, db: db) }
    }

    /// Exams and quizzes in these courses, soonest first, past ones last --
    /// what a new guide can be attached to.
    func examEvents(inCourses courseIds: [String], now: Date = Date()) -> [CalendarEvent] {
        guard !courseIds.isEmpty else { return [] }
        let kinds = CalendarEventKind.examLike.map(\.rawValue)
        let events = (try? database.queue.read { db in
            try CalendarEvent
                .filter(courseIds.contains(Column("courseId")))
                .filter(kinds.contains(Column("kind")))
                .order(Column("startsAt"))
                .fetchAll(db)
        }) ?? []
        let today = Calendar.current.startOfDay(for: now)
        return events.filter { $0.startsAt >= today } + events.filter { $0.startsAt < today }.reversed()
    }

    func studyGuides(inCourse courseId: String) -> [StudyGuide] {
        (try? database.queue.read { db in try StudyGuideActions.guides(forCourse: courseId, db: db) }) ?? []
    }

    /// The file a guide was imported from, when it's still on disk -- for
    /// the tables and figures its text can't carry.
    func fileURL(ofGuide guide: StudyGuide) -> URL? {
        guard let materialId = guide.materialId,
              let material = try? database.queue.read({ db in try Material.fetchOne(db, key: materialId) }),
              FileManager.default.fileExists(atPath: material.relativePath)
        else { return nil }
        return URL(fileURLWithPath: material.relativePath)
    }

    // MARK: - Writing

    /// Imports guide files into a course (they become guides, not cards,
    /// because of their names) and, when an exam is given, links every
    /// guide the import touched to it.
    @discardableResult
    func importStudyGuides(_ urls: [URL], intoCourse courseId: String,
                           examEventId: String? = nil) async -> ImportSummary {
        let before = Set(studyGuides(inCourse: courseId).map(\.id))
        // A folder of review material -- practice questions beside a review
        // sheet -- becomes one guide (see `ExamPack`); anything else in the
        // batch goes through the ordinary import.
        let packURLs = ExamPack.packFiles(in: urls) { $0.deletingPathExtension().lastPathComponent }
        var packSummary = ImportSummary()
        var remaining = urls
        if !packURLs.isEmpty {
            let files = packURLs.compactMap { url -> ExamPack.SourceFile? in
                let title = url.deletingPathExtension().lastPathComponent
                let pages: [String]?
                if url.pathExtension.lowercased() == "pdf" {
                    pages = PDFExtractor.extractPages(from: url)
                } else {
                    pages = (try? PlainTextReader.read(url)).map { [$0] }
                }
                return pages.map { ExamPack.SourceFile(title: title, pages: $0) }
            }
            if let document = ExamPack.build(files) {
                try? await database.queue.write { db in
                    try StudyGuideActions.importExamPack(courseId: courseId, examEventId: examEventId,
                                                         document: document, db: db)
                }
                packSummary.studyGuidesImported = 1
                packSummary.filesScanned = packURLs.count
                let packed = Set(packURLs)
                remaining = urls.filter { !packed.contains($0) }
                reload()
            }
        }
        var summary = remaining.isEmpty ? ImportSummary() : await importFiles(remaining, intoCourse: courseId)
        summary.studyGuidesImported += packSummary.studyGuidesImported
        summary.filesScanned += packSummary.filesScanned
        if let examEventId {
            let paths = Set(urls.map { $0.standardizedFileURL.path })
            try? await database.queue.write { db in
                for guide in try StudyGuideActions.guides(forCourse: courseId, db: db) {
                    guard let materialId = guide.materialId,
                          let material = try Material.fetchOne(db, key: materialId),
                          paths.contains(URL(fileURLWithPath: material.relativePath).standardizedFileURL.path)
                            || !before.contains(guide.id)
                    else { continue }
                    try StudyGuideActions.setExam(guideId: guide.id, examEventId: examEventId, db: db)
                }
            }
            reload()
        }
        return summary
    }

    /// Reads again any guide an older parser read, from its file, so a
    /// parser fix reaches guides already imported. Quiet: runs at launch,
    /// keeps each guide's exam and hand-picked decks.
    func refreshStaleStudyGuides() async {
        guard let stale = try? await database.queue.read({ db in try StudyGuideActions.staleGuideFiles(db: db) })
        else { return }
        let byCourse = Dictionary(grouping: stale.filter { FileManager.default.fileExists(atPath: $0.path) },
                                  by: \.courseId)
        for (courseId, files) in byCourse {
            await importStudyGuides(files.map { URL(fileURLWithPath: $0.path) }, intoCourse: courseId)
        }
    }

    /// Folds the same guide imported twice into one. Quiet and cheap, so it
    /// runs at every launch; returns how many extra copies it removed.
    @discardableResult
    func mergeDuplicateStudyGuides() -> Int {
        let removed = (try? database.queue.write { db in try StudyGuideActions.mergeDuplicateGuides(db: db) }) ?? 0
        if removed > 0 { reload() }
        return removed
    }

    // MARK: - Writing practice guides

    static let studyGuideJobKey = "studyGuides"

    func dismissStudyGuideRun() { lastStudyGuideRun = nil }

    /// Writes practice guides from these decks in the background, with the
    /// usual progress strip and Stop button. Returns false when one is
    /// already running.
    @discardableResult
    func generateStudyGuides(courseIds: [String], deckIds: [String], problemsPerDeck: Int,
                             examEventId: String?) -> Bool {
        lastStudyGuideRun = nil
        let run = AIActivity(headline: "Writing practice guide", units: 1, purpose: "study guide")
        return runAIJob(Self.studyGuideJobKey, activity: run) { [weak self] run in
            guard let self else { return }
            let generator = await CardGenerators.select()
            let outcome: StudyGuideBuilder.Outcome?
            var failure: String?
            do {
                outcome = try await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                    try await StudyGuideBuilder.generate(
                        courseIds: courseIds, deckIds: deckIds, problemsPerDeck: problemsPerDeck,
                        examEventId: examEventId, using: generator, database: self.database
                    )
                }
            } catch {
                outcome = nil
                failure = "Couldn't save the guide: \(error.localizedDescription)"
            }
            if failure == nil, outcome?.guideIds.isEmpty ?? true, !run.stopRequested {
                failure = "The model didn't write anything usable"
                    + (CloudUsage.shared.lastTransportError.map { ". \($0)" } ?? ". Settings → AI shows which model is in use.")
            }
            self.lastStudyGuideRun = StudyGuideRunResult(
                guideIds: outcome?.guideIds ?? [], skippedDecks: outcome?.skippedDecks ?? [],
                wasStopped: run.stopRequested, failure: failure
            )
            self.reload()
        }
    }

    func setGuideExam(guideId: String, examEventId: String?) {
        try? database.queue.write { db in
            try StudyGuideActions.setExam(guideId: guideId, examEventId: examEventId, db: db)
        }
        reload()
    }

    func setGuideDecks(guideId: String, partIndex: Int, deckIds: [String]) {
        try? database.queue.write { db in
            try StudyGuideActions.setDecks(guideId: guideId, partIndex: partIndex, deckIds: deckIds, db: db)
        }
        reload()
    }

    func rateSkill(guideId: String, skillId: String, rating: SkillConfidence?) {
        try? database.queue.write { db in
            try StudyGuideActions.rate(guideId: guideId, skillId: skillId, rating: rating, db: db)
        }
        reload()
    }

    func deleteStudyGuide(_ guideId: String) {
        try? database.queue.write { db in try StudyGuideActions.delete(guideId: guideId, db: db) }
        reload()
    }

    // MARK: - Skill explanations

    func savedSkillExplanation(guideId: String, skillId: String) -> String? {
        (try? database.queue.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM skillExplanation WHERE guideId = ? AND skillId = ?",
                                arguments: [guideId, skillId])
        }) ?? nil
    }

    /// What a skill means: the saved explanation, else one written now by
    /// whichever model is set up (and saved). nil when none is available.
    func skillExplanation(guideId: String, skillId: String, skill: String, subject: String,
                          context: String) async -> String? {
        if let saved = savedSkillExplanation(guideId: guideId, skillId: skillId) { return saved }
        let generator = await CardGenerators.select()
        guard await generator.isAvailable,
              let text = await generator.explainSkill(skill, subject: subject, context: context) else { return nil }
        let model = generatorStatus
        try? await database.queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO skillExplanation (guideId, skillId, body, model, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [guideId, skillId, text, model, Date()])
        }
        return text
    }
}
