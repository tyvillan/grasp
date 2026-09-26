import Foundation
import GRDB

/// Study guides' reads and writes, shared by every app. Each takes the
/// database connection its caller opened, like `Study` and `CardActions`.
public enum StudyGuideActions {
    // MARK: - Importing

    /// Parses a guide file's pages and saves it, linking it to an exam and
    /// its parts to decks. Called by the importer for a file
    /// `StudyGuideMatcher.isStudyGuide` recognizes. Re-importing the same
    /// file updates its guide in place: the exam link the student chose
    /// stays, and parts they re-mapped by hand keep their decks.
    @discardableResult
    public static func importGuide(material: Material, pages: [String], now: Date = Date(),
                                   db: Database) throws -> StudyGuide {
        let document = StudyGuideParser.parse(pages: pages)
        let body = try StudyGuideCoding.encode(document)

        var guide = try StudyGuide.filter(Column("materialId") == material.id).fetchOne(db)
            ?? StudyGuide(courseId: material.courseId, materialId: material.id,
                          title: material.title, bodyJSON: body, createdAt: now)
        guide.courseId = material.courseId
        guide.title = displayName(material: material, document: document)
        guide.bodyJSON = body
        guide.bodySchemaVersion = StudyGuideDocument.schemaVersion
        guide.sourceContentHash = material.contentHash
        guide.parser = "rules"
        guide.updatedAt = now
        if guide.examEventId == nil {
            guide.examEventId = try StudyGuideMatcher.exam(
                for: document, guideTitle: material.title, courseId: material.courseId, now: now, db: db
            )?.id
        }
        try guide.save(db)
        try rematchDecks(guideId: guide.id, document: document, courseId: guide.courseId, db: db)
        return guide
    }

    /// The filename, readably: "Microeconomics Exam 1 Review Professor"
    /// stays as it is, "2026-09-24_Exam-1_Study-Guide" loses its dashes.
    static func displayName(material: Material, document: StudyGuideDocument) -> String {
        material.title
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"(?<=\w)-(?=\w)"#, with: " ", options: .regularExpression)
    }

    /// Replaces the automatic part→deck rows, leaving any part the student
    /// mapped by hand alone.
    public static func rematchDecks(guideId: String, document: StudyGuideDocument, courseId: String,
                                    db: Database) throws {
        let manualParts = Set(try Int.fetchAll(db, sql:
            "SELECT DISTINCT partIndex FROM studyGuidePartDeck WHERE guideId = ? AND isManual = 1",
            arguments: [guideId]))
        try StudyGuidePartDeck
            .filter(Column("guideId") == guideId)
            .filter(Column("isManual") == false)
            .deleteAll(db)
        for (partIndex, deckIds) in try StudyGuideMatcher.decks(for: document, courseId: courseId, db: db)
        where !manualParts.contains(partIndex) {
            for deckId in deckIds {
                try StudyGuidePartDeck(guideId: guideId, partIndex: partIndex, deckId: deckId).insert(db)
            }
        }
    }

    // MARK: - Editing

    public static func setExam(guideId: String, examEventId: String?, now: Date = Date(),
                               db: Database) throws {
        guard var guide = try StudyGuide.fetchOne(db, key: guideId) else { return }
        guide.examEventId = examEventId
        guide.updatedAt = now
        try guide.save(db)
    }

    /// The student's own answer to "which lectures does this part cover?".
    /// Saved as manual, so a re-import keeps it. Clearing a part removes
    /// its rows; since there's no row left to mark manual, a later change
    /// to the guide file may match it again automatically.
    public static func setDecks(guideId: String, partIndex: Int, deckIds: [String], db: Database) throws {
        try StudyGuidePartDeck
            .filter(Column("guideId") == guideId)
            .filter(Column("partIndex") == partIndex)
            .deleteAll(db)
        for deckId in deckIds {
            try StudyGuidePartDeck(guideId: guideId, partIndex: partIndex, deckId: deckId, isManual: true).insert(db)
        }
    }

