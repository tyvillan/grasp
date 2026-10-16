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

    /// Whether the checking tools are installed (compiler and Python).
    var hasCodeTools: Bool {
        guard let executor = codeExecutor else { return false }
        return CodeLanguage.allCases.contains { executor.canRun($0) }
    }

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
}
