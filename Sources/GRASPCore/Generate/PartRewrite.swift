import Foundation

/// One readable block of a rewritten study-guide part: a heading, a
/// plain-English explanation, and the code or syntax it is about.
public struct RewrittenBlock: Codable, Sendable, Equatable {
    public var heading: String
    public var explanation: String
    public var code: String?

    public init(heading: String, explanation: String, code: String? = nil) {
        self.heading = heading; self.explanation = explanation; self.code = code
    }
}

extension OllamaGenerator {
    /// Turns a part's raw notes -- often a list of code lines and comments
    /// copied from a handout -- into a few titled blocks that explain what
    /// each is for, keeping the code itself intact.
    public func rewritePart(title: String, subject: String, text: String) async -> [RewrittenBlock] {
        let source = String(text.prefix(3500))
        guard source.count > 40 else { return [] }
        let prompt = """
        These are raw notes from an exam study guide for "\(subject)", from the part titled "\(title)". They were copied \
        from a handout, so they may be a run of code lines, comments and fragments with no explanation.

        Rewrite them so a student can read them: group related lines into at most 8 blocks. Each block has:
        - "heading": a short title (2 to 5 words)
        - "explanation": one or two plain sentences saying what it is and when it matters on the exam
        - "code": the exact code or syntax from the notes that belongs to that block, with line breaks as \\n; omit it \
        or use "" when the block has no code. Do not invent code that is not in the notes.

        Reply with JSON only: {"blocks": [{"heading": "...", "explanation": "...", "code": "..."}]}

        Notes:
        \(source)
        """
        guard let reply = try? await chat(prompt: prompt, maxTokens: 2200),
              let data = Self.salvageJSON(reply).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["blocks"] as? [[String: Any]]
        else { return [] }
        return raw.prefix(8).compactMap { entry in
            guard let heading = (entry["heading"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let explanation = (entry["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !heading.isEmpty, !explanation.isEmpty else { return nil }
            let code = (entry["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RewrittenBlock(heading: PlainMath.clean(heading), explanation: PlainMath.clean(explanation),
                                  code: (code?.isEmpty ?? true) ? nil : code)
        }
    }

    /// Short-answer quiz questions about one part of a study guide.
    public func generateGuideQuestions(context: String, count: Int) async -> [GeneratedTestQuestion] {
        guard count > 0, context.count > 40 else { return [] }
        let prompt = """
        Write \(count) quiz questions that test a student on this part of their exam study guide. Each answer must be \
        short: a term, a value, a line of code, or at most twelve words. Ask about what the material actually says; \
        never add facts it doesn't contain. Vary them: definitions, "what happens when", "which one", reading code.

        Reply with JSON only: {"questions": [{"q": "...", "a": "..."}]}

        Study guide part:
        \(context.prefix(2400))
        """
        guard let reply = try? await chat(prompt: prompt, maxTokens: 900),
              let data = Self.salvageJSON(reply).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["questions"] as? [[String: Any]] else { return [] }
        return raw.prefix(count).compactMap { entry in
            guard let q = (entry["q"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let a = (entry["a"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !q.isEmpty, !a.isEmpty, a.count <= 140 else { return nil }
            return GeneratedTestQuestion(prompt: PlainMath.clean(q), correctAnswer: PlainMath.clean(a))
        }
    }
}
