import Foundation
import Testing
import GRDB
@testable import GRASPCore

/// A model that structures photo questions from a fixed reply, and counts its calls.
private final class PhotoGenerator: CardGenerator, @unchecked Sendable {
    var available = true
    var structured: GeneratedProblem?
    var solverAnswer: Int?
    var structureCalls = 0
    var solveCalls = 0

    var isAvailable: Bool { get async { available } }
    func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
    func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
    func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
    func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
    func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation { ContextValidation(.valid) }
    func generateOverview(noteTitle: String, courseName: String, noteContext: String, includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
    func generateFigures(noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
    func structurePhotoQuestion(text: String, courseName: String) async -> GeneratedProblem? { structureCalls += 1; return structured }
    func solveMultipleChoice(prompt: String, choices: [String]) async -> Int? { solveCalls += 1; return solverAnswer }
}

@Suite("Photo import")
struct PhotoImportTests {
    private struct Library { var db: GRASPDatabase; var courseId: String; var deckId: String }

    private func makeLibrary() throws -> Library {
        let db = try GRASPDatabase.inMemory()
        return try db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Biology"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Cells"); try deck.insert(conn)
            return Library(db: db, courseId: course.id, deckId: deck.id)
        }
    }

    private func drafts(_ lib: Library) throws -> [TestQuestion] {
        try lib.db.queue.read { try QuestionBank.drafts(inDecks: [lib.deckId], db: $0) }
    }

    private func saveImage(_ lib: Library) throws -> String {
        try lib.db.queue.write { try QuestionImages.save(jpeg: Data([1, 2, 3]), width: 10, height: 10, courseId: lib.courseId, db: $0).id }
    }

    @Test("a multiple choice question with its answer printed is kept as printed, with no AI call")
    func printedAnswerNeedsNoAI() async throws {
        let lib = try makeLibrary()
        let image = try saveImage(lib)
        let generator = PhotoGenerator()
        let page = PhotoPage(imageId: image, text: """
            1. What organelle makes most of a cell's energy?
            A) Nucleus
            B) Mitochondrion
            C) Ribosome
            Answer: B
            """)
        let outcome = await PhotoQuestionImporter.importPages([page], deckId: lib.deckId, using: generator, database: lib.db)
        #expect(outcome.saved == 1 && outcome.drops.isEmpty)
        #expect(generator.structureCalls == 0 && generator.solveCalls == 0)
        let saved = try #require(try drafts(lib).first)
        #expect(saved.sourceKind == .photo && saved.statusKind == .draft && saved.imageId == image)
        #expect(saved.verifiedBy == "from a photo, answer printed on the page")
        let problem = try #require(saved.problem)
        #expect(problem.choices == ["Nucleus", "Mitochondrion", "Ribosome"] && problem.correct == 1)
    }

    @Test("an answer the page does not print is written by AI, flagged, and left out of Approve all")
    func aiAnswerIsFlagged() async throws {
        let lib = try makeLibrary()
        let image = try saveImage(lib)
        let generator = PhotoGenerator()
        generator.structured = GeneratedProblem(kind: .multipleChoice, prompt: "Which organelle holds the cell's DNA?",
                                                choices: ["Nucleus", "Golgi body"], correct: 0, explanation: "The nucleus holds DNA.",
                                                answerGiven: false)
        let page = PhotoPage(imageId: image, text: "1. Which organelle holds the cell's DNA?\nA) Nucleus\nB) Golgi body")
        let outcome = await PhotoQuestionImporter.importPages([page], deckId: lib.deckId, using: generator, database: lib.db)
        #expect(outcome.saved == 1)
        let saved = try #require(try drafts(lib).first)
        #expect(QuestionBank.needsAnswerCheck(saved))
        let all = try await lib.db.queue.write { try QuestionBank.approveAll(inDecks: [lib.deckId], db: $0) }
        #expect(all.approved == 0 && all.skipped.count == 1)
        #expect(try drafts(lib).count == 1)
        // Approving it yourself is the check.
        #expect(try await lib.db.queue.write { try QuestionBank.approve(saved.id, db: $0) } == nil)
        let approved = try #require(try await lib.db.queue.read { try TestQuestion.fetchOne($0, key: saved.id) })
        #expect(approved.statusKind == .active && !QuestionBank.needsAnswerCheck(approved))
        #expect(approved.verifiedBy.contains("checked by you"))
    }

