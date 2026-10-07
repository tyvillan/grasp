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

    /// Whether this device can write new code questions.
    var canWriteCodeQuestions: Bool {
        guard let executor = codeExecutor else { return false }
        return CodeLanguage.allCases.contains { executor.canRun($0) } && isGeneratorAvailable
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

    /// Writes verified code questions from these decks in the background,
    /// with the usual progress strip and Stop button. False when one is
    /// already running for this course.
    @discardableResult
    func writeCodeQuestions(deckIds: [String], courseId: String?, kinds: [CodeQuestionKind], count: Int) -> Bool {
        guard let executor = codeExecutor else { return false }
        lastCodeQuestionRun = nil
        let run = AIActivity(headline: "Writing code questions", units: 1, purpose: "code questions")
        return runAIJob(codeQuestionJobKey(courseId: courseId), activity: run) { [weak self] run in
            guard let self else { return }
            let generator = await CardGenerators.select()
            let outcome = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await CodeQuestionBuilder.generate(
                    deckIds: deckIds, kinds: kinds, count: count, using: generator,
                    executor: executor, database: self.database
                )
            }
            var failure: String?
            let topReason = outcome.reasons.max { $0.value < $1.value }?.key
            if outcome.cannotRun {
                failure = "This Mac has no compiler for the code in these notes. Installing Xcode's command line tools "
                    + "(run xcode-select --install in Terminal) adds one."
            } else if !outcome.notCodeDecks.isEmpty {
                failure = "These notes don't hold any code to write questions about."
            } else if outcome.saved == 0, !run.stopRequested {
                failure = outcome.rejected > 0
                    ? "The model wrote \(outcome.rejected) question\(outcome.rejected == 1 ? "" : "s"), but none ran correctly, so none were kept"
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