    public static func delete(guideId: String, db: Database) throws {
        _ = try StudyGuide.deleteOne(db, key: guideId)
    }

    public static func rate(guideId: String, skillId: String, rating: SkillConfidence?,
                            now: Date = Date(), db: Database) throws {
        if let rating {
            try SkillRating(guideId: guideId, skillId: skillId, rating: rating, ratedAt: now).save(db)
        } else {
            _ = try SkillRating.deleteOne(db, key: ["guideId": guideId, "skillId": skillId])
        }
    }

    // MARK: - Reading

    public static func guides(forCourse courseId: String, db: Database) throws -> [StudyGuide] {
        try StudyGuide
            .filter(Column("courseId") == courseId)
            .order(Column("createdAt"))
            .fetchAll(db)
    }

    /// Exams in a course that at least one guide prepares for, soonest
    /// first. Past exams are included from `since`, so a guide stays
    /// reachable on the day of the exam and just after.
    public static func guidedExams(courseId: String, since: Date, db: Database) throws -> [CalendarEvent] {
        try CalendarEvent.fetchAll(db, sql: """
            SELECT * FROM calendarEvent
            WHERE courseId = ? AND startsAt >= ?
              AND id IN (SELECT examEventId FROM studyGuide WHERE examEventId IS NOT NULL)
            ORDER BY startsAt
            """, arguments: [courseId, since])
    }

