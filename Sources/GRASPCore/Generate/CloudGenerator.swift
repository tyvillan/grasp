import Foundation

/// Every AI feature on Google Gemini: the same prompts and parsers as
/// `OllamaGenerator` (it runs one on a cloud transport), so the two can't
/// drift apart.
public struct CloudGenerator: CardGenerator {
    public let modelName: String
    /// Set in Automatic when the local model is Ollama: each call that the
    /// cloud can't take goes there instead, so a job switches mid-way.
    public let localModelName: String?
    let pipeline: OllamaGenerator
    let failures: FailureLog
    private let hasKey: Bool

    public init(apiKey: String, model: String, alternates: [String] = [],
                fallingBackTo local: OllamaGenerator? = nil, usage: CloudUsage = .shared) {
        let failures = FailureLog()
        let gemini = GeminiTransport(apiKey: apiKey, model: model, usage: usage, failures: failures,
                                     alternates: alternates)
        let transport: any ChatTransport = local.map {
            FallbackTransport(primary: gemini, secondary: OllamaTransport(baseURL: $0.serverURL, model: $0.modelName),
                              secondaryName: $0.modelName, usage: usage)
        } ?? gemini
        // Gemini reads far more than a local model, so a lecture is one
        // piece -- fewer calls against the free limit. With Ollama behind it,
        // a piece must still fit Ollama's 8K context if a call lands there.
        let budget = local == nil ? 6_000 : 3_000
        self.init(model: model, localModelName: local?.modelName, hasKey: !apiKey.isEmpty, failures: failures,
                  pipeline: OllamaGenerator(transport: transport, model: model, wordBudget: budget))
    }

    init(model: String, localModelName: String?, hasKey: Bool, failures: FailureLog, pipeline: OllamaGenerator) {
        self.modelName = model
        self.localModelName = localModelName
        self.hasKey = hasKey
        self.failures = failures
        self.pipeline = pipeline
    }

    /// Whether a key is set. Not a live check: that would spend a request
    /// from the free allowance every time a screen asked.
    public var isAvailable: Bool { get async { hasKey } }

    public var overviewContextWordBudget: Int { pipeline.overviewContextWordBudget }

