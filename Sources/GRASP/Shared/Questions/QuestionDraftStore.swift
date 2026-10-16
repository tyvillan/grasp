import Foundation
import GRASPCore

/// "Generate questions with AI": the Questions tab's job, its drafts, and
/// approving them. Nothing here runs unless a student asks for it.
extension AppStore {
    func questionDraftJobKey(courseId: String?) -> String { "questionDrafts:\(courseId ?? "none")" }

    func questionDraftCount(inDecks deckIds: [String]) -> Int {
        (try? database.queue.read { try QuestionBank.draftCount(inDecks: deckIds, db: $0) }) ?? 0
    }

    func draftNotes(inDecks deckIds: [String]) -> [DraftNote] {
        (try? database.queue.read { try QuestionDrafter.notes(inDecks: deckIds, db: $0) }) ?? []
    }

    /// Whether code and math questions can be written here: a Mac with the
    /// checking tools. The iPhone writes multiple choice and written ones.
    var canCheckCodeAndMath: Bool { hasCodeTools }

    /// Writes draft questions in the background with the usual progress strip
    /// and Stop button; drafts already written are kept on Stop. False when a
    /// run is already going for this course.
    @discardableResult
    func draftQuestions(_ request: QuestionDrafter.Request, courseId: String?) -> Bool {
        lastQuestionDraftRun = nil
        let run = AIActivity(headline: "Writing questions", units: 1, purpose: "question drafts")
        let deckIds = request.deckIds
        return runAIJob(questionDraftJobKey(courseId: courseId), activity: run) { [weak self] run in
            guard let self else { return }
            let generator: any CardGenerator = StubHooks.enabled("GRASP_STUB_QUESTIONS")
                ? StubQuestionGenerator() : await CardGenerators.select()
            let outcome = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await QuestionDrafter.generate(request, using: generator, executor: self.codeExecutor, database: self.database)
            }
            var failure: String?
            if outcome.modelUnreachable {
                failure = "No AI model is reachable right now. Settings has the setup."
            } else if outcome.noNotes {
                failure = "These decks have no notes to write questions from."
            } else if outcome.cannotRun {
                failure = "That kind of question needs a Mac with Xcode's command line tools to check the answers."
            } else if outcome.saved == 0, !run.stopRequested {
                failure = outcome.drops.isEmpty
                    ? "The model didn't write anything usable from these notes."
                    : "None of the questions the model wrote were kept."
            }
            self.lastQuestionDraftRun = QuestionDraftRunResult(deckIds: deckIds, outcome: outcome, failure: failure)
            self.reload()
        }
    }

    /// Approves one draft; returns why it was not approved, or nil.
    @discardableResult
    func approveQuestion(_ id: String) -> String? {
        let why = (try? database.queue.write { try QuestionBank.approve(id, db: $0) }) ?? "It couldn't be saved."
        reload()
        return why
    }

    func approveAllQuestions(inDecks deckIds: [String]) -> QuestionBank.ApproveAllResult {
        let result = (try? database.queue.write { try QuestionBank.approveAll(inDecks: deckIds, db: $0) }) ?? QuestionBank.ApproveAllResult()
        reload()
        return result
    }
}
