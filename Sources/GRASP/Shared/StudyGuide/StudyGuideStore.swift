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
        let summary = await importFiles(urls, intoCourse: courseId)
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
}
