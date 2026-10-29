import Foundation
import GRDB

/// A rectangle on a picture, as fractions of its width and height from the top left corner.
public struct PhotoBox: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }

    public var encoded: String { String(format: "%.4f,%.4f,%.4f,%.4f", x, y, width, height) }

    public init?(encoded: String?) {
        guard let parts = encoded?.split(separator: ",").compactMap({ Double($0) }), parts.count == 4,
              parts[2] > 0, parts[3] > 0 else { return nil }
        self.init(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// The smallest box holding all of these, with a margin, kept inside the picture.
    public static func around(_ boxes: [PhotoBox], margin: Double = 0.015) -> PhotoBox? {
        guard let first = boxes.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for box in boxes.dropFirst() {
            minX = min(minX, box.x); minY = min(minY, box.y)
            maxX = max(maxX, box.x + box.width); maxY = max(maxY, box.y + box.height)
        }
        minX = max(0, minX - margin); minY = max(0, minY - margin)
        maxX = min(1, maxX + margin); maxY = min(1, maxY + margin)
        return PhotoBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The text the device read from one picture, with the picture it came from.
public struct PhotoPage: Sendable, Equatable {
    /// The stored picture (`QuestionImage.id`), so a draft can show it.
    public var imageId: String?
    public var text: String
    /// Where each printed line of `text` is on the picture (one per non-empty line), when known.
    public var boxes: [PhotoBox?]
    /// The reader was unsure of much of the page (poor light, blur, handwriting).
    public var hardToRead: Bool
    public init(imageId: String? = nil, text: String, boxes: [PhotoBox?] = [], hardToRead: Bool = false) {
        self.imageId = imageId; self.text = text; self.boxes = boxes; self.hardToRead = hardToRead
    }

    var lineCount: Int { text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
}

/// Photo import, after the device has read the pictures: cuts each page into
/// questions, finishes each one (an answer the page prints is kept as printed;
/// one it does not print is written by the AI and flagged "check it"), runs
/// the same quality and repeat checks as every other draft, and saves what
/// passes as drafts that stay on this device until you approve them. Nothing
/// here reads a picture; that is the app's job, so this is plain text in.
public enum PhotoQuestionImporter {
    private struct Candidate {
        var problem: ProblemQuestion
        var verifiedBy: String
    }

    /// A question with the page it was printed on, and whether it is on a page that was hard to read.
    private struct Located {
        var page: PhotoPage
        var raw: RawQuestion
        var hard: Bool
    }

    /// Every question on the photos, in order. The top of a photo that finishes a question begun on
    /// the one before (options, or an answer, with no question above them) is added to that
    /// question, which keeps the first photo. Notes say what could not be joined.
    private static func questions(on pages: [PhotoPage]) -> (work: [Located], notes: [DraftDrop]) {
        var work: [Located] = []
        var notes: [DraftDrop] = []
        for page in pages {
            let lead = QuestionSplitter.continuation(of: page.text)
            if !lead.isEmpty {
                if var previous = work.popLast() {
                    let start = previous.raw.number.map { "\($0). " } ?? ""
                    let text = start + previous.raw.fullText + "\n" + lead.joined(separator: "\n")
                    if let joined = QuestionSplitter.split(text).first { previous.raw = joined }
                    previous.hard = previous.hard || page.hardToRead
                    work.append(previous)
                } else {
                    notes.append(DraftDrop(text: lead[0], reason: .unclear,
                                           detail: "The photo starts partway through a question. If the start of it is on another photo, add that photo first."))
                }
            }
            work += QuestionSplitter.split(page.text).map { Located(page: page, raw: $0, hard: page.hardToRead) }
        }
        return (work, notes)
    }

    /// Where a question is on its page, when every one of its lines has a known place and it is
    /// not most of the page anyway.
    private static func crop(of raw: RawQuestion, on page: PhotoPage) -> String? {
        guard let range = raw.lineRange, page.boxes.count == page.lineCount, range.upperBound < page.boxes.count else { return nil }
        let boxes = page.boxes[range].compactMap { $0 }
        guard boxes.count == range.count, let box = PhotoBox.around(boxes) else { return nil }
        return box.width * box.height > 0.6 ? nil : box.encoded
    }

    public static func importPages(
        _ pages: [PhotoPage], deckId: String, using generator: any CardGenerator, database: GRASPDatabase
    ) async -> DraftOutcome {
        var outcome = DraftOutcome()
        let progress = AIProgress.current
        guard let context = try? await database.queue.read({ db -> (deck: Deck, course: String, known: [String])? in
            guard let deck = try Deck.fetchOne(db, key: deckId) else { return nil }
            let course = try Course.fetchOne(db, key: deck.courseId)?.name ?? ""
            return (deck, course, try QuestionBank.listing(inDecks: [deckId], db: db).map(\.promptText))
        }) else { outcome.noNotes = true; return outcome }

        var known = context.known
        // Newest first is how drafts are listed, so earlier questions get slightly later times and read 1, 2, 3 down the list.
        let batchStart = Date()
        let aiAvailable = await generator.isAvailable
        let modelName = OverviewOrigin.of(generator)?.model
        let (work, notes) = questions(on: pages)
        outcome.drops.append(contentsOf: notes)
        defer { releaseUnusedPictures(pages.compactMap(\.imageId), database: database) }
        guard !work.isEmpty else { return outcome }
        progress?.expect(work.count)

        for (index, item) in work.enumerated() {
            if Task.isCancelled { outcome.wasCancelled = true; break }
            let (page, raw, hard) = (item.page, item.raw, item.hard)
            progress?.begin("Reading question \(index + 1) of \(work.count)")
            defer { progress?.advance() }

            guard var candidate = await finish(raw, course: context.course, generator: generator, aiAvailable: aiAvailable) else {
                outcome.drops.append(DraftDrop(
                    text: raw.stem, reason: .unclear,
                    detail: aiAvailable
                        ? "The AI could not turn it into a question with an answer."
                        : "It needs the AI to write its answer, and no AI model is available."))
                continue
            }
            if let why = QuestionBank.qualityProblem(candidate.problem) {
                outcome.drops.append(DraftDrop(text: candidate.problem.prompt, reason: .unclear, detail: "It " + why + "."))
                continue
            }
            if known.contains(where: { QuestionText.isRepeat($0, candidate.problem.prompt) }) {
                outcome.drops.append(DraftDrop(text: candidate.problem.prompt, reason: .repeated,
                                               detail: "It asks the same thing as a question already here."))
                continue
            }
            if hard { candidate.verifiedBy += "; " + QuestionBank.readCheckMarker }
            guard let body = candidate.problem.encoded() else { continue }
            var record = TestQuestion(courseId: context.deck.courseId, deckId: deckId, problem: candidate.problem, bodyJSON: body,
                                      verifiedBy: candidate.verifiedBy, model: modelName, createdAt: batchStart.addingTimeInterval(-Double(index) * 0.001),
                                      source: .photo, status: .draft)
            record.imageId = page.imageId
            record.imageCrop = crop(of: raw, on: page)
            let toSave = record
            if (try? await database.queue.write({ try toSave.insert($0) })) != nil {
                known.append(candidate.problem.prompt)
                outcome.saved += 1
            }
        }
        if aiAvailable == false, outcome.saved == 0, !outcome.drops.isEmpty { outcome.modelUnreachable = true }
        return outcome
    }

    /// A picture whose page gave no question is not kept.
    private static func releaseUnusedPictures(_ ids: [String], database: GRASPDatabase) {
        try? database.queue.write { db in
            for id in ids { try QuestionImages.releaseIfUnused(id, db: db) }
        }
    }

    private static let printed = "from a photo, answer printed on the page"

    /// One raw question made into a problem, or nil when it can't be.
    private static func finish(_ raw: RawQuestion, course: String, generator: any CardGenerator, aiAvailable: Bool) async -> Candidate? {
        let optionCount = raw.options.count

        // The page prints the options and says which is right: keep it as printed, no AI.
        if optionCount >= 2, let letter = raw.answerLetter,
           let index = "ABCDEFGH".firstIndex(of: letter).map({ "ABCDEFGH".distance(from: "ABCDEFGH".startIndex, to: $0) }),
           index < optionCount {
            let problem = ProblemQuestion(kind: .multipleChoice, subject: .concepts, prompt: raw.stem, choices: raw.options, correct: index)
            return Candidate(problem: problem, verifiedBy: printed)
        }
        // No options but an answer in words: a written question, as printed.
        if optionCount == 0, let answer = raw.answerText, !answer.isEmpty, !looksTrueFalse(raw.stem) {
            let problem = ProblemQuestion(kind: .written, subject: .concepts, prompt: raw.stem, answer: answer)
            return Candidate(problem: problem, verifiedBy: printed)
        }
        guard aiAvailable else { return nil }

        // Anything else the AI finishes: it cleans the question and works out the missing answer.
        if let generated = await generator.structurePhotoQuestion(text: raw.fullText, courseName: course),
           let problem = problem(from: generated) {
            let given = generated.answerGiven == true && (raw.answerLetter != nil || raw.answerText != nil)
            return Candidate(problem: problem,
                             verifiedBy: given ? printed : "from a photo, " + QuestionBank.answerCheckMarker)
        }
        // Four printed options and no answer: a cold second opinion is still something.
        if optionCount == 4, let index = await generator.solveMultipleChoice(prompt: raw.stem, choices: raw.options) {
            let problem = ProblemQuestion(kind: .multipleChoice, subject: .concepts, prompt: raw.stem, choices: raw.options, correct: index)
            return Candidate(problem: problem, verifiedBy: "from a photo, " + QuestionBank.answerCheckMarker)
        }
        return nil
    }

    private static func looksTrueFalse(_ stem: String) -> Bool {
        let lower = stem.lowercased()
        return lower.hasPrefix("true or false") || lower.hasPrefix("true/false") || lower.hasPrefix("t/f")
    }

    private static func problem(from generated: GeneratedProblem) -> ProblemQuestion? {
        switch generated.kind {
        case .multipleChoice:
            guard let correct = generated.correct, generated.choices.indices.contains(correct) else { return nil }
            return ProblemQuestion(kind: .multipleChoice, subject: .concepts, prompt: generated.prompt, choices: generated.choices,
                                   correct: correct, explanation: generated.explanation)
        case .written:
            guard !generated.claimedAnswer.isEmpty else { return nil }
            return ProblemQuestion(kind: .written, subject: .concepts, prompt: generated.prompt,
                                   explanation: generated.explanation, answer: generated.claimedAnswer)
        case .trueFalse:
            let answer = generated.claimedAnswer.lowercased()
            guard answer.hasPrefix("true") || answer.hasPrefix("false") else { return nil }
            return ProblemQuestion(kind: .trueFalse, subject: .concepts, prompt: generated.prompt,
                                   explanation: generated.explanation, isTrue: answer.hasPrefix("true"))
        default:
            return nil
        }
    }
}