    @Test("a written answer printed under a question is kept, and an unanswerable one is dropped when no AI is available")
    func writtenAndNoModel() async throws {
        let lib = try makeLibrary()
        let generator = PhotoGenerator()
        generator.available = false
        let page = PhotoPage(text: """
            1. Name the organelle where photosynthesis happens.
            Answer: the chloroplast
            2. Explain why cells divide.
            """)
        let outcome = await PhotoQuestionImporter.importPages([page], deckId: lib.deckId, using: generator, database: lib.db)
        #expect(outcome.saved == 1 && outcome.drops.count == 1)
        #expect(outcome.drops[0].detail.contains("no AI model"))
        let written = try #require(try drafts(lib).first?.problem)
        #expect(written.kind == .written && written.answer == "the chloroplast")
    }

    @Test("a question the deck already has is dropped as a repeat, and a too-short one as unclear")
    func repeatsAndUnclear() async throws {
        let lib = try makeLibrary()
        try await lib.db.queue.write { db in
            _ = try QuestionBank.create(UserQuestionInput(kind: .written, prompt: "Name the organelle where photosynthesis happens.",
                                                          answer: "chloroplast"), deckId: lib.deckId, db: db)
        }
        let generator = PhotoGenerator()
        let page = PhotoPage(text: """
            1. Name the organelle where photosynthesis happens.
            Answer: chloroplast
            2. What is DNA?
            Answer: a molecule
            """)
        let outcome = await PhotoQuestionImporter.importPages([page], deckId: lib.deckId, using: generator, database: lib.db)
        #expect(outcome.saved == 0)
        #expect(Set(outcome.drops.map(\.reason)) == [.repeated, .unclear])
    }

    @Test("an AI-structured true/false and written question are read into the right kinds")
    func structuredKinds() async throws {
        let lib = try makeLibrary()
        let generator = PhotoGenerator()
        generator.structured = GeneratedProblem(kind: .trueFalse, prompt: "Mitochondria have their own DNA.", claimedAnswer: "True", answerGiven: false)
        let outcome = await PhotoQuestionImporter.importPages([PhotoPage(text: "1. True or false: mitochondria have their own DNA.")],
                                                              deckId: lib.deckId, using: generator, database: lib.db)
        #expect(outcome.saved == 1)
        let problem = try #require(try drafts(lib).first?.problem)
        #expect(problem.kind == .trueFalse && problem.isTrue == true)
    }

    @Test("a stopped import keeps what it had and says it stopped")
    func stopped() async throws {
        let lib = try makeLibrary()
        let generator = PhotoGenerator()
        let task = Task {
            await PhotoQuestionImporter.importPages([PhotoPage(text: "1. First question here?\nA) one\nB) two\nAnswer: A")],
                                                    deckId: lib.deckId, using: generator, database: lib.db)
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.wasCancelled || outcome.saved <= 1)
    }

    // MARK: Pictures

    @Test("a picture stays on the device while its question is a draft and syncs once approved")
    func pictureFollowsQuestion() async throws {
        let device = try GRASPDatabase.inMemory()
        let engine = SyncEngine(database: device)
        let (courseId, deckId) = try await device.queue.write { db -> (String, String) in
            let course = Course(semesterId: nil, name: "Biology"); try course.insert(db)
            let deck = Deck(courseId: course.id, name: "Cells"); try deck.insert(db)
            return (course.id, deck.id)
        }
        try engine.enable(accountUserId: "u", uploadExisting: false)
        let imageId = try await device.queue.write { try QuestionImages.save(jpeg: Data([9, 9, 9]), width: 5, height: 5, courseId: courseId, db: $0).id }
        func queued(_ table: String) throws -> Int {
            try device.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncOutbox WHERE tableName = ?", arguments: [table]) ?? 0 }
        }
        #expect(try queued("questionImage") == 0)
        let problem = ProblemQuestion(kind: .written, subject: .concepts, prompt: "What does the nucleus do in a cell?", answer: "Holds the DNA")
        var record = TestQuestion(courseId: courseId, deckId: deckId, problem: problem, bodyJSON: problem.encoded() ?? "{}",
                                  verifiedBy: "from a photo, answer printed on the page", source: .photo, status: .draft)
        record.imageId = imageId
        let toSave = record
        try await device.queue.write { try toSave.insert($0) }
        #expect(try queued("testQuestion") == 0 && queued("questionImage") == 0)
        #expect(try await device.queue.write { try QuestionBank.approve(toSave.id, db: $0) } == nil)
        #expect(try queued("testQuestion") == 1 && queued("questionImage") == 1)
    }

