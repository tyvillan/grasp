import Foundation
import GRDB

/// The text the device read from one picture, with the picture it came from.
public struct PhotoPage: Sendable, Equatable {
    /// The stored picture (`QuestionImage.id`), so a draft can show it.
    public var imageId: String?
    public var text: String
    public init(imageId: String? = nil, text: String) { self.imageId = imageId; self.text = text }
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
        let aiAvailable = await generator.isAvailable
        let modelName = OverviewOrigin.of(generator)?.model
        let work = pages.flatMap { page in QuestionSplitter.split(page.text).map { (page.imageId, $0) } }
        guard !work.isEmpty else { return outcome }
        progress?.expect(work.count)

        for (index, item) in work.enumerated() {
            if Task.isCancelled { outcome.wasCancelled = true; break }
            let (imageId, raw) = item
            progress?.begin("Reading question \(index + 1) of \(work.count)")
            defer { progress?.advance() }

            guard let candidate = await finish(raw, course: context.course, generator: generator, aiAvailable: aiAvailable) else {
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
            guard let body = candidate.problem.encoded() else { continue }
            var record = TestQuestion(courseId: context.deck.courseId, deckId: deckId, problem: candidate.problem, bodyJSON: body,
                                      verifiedBy: candidate.verifiedBy, model: modelName, source: .photo, status: .draft)
            record.imageId = imageId
            let toSave = record
            if (try? await database.queue.write({ try toSave.insert($0) })) != nil {
                known.append(candidate.problem.prompt)
                outcome.saved += 1
            }
        }
        if aiAvailable == false, outcome.saved == 0, !outcome.drops.isEmpty { outcome.modelUnreachable = true }
        return outcome
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
