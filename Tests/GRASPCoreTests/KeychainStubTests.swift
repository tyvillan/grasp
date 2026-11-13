import Foundation
import Testing
import GRDB
@testable import GRASPCore

/// A stand-in compiler where every wrong fill "fails", so a blank question
/// gets its three wrong options.
private struct FailingFillExecutor: CodeExecuting {
    func canRun(_ language: CodeLanguage) -> Bool { true }
    func run(_ source: String, language: CodeLanguage) async -> CodeRunResult {
        source.contains("RIGHT") ? CodeRunResult(compiled: true, stdout: "7\n") : CodeRunResult(compiled: false, stderr: "error")
    }
}

@Suite("Stub runs and the choice upgrade", .serialized)
struct KeychainStubTests {
    #if DEBUG
    @Test("with the stub flag on, no Keychain call is made for reading, saving, deleting or state")
    func stubNeverTouchesKeychain() {
        let before = AIKeyStore.skipsKeychain
        defer { AIKeyStore.skipsKeychain = before }
        AIKeyStore.skipsKeychain = true
        let calls = AIKeyStore.keychainCalls
        #expect(AIKeyStore.read() == nil)
        #expect(AIKeyStore.state() == .missing)
        #expect(AIKeyStore.save("abcdefghijklmnopqrstuvwxyz"))
        AIKeyStore.delete()
        #expect(AIKeyStore.keychainCalls == calls)
    }

    #endif

    @Test("the choice upgrade changes only question rows, nothing else in the library")
    func upgradeOnlyTouchesQuestions() async throws {
        let db = try GRASPDatabase.inMemory()
        var question = CodeQuestion(kind: .codeBlanks, language: .python, prompt: "p",
                                    code: "print([[1]])", blanks: [["RIGHT"]])
        question.expectedOutput = "7"
        let body = question.encoded() ?? ""
        try await db.queue.write { conn in
            let course = Course(semesterId: nil, name: "Systems"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Python"); try deck.insert(conn)
            let card = Card(materialId: nil, front: "F", back: "B", origin: .manual, status: .active); try card.insert(conn)
            try DeckCard(deckId: deck.id, cardId: card.id).insert(conn)
            try TestQuestion(courseId: course.id, deckId: deck.id, kind: .codeBlanks, language: .python,
                             bodyJSON: body, verifiedBy: "test").insert(conn)
        }
        func snapshot() throws -> [String: String] {
            try db.queue.read { conn in
                var out: [String: String] = [:]
                let names = try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                for name in names where name != "testQuestion" && !name.lowercased().contains("sync") && !name.hasPrefix("grdb") {
                    let rows = try Row.fetchAll(conn, sql: "SELECT * FROM \"\(name)\"")
                    out[name] = rows.map { "\($0)" }.sorted().joined(separator: "\n")
                }
                return out
            }
        }
        let before = try snapshot()
        let changed = await CodeQuestionBank.addMissingChoices(database: db, using: FailingFillExecutor())
        #expect(changed == 1)
        let after = try snapshot()
        #expect(after == before)
        let stored = try await db.queue.read { try TestQuestion.fetchAll($0) }
        #expect(stored.count == 1)
        // Tried once: either wrong options were found or an empty list marks it done.
        #expect(stored[0].question?.choices != nil)
    }
}
