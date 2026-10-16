import Testing
import Foundation
@testable import GRASP

@Suite("AI action naming")
struct CopyNamingTests {
    /// Card generation is "Generate cards"; "questions" belongs to tests. The
    /// Questions tab's own "Generate questions with AI" is the one place the
    /// phrase is right: it writes questions, not cards.
    @Test("no screen calls card generation 'Generate questions'")
    func noGenerateQuestions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for dir in ["Sources/GRASP", "GRASPiOS/App"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                    .replacingOccurrences(of: "\"Generate questions with AI", with: "")
                for banned in ["\"Generate questions", "\"Generate Questions", "Generating from \\($0)", "Generating from your notes"]
                where text.contains(banned) {
                    offenders.append("\(url.lastPathComponent): \(banned)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("a card-generation failure never says 'questions'")
    func failureMessages() {
        let text = AppStore.message(for: .noSourceNotes)
        #expect(text.contains("new cards"))
        #expect(!text.lowercased().contains("question"))
    }
}

@Suite("Background choice upgrade placement")
struct ChoiceUpgradePlacementTests {
    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var out: [(String, String)] = []
        for dir in ["Sources/GRASP", "GRASPiOS/App"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    @Test("the upgrade starts when the Questions tab opens and nowhere else, never from Test setup")
    func startsOnlyFromQuestionsTab() throws {
        let callers = try sources().filter { $0.text.contains("addMissingChoicesInBackground()") && $0.name != "CodeQuestionStore.swift" }
        #expect(callers.map(\.name) == ["QuestionsTab.swift"])
        let testSetup = try #require(sources().first { $0.name == "TestFlowView.swift" })
        #expect(!testSetup.text.contains("addMissingChoices"))
    }
}
