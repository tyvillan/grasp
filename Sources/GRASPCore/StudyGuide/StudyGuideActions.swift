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

        // A copy of a guide already in the library (the same file imported
        // again from another folder, e.g. moved from the Desktop into the
        // vault) takes over that guide, so its exam link, skill ratings and
        // hand-picked decks carry over instead of a second guide appearing.
        var guide = try StudyGuide.filter(Column("materialId") == material.id).fetchOne(db)
            ?? existingCopy(of: material, db: db)
            ?? StudyGuide(courseId: material.courseId, materialId: material.id,
                          title: material.title, bodyJSON: body, createdAt: now)
        guide.materialId = material.id
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

    /// A title reduced to what identifies it: case, punctuation and spacing
    /// dropped, so "ECO 2023 - Exam 1 Study Guide" and
    /// "eco-2023_exam-1_study-guide" are the same guide.
    static func identity(ofTitle title: String) -> String {
        title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// An imported guide in the same course that this file duplicates: the
    /// same content, or the same title, from a different file.
    static func existingCopy(of material: Material, db: Database) throws -> StudyGuide? {
        let identity = identity(ofTitle: material.title)
        return try StudyGuide
            .filter(Column("courseId") == material.courseId)
            .filter(Column("materialId") != nil)
            .filter(Column("materialId") != material.id)
            .order(Column("createdAt"))
            .fetchAll(db)
            .first { guide in
                if let hash = material.contentHash, guide.sourceContentHash == hash { return true }
                return Self.identity(ofTitle: guide.title) == identity
            }
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
        Deck.ordered(try Deck.fetchAll(db, sql: """
            SELECT deck.* FROM deck
            WHERE deck.deletedAt IS NULL AND deck.id IN (
                SELECT deckId FROM studyGuidePartDeck
                WHERE guideId IN (SELECT id FROM studyGuide WHERE examEventId = ?))
            """, arguments: [examEventId])).map(\.id)
    }

    // MARK: - Duplicates

    /// Folds guides that are the same guide imported twice (same course,
    /// same title or same content) into one. The survivor is the copy whose
    /// file is still on disk, else the older one; it takes the exam link,
    /// the skill ratings and the hand-picked decks the others had, when its
    /// parts line up with theirs. Generated guides are never merged: they
    /// have no file, and two practice sets are two sets.
    ///
    /// Idempotent and cheap, so the app runs it on every launch.
    @discardableResult
    public static func mergeDuplicateGuides(db: Database,
                                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws -> Int {
        let imported = try StudyGuide.filter(Column("materialId") != nil).order(Column("createdAt")).fetchAll(db)
        var groups: [String: [StudyGuide]] = [:]
        for guide in imported {
            groups["\(guide.courseId)#\(identity(ofTitle: guide.title))", default: []].append(guide)
        }
        var removed = 0
        for (_, guides) in groups where guides.count > 1 {
            func hasFile(_ guide: StudyGuide) -> Bool {
                guard let id = guide.materialId, let material = try? Material.fetchOne(db, key: id) else { return false }
                return material.deletedAt == nil && fileExists(material.relativePath)
            }
            let survivor = guides.first(where: hasFile) ?? guides[0]
            for loser in guides where loser.id != survivor.id {
                try absorb(loser, into: survivor, db: db)
                _ = try StudyGuide.deleteOne(db, key: loser.id)
                removed += 1
            }
        }
        return removed
    }

    private static func absorb(_ loser: StudyGuide, into survivor: StudyGuide, db: Database) throws {
        if survivor.examEventId == nil, let exam = loser.examEventId {
            try setExam(guideId: survivor.id, examEventId: exam, db: db)
        }
        guard let from = loser.document(), let to = survivor.document() else { return }

        // Ratings are addressed by position ("p2s1"), so one carries over
        // only where the survivor has the very same skill at that spot.
        let have = Set(try SkillRating.filter(Column("guideId") == survivor.id).fetchAll(db).map(\.skillId))
        for rating in try SkillRating.filter(Column("guideId") == loser.id).fetchAll(db) where !have.contains(rating.skillId) {
            guard let (part, skill) = position(of: rating.skillId),
                  from.parts.indices.contains(part), to.parts.indices.contains(part),
                  from.parts[part].skills.indices.contains(skill), to.parts[part].skills.indices.contains(skill),
                  from.parts[part].skills[skill] == to.parts[part].skills[skill]
            else { continue }
            try SkillRating(guideId: survivor.id, skillId: rating.skillId, rating: rating.rating,
                            ratedAt: rating.ratedAt).save(db)
        }

        // Decks the student picked by hand, for parts that line up by title.
        let survivorManual = Set(try StudyGuidePartDeck
            .filter(Column("guideId") == survivor.id).filter(Column("isManual") == true).fetchAll(db).map(\.partIndex))
        for row in try StudyGuidePartDeck.filter(Column("guideId") == loser.id).filter(Column("isManual") == true).fetchAll(db)
        where !survivorManual.contains(row.partIndex)
            && from.parts.indices.contains(row.partIndex) && to.parts.indices.contains(row.partIndex)
            && from.parts[row.partIndex].title == to.parts[row.partIndex].title {
            try StudyGuidePartDeck.filter(Column("guideId") == survivor.id)
                .filter(Column("partIndex") == row.partIndex).filter(Column("isManual") == false).deleteAll(db)
            try StudyGuidePartDeck(guideId: survivor.id, partIndex: row.partIndex, deckId: row.deckId,
                                   isManual: true).save(db)
        }
    }

    /// "p2s1" -> (2, 1).
    static func position(of skillId: String) -> (part: Int, skill: Int)? {
        let pieces = skillId.dropFirst().split(separator: "s")
        guard skillId.hasPrefix("p"), pieces.count == 2, let part = Int(pieces[0]), let skill = Int(pieces[1])
        else { return nil }
        return (part, skill)
    }

    // MARK: - The study guide hub

    public struct HubExam: Identifiable, Sendable {
        public var id: String { exam.id }
        public let exam: CalendarEvent
        public let guides: [StudyGuide]
        public let isPast: Bool
    }

    public struct HubCourse: Identifiable, Sendable {
        public var id: String { course.id }
        public let course: Course
        /// Upcoming exams soonest first, then past ones, most recent first.
        public let exams: [HubExam]
        /// Guides that prepare for no exam: practice sets, and imports
        /// that matched none.
        public let practiceSets: [StudyGuide]
    }

    /// Every course's guides, past exams included -- the one place a guide
    /// stays reachable once its exam is behind you.
    public static func hub(now: Date = Date(), db: Database) throws -> [HubCourse] {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let courses = try Course.filter(Column("isArchived") == false).order(Column("sortIndex"), Column("name")).fetchAll(db)
        var result: [HubCourse] = []
        for course in courses {
            let guides = try guides(forCourse: course.id, db: db)
            guard !guides.isEmpty else { continue }
            var byExam: [String: [StudyGuide]] = [:]
            var loose: [StudyGuide] = []
            for guide in guides {
                if let id = guide.examEventId { byExam[id, default: []].append(guide) } else { loose.append(guide) }
            }
            var exams: [HubExam] = []
            for (examId, examGuides) in byExam {
                guard let exam = try CalendarEvent.fetchOne(db, key: examId) else { loose += examGuides; continue }
                exams.append(HubExam(exam: exam, guides: examGuides, isPast: exam.startsAt < startOfToday))
            }
            exams.sort { a, b in
                if a.isPast != b.isPast { return !a.isPast }
                return a.isPast ? a.exam.startsAt > b.exam.startsAt : a.exam.startsAt < b.exam.startsAt
            }
            result.append(HubCourse(course: course, exams: exams,
                                    practiceSets: loose.sorted { $0.createdAt > $1.createdAt }))
        }
        return result
    }

    /// A guide with no exam, read as a page of its own. The "exam" on it is
    /// a stand-in (never saved) so the same page and downloads work.
    public static func practicePage(guideId: String, db: Database) throws -> ExamPage? {
        guard let guide = try StudyGuide.fetchOne(db, key: guideId) else { return nil }
        let stand = CalendarEvent(courseId: guide.courseId, kind: .study, title: guide.title,
                                  startsAt: guide.createdAt, isAllDay: true)
        return try page(exam: stand, guides: [guide], isPracticeSet: true, db: db)
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
        /// A guide with no exam: `exam` is a stand-in carrying its title
        /// and creation date.
        public let isPracticeSet: Bool

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
        return try page(exam: exam, guides: guides, isPracticeSet: false, db: db)
    }

    static func page(exam: CalendarEvent, guides: [StudyGuide], isPracticeSet: Bool,
                     db: Database) throws -> ExamPage {
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
                    let item = PageExample(id: "\(source.guideId)#p\(source.partIndex)e\(i)",
                                           guideId: source.guideId, example: example)
                    // A student's guide often reworks the professor's own
                    // examples: show each problem once, in the version
                    // that's easier to use, where the first one stood.
                    if let at = examples.firstIndex(where: {
                        $0.guideId != source.guideId && isSameProblem($0.example, example)
                    }) {
                        if preference(example) > preference(examples[at].example) { examples[at] = item }
                    } else {
                        examples.append(item)
                    }
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
                        notes: notes, parts: parts, unreadGuides: unread, isPracticeSet: isPracticeSet)
    }

    /// Two guides' versions of one problem: most of the same numbers (the
    /// wedding's $45, $100 and $70), or, for one without many numbers, most
    /// of the same words (the driving-age claims). Different problems on one
    /// topic share a few numbers ($3 smoothies) but not most of them.
    static func isSameProblem(_ a: StudyGuideDocument.Example, _ b: StudyGuideDocument.Example) -> Bool {
        func text(_ e: StudyGuideDocument.Example) -> String {
            ([e.question] + e.steps + [e.answer ?? ""]).joined(separator: " ")
        }
        func numbers(_ text: String) -> Set<String> {
            let regex = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#)
            let ns = text as NSString
            return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range).replacingOccurrences(of: ",", with: "") })
        }
        func jaccard(_ x: Set<String>, _ y: Set<String>) -> Double {
            let union = x.union(y).count
            return union == 0 ? 0 : Double(x.intersection(y).count) / Double(union)
        }
        let (ta, tb) = (text(a), text(b))
        let (na, nb) = (numbers(ta), numbers(tb))
        if na.count >= 3, nb.count >= 3, jaccard(na, nb) >= 0.6 { return true }
        return jaccard(StudyGuideParser.contentWords(ta), StudyGuideParser.contentWords(tb)) >= 0.35
    }

    /// Which of two versions to keep: one you can do from the text alone,
    /// then one with an answer to check, then one with worked steps.
    static func preference(_ e: StudyGuideDocument.Example) -> Int {
        (e.usesFigure == true ? 0 : 4) + (e.isPractice ? 2 : 0) + (e.steps.isEmpty ? 0 : 1)
    }

    /// Whether a guide was read by an older parser than this one, so its
    /// file should be read again even though it hasn't changed.
    public static func isStale(materialId: String, db: Database) throws -> Bool {
        try StudyGuide
            .filter(Column("materialId") == materialId)
            .filter(Column("bodySchemaVersion") < StudyGuideDocument.schemaVersion)
            .fetchCount(db) > 0
    }

    /// Guides read by an older parser whose files are still where they were
    /// imported from: what a launch reads again.
    public static func staleGuideFiles(db: Database) throws -> [(courseId: String, path: String)] {
        let guides = try StudyGuide
            .filter(Column("bodySchemaVersion") < StudyGuideDocument.schemaVersion)
            .fetchAll(db)
        return try guides.compactMap { guide in
            guard let materialId = guide.materialId,
                  let material = try Material.fetchOne(db, key: materialId), material.deletedAt == nil
            else { return nil }
            return (guide.courseId, material.relativePath)
        }
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
