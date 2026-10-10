import Foundation
import GRASPCore

/// The saved code questions: counting, reading and deleting them (every
/// device), and writing them (only where code can be run).
extension AppStore {
    /// A way to run code, or nil on a device that can't (the iPhone). A
    /// Mac without developer tools still has one, but `canRun` says no.
    var codeExecutor: (any CodeExecuting)? {
        #if os(macOS)
        return ProcessCodeExecutor()
        #else
        return nil
        #endif
    }

    /// Whether this device can write new practice (it needs a model, and
    /// the Mac's tools to check what the model wrote).
    var canWriteCodeQuestions: Bool { codeExecutor != nil && isGeneratorAvailable }

    /// Whether the checking tools are installed (compiler and Python).
    var hasCodeTools: Bool {
        guard let executor = codeExecutor else { return false }
        return CodeLanguage.allCases.contains { executor.canRun($0) }
    }

    func codeQuestionJobKey(courseId: String?) -> String { "codeQuestions:\(courseId ?? "none")" }

    func codeQuestionCount(inDecks deckIds: [String]) -> Int {
        (try? database.queue.read { try CodeQuestionBank.count(inDecks: deckIds, db: $0) }) ?? 0
    }

    func codeQuestions(inDecks deckIds: [String]) -> [TestQuestion] {
        (try? database.queue.read { try CodeQuestionBank.questions(inDecks: deckIds, db: $0) }) ?? []
    }

    func isCodeQuestionStale(_ question: TestQuestion) -> Bool {
        (try? database.queue.read { try CodeQuestionBank.isStale(question, db: $0) }) ?? false
    }

    func deleteCodeQuestion(_ id: String) {
        try? database.queue.write { try CodeQuestionBank.delete(id, db: $0) }
        reload()
    }

    /// Writes checked practice from these decks in the background, with
    /// the usual progress strip and Stop button. False when one is already
    /// running for this course.
    /// Gives saved fill-in-the-blank questions their multiple-choice version
    /// (wrong options checked by running them). Mac only; once per launch.
    func addMissingChoicesInBackground() {
        guard let executor = codeExecutor, !choiceUpgradeStarted else { return }
        choiceUpgradeStarted = true
        let database = database
        Task.detached(priority: .utility) { [weak self] in
            let changed = await CodeQuestionBank.addMissingChoices(database: database, using: executor)
            if changed > 0 { await MainActor.run { self?.reload() } }
        }
    }

    @discardableResult
    func writePractice(_ request: PracticeBuilder.Request, courseId: String?) -> Bool {
        guard let executor = codeExecutor else { return false }
        lastCodeQuestionRun = nil
        let run = AIActivity(headline: "Writing practice problems", units: 1, purpose: "practice problems")
        return runAIJob(codeQuestionJobKey(courseId: courseId), activity: run) { [weak self] run in
            guard let self else { return }
            let generator = await CardGenerators.select()
            let outcome = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await PracticeBuilder.generate(request, using: generator, executor: executor, database: self.database)
            }
            var failure: String?
            let topReason = outcome.reasons.max { $0.value < $1.value }?.key
            if outcome.cannotRun {
                failure = "This Mac is missing the tools that check the answers. Installing Xcode's command line tools "
                    + "(run xcode-select --install in Terminal) adds them."
            } else if !outcome.notCodeDecks.isEmpty {
                failure = "These decks have no notes to write problems from."
            } else if outcome.saved == 0, !run.stopRequested {
                failure = outcome.rejected > 0
                    ? "The model wrote \(outcome.rejected) problem\(outcome.rejected == 1 ? "" : "s"), but none checked out, so none were kept"
                        + (topReason.map { " (usually: \($0))" } ?? "") + ". Trying again, or a stronger model, usually helps."
                    : "The model didn't write anything usable"
                        + (CloudUsage.shared.lastTransportError.map { ". \($0)" } ?? ". Settings → AI shows which model is in use.")
            }
            self.lastCodeQuestionRun = CodeQuestionRunResult(
                saved: outcome.saved, rejected: outcome.rejected, wasStopped: run.stopRequested, failure: failure,
                topReason: topReason
            )
            self.reload()
        }
    }
}