    public func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        await pipeline.refine(candidates, noteContext: noteContext)
    }

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        await pipeline.distractors(for: correctAnswer, deckContext: deckContext, count: count)
    }

    public func generateAdditional(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
    ) async -> [GeneratedCard] {
        await pipeline.generateAdditional(existing: existing, noteContext: noteContext, maxCount: maxCount, topic: topic)
    }

    public func generateTestQuestions(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) async -> [GeneratedTestQuestion] {
        await pipeline.generateTestQuestions(existing: existing, noteContext: noteContext, maxCount: maxCount)
    }

    public func validateContext(
        front: String, back: String, noteContext: String, courseName: String
    ) async -> ContextValidation {
        await pipeline.validateContext(front: front, back: back, noteContext: noteContext, courseName: courseName)
    }

    public func generateOverview(
        noteTitle: String, courseName: String, noteContext: String,
        includeFormulas: Bool, partLabel: String?
    ) async -> GeneratedOverview {
        await pipeline.generateOverview(
            noteTitle: noteTitle, courseName: courseName, noteContext: noteContext,
            includeFormulas: includeFormulas, partLabel: partLabel
        )
    }

    public func generateFigures(
        noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]
    ) async -> [GeneratedFigure] {
        await pipeline.generateFigures(
            noteTitle: noteTitle, courseName: courseName, noteContext: noteContext, sectionHeadings: sectionHeadings
        )
    }

    public func generateStudyGuidePart(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String], problemCount: Int
    ) async -> GeneratedGuidePart {
        await pipeline.generateStudyGuidePart(
            deckName: deckName, courseName: courseName, noteContext: noteContext,
            cardTerms: cardTerms, problemCount: problemCount
        )
    }

    public func generateCodeQuestions(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        language: CodeLanguage, kinds: [CodeQuestionKind], count: Int
    ) async -> [GeneratedCodeQuestion] {
        await pipeline.generateCodeQuestions(
            deckName: deckName, courseName: courseName, noteContext: noteContext, cardTerms: cardTerms,
            language: language, kinds: kinds, count: count
        )
    }

    public func generateProblems(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        subject: ProblemSubject, kinds: [ProblemKind], count: Int
    ) async -> [GeneratedProblem] {
        await pipeline.generateProblems(
            deckName: deckName, courseName: courseName, noteContext: noteContext, cardTerms: cardTerms,
            subject: subject, kinds: kinds, count: count
        )
    }

    public func solveMultipleChoice(prompt: String, choices: [String]) async -> Int? {
        await pipeline.solveMultipleChoice(prompt: prompt, choices: choices)
    }

    public func explainSkill(_ skill: String, subject: String, context: String) async -> String? {
        await pipeline.explainSkill(skill, subject: subject, context: context)
    }

    public func explainSkills(_ skills: [String], subject: String, context: String) async -> [String: String] {
        await pipeline.explainSkills(skills, subject: subject, context: context)
    }

    public func rewritePart(title: String, subject: String, text: String) async -> [RewrittenBlock] {
        await pipeline.rewritePart(title: title, subject: subject, text: text)
    }

    public func reviewSection(noteContext: String, section: OverviewSection) async -> [OverviewFix] {
        await pipeline.reviewSection(noteContext: noteContext, section: section)
    }

    public func findRepetition(in document: OverviewDocument) async -> OverviewRepetition {
        await pipeline.findRepetition(in: document)
    }

    public enum ConnectionCheck: Equatable, Sendable {
        case ok(models: [String])
        case badKey
        case quotaUsedUp
        case offline
        case failed(String)
    }

    public struct ConnectionReport: Sendable {
        public var status: ConnectionCheck
        /// The key's usable models, best first -- kept even when the check
        /// failed, so the model picker still works.
        public var models: [String]
    }

    /// Proves the key works and that a model it can use actually answers:
    /// lists the models (free), then sends one tiny generation request,
    /// moving on to the next model if one is overloaded. Listing alone said
    /// "Connected" for a model that then refused every real request.
    public static func check(apiKey: String) async -> ConnectionReport {
        guard !apiKey.isEmpty else { return ConnectionReport(status: .badKey, models: []) }
        let models: [String]
        do {
            models = CloudProvider.chatModels(from: try await GeminiTransport.listModels(apiKey: apiKey))
        } catch AIBackendError.unauthorized {
            return ConnectionReport(status: .badKey, models: [])
        } catch AIBackendError.quotaExhausted {
            return ConnectionReport(status: .quotaUsedUp, models: [])
        } catch AIBackendError.unreachable {
            return ConnectionReport(status: .offline, models: [])
        } catch AIBackendError.overloaded(let status) {
            return ConnectionReport(status: .failed("Google isn't answering right now (HTTP \(status)). Try again in a few minutes."), models: [])
        } catch AIBackendError.badResponse(let detail) {
            return ConnectionReport(status: .failed(detail), models: [])
        } catch {
            return ConnectionReport(status: .failed(String(describing: error)), models: [])
        }

        let pinned = AIPreferences.cloudModel
        let primary = pinned.isEmpty ? (models.first ?? CloudProvider.fallbackModel) : pinned
        let rest = pinned.isEmpty ? AIPreferences.alternates(from: models, besides: primary) : []
        do {
            // One call walks the list the way a real request does, without
            // waiting on a busy model.
            _ = try await GeminiTransport(apiKey: apiKey, model: primary, alternates: rest, overloadPauses: [])
                .complete(prompt: "Reply with exactly this JSON and nothing else: {\"ok\": true}", json: true, maxTokens: 20)
            return ConnectionReport(status: .ok(models: models), models: models)
        } catch AIBackendError.unauthorized {
            return ConnectionReport(status: .badKey, models: models)
        } catch AIBackendError.quotaExhausted {
            return ConnectionReport(status: .quotaUsedUp, models: models)
        } catch AIBackendError.rateLimited {
            // The key is fine; Google is just busy this minute.
            return ConnectionReport(status: .ok(models: models), models: models)
        } catch AIBackendError.unreachable {
            return ConnectionReport(status: .offline, models: models)
        } catch AIBackendError.overloaded {
            return ConnectionReport(
                status: .failed(CloudUsage.shared.lastTransportError
                                ?? "Google's models are overloaded right now. Try again in a few minutes."),
                models: models)
        } catch AIBackendError.badResponse(let detail) {
            return ConnectionReport(status: .failed("\(primary): \(GeminiTransport.summarize(detail))"), models: models)
        } catch {
            return ConnectionReport(status: .failed(String(describing: error)), models: models)
        }
    }
}

/// Automatic with Ollama behind it: each call goes to the cloud unless the
/// cloud can't take it, then to Ollama. Switching per call means a job that
/// hits the limit halfway finishes locally instead of starting over.
struct FallbackTransport: ChatTransport {
    let primary: GeminiTransport
    let secondary: any ChatTransport
    let secondaryName: String
    let usage: CloudUsage

