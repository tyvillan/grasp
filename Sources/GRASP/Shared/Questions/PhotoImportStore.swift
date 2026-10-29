import Foundation
import GRASPCore

/// "From a photo": reads the pictures on this device, then writes drafts from
/// them the same way "Generate questions with AI" does, with a progress strip
/// and Stop. Nothing runs until a student asks for it.
extension AppStore {
    func photoImportJobKey(courseId: String?) -> String { "photoImport:\(courseId ?? "none")" }

    func questionImage(_ id: String) -> QuestionImage? {
        (try? database.queue.read { try QuestionImages.image(id, db: $0) }) ?? nil
    }

    /// Reads the pictures and saves what they hold as drafts under To review.
    /// False when an import is already running for this course.
    @discardableResult
    func importPhotoQuestions(_ files: [Data], deckId: String, courseId: String?) -> Bool {
        lastQuestionDraftRun = nil
        let run = AIActivity(headline: "Reading questions from photos", units: 1, purpose: "photo questions")
        return runAIJob(photoImportJobKey(courseId: courseId), activity: run) { [weak self] run in
            guard let self else { return }
            var pages: [PhotoPage] = []
            var unreadable = 0
            run.reporter(forUnit: 0).setNote("Reading the photo on this device")
            var hard: [Int] = []
            for (number, data) in files.enumerated() {
                if Task.isCancelled { break }
                // Nothing is kept of a photo that holds no readable text.
                guard let reading = await PhotoSupport.read(data), !reading.lines.isEmpty else { unreadable += 1; continue }
                let imageId = try? await self.database.queue.write {
                    try QuestionImages.save(jpeg: reading.jpeg, width: reading.width, height: reading.height,
                                            courseId: courseId, db: $0).id
                }
                if reading.hardToRead { hard.append(number + 1) }
                pages.append(PhotoPage(imageId: imageId, text: reading.text, boxes: reading.lines.map { Optional($0.box) },
                                       hardToRead: reading.hardToRead))
            }

            var outcome = DraftOutcome()
            var failure: String?
            if pages.isEmpty {
                failure = files.count == 1
                    ? "No text could be read from that photo. Try a sharper one with the page filling the frame."
                    : "No text could be read from those photos. Try sharper ones with the page filling the frame."
            } else {
                let generator: any CardGenerator = StubHooks.enabled("GRASP_STUB_QUESTIONS")
                    ? StubQuestionGenerator() : await CardGenerators.select()
                outcome = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                    await PhotoQuestionImporter.importPages(pages, deckId: deckId, using: generator, database: self.database)
                }
                if outcome.saved == 0, !run.stopRequested {
                    if outcome.drops.isEmpty {
                        failure = files.count == 1
                            ? "No questions were found on that photo. It has text but nothing numbered like a question, so it looks like notes. Numbered questions (1., 2., 3.) read best."
                            : "No questions were found on those photos. They have text but nothing numbered like a question. Numbered questions (1., 2., 3.) read best."
                    } else if outcome.modelUnreachable {
                        failure = "No AI model is reachable right now, and these questions need one to write their answers. Settings has the setup."
                    } else {
                        failure = "None of the questions on the photo could be kept."
                    }
                }
                if !hard.isEmpty, !run.stopRequested {
                    outcome.drops.append(DraftDrop(
                        text: "Photo \(hard.map(String.init).joined(separator: ", "))", reason: .unclear,
                        detail: "Hard to read (blur, poor light or handwriting). Words may be wrong and questions may be missing, so check each draft against its photo."))
                }
                if outcome.saved > 0 || !outcome.drops.isEmpty, unreadable > 0, files.count > 1 {
                    // Some pictures worked: say so rather than hide the ones that did not.
                    outcome.drops.append(DraftDrop(text: "\(unreadable) photo\(unreadable == 1 ? "" : "s")", reason: .unclear,
                                                   detail: "No text could be read."))
                }
            }
            self.lastQuestionDraftRun = QuestionDraftRunResult(deckIds: [deckId], outcome: outcome, failure: failure)
            self.reload()
        }
    }
}
