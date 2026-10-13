import Foundation

/// What a true/false question says above its statement.
///
/// The test builder pairs a card's prompt with either its own answer or
/// another card's, so a prompt that is itself a question -- "Which tool is
/// suggested for…?" -- ended up over a bare statement, which reads as a
/// question with the answer already filled in. The lead-in turns that into
/// a statement the student can call true or false.
enum TrueFalseLeadIn {
    static func text(forPrompt prompt: String) -> String {
        isQuestion(prompt) ? "Is this the right answer?" : "Is this its definition?"
    }

    static func isQuestion(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        let openers = ["which ", "what ", "who ", "whom ", "whose ", "when ", "where ", "why ", "how ",
                       "according to", "name ", "identify ", "describe ", "explain ", "define ", "list "]
        return openers.contains { lower.hasPrefix($0) } || lower.contains(", which ") || lower.contains(", what ")
    }
}
