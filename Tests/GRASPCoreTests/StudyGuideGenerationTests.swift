import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// Writes a recognisable part for every deck it's asked about, except the
/// decks named in `failing`, and remembers what it was handed.
private final class RecordingGenerator: CardGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(deck: String, course: String, notes: String, terms: [String], problems: Int)] = []
    let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    var calls: [(deck: String, course: String, notes: String, terms: [String], problems: Int)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    private func record(_ call: (deck: String, course: String, notes: String, terms: [String], problems: Int)) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
    }

    var isAvailable: Bool { get async { true } }
    func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
    func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
    func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
    func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
    func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
        ContextValidation(.valid)
    }
    func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                          includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
    func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                         sectionHeadings: [String]) async -> [GeneratedFigure] { [] }

    func generateStudyGuidePart(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String], problemCount: Int
    ) async -> GeneratedGuidePart {
        record((deckName, courseName, noteContext, cardTerms, problemCount))
        guard !failing.contains(deckName) else { return .empty }
        return GeneratedGuidePart(part: StudyGuideDocument.Part(
            title: "model's own title", skills: ["Explain \(deckName)"],
            examples: [.init(label: "Practice 1", question: "Q about \(deckName)", steps: ["Step"], answer: "A")]
        ))
    }
}

@Suite("StudyGuideGeneration")
struct StudyGuideGenerationTests {
    // MARK: - Parsing

    @Test("a model's messy answer is read: fences, a numeric answer, steps as one string")
    func parsesMessyAnswer() throws {
        let raw = """
        Here is the guide:
        ```json
        {"skills": ["Compute elasticity", "  "],
         "problems": [
           {"question": "Price rises from $4 to $5 and quantity falls from 100 to 80. Find the elasticity.",
            "steps": "Percent change in quantity is -20%\\nPercent change in price is 25%", "answer": 0.8},
           {"question": "No answer given here", "steps": ["x"]},
           {"question": "", "answer": "orphan"}],
         "questions": [{"question": "Which is elastic? A) a B) b", "answer": "A"}],
         "terms": [{"term": "Elasticity", "definition": "Responsiveness of quantity to price."},
                   {"term": "Half a term"}],
         "traps": "Forgetting the sign"}
        ```
        """
        let part = try #require(OllamaGenerator.parseStudyGuidePart(raw, title: "Lecture 4", problemLimit: 5))
        #expect(part.title == "Lecture 4")
        #expect(part.skills == ["Compute elasticity"])
        #expect(part.examples.count == 2)
        #expect(part.examples[0].label == "Practice 1")
        #expect(part.examples[0].answer == "0.8")
        #expect(part.examples[0].steps.count == 2)
        #expect(part.examples[0].isPractice)
        #expect(part.examples[1].label == "Sample question 1")
        #expect(part.terms == [.init(term: "Elasticity", definition: "Responsiveness of quantity to price.")])
        #expect(part.traps == ["Forgetting the sign"])
    }