    /// Every deck any of the exam's guides maps a part to, in course order
    /// -- what "Study for this exam" studies.
    public static func examDeckIds(examEventId: String, db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT deck.id FROM deck
            WHERE deck.deletedAt IS NULL AND deck.id IN (
                SELECT deckId FROM studyGuidePartDeck
                WHERE guideId IN (SELECT id FROM studyGuide WHERE examEventId = ?))
            ORDER BY deck.sortIndex, deck.chapter, deck.name
            """, arguments: [examEventId])
    }

    // MARK: - The exam page

    /// One exam's guides read together: parts that two guides share are
    /// merged, so the professor's skills and traps sit next to the
    /// student's own definitions for the same part.
    public struct ExamPage: Sendable {
        public let exam: CalendarEvent
        public let guides: [StudyGuide]
        /// From whichever guide states them.
        public let questionCount: Int?
        public let format: [String]
        public let notes: [String]
        public let parts: [PagePart]
        /// Guides whose text gave no parts -- shown so they aren't silently
        /// missing.
        public let unreadGuides: [StudyGuide]

        public var deckIds: [String] {
            var seen = Set<String>()
            return parts.flatMap(\.deckIds).filter { seen.insert($0).inserted }
        }
    }

    public struct PagePart: Identifiable, Sendable {
        public var id: String { "\(number.map(String.init) ?? "")#\(title)" }
        public let number: Int?
        public let title: String
        public let questionCount: Int?
        /// Where each guide has this part, for editing its decks.
        public let sources: [Source]
        public let deckIds: [String]
        public let skills: [Skill]
        public let traps: [String]
        public let examples: [PageExample]
        public let terms: [StudyGuideDocument.Term]
        public let formulas: [String]
        public let remember: [String]
        public let notes: [String]

        public struct Source: Sendable, Hashable {
            public let guideId: String
            public let partIndex: Int
        }

        /// Share of the exam's questions, when both counts are known.
        public func weight(of total: Int?) -> Double? {
            guard let questionCount, let total, total > 0 else { return nil }
            return Double(questionCount) / Double(total)
        }
    }

    public struct Skill: Identifiable, Sendable {
        public var id: String { "\(guideId)#\(skillId)" }
        public let guideId: String
        public let skillId: String
        public let text: String
        public let rating: SkillConfidence?
    }

    public struct PageExample: Identifiable, Sendable {
        public let id: String
        public let guideId: String
        public let example: StudyGuideDocument.Example
    }

    public static func examPage(examEventId: String, db: Database) throws -> ExamPage? {
        guard let exam = try CalendarEvent.fetchOne(db, key: examEventId) else { return nil }
        let guides = try StudyGuide
            .filter(Column("examEventId") == examEventId)
            .order(Column("createdAt"))
            .fetchAll(db)
        let ids = guides.map(\.id)
        let partDecks = try StudyGuidePartDeck.filter(ids.contains(Column("guideId"))).fetchAll(db)
        let ratings = try SkillRating.filter(ids.contains(Column("guideId"))).fetchAll(db)
            .reduce(into: [String: SkillConfidence]()) { $0["\($1.guideId)#\($1.skillId)"] = $1.rating }

        var merged: [(part: StudyGuideDocument.Part, sources: [PagePart.Source])] = []
        var unread: [StudyGuide] = []
        var questionCount: Int?
        var format: [String] = []
        var notes: [String] = []
        // The guide that states the exam's shape (a professor's) goes first,
        // so its part titles and numbers are the ones shown.
        let documents = guides.compactMap { guide in guide.document().map { (guide, $0) } }
            .sorted { ($0.1.totalQuestions == nil ? 1 : 0) < ($1.1.totalQuestions == nil ? 1 : 0) }
        for (guide, document) in documents {
            if document.parts.isEmpty { unread.append(guide); continue }
            questionCount = questionCount ?? document.totalQuestions
            for item in document.format where !format.contains(item) { format.append(item) }
            notes += document.notes
            for (index, part) in document.parts.enumerated() {
                let source = PagePart.Source(guideId: guide.id, partIndex: index)
                if let at = merged.firstIndex(where: { StudyGuideMatcher.samePart($0.part, part) }) {
                    merged[at].part = combine(merged[at].part, part)
                    merged[at].sources.append(source)
                } else {
                    merged.append((part, [source]))
                }
            }
        }
        unread += guides.filter { $0.document() == nil }

        let parts = merged.map { entry -> PagePart in
            let sources = Set(entry.sources)
            var seen = Set<String>()
            let deckIds = partDecks
                .filter { sources.contains(.init(guideId: $0.guideId, partIndex: $0.partIndex)) }
                .map(\.deckId)
                .filter { seen.insert($0).inserted }
            var skills: [Skill] = []
            var examples: [PageExample] = []
            for source in entry.sources {
                guard let document = documents.first(where: { $0.0.id == source.guideId })?.1 else { continue }
                let part = document.parts[source.partIndex]
                for (i, text) in part.skills.enumerated() {
                    let skillId = StudyGuideDocument.skillId(part: source.partIndex, skill: i)
                    skills.append(Skill(guideId: source.guideId, skillId: skillId, text: text,
                                        rating: ratings["\(source.guideId)#\(skillId)"]))
                }
                for (i, example) in part.examples.enumerated() {
                    examples.append(PageExample(id: "\(source.guideId)#p\(source.partIndex)e\(i)",
                                                guideId: source.guideId, example: example))
                }
            }
            let part = entry.part
            return PagePart(
                number: part.number, title: part.title, questionCount: part.questionCount,
                sources: entry.sources, deckIds: deckIds, skills: skills, traps: part.traps,
                examples: examples, terms: part.terms, formulas: part.formulas,
                remember: part.remember, notes: part.notes
            )
        }
        .sorted { ($0.number ?? .max) < ($1.number ?? .max) }

        return ExamPage(exam: exam, guides: guides, questionCount: questionCount, format: format,
                        notes: notes, parts: parts, unreadGuides: unread)
    }

    /// Text fields merged; the first guide's title, number and count win.
    static func combine(_ a: StudyGuideDocument.Part, _ b: StudyGuideDocument.Part) -> StudyGuideDocument.Part {
        var part = a
        part.number = a.number ?? b.number
        part.questionCount = a.questionCount ?? b.questionCount
        part.traps += b.traps
        part.terms += b.terms
        part.formulas += b.formulas
        part.remember += b.remember
        part.notes += b.notes
        return part
    }
}