    func complete(prompt: String, json: Bool, maxTokens: Int?) async throws -> String {
        if usage.pausedUntil == nil {
            do {
                let answer = try await primary.complete(prompt: prompt, json: json, maxTokens: maxTokens)
                if AIProgress.current?.snapshot.note != nil { AIProgress.current?.setNote(nil) }
                return answer
            } catch let error as AIBackendError where error.warrantsFallback {
                let message = FallbackMessage.text(for: error, local: secondaryName)
                usage.recordFallback(message)
                AIProgress.current?.setNote(message)
            }
        } else {
            AIProgress.current?.setNote(FallbackMessage.text(for: .quotaExhausted, local: secondaryName))
        }
        return try await secondary.complete(prompt: prompt, json: json, maxTokens: maxTokens)
    }
}

enum FallbackMessage {
    static func text(for error: AIBackendError, local: String) -> String {
        switch error {
        case .quotaExhausted:
            return "Gemini's free limit for today is used up, so this is running on \(local)."
        case .rateLimited:
            return "Gemini is busy right now, so this is running on \(local)."
        case .unreachable:
            return "Gemini can't be reached, so this is running on \(local)."
        case .overloaded:
            return "Gemini is overloaded right now, so this is running on \(local)."
        case .unauthorized, .badResponse:
            return "Running on \(local)."
        }
    }
}

/// Automatic when the local model isn't Ollama (Apple's on-device model, on
/// an iPhone): a call the cloud couldn't finish runs again, whole, locally.
public struct FallbackGenerator: CardGenerator {
    public let cloud: CloudGenerator
    public let local: any CardGenerator
    let localName: String
    let usage: CloudUsage

    public init(cloud: CloudGenerator, local: any CardGenerator, localName: String, usage: CloudUsage = .shared) {
        self.cloud = cloud
        self.local = local
        self.localName = localName
        self.usage = usage
    }

    public var isAvailable: Bool {
        get async {
            if await cloud.isAvailable { return true }
            return await local.isAvailable
        }
    }

    /// The local model's budget: a call that falls back must fit there too.
    public var overviewContextWordBudget: Int { local.overviewContextWordBudget }

    /// Runs on the cloud, then again locally if a cloud call failed in a way
    /// the cloud won't fix by itself. `keep` lets a partly written result
    /// stand rather than being thrown away for a weaker model's version.
    private func run<T>(
        keep: (T) -> Bool = { _ in false },
        cloud cloudCall: () async -> T,
        local localCall: () async -> T
    ) async -> T {
        if usage.pausedUntil != nil {
            AIProgress.current?.setNote(FallbackMessage.text(for: .quotaExhausted, local: localName))
            return await localCall()
        }
        cloud.failures.reset()
        let result = await cloudCall()
        guard let error = cloud.failures.lastError, error.warrantsFallback, !keep(result) else { return result }
        let message = FallbackMessage.text(for: error, local: localName)
        usage.recordFallback(message)
        AIProgress.current?.setNote(message)
        return await localCall()
    }

