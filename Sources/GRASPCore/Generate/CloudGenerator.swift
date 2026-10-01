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

    public init(apiKey: String, model: String, fallingBackTo local: OllamaGenerator? = nil,
                usage: CloudUsage = .shared) {
        let failures = FailureLog()
        let gemini = GeminiTransport(apiKey: apiKey, model: model, usage: usage, failures: failures)
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

    /// Lists the models the key can use: proves the key works without
    /// spending a generation request.
    public static func check(apiKey: String) async -> ConnectionCheck {
        guard !apiKey.isEmpty else { return .badKey }
        do {
            return .ok(models: CloudProvider.chatModels(from: try await GeminiTransport.listModels(apiKey: apiKey)))
        } catch AIBackendError.unauthorized {
            return .badKey
        } catch AIBackendError.quotaExhausted {
            return .quotaUsedUp
        } catch AIBackendError.unreachable {
            return .offline
        } catch AIBackendError.badResponse(let detail) {
            return .failed(detail)
        } catch {
            return .failed(String(describing: error))
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

    public func reviewSection(noteContext: String, section: OverviewSection) async -> [OverviewFix] {
        await run(cloud: { await cloud.reviewSection(noteContext: noteContext, section: section) },
                  local: { await local.reviewSection(noteContext: noteContext, section: section) })
    }

    public func findRepetition(in document: OverviewDocument) async -> OverviewRepetition {
        await run(cloud: { await cloud.findRepetition(in: document) },
                  local: { await local.findRepetition(in: document) })
    }
}