    @Test("practice problems beyond the requested number are dropped")
    func honoursProblemLimit() throws {
        let problems = (1...6).map { #"{"question": "Q\#($0)", "steps": [], "answer": "A\#($0)"}"# }.joined(separator: ",")
        let part = try #require(OllamaGenerator.parseStudyGuidePart(
            #"{"skills": [], "problems": [\#(problems)]}"#, title: "T", problemLimit: 3))
        #expect(part.examples.map(\.question) == ["Q1", "Q2", "Q3"])
    }

    @Test("garbage and empty answers give no part")
    func rejectsNothingUsable() {
        #expect(OllamaGenerator.parseStudyGuidePart("I can't help with that.", title: "T", problemLimit: 3) == nil)
        #expect(OllamaGenerator.parseStudyGuidePart(#"{"skills": [], "problems": [], "questions": []}"#,
                                                    title: "T", problemLimit: 3) == nil)
    }

    @Test("a lettered answer whose question has no options loses the letter; one with options keeps it")
    func dropsDanglingChoiceLetter() {
        let f = OllamaGenerator.withoutDanglingChoice
        #expect(f("B - producing inside the frontier.", "Which describes waste?") == "producing inside the frontier.")
        #expect(f("B) The transfer strand.", "Which strand was removed?") == "The transfer strand.")
        #expect(f("B - producing inside the frontier.", "Which? A) a B) producing inside the frontier") == "B - producing inside the frontier.")
        // An ordinary answer that merely starts with the word "A" is left alone.
        #expect(f("A cost already incurred.", "What is a sunk cost?") == "A cost already incurred.")
        #expect(f("B", "Which?") == "B")
    }

    @Test("the prompt names the course and deck, the count, the notes and the existing card terms")
    func promptContents() {
        let prompt = OllamaGenerator.studyGuidePartPrompt(
            deckName: "Lecture 4", courseName: "Microeconomic Principles",
            noteContext: "Elasticity measures responsiveness.", cardTerms: ["Elasticity", "Substitute"], problemCount: 5
        )
        #expect(prompt.contains("Microeconomic Principles"))
        #expect(prompt.contains("Lecture 4"))
        #expect(prompt.contains("exactly 5 practice problems"))
        #expect(prompt.contains("Elasticity measures responsiveness."))
        #expect(prompt.contains("Elasticity; Substitute"))
        #expect(prompt.contains("Never add outside facts"))
    }

    // MARK: - Building

    /// A course with decks "Lecture 10", "Lecture 2" (both with notes) and
    /// "Empty" (no notes), plus an exam.
    private func makeLibrary() async throws -> (db: GRASPDatabase, courseId: String, deckIds: [String: String], examId: String) {
        let db = try GRASPDatabase.inMemory()
        let made = try await db.queue.write { conn -> (String, [String: String], String) in
            let course = Course(semesterId: nil, name: "Microeconomic Principles")
            try course.insert(conn)
            var ids: [String: String] = [:]
            for name in ["Lecture 10", "Lecture 2", "Empty"] {
                let deck = Deck(courseId: course.id, name: name, chapter: name)
                try deck.insert(conn)
                ids[name] = deck.id
                guard name != "Empty" else { continue }
                let material = Material(courseId: course.id, relativePath: "/v/\(name).md", kind: .markdown,
                                        contentHash: name, title: name)
                try material.insert(conn)
                let text = "Notes for \(name). " + Array(repeating: "supply and demand", count: 40).joined(separator: " ")
                try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 123, hasMath: false).insert(conn)
                let card = Card(materialId: material.id, front: "Term of \(name)", back: "B", origin: .parser, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            }
            let exam = CalendarEvent(courseId: course.id, kind: .exam, title: "Midterm 1", startsAt: Date())
            try exam.insert(conn)
            return (course.id, ids, exam.id)
        }
        return (db, made.0, made.1, made.2)
    }

    @Test("one guide per course, one part per deck in natural order, linked to its decks and the chosen exam")
    func buildsGuide() async throws {
        let (db, courseId, ids, examId) = try await makeLibrary()
        let generator = RecordingGenerator()
        let outcome = try await StudyGuideBuilder.generate(
            courseIds: [courseId], deckIds: Array(ids.values), problemsPerDeck: 4, examEventId: examId,
            using: generator, database: db
        )
        #expect(outcome.guideIds.count == 1)
        #expect(outcome.partsWritten == 2)
        #expect(outcome.skippedDecks == ["Empty"])

        try await db.queue.read { conn in
            let guide = try #require(try StudyGuide.fetchOne(conn, key: outcome.guideIds[0]))
            #expect(guide.examEventId == examId)
            #expect(guide.materialId == nil)
            #expect(guide.parser.hasPrefix("ai:"))
            #expect(guide.title.contains("Microeconomic Principles practice set"))
            let document = try #require(guide.document())
            // Lecture 2 before Lecture 10, titled by the deck, numbered from 1.
            #expect(document.parts.map(\.title) == ["Lecture 2", "Lecture 10"])
            #expect(document.parts.map(\.number) == [1, 2])
            let links = try StudyGuidePartDeck.filter(Column("guideId") == guide.id).order(Column("partIndex")).fetchAll(conn)
            #expect(links.map(\.deckId) == [ids["Lecture 2"]!, ids["Lecture 10"]!])
            #expect(links.allSatisfy { !$0.isManual })
        }
        #expect(generator.calls.allSatisfy { $0.problems == 4 && $0.course == "Microeconomic Principles" })
        let lecture2 = try #require(generator.calls.first { $0.deck == "Lecture 2" })
        #expect(lecture2.notes.contains("Notes for Lecture 2."))
        #expect(lecture2.terms == ["Term of Lecture 2"])
    }

    @Test("an exam is attached only to the guide of its own course")
    func examAttachesToItsOwnCourseOnly() async throws {
        let (db, courseA, idsA, examId) = try await makeLibrary()
        let (courseB, deckB) = try await db.queue.write { conn -> (String, String) in
            let course = Course(semesterId: nil, name: "Matrix Theory")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Lecture 1", chapter: "Lecture 1")
            try deck.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/v/m.md", kind: .markdown, contentHash: "m", title: "m")
            try material.insert(conn)
            let text = Array(repeating: "row reduction", count: 40).joined(separator: " ")
            try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 80, hasMath: false).insert(conn)
            let card = Card(materialId: material.id, front: "Pivot", back: "B", origin: .parser, status: .active)
            try card.insert(conn)
            try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            return (course.id, deck.id)
        }
        let outcome = try await StudyGuideBuilder.generate(
            courseIds: [courseA, courseB], deckIds: Array(idsA.values) + [deckB], problemsPerDeck: 3,
            examEventId: examId, using: RecordingGenerator(), database: db
        )
        #expect(outcome.guideIds.count == 2)
        let byCourse = try await db.queue.read { conn in
            try StudyGuide.fetchAll(conn).reduce(into: [String: String?]()) { $0[$1.courseId] = $1.examEventId }
        }
        #expect(byCourse[courseA] == .some(examId))
        #expect(byCourse[courseB] == .some(nil))
    }

    @Test("with no exam the guide is a practice set, and a deck the model failed on is skipped")
    func practiceSetAndFailures() async throws {
        let (db, courseId, ids, _) = try await makeLibrary()
        let outcome = try await StudyGuideBuilder.generate(
            courseIds: [courseId], deckIds: Array(ids.values), problemsPerDeck: 3, examEventId: nil,
            using: RecordingGenerator(failing: ["Lecture 10"]), database: db
        )
        #expect(outcome.partsWritten == 1)
        #expect(Set(outcome.skippedDecks) == ["Lecture 10", "Empty"])
        let id = try #require(outcome.guideIds.first)
        try await db.queue.read { conn in
            let saved = try #require(try StudyGuide.fetchOne(conn, key: id))
            #expect(saved.examEventId == nil)
            let page = try #require(try StudyGuideActions.practicePage(guideId: id, db: conn))
            #expect(page.isPracticeSet)
            #expect(page.parts.map(\.title) == ["Lecture 2"])
            #expect(page.parts[0].examples.count == 1)
        }
    }

    @Test("when the model writes nothing for any deck, no guide is saved")
    func noGuideWhenEverythingFails() async throws {
        let (db, courseId, ids, _) = try await makeLibrary()
        let outcome = try await StudyGuideBuilder.generate(
            courseIds: [courseId], deckIds: Array(ids.values), problemsPerDeck: 3, examEventId: nil,
            using: RecordingGenerator(failing: ["Lecture 10", "Lecture 2"]), database: db
        )
        #expect(outcome.guideIds.isEmpty)
        let saved = try await db.queue.read { try StudyGuide.fetchCount($0) }
        #expect(saved == 0)
    }

    // MARK: - Duplicates and the hub

    private func addGuide(_ db: Database, courseId: String, title: String, path: String, hash: String?,
                          examId: String?, skills: [String], created: Date) throws -> StudyGuide {
        let material = Material(courseId: courseId, relativePath: path, kind: .pdf, contentHash: hash, title: title)
        try material.insert(db)
        let document = StudyGuideDocument(parts: [.init(number: 1, title: "Part 1", skills: skills)])
        let guide = StudyGuide(courseId: courseId, examEventId: examId, materialId: material.id, title: title,
                               bodyJSON: try StudyGuideCoding.encode(document), sourceContentHash: hash,
                               createdAt: created, updatedAt: created)
        try guide.insert(db)
        return guide
    }

    @Test("the same guide imported twice becomes one: the copy with a file survives and keeps the older copy's ratings and exam")
    func mergesDuplicateGuides() async throws {
        let (db, courseId, _, examId) = try await makeLibrary()
        let ids = try await db.queue.write { conn -> (old: String, new: String) in
            let old = try self.addGuide(conn, courseId: courseId, title: "ECO 2023 - Exam 1 Study Guide",
                                        path: "/Desktop/guide.pdf", hash: "h1", examId: examId,
                                        skills: ["Find the equilibrium", "Compute surplus"], created: Date(timeIntervalSince1970: 100))
            let new = try self.addGuide(conn, courseId: courseId, title: "ECO 2023 - Exam 1 Study Guide",
                                        path: "/Vault/guide.pdf", hash: "h1", examId: nil,
                                        skills: ["Find the equilibrium", "Compute surplus"], created: Date(timeIntervalSince1970: 200))
            try SkillRating(guideId: old.id, skillId: "p0s1", rating: .shaky).insert(conn)
            // A rating whose skill is not the same text in the other copy must not be carried over.
            try SkillRating(guideId: old.id, skillId: "p0s5", rating: .cantYet).insert(conn)
            return (old.id, new.id)
        }
        let removed = try await db.queue.write { conn in
            try StudyGuideActions.mergeDuplicateGuides(db: conn, fileExists: { $0.hasPrefix("/Vault") })
        }
        #expect(removed == 1)
        try await db.queue.read { conn in
            #expect(try StudyGuide.fetchCount(conn) == 1)
            let survivor = try #require(try StudyGuide.fetchOne(conn, key: ids.new))
            #expect(survivor.examEventId == examId)
            let ratings = try SkillRating.filter(Column("guideId") == ids.new).fetchAll(conn)
            #expect(ratings.map(\.skillId) == ["p0s1"])
            #expect(ratings.first?.rating == .shaky)
        }
        // Running it again changes nothing.
        let again = try await db.queue.write { conn in
            try StudyGuideActions.mergeDuplicateGuides(db: conn, fileExists: { $0.hasPrefix("/Vault") })
        }
        #expect(again == 0)
    }

    @Test("two generated practice sets are never merged, and different guides stay separate")
    func leavesDistinctGuidesAlone() async throws {
        let (db, courseId, ids, _) = try await makeLibrary()
        for _ in 0..<2 {
            _ = try await StudyGuideBuilder.generate(
                courseIds: [courseId], deckIds: Array(ids.values), problemsPerDeck: 3, examEventId: nil,
                using: RecordingGenerator(), database: db, now: Date()
            )
        }
        try await db.queue.write { conn in
            _ = try self.addGuide(conn, courseId: courseId, title: "Professor Review", path: "/a.pdf", hash: "x",
                                  examId: nil, skills: [], created: Date())
            _ = try self.addGuide(conn, courseId: courseId, title: "Student Guide", path: "/b.pdf", hash: "y",
                                  examId: nil, skills: [], created: Date())
        }
        let removed = try await db.queue.write { try StudyGuideActions.mergeDuplicateGuides(db: $0, fileExists: { _ in true }) }
        #expect(removed == 0)
        let remaining = try await db.queue.read { try StudyGuide.fetchCount($0) }
        #expect(remaining == 4)
    }

    @Test("re-importing a guide from another folder takes over the existing guide instead of adding a second")
    func importAdoptsExistingCopy() async throws {
        let (db, courseId, _, examId) = try await makeLibrary()
        let original = try await db.queue.write { conn in
            try self.addGuide(conn, courseId: courseId, title: "ECO 2023 - Exam 1 Study Guide",
                              path: "/Desktop/guide.pdf", hash: "h1", examId: examId, skills: ["A"], created: Date())
        }
        try await db.queue.write { conn in
            let moved = Material(courseId: courseId, relativePath: "/Vault/guide.pdf", kind: .pdf,
                                 contentHash: "h1", title: "ECO 2023 - Exam 1 Study Guide")
            try moved.insert(conn)
            try StudyGuideActions.importGuide(material: moved, pages: ["Part 1 · Supply\nYou should be able to\n- Explain supply"], db: conn)
        }
        try await db.queue.read { conn in
            let guides = try StudyGuide.fetchAll(conn)
            #expect(guides.count == 1)
            #expect(guides[0].id == original.id)
            #expect(guides[0].examEventId == examId)
            let materialId = try #require(guides[0].materialId)
            let material = try #require(try Material.fetchOne(conn, key: materialId))
            #expect(material.relativePath == "/Vault/guide.pdf")
        }
    }

    @Test("the hub keeps a past exam's guide reachable, lists upcoming exams first, and leaves out archived courses")
    func hubListsPastExams() async throws {
        let (db, courseId, _, pastExam) = try await makeLibrary()
        let now = Date()
        try await db.queue.write { conn in
            var past = try #require(try CalendarEvent.fetchOne(conn, key: pastExam))
            past.startsAt = now.addingTimeInterval(-5 * 86_400)
            try past.save(conn)
            let next = CalendarEvent(courseId: courseId, kind: .exam, title: "Midterm 2", startsAt: now.addingTimeInterval(9 * 86_400))
            try next.insert(conn)
            _ = try self.addGuide(conn, courseId: courseId, title: "Old guide", path: "/o.pdf", hash: "o",
                                  examId: pastExam, skills: [], created: now)
            _ = try self.addGuide(conn, courseId: courseId, title: "New guide", path: "/n.pdf", hash: "n",
                                  examId: next.id, skills: [], created: now)
            _ = try self.addGuide(conn, courseId: courseId, title: "Loose guide", path: "/l.pdf", hash: "l",
                                  examId: nil, skills: [], created: now)
            let archived = Course(semesterId: nil, name: "Archived course", isArchived: true)
            try archived.insert(conn)
            _ = try self.addGuide(conn, courseId: archived.id, title: "Hidden", path: "/h.pdf", hash: "h",
                                  examId: nil, skills: [], created: now)
        }
        let hub = try await db.queue.read { try StudyGuideActions.hub(now: now, db: $0) }
        #expect(hub.count == 1)
        let course = try #require(hub.first)
        #expect(course.exams.map(\.exam.title) == ["Midterm 2", "Midterm 1"])
        #expect(course.exams.map(\.isPast) == [false, true])
        #expect(course.practiceSets.map(\.title) == ["Loose guide"])
    }

    @Test("an upcoming exam with no guide yet is listed, so a guide can be added to it")
    func hubListsExamsWithoutGuides() async throws {
        let db = try GRASPDatabase.inMemory()
        let now = Date()
        try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Systems"); try course.insert(conn)
            try CalendarEvent(courseId: course.id, kind: .exam, title: "Midterm", startsAt: now.addingTimeInterval(5 * 86_400)).insert(conn)
            try CalendarEvent(courseId: course.id, kind: .study, title: "Review class", startsAt: now.addingTimeInterval(3 * 86_400)).insert(conn)
            try CalendarEvent(courseId: course.id, kind: .exam, title: "Old exam", startsAt: now.addingTimeInterval(-9 * 86_400)).insert(conn)
        }
        let hub = try await db.queue.read { try StudyGuideActions.hub(now: now, db: $0) }
        let course = try #require(hub.first)
        #expect(course.exams.map(\.exam.title) == ["Midterm"])
        #expect(course.exams.first?.guides.isEmpty == true)
    }
}