    public func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        await run(cloud: { await cloud.refine(candidates, noteContext: noteContext) },
                  local: { await local.refine(candidates, noteContext: noteContext) })
    }

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        await run(cloud: { await cloud.distractors(for: correctAnswer, deckContext: deckContext, count: count) },
                  local: { await local.distractors(for: correctAnswer, deckContext: deckContext, count: count) })
    }

    public func generateAdditional(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
    ) async -> [GeneratedCard] {
        await run(
            cloud: { await cloud.generateAdditional(existing: existing, noteContext: noteContext, maxCount: maxCount, topic: topic) },
            local: { await local.generateAdditional(existing: existing, noteContext: noteContext, maxCount: maxCount, topic: topic) }
        )
    }

    public func generateTestQuestions(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) async -> [GeneratedTestQuestion] {
        await run(
            cloud: { await cloud.generateTestQuestions(existing: existing, noteContext: noteContext, maxCount: maxCount) },
            local: { await local.generateTestQuestions(existing: existing, noteContext: noteContext, maxCount: maxCount) }
        )
    }

    public func validateContext(
        front: String, back: String, noteContext: String, courseName: String
    ) async -> ContextValidation {
        await run(
            cloud: { await cloud.validateContext(front: front, back: back, noteContext: noteContext, courseName: courseName) },
            local: { await local.validateContext(front: front, back: back, noteContext: noteContext, courseName: courseName) }
        )
    }

    public func generateOverview(
        noteTitle: String, courseName: String, noteContext: String,
        includeFormulas: Bool, partLabel: String?
    ) async -> GeneratedOverview {
        await run(
            keep: { !$0.document.sections.isEmpty },
            cloud: {
                await cloud.generateOverview(noteTitle: noteTitle, courseName: courseName, noteContext: noteContext,
                                             includeFormulas: includeFormulas, partLabel: partLabel)
            },
            local: {
                await local.generateOverview(noteTitle: noteTitle, courseName: courseName, noteContext: noteContext,
                                             includeFormulas: includeFormulas, partLabel: partLabel)
            }
        )
    }

    public func generateFigures(
        noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]
    ) async -> [GeneratedFigure] {
        await run(
            cloud: {
                await cloud.generateFigures(noteTitle: noteTitle, courseName: courseName, noteContext: noteContext,
                                            sectionHeadings: sectionHeadings)
            },
            local: {
                await local.generateFigures(noteTitle: noteTitle, courseName: courseName, noteContext: noteContext,
                                            sectionHeadings: sectionHeadings)
            }
        )
    }

    public func generateStudyGuidePart(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String], problemCount: Int
    ) async -> GeneratedGuidePart {
        await run(
            keep: { $0.part != nil },
            cloud: {
                await cloud.generateStudyGuidePart(deckName: deckName, courseName: courseName, noteContext: noteContext,
                                                   cardTerms: cardTerms, problemCount: problemCount)
            },
            local: {
                await local.generateStudyGuidePart(deckName: deckName, courseName: courseName, noteContext: noteContext,
                                                   cardTerms: cardTerms, problemCount: problemCount)
            }
        )
    }

    public func generateCodeQuestions(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        language: CodeLanguage, kinds: [CodeQuestionKind], count: Int
    ) async -> [GeneratedCodeQuestion] {
        await run(
            keep: { !$0.isEmpty },
            cloud: {
                await cloud.generateCodeQuestions(deckName: deckName, courseName: courseName, noteContext: noteContext,
                                                  cardTerms: cardTerms, language: language, kinds: kinds, count: count)
            },
            local: {
                await local.generateCodeQuestions(deckName: deckName, courseName: courseName, noteContext: noteContext,
                                                  cardTerms: cardTerms, language: language, kinds: kinds, count: count)
            }
        )
    }

    public func generateProblems(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String],
        subject: ProblemSubject, kinds: [ProblemKind], count: Int
    ) async -> [GeneratedProblem] {
        await run(
            keep: { !$0.isEmpty },
            cloud: {
                await cloud.generateProblems(deckName: deckName, courseName: courseName, noteContext: noteContext,
                                             cardTerms: cardTerms, subject: subject, kinds: kinds, count: count)
            },
            local: {
                await local.generateProblems(deckName: deckName, courseName: courseName, noteContext: noteContext,
                                             cardTerms: cardTerms, subject: subject, kinds: kinds, count: count)
            }
        )
    }

    public func solveMultipleChoice(prompt: String, choices: [String]) async -> Int? {
        await run(keep: { $0 != nil },
                  cloud: { await cloud.solveMultipleChoice(prompt: prompt, choices: choices) },
                  local: { await local.solveMultipleChoice(prompt: prompt, choices: choices) })
    }

    public func explainSkill(_ skill: String, subject: String, context: String) async -> String? {
        await run(keep: { $0 != nil },
                  cloud: { await cloud.explainSkill(skill, subject: subject, context: context) },
                  local: { await local.explainSkill(skill, subject: subject, context: context) })
    }

    public func explainSkills(_ skills: [String], subject: String, context: String) async -> [String: String] {
        await run(keep: { !$0.isEmpty },
                  cloud: { await cloud.explainSkills(skills, subject: subject, context: context) },
                  local: { await local.explainSkills(skills, subject: subject, context: context) })
    }

    public func rewritePart(title: String, subject: String, text: String) async -> [RewrittenBlock] {
        await run(keep: { !$0.isEmpty },
                  cloud: { await cloud.rewritePart(title: title, subject: subject, text: text) },
                  local: { await local.rewritePart(title: title, subject: subject, text: text) })
    }

    public func reviewSection(noteContext: String, section: OverviewSection) async -> [OverviewFix] {
        await run(cloud: { await cloud.reviewSection(noteContext: noteContext, section: section) },
                  local: { await local.reviewSection(noteContext: noteContext, section: section) })
    }

    public func findRepetition(in document: OverviewDocument) async -> OverviewRepetition {
        await run(cloud: { await cloud.findRepetition(in: document) },
                  local: { await local.findRepetition(in: document) })
    }
}