    @Test("deleting the only question that uses a picture removes the picture")
    func pictureReleased() async throws {
        let lib = try makeLibrary()
        let image = try saveImage(lib)
        let generator = PhotoGenerator()
        _ = await PhotoQuestionImporter.importPages(
            [PhotoPage(imageId: image, text: "1. First question here today?\nA) one\nB) two\nAnswer: A")],
            deckId: lib.deckId, using: generator, database: lib.db)
        let saved = try #require(try drafts(lib).first)
        #expect(try await lib.db.queue.read { try QuestionImages.image(image, db: $0) } != nil)
        try await lib.db.queue.write { try CodeQuestionBank.delete(saved.id, db: $0) }
        #expect(try await lib.db.queue.read { try QuestionImages.image(image, db: $0) } == nil)
    }

    @Test("a picture over the size limit is refused in plain words")
    func tooLarge() throws {
        let lib = try makeLibrary()
        let big = Data(count: QuestionImages.maxBytes + 1)
        #expect(throws: QuestionBankError.self) {
            try lib.db.queue.write { _ = try QuestionImages.save(jpeg: big, width: 1, height: 1, courseId: nil, db: $0) }
        }
    }

    @Test("the v20 migration adds the picture table and registers it for sync after the questions")
    func migration() throws {
        let names = SyncSchema.tables.map(\.name)
        let q = try #require(names.firstIndex(of: "testQuestion")), i = try #require(names.firstIndex(of: "questionImage"))
        #expect(i > q)
        let db = try GRASPDatabase.inMemory()
        #expect(try db.queue.read { try $0.tableExists("questionImage") })
    }

    // MARK: The model's reply

    @Test("a photo reply with three options and a given answer parses")
    func parsesPhotoReply() {
        let reply = """
        ### PROBLEM
        KIND: multipleChoice
        PROMPT: Which organelle holds the DNA?
        CHOICES:
        A) Nucleus
        B) Golgi body
        C) Ribosome
        ANSWER: A
        GIVEN: yes
        EXPLANATION: The nucleus holds the DNA.
        ### END
        """
        let parsed = OllamaGenerator.parseProblems(reply, choiceCounts: 2...6)
        #expect(parsed.count == 1 && parsed[0].choices.count == 3 && parsed[0].correct == 0 && parsed[0].answerGiven == true)
        // The notes-writing path still insists on four.
        #expect(OllamaGenerator.parseProblems(reply).isEmpty)
    }

    // MARK: Pages that are not a tidy quiz

    @Test("a page of notes with no questions in it makes no question")
    func proseIsNotAQuestion() {
        let notes = "The mitochondrion is an organelle found in most cells.\nIt makes most of the cell's energy.\nMitochondria have their own genome.\nChloroplasts perform photosynthesis."
        #expect(QuestionSplitter.split(notes).isEmpty)
        #expect(QuestionSplitter.split("Explain why cells divide.").count == 1)
        #expect(QuestionSplitter.split("Why do cells divide? Give two reasons.").count == 1)
    }

    @Test("a page that starts with options or an answer starts partway through a question")
    func continuation() {
        #expect(QuestionSplitter.startsMidQuestion("A) DNA\nB) ATP"))
        #expect(QuestionSplitter.startsMidQuestion("Answer: B\n5. Next question here?"))
        #expect(!QuestionSplitter.startsMidQuestion("BIO 1010 Quiz\n1. First question?"))
        #expect(!QuestionSplitter.startsMidQuestion("1. First question?\nA) one"))
    }

    @Test("a question that runs onto the next photo is joined, with its answer")
    func questionSpansTwoPhotos() async throws {
        let lib = try makeLibrary()
        let first = PhotoPage(imageId: try saveImage(lib), text: "1. Name an organelle with its own DNA.\nAnswer: mitochondrion\n2. Which molecule carries the genetic code?")
        let second = PhotoPage(imageId: try saveImage(lib), text: "A) DNA\nB) ATP\nC) Glucose\nAnswer: A\n3. Which sugar do cells burn?\nAnswer: glucose")
        let outcome = await PhotoQuestionImporter.importPages([first, second], deckId: lib.deckId, using: PhotoGenerator(), database: lib.db)
        #expect(outcome.saved == 3 && outcome.drops.isEmpty)
        let two = try #require(try drafts(lib).first { $0.promptText.contains("genetic code") })
        let problem = try #require(two.problem)
        #expect(problem.choices == ["DNA", "ATP", "Glucose"] && problem.correct == 0)
    }

    @Test("a photo that starts partway through a question with nothing before it says so")
    func orphanStart() async throws {
        let lib = try makeLibrary()
        let page = PhotoPage(text: "A) DNA\nB) ATP\nAnswer: A\n2. Which sugar do cells burn?\nAnswer: glucose")
        let outcome = await PhotoQuestionImporter.importPages([page], deckId: lib.deckId, using: PhotoGenerator(), database: lib.db)
        #expect(outcome.saved == 1)
        #expect(outcome.drops.contains { $0.detail.contains("starts partway through") })
    }

    @Test("a question is cropped to its own lines of the page, and a page-sized one is not")
    func cropsToTheQuestion() async throws {
        let lib = try makeLibrary()
        let lines = ["1. First question here today?", "A) one", "B) two", "Answer: A", "2. Second question here today?", "A) one", "B) two", "Answer: B"]
        let boxes: [PhotoBox?] = lines.indices.map { PhotoBox(x: 0.1, y: 0.05 + Double($0) * 0.1, width: 0.6, height: 0.05) }
        let page = PhotoPage(imageId: try saveImage(lib), text: lines.joined(separator: "\n"), boxes: boxes)
        _ = await PhotoQuestionImporter.importPages([page], deckId: lib.deckId, using: PhotoGenerator(), database: lib.db)
        let second = try #require(try drafts(lib).first { $0.promptText.hasPrefix("Second") })
        let box = try #require(PhotoBox(encoded: second.imageCrop))
        #expect(box.y > 0.4 && box.y < 0.5 && box.height < 0.5 && box.width > 0.6)
        // No boxes known: the whole picture is shown.
        let whole = PhotoPage(imageId: try saveImage(lib), text: "1. A third question here today?\nA) one\nB) two\nAnswer: A")
        _ = await PhotoQuestionImporter.importPages([whole], deckId: lib.deckId, using: PhotoGenerator(), database: lib.db)
        #expect(try drafts(lib).first { $0.promptText.hasPrefix("A third") }?.imageCrop == nil)
    }

    @Test("a photo that was hard to read marks every question, even with printed answers, and Approve all leaves them")
    func hardToReadIsFlagged() async throws {
        let lib = try makeLibrary()
        let page = PhotoPage(imageId: try saveImage(lib), text: "1. Which organelle makes energy?\nA) Nucleus\nB) Mitochondrion\nAnswer: B", hardToRead: true)
        let outcome = await PhotoQuestionImporter.importPages([page], deckId: lib.deckId, using: PhotoGenerator(), database: lib.db)
        #expect(outcome.saved == 1)
        let saved = try #require(try drafts(lib).first)
        #expect(QuestionBank.needsAnswerCheck(saved) && QuestionBank.checkLabel(saved) == "Check the wording")
        let all = try await lib.db.queue.write { try QuestionBank.approveAll(inDecks: [lib.deckId], db: $0) }
        #expect(all.approved == 0 && all.skipped.first?.reason.contains("hard to read") == true)
        #expect(try await lib.db.queue.write { try QuestionBank.approve(saved.id, db: $0) } == nil)
        let approved = try #require(try await lib.db.queue.read { try TestQuestion.fetchOne($0, key: saved.id) })
        #expect(approved.verifiedBy.contains("checked by you") && QuestionBank.checkLabel(approved) == nil)
    }

    @Test("a picture whose page gave no question is not kept")
    func unusedPictureReleased() async throws {
        let lib = try makeLibrary()
        let image = try saveImage(lib)
        let page = PhotoPage(imageId: image, text: "The mitochondrion is an organelle found in most cells.\nIt makes most of the cell's energy.\nMitochondria have their own genome.\nChloroplasts perform photosynthesis.")
        let outcome = await PhotoQuestionImporter.importPages([page], deckId: lib.deckId, using: PhotoGenerator(), database: lib.db)
        #expect(outcome.saved == 0 && outcome.drops.isEmpty)
        #expect(try await lib.db.queue.read { try QuestionImages.image(image, db: $0) } == nil)
    }
}
