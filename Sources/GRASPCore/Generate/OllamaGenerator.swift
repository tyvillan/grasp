import Foundation
#if canImport(FoundationNetworking)
// URLSession lives here off Apple platforms.
import FoundationNetworking
#endif

/// Talks to a local Ollama server (`127.0.0.1:11434`) for card refinement
/// and distractor generation. Ollama isn't installed on the machine this
/// was built on, so this is written against the documented REST API and
/// verified only by what's actually testable without a server: prompt
/// construction, response parsing, and graceful unavailability. Every
/// failure mode (server not running, model not pulled, malformed JSON
/// back) falls back to returning the input untouched rather than
/// throwing -- callers never need a special case for "Ollama isn't set
/// up," which is the whole point of it being optional.
public struct OllamaGenerator: CardGenerator {
    private let baseURL: URL
    private let model: String
    private let session: URLSession

    /// Exposed so a stored overview can record which model wrote it.
    public var modelName: String { model }

    /// Most lectures run 900-1,700 words. At the default 1,200 -- and 900
    /// once LaTeX shrinks it -- they were cut in two, and each piece paid
    /// for its own plan, sections, figures and diagram: fourteen-odd calls
    /// and eight minutes for a 950-word note. At 1,800 (1,350 with math) a
    /// lecture is one piece, about half the calls. It fits: 1,800 words is
    /// roughly 2,500 tokens, plus instructions and the answer, well inside
    /// `contextTokens`.
    public var overviewContextWordBudget: Int { 1_800 }

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String = "qwen2.5:7b-instruct"
    ) {
        self.baseURL = baseURL
        self.model = model
        // Every request here sets `stream: false`, so Ollama holds the
        // entire response until generation is completely done and then
        // sends it as one burst -- there is no incremental data to reset a
        // "waiting for more" timer against. That makes
        // `timeoutIntervalForRequest` (URLSession's "no new bytes for this
        // long" timeout, which is what actually fires here, not the
        // resource ceiling below) behave as a hard deadline on the whole
        // call, not an idle timeout. Measured against a real local server:
        // a small prompt answers in well under a second, but a full
        // overview -- structured, multi-section, asked of a 7B model --
        // took 34 seconds before a single byte arrived. A short value here
        // (this was 4) aborts every real generation a few seconds in, and
        // `try?` swallows the resulting error silently -- indistinguishable
        // from the outside from the model having nothing to say. Both
        // timeouts are set to the same generous ceiling for that reason --
        // five minutes, because a full lesson (several sections, each with
        // terms and a check) is a much longer answer than the overview
        // that 34-second measurement was taken against.
        self.session = Self.sharedSession
    }

    /// One session for every generator. A generator is made per AI action
    /// -- often several -- and each used to open its own session, never
    /// invalidated, so they piled up over a long sitting.
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    public var isAvailable: Bool {
        get async {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
            request.timeoutInterval = 2
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return false }
            return http.statusCode == 200
        }
    }

    private struct TagsResponse: Decodable {
        let models: [ModelEntry]
        struct ModelEntry: Decodable { let name: String }
    }

    /// The model names actually pulled on this server, for Settings'
    /// status section -- an empty array (never a thrown error) whether
    /// that's because the server is unreachable, in the 2-second budget
    /// every check in this type keeps, or reachable but genuinely bare.
    public func installedModels() async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return [] }
        return decoded.models.map(\.name)
    }

    /// Candidates are batched (per the design, ~15 at a time) so a single
    /// request/response stays small enough for a 7-8B local model to
    /// handle reliably; batches run sequentially to stay polite to a
    /// single local server with no concurrency budget of its own.
    private static let batchSize = 15

    public func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        guard !candidates.isEmpty else { return [] }
        var results: [GeneratedCard] = []
        for batch in stride(from: 0, to: candidates.count, by: Self.batchSize) {
            let slice = Array(candidates[batch..<min(batch + Self.batchSize, candidates.count)])
            let refined = await refineBatch(slice, noteContext: noteContext)
            // A failed batch passes its cards through untouched -- the
            // protocol's fail-soft contract -- so the other batches of the
            // same note still count. The caller skips writing anything that
            // came back unchanged.
            results += refined.isEmpty
                ? slice.map { GeneratedCard(front: $0.front, back: $0.back) }
                : refined
        }
        return results
    }

    private func refineBatch(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
        // Nothing back on failure, not the originals: the caller can't tell
        // an unchanged original from a refined card, and used to save every
        // failed batch as "refined by AI".
        let prompt = Self.refinePrompt(candidates: candidates, noteContext: noteContext)
        guard let content = try? await chat(prompt: prompt),
              let decoded = Self.decodeList(RefinedPairDTO.self, from: content),
              decoded.count == candidates.count
        else { return [] }
        return decoded.map { GeneratedCard(front: $0.front, back: $0.back) }
    }

    public func generateAdditional(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?
    ) async -> [GeneratedCard] {
        guard maxCount > 0, !noteContext.isEmpty else { return [] }
        let prompt = Self.generateAdditionalPrompt(
            existing: existing, noteContext: noteContext, maxCount: maxCount, topic: topic
        )
        guard let content = try? await chat(prompt: prompt),
              let decoded = Self.decodeList(RefinedPairDTO.self, from: content)
        else { return [] }
        return Array(decoded.prefix(maxCount)).map { GeneratedCard(front: $0.front, back: $0.back) }
    }

    public func generateTestQuestions(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) async -> [GeneratedTestQuestion] {
        guard maxCount > 0, !noteContext.isEmpty else { return [] }
        let prompt = Self.generateTestQuestionsPrompt(existing: existing, noteContext: noteContext, maxCount: maxCount)
        guard let content = try? await chat(prompt: prompt),
              let decoded = Self.decodeList(TestQuestionDTO.self, from: content)
        else { return [] }
        return Array(decoded.prefix(maxCount)).map { GeneratedTestQuestion(prompt: $0.prompt, correctAnswer: $0.answer) }
    }

    public func validateContext(
        front: String, back: String, noteContext: String, courseName: String
    ) async -> ContextValidation {
        guard !noteContext.isEmpty else { return ContextValidation(.valid) }
        let prompt = Self.validateContextPrompt(front: front, back: back, noteContext: noteContext, courseName: courseName)
        guard let content = try? await chat(prompt: prompt),
              let data = Self.salvageJSON(content).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ContextValidationDTO.self, from: data)
        else { return ContextValidation(.valid) }
        switch decoded.verdict.lowercased() {
        case "refine":
            guard let refined = decoded.refinedBack?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !refined.isEmpty
            else { return ContextValidation(.valid) }
            return ContextValidation(.refine(newBack: refined))
        case "reject":
            return ContextValidation(.reject)
        default:
            return ContextValidation(.valid)
        }
    }

    public func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] {
        let fallback = Array(deckContext.filter { $0 != correctAnswer }.shuffled().prefix(count))
        guard !deckContext.isEmpty else { return fallback }
        let prompt = Self.distractorPrompt(correctAnswer: correctAnswer, deckContext: deckContext, count: count)
        guard let content = try? await chat(prompt: prompt),
              let decoded = Self.decodeList(String.self, from: content),
              !decoded.isEmpty
        else { return fallback }
        return Array(decoded.prefix(count))
    }

    /// Plans the lesson, then writes it one section at a time.
    ///
    /// Measured against a real lecture note, a single prompt asking for the
    /// whole lesson at once produced three one-sentence sections with topic
    /// headings -- and skipped five of the note's eight parts. A 7B asked
    /// for everything at once satisfies the JSON shape and quietly drops
    /// the harder instructions. Splitting it gives each call one job: the
    /// plan call decides *what* the lesson teaches, in order, stated as
    /// claims; each section call only has to teach one claim well. More
    /// calls, but each one is short, and the result is the difference
    /// between an outline and a lesson.
    ///
    /// Falls back to the single-shot prompt if the plan comes back unusable,
    /// so a model that struggles with the two-stage shape still produces
    /// something.
    public func generateOverview(
        noteTitle: String, courseName: String, noteContext: String,
        includeFormulas: Bool, partLabel: String?
    ) async -> GeneratedOverview {
        guard !noteContext.isEmpty else { return .empty }
        // The composer budgets one plan call plus an assumed number of
        // sections; this corrects that as soon as the real number is known.
        let progress = AIProgress.current
        let assumed = OverviewComposer.assumedSectionsPerPart

        let planPrompt = Self.lessonPlanPrompt(
            noteTitle: noteTitle, courseName: courseName, noteContext: noteContext,
            includeFormulas: includeFormulas, partLabel: partLabel
        )
        // One retry before giving up on the plan. The same prompt on the
        // same note parses cleanly most of the time and occasionally
        // doesn't; the fallback below is both slower and worse, so a second
        // 40-second try is the cheaper way out.
        var plan: LessonPlan?
        for attempt in 0..<2 where plan == nil {
            if Task.isCancelled { return .empty }
            if attempt > 0 { progress?.expect(1) }
            progress?.begin("Planning the lesson")
            let response = try? await chat(prompt: planPrompt, maxTokens: 900)
            progress?.advance()
            if let response {
                let parsed = Self.parseLessonPlan(response)
                if !parsed.sections.isEmpty { plan = parsed }
            }
        }
        if let plan {
            progress?.expect(plan.sections.count - assumed)
            var sections: [OverviewSection] = []
            for (index, planned) in plan.sections.enumerated() {
                // Cancellation throws out of the request in flight, but
                // `try?` below would then just move on to the next
                // section -- so the loop checks for itself.
                if Task.isCancelled { return .empty }
                let prompt = Self.sectionPrompt(
                    courseName: courseName, noteContext: noteContext,
                    heading: planned.heading, covers: planned.covers,
                    lessonHeadings: plan.sections.map(\.heading)
                )
                progress?.begin("Writing section \(index + 1) of \(plan.sections.count)")
                // Room for a worked example, its pictures and is/isn't pairs
                // on top of the paragraphs -- 1,000 cut the example off
                // mid-JSON.
                let response = try? await chat(prompt: prompt, maxTokens: 1_800)
                progress?.advance()
                guard let response,
                      let section = Self.parseSectionResponse(response, heading: planned.heading)
                else { continue }
                sections.append(section)
            }
            if !sections.isEmpty {
                var document = plan.document
                document.sections = sections
                return GeneratedOverview(document: document)
            }
            // Every section failed: the fallback below is one more call.
            progress?.expect(1)
        } else {
            progress?.expect(1 - assumed)
        }

        if Task.isCancelled { return .empty }
        progress?.begin("Writing the lesson")
        defer { progress?.advance() }
        // Capped too: this is the call that, uncapped, once wrote
        // over 3,000 tokens and ran into the five-minute timeout.
        let prompt = Self.overviewPrompt(
            noteTitle: noteTitle, courseName: courseName, noteContext: noteContext,
            includeFormulas: includeFormulas, partLabel: partLabel
        )
        guard let content = try? await chat(prompt: prompt, maxTokens: 2_000) else { return .empty }
        return GeneratedOverview(document: Self.parseOverviewResponse(content))
    }

    public func generateDiagram(
        noteTitle: String, courseName: String, conceptOutline: String
    ) async -> String {
        guard !conceptOutline.isEmpty else { return "" }
        let prompt = Self.diagramPrompt(
            noteTitle: noteTitle, courseName: courseName, conceptOutline: conceptOutline
        )
        guard let content = try? await chat(prompt: prompt, json: false, maxTokens: 600) else { return "" }
        return Self.salvageMermaid(content)
    }

    public func reviewSection(noteContext: String, section: OverviewSection) async -> [OverviewFix] {
        guard !noteContext.isEmpty, !section.paragraphs.isEmpty else { return [] }
        let prompt = Self.reviewPrompt(noteContext: noteContext, section: section)
        guard let content = try? await chat(prompt: prompt, maxTokens: 700),
              let data = Self.salvageJSON(content).data(using: .utf8),
              let dto = try? JSONDecoder().decode(ReviewDTO.self, from: data)
        else { return [] }
        return (dto.items ?? []).compactMap { item in
            guard let original = Self.clean(item.original) else { return nil }
            return OverviewFix(original: original, corrected: Self.clean(item.corrected))
        }
    }

    public func findRepetition(in document: OverviewDocument) async -> OverviewRepetition {
        guard document.sections.count > 2 else { return .none }
        let prompt = Self.repetitionPrompt(document: document)
        guard let content = try? await chat(prompt: prompt, maxTokens: 300),
              let data = Self.salvageJSON(content).data(using: .utf8),
              let dto = try? JSONDecoder().decode(RepetitionDTO.self, from: data)
        else { return .none }
        // The prompt numbers from 1, the way a person reads a list. Only
        // "most" counts as a repeat; "some" overlap is ordinary in a lesson
        // that builds one idea on the last.
        let sections = (dto.overlaps ?? []).compactMap { entry -> (repeated: Int, original: Int)? in
            guard let section = entry.section, let closest = entry.closest,
                  entry.repeats?.lowercased() == "most" else { return nil }
            return (section - 1, closest - 1)
        }
        // Its takeaway verdicts aren't used: on a real lesson it marked three
        // of four distinct takeaways as repeats. The deterministic
        // near-duplicate check in `OverviewReview.cleaned` handles those.
        return OverviewRepetition(sections: sections, takeaways: [])
    }

    private struct ReviewDTO: Decodable {
        let items: [Item]?
        struct Item: Decodable {
            let original: String?
            let corrected: String?
        }
    }

    private struct RepetitionDTO: Decodable {
        let overlaps: [Overlap]?
        let takeaways: [Int]?
        struct Overlap: Decodable {
            let section: Int?
            let closest: Int?
            let repeats: String?
        }
    }

    public func generateFigures(
        noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]
    ) async -> [GeneratedFigure] {
        guard !noteContext.isEmpty, !sectionHeadings.isEmpty else { return [] }
        let prompt = Self.figuresPrompt(
            noteTitle: noteTitle, courseName: courseName,
            noteContext: noteContext, sectionHeadings: sectionHeadings
        )
        guard let content = try? await chat(prompt: prompt, maxTokens: 500) else { return [] }
        return Self.parseFiguresResponse(content, sectionCount: sectionHeadings.count)
    }

    // MARK: - HTTP

    private struct RefinedPairDTO: Decodable {
        let front: String
        let back: String
    }

    /// Every field optional, unlike `RefinedPairDTO`. A pair missing one of
    /// its two keys is worthless, so requiring both there is right. Here a
    /// missing `takeaways` key must not cost the sections -- one absent part
    /// is a thinner lesson, not a failed one.
    private struct OverviewDTO: Decodable {
        let title: String?
        let hook: String?
        let objectives: [String]?
        let sections: [SectionDTO]?
        let takeaways: [String]?
        let formulas: [FormulaDTO]?

        struct SectionDTO: Decodable {
            let heading: String?
            let paragraphs: [String]?
            let terms: [DefinitionDTO]?
            let check: CheckDTO?
        }

        struct DefinitionDTO: Decodable {
            let term: String?
            let definition: String?
            let example: String?
            let nonExample: String?
        }

        struct ExampleDTO: Decodable {
            let title: String?
            let setup: String?
            let steps: [StepDTO]?
            let outcome: String?

            struct StepDTO: Decodable {
                let action: String?
                let result: String?
                let why: String?
                let label: String?
                let visual: VisualDTO?
            }

            /// Every field optional, and `rows` forgiving of numbers written
            /// as numbers: a model asked for a grid of strings writes
            /// `[[1, 2], [3, 4]]` as often as `[["1", "2"], ...]`.
            struct VisualDTO: Decodable {
                let kind: String?
                let caption: String?
                let rows: [[FlexibleString]]?
                let bar: Int?
                let highlightRows: [Int]?
                let highlightColumns: [Int]?
                let vectors: [VectorDTO]?
                let combine: Bool?
                let nodes: [String]?
                let highlight: Int?
            }

            struct VectorDTO: Decodable {
                let label: String?
                let x: Double?
                let y: Double?
                let weight: Double?
            }

            struct FlexibleString: Decodable {
                let value: String
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let string = try? container.decode(String.self) { value = string }
                    else if let int = try? container.decode(Int.self) { value = String(int) }
                    else { value = OverviewFigures.format(try container.decode(Double.self)).replacingOccurrences(of: "−", with: "-") }
                }
            }
        }

        struct CheckDTO: Decodable {
            let question: String?
            let answer: String?
        }

        struct FormulaDTO: Decodable {
            let name: String?
            let latex: String?
            let plain: String?
            let meaning: String?
        }
    }

    private struct FiguresDTO: Decodable {
        let figures: [FigureDTO]?

        struct FigureDTO: Decodable {
            let section: LenientNumber?
            let kind: String?
            let caption: String?
            let equations: [[LenientNumber]]?
            let steps: [StepDTO]?
            let matrix: [[LenientNumber]]?
        }

        struct StepDTO: Decodable {
            let op: String?
            let target: LenientNumber?
            let source: LenientNumber?
            let multiplier: LenientNumber?
        }
    }

    /// A number however a model chose to write it. Row reduction is full of
    /// fractions, and a 7B writing JSON will put `-1/9` in quotes, write a
    /// Unicode minus, or emit an integer where a double was asked for --
    /// each of which a plain `Double` decode rejects, taking the whole
    /// figure with it.
    struct LenientNumber: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = Self.parse(text)
            } else {
                value = nil
            }
        }

        static func parse(_ text: String) -> Double? {
            let cleaned = text
                .replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: " ", with: "")
            if let direct = Double(cleaned) { return direct }
            let parts = cleaned.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]), denominator != 0
            else { return nil }
            return numerator / denominator
        }
    }

    /// Salvage, decode and normalise one overview response. Internal so a
    /// test can drive the whole tolerance path -- fences, preambles,
    /// missing sections, newlines the model slipped in -- against real
    /// response text, without needing a server.
    static func parseOverviewResponse(_ raw: String) -> OverviewDocument {
        guard let data = salvageJSON(raw).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OverviewDTO.self, from: data)
        else { return .empty }
        return document(from: decoded)
    }

    /// Normalisation rather than decoding: drops entries missing their one
    /// required field, trims, collapses any newline the model slipped in
    /// despite being asked not to, and caps each section. The caps are the
    /// same "one chatty response must not flood the view" guard
    /// `generateAdditionalCards` applies with `maxPerNote`.
    private static func document(from dto: OverviewDTO) -> OverviewDocument {
        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let collapsed = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? nil : collapsed
        }

        let sections = (dto.sections ?? []).compactMap { entry -> OverviewSection? in
            let paragraphs = (entry.paragraphs ?? []).compactMap(clean)
                .prefix(OverviewLimits.paragraphsPerSection)
            // A heading with nothing under it isn't a section, and neither
            // is prose with no heading to hang it on.
            guard let heading = clean(entry.heading), !paragraphs.isEmpty else { return nil }
            let terms = (entry.terms ?? []).compactMap { term -> OverviewDefinition? in
                guard let name = clean(term.term), let text = clean(term.definition) else { return nil }
                return OverviewDefinition(term: name, text: text)
            }.prefix(OverviewLimits.termsPerSection)
            // A question with no answer is dropped rather than shown bare:
            // the whole point of the reveal is being able to check yourself.
            let check = entry.check.flatMap { check -> OverviewCheck? in
                guard let question = clean(check.question), let answer = clean(check.answer)
                else { return nil }
                return OverviewCheck(question: question, answer: answer)
            }
            return OverviewSection(
                heading: heading, paragraphs: Array(paragraphs), terms: Array(terms), check: check
            )
        }.prefix(OverviewLimits.sections)

        let formulas = (dto.formulas ?? []).compactMap { entry -> OverviewFormula? in
            guard let name = clean(entry.name) else { return nil }
            let latex = clean(entry.latex)
            // A formula with neither a written form nor LaTeX is a heading,
            // not a formula.
            guard let plain = clean(entry.plain) ?? latex.map(LatexPlainText.render) else { return nil }
            return OverviewFormula(
                name: name, latex: latex, plain: plain, meaning: clean(entry.meaning)
            )
        }.prefix(OverviewLimits.formulas)

        return OverviewDocument(
            title: clean(dto.title),
            hook: clean(dto.hook),
            objectives: Array((dto.objectives ?? []).compactMap(clean).prefix(OverviewLimits.objectives)),
            sections: Array(sections),
            takeaways: Array((dto.takeaways ?? []).compactMap(clean).prefix(OverviewLimits.takeaways)),
            formulas: Array(formulas)
        )
    }

    // MARK: - Two-stage lesson

    struct PlannedSection: Equatable {
        let heading: String
        /// What part of the note this section teaches, in the plan's own
        /// words -- the section call's brief.
        let covers: String
    }

    /// The first stage's result: everything about the lesson except the
    /// sections' prose, plus the list of sections still to be written.
    struct LessonPlan: Equatable {
        var document: OverviewDocument
        var sections: [PlannedSection]
    }

    private struct PlanDTO: Decodable {
        let title: String?
        let hook: String?
        let objectives: [String]?
        let sections: [PlannedDTO]?
        let takeaways: [String]?
        let formulas: [OverviewDTO.FormulaDTO]?

        struct PlannedDTO: Decodable {
            let heading: String?
            let covers: String?
        }
    }

    private struct SectionBodyDTO: Decodable {
        let claim: String?
        let paragraphs: [String]?
        let terms: [OverviewDTO.DefinitionDTO]?
        let example: OverviewDTO.ExampleDTO?
        let check: OverviewDTO.CheckDTO?
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    static func parseLessonPlan(_ raw: String) -> LessonPlan {
        guard let data = salvageJSON(raw).data(using: .utf8),
              let dto = try? JSONDecoder().decode(PlanDTO.self, from: data)
        else { return LessonPlan(document: .empty, sections: []) }

        let planned = (dto.sections ?? []).compactMap { entry -> PlannedSection? in
            guard let heading = clean(entry.heading) else { return nil }
            return PlannedSection(heading: heading, covers: clean(entry.covers) ?? heading)
        }
        var seen: Set<String> = []
        let unique = planned.filter { seen.insert(AnswerGrading.normalize($0.heading)).inserted }

        let formulas = (dto.formulas ?? []).compactMap { entry -> OverviewFormula? in
            guard let name = clean(entry.name) else { return nil }
            let latex = clean(entry.latex)
            guard let plain = clean(entry.plain) ?? latex.map(LatexPlainText.render) else { return nil }
            return OverviewFormula(name: name, latex: latex, plain: plain, meaning: clean(entry.meaning))
        }
        let document = OverviewDocument(
            title: clean(dto.title),
            hook: clean(dto.hook),
            objectives: Array((dto.objectives ?? []).compactMap(clean).prefix(OverviewLimits.objectives)),
            sections: [],
            takeaways: Array((dto.takeaways ?? []).compactMap(clean).prefix(OverviewLimits.takeaways)),
            formulas: Array(formulas.prefix(OverviewLimits.formulas))
        )
        return LessonPlan(document: document, sections: Array(unique.prefix(OverviewLimits.sections)))
    }

    /// One section's body, headed by the claim the section call stated
    /// after writing it -- or the plan's heading when that claim doesn't
    /// read as one.
    ///
    /// Measured on a real lecture: a plan call told to "write claims, not
    /// topics" still produced "Consistency and Inconsistency" and
    /// "Augmented Matrices". Asking the model to state the insight of a
    /// section it has *just written* is a summarising task rather than a
    /// style rule, and a 7B is far better at those.
    static func parseSectionResponse(_ raw: String, heading: String) -> OverviewSection? {
        guard let data = salvageJSON(raw).data(using: .utf8),
              let dto = try? JSONDecoder().decode(SectionBodyDTO.self, from: data)
        else { return nil }
        let paragraphs = (dto.paragraphs ?? []).compactMap(clean).prefix(OverviewLimits.paragraphsPerSection)
        guard !paragraphs.isEmpty else { return nil }
        let terms = (dto.terms ?? []).compactMap { term -> OverviewDefinition? in
            guard let name = clean(term.term), let text = clean(term.definition) else { return nil }
            return OverviewDefinition(term: name, text: text,
                                      example: clean(term.example), nonExample: clean(term.nonExample))
        }.prefix(OverviewLimits.termsPerSection)
        let check = dto.check.flatMap { check -> OverviewCheck? in
            guard let question = clean(check.question), let answer = clean(check.answer) else { return nil }
            return OverviewCheck(question: question, answer: answer)
        }
        return OverviewSection(
            heading: readsAsClaim(clean(dto.claim)) ?? heading,
            paragraphs: Array(paragraphs), terms: Array(terms),
            example: dto.example.flatMap(workedExample), check: check
        )
    }

    /// A worked example with at least two usable steps, or nil. The
    /// composer separately drops any whose numbers aren't in the note.
    private static func workedExample(_ dto: OverviewDTO.ExampleDTO) -> OverviewWorkedExample? {
        let steps = (dto.steps ?? []).compactMap { step -> OverviewExampleStep? in
            guard let action = clean(step.action) else { return nil }
            return OverviewExampleStep(action: action, result: clean(step.result), why: clean(step.why),
                                       label: clean(step.label), visual: step.visual.flatMap(stepVisual))
        }.prefix(OverviewLimits.exampleSteps)
        guard steps.count >= 2 else { return nil }
        return OverviewWorkedExample(title: clean(dto.title), setup: clean(dto.setup),
                                     steps: Array(steps), outcome: clean(dto.outcome))
    }

    private static func stepVisual(_ dto: OverviewDTO.ExampleDTO.VisualDTO) -> OverviewStepVisual? {
        guard let raw = dto.kind?.lowercased(), let kind = OverviewStepVisual.Kind(rawValue: raw) else { return nil }
        return OverviewStepVisual(
            kind: kind, caption: clean(dto.caption),
            rows: dto.rows?.map { $0.map(\.value) }, bar: dto.bar,
            highlightRows: dto.highlightRows, highlightColumns: dto.highlightColumns,
            vectors: dto.vectors?.compactMap { v in
                guard let x = v.x, let y = v.y else { return nil }
                return VisualVector(label: clean(v.label), x: x, y: y, weight: v.weight)
            },
            combine: dto.combine, nodes: dto.nodes?.compactMap(clean), highlight: dto.highlight
        )
    }

    /// A claim states something, so it's a sentence of some length rather
    /// than a two-word label. Crude, but it only has to tell "Augmented
    /// Matrices" apart from "You can drop the variables and work with the
    /// numbers alone" -- and a false negative just keeps the plan's heading.
    static func readsAsClaim(_ text: String?) -> String? {
        guard var text else { return nil }
        let words = text.split(separator: " ").count
        // Upper bound from real output: qwen3.5 wrote 23-word "headings"
        // that were really topic sentences; past ~16 words a heading stops
        // being scannable, so the plan's shorter one is kept instead.
        guard words >= 5, words <= 16 else { return nil }
        // A question poses the insight instead of stating it, and these
        // openers are topic labels dressed as sentences -- all seen from a
        // real 7B in place of a claim.
        if text.hasSuffix("?") { return nil }
        let lowered = text.lowercased()
        let labelOpeners = ["what is", "what are", "how to", "introduction to", "understanding",
                            "the power of", "overview of", "an overview", "exploring", "visualizing"]
        if labelOpeners.contains(where: { lowered.hasPrefix($0) }) { return nil }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Salvage, decode and validate a figures response. Anything that
    /// doesn't survive `OverviewFigures.validate` is dropped, and so is a
    /// figure pointing at a section that doesn't exist -- a figure beside
    /// the wrong idea misleads worse than a missing one.
    static func parseFiguresResponse(_ raw: String, sectionCount: Int) -> [GeneratedFigure] {
        guard let data = salvageJSON(raw).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FiguresDTO.self, from: data)
        else { return [] }

        var result: [GeneratedFigure] = []
        var usedSections: Set<Int> = []
        for entry in decoded.figures ?? [] {
            guard result.count < OverviewLimits.figures,
                  let kindName = entry.kind, let kind = OverviewFigure.Kind(rawValue: kindName),
                  let sectionNumber = entry.section?.value.flatMap(Self.wholeNumber),
                  (1...sectionCount).contains(sectionNumber),
                  // One figure per section: two stacked figures beside one
                  // idea is a slideshow, not a lesson.
                  usedSections.insert(sectionNumber).inserted
            else { continue }

            let steps = (entry.steps ?? []).compactMap { step -> RowOperation? in
                guard let opName = step.op?.lowercased(),
                      let op = RowOperation.Kind(rawValue: opName),
                      let target = step.target?.value.flatMap(Self.wholeNumber)
                else { return nil }
                return RowOperation(
                    kind: op, target: target,
                    source: step.source?.value.flatMap(Self.wholeNumber),
                    multiplier: step.multiplier?.value
                )
            }
            let caption = entry.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            let figure = OverviewFigure(
                kind: kind,
                caption: caption?.isEmpty == false ? caption : nil,
                equations: entry.equations?.map { $0.compactMap(\.value) },
                steps: steps,
                matrix: entry.matrix?.map { $0.compactMap(\.value) }
            )
            guard let valid = OverviewFigures.validate(figure) else { continue }
            result.append(GeneratedFigure(sectionIndex: sectionNumber - 1, figure: valid))
        }
        return result
    }

    private struct TestQuestionDTO: Decodable {
        let prompt: String
        let answer: String
    }

    private struct ContextValidationDTO: Decodable {
        let verdict: String
        let refinedBack: String?
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        /// Optional so the diagram pass can omit the key entirely: Swift's
        /// synthesized `Encodable` skips a nil, and an absent `format` is
        /// exactly Ollama's free-text default.
        let format: String?
        let stream: Bool
        /// Always false. Newer models (qwen3.5, gemma4) reason to themselves
        /// before answering unless told not to, and nothing here reads that
        /// reasoning. Measured locally: qwen3.5 spent 50 seconds and ~600
        /// tokens thinking before replying with a two-key JSON object, and
        /// answered in 0.6s with this set. Older models ignore the flag.
        let think: Bool
        let options: Options
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable {
            let num_ctx: Int
            /// Omitted when nil: no cap, Ollama's default.
            let num_predict: Int?
        }
    }

    /// The same for every call, never varied per call: Ollama reloads the
    /// model whenever this changes. 8K rather than Ollama's 4K default so a
    /// typical lecture fits in one piece with room to answer -- see
    /// `overviewContextWordBudget`.
    static let contextTokens = 8_192

    private struct ChatResponse: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }

    /// `json: false` drops Ollama's JSON grammar mode. Only the diagram
    /// pass wants that, for the reason on `CardGenerator.generateDiagram`:
    /// Mermaid is multi-line, and a newline inside a JSON string is where a
    /// 7B model's response breaks.
    ///
    /// `maxTokens` caps how much one answer can write. Generation is where
    /// the time and heat go -- reading a note takes seconds, writing about
    /// it takes most of a minute -- and a local model occasionally runs on
    /// far past what was asked for. Each cap is about twice a normal answer.
    private func chat(prompt: String, json: Bool = true, maxTokens: Int? = nil) async throws -> String {
        // Check the server is there first, in the 2-second budget. A refused
        // connection fails at once on Apple platforms, but on Windows
        // URLSession sits out the full 300-second timeout -- five minutes
        // before any AI action with Ollama stopped fell back.
        guard await isAvailable else { throw URLError(.cannotConnectToHost) }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model, messages: [.init(role: "user", content: prompt)],
            format: json ? "json" : nil, stream: false, think: false,
            options: .init(num_ctx: Self.contextTokens, num_predict: maxTokens)
        ))
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
    }

    // MARK: - Salvage

    /// Ollama's `format: "json"` constrains the *grammar* of the response,
    /// not the model's habit of wrapping it in a ```json fence or opening
    /// with "Here is the JSON:". Every decode in this file used to go
    /// straight from `content` into `JSONDecoder`, so one stray character
    /// meant the whole call silently returned its fallback with nothing
    /// logged and nothing retried.
    ///
    /// This is deliberately salvage and not *repair*: no quote balancing,
    /// no comma insertion, nothing that could turn a broken response into a
    /// plausible-looking wrong one. Just the two things that actually
    /// happen -- a code fence and surrounding prose -- both handled by
    /// taking the outermost bracketed span. Anything it can't find it
    /// returns untouched, so a genuinely malformed response still falls
    /// back exactly as before.
    /// Reads a list out of a response, whatever shape the list arrived in.
    ///
    /// Ollama's JSON mode only produces a top-level *object*: asked for an
    /// array, a model in that mode returns just the first element. Every
    /// list-shaped call here asked for an array and decoded `[T]`, so every
    /// one of them failed -- "Add More Cards" always added nothing, AI test
    /// questions never arrived, and refining silently changed nothing. The
    /// prompts now ask for `{"items": [...]}`; this also accepts a bare
    /// array, a list under some other key, or a lone element, so a model
    /// that answers in any of those shapes still gets through.
    static func decodeList<T: Decodable>(_ type: T.Type, from raw: String) -> [T]? {
        guard let data = salvageJSON(raw).data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        let elements: [Any]
        if let array = top as? [Any] {
            elements = array
        } else if let object = top as? [String: Any] {
            if let items = object["items"] as? [Any] {
                elements = items
            } else if let list = object.values.compactMap({ $0 as? [Any] }).first, object.count == 1 {
                elements = list
            } else {
                elements = [object]
            }
        } else {
            return nil
        }
        return elements.compactMap { element in
            guard JSONSerialization.isValidJSONObject([element]),
                  let data = try? JSONSerialization.data(withJSONObject: [element])
            else { return nil }
            return (try? JSONDecoder().decode([T].self, from: data))?.first
        }
    }

    /// A row or section number from a model, or nil. `Int(Double)` traps
    /// on infinity, NaN or anything past Int's range, and a model can send
    /// "inf" or 1e20 as happily as 2.
    static func wholeNumber(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 1_000_000 else { return nil }
        return Int(value.rounded())
    }

    static func salvageJSON(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            if let close = text.range(of: "```", options: .backwards) {
                text = String(text[..<close.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return text }
        let closer: Character = text[first] == "{" ? "}" : "]"
        guard let last = text.lastIndex(of: closer), last > first else { return text }
        return String(text[first...last])
    }

    /// The plain-text counterpart to `salvageJSON`. Strips a fence the
    /// prompt already forbade, treats the explicit "NONE" answer as
    /// nothing, and otherwise drops everything before the first line that
    /// opens a diagram the parser accepts. `MermaidParser` would reject a
    /// preamble anyway -- doing it here is what keeps an empty string,
    /// rather than a paragraph of apology, in `mermaidSource`.
    static func salvageMermaid(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            if let close = text.range(of: "```", options: .backwards) {
                text = String(text[..<close.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return "" }
        if text.uppercased() == "NONE" { return "" }

        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            return trimmed == "mindmap"
                || trimmed.hasPrefix("graph ") || trimmed == "graph"
                || trimmed.hasPrefix("flowchart ")
        }) else { return "" }
        return lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompts

    static func refinePrompt(candidates: [CandidatePair], noteContext: String) -> String {
        let items = candidates.enumerated()
            .map { "\($0.offset). front: \"\($0.element.front)\" back: \"\($0.element.back)\"" }
            .joined(separator: "\n")
        return """
        You are cleaning up flashcards auto-extracted from a student's lecture notes. \
        For each numbered pair below, first check whether the front actually names the concept \
        the back describes. If the front is garbled, truncated, or clearly mislabeled -- it doesn't \
        match what the back is really about -- replace it entirely with the correct short term or \
        question for that concept, grounded only in the note context below. Otherwise, leave the \
        term's meaning alone and only fix minor wording or OCR/parsing artifacts. For the back, \
        rewrite it as a concise, accurate answer. Do not invent facts not implied by the note context.

        Note context:
        \(noteContext.prefix(2000))

        Pairs:
        \(items)

        Respond with ONLY one JSON object shaped {"items": [...]}, where items holds exactly \
        \(candidates.count) objects, in the same order, each shaped {"front": "...", "back": "..."}. \
        No other text.
        """
    }

    /// Deliberately more restrictive than `refinePrompt`: this one is
    /// allowed to add cards the parser never produced, so the instruction
    /// to stay grounded in the note text (and to prefer an empty array
    /// over a forced answer) matters even more here than it does there.
    /// `topic`, when given, narrows *where to look* -- it never relaxes
    /// the "don't add outside knowledge" instruction below it.
    static func generateAdditionalPrompt(
        existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String? = nil
    ) -> String {
        let covered = existing.map { "- \($0.front): \($0.back)" }.joined(separator: "\n")
        let trimmedTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusLine = (trimmedTopic?.isEmpty == false) ? "Focus especially on: \(trimmedTopic!).\n\n" : ""
        return """
        You are a student's study assistant. Below is one of their lecture notes, and the flashcards \
        already made from it. Your job is to find, at most, \(maxCount) additional concept(s) this \
        note itself mentions or clearly implies but that aren't covered by an existing card yet -- \
        for example a term used in passing but never given its own definition, or a listed item \
        without an example. Every fact on a new card must be directly supported by the note text \
        below. Do not add outside knowledge, and do not invent an example, number, or date that \
        isn't in the note. If you can't find any such gap, return an empty array -- that is a normal \
        and expected result, not a failure.

        \(focusLine)Note:
        \(noteContext.prefix(3000))

        Cards already made from this note:
        \(covered.isEmpty ? "(none yet)" : covered)

        Respond with ONLY one JSON object shaped {"items": [...]}, where items holds at most \
        \(maxCount) objects, each shaped {"front": "...", "back": "..."}. Return {"items": []} if \
        there is nothing worth adding. No other text.
        """
    }

    /// Same grounding contract as `generateAdditionalPrompt` (every fact
    /// must come from `noteContext`, an empty array is a normal result),
    /// but asks for a `{"prompt","answer"}` shape rather than
    /// `{"front","back"}` -- deliberately different field names so the
    /// model reads this as "ask a question, state its answer" rather than
    /// "flashcard term/definition." These are test-only and never
    /// persisted, so there's no `topic` steering parameter to plumb here.
    static func generateTestQuestionsPrompt(
        existing: [CandidatePair], noteContext: String, maxCount: Int
    ) -> String {
        let covered = existing.map { "- \($0.front): \($0.back)" }.joined(separator: "\n")
        return """
        You are a student's study assistant, writing practice questions for a test. Below is one \
        of their lecture notes, and the flashcards already made from it. Write, at most, \(maxCount) \
        short free-response practice question(s) that test understanding of this note -- prefer \
        something that requires connecting or applying an idea from the note over one that just \
        restates an existing card word-for-word. Every fact in the question and its answer must be \
        directly supported by the note text below. Do not add outside knowledge, and do not invent \
        an example, number, or date that isn't in the note. If the note doesn't support any good \
        question beyond what's already covered, return an empty array -- that is a normal and \
        expected result, not a failure.

        Note:
        \(noteContext.prefix(3000))

        Cards already made from this note:
        \(covered.isEmpty ? "(none yet)" : covered)

        Respond with ONLY one JSON object shaped {"items": [...]}, where items holds at most \
        \(maxCount) objects, each shaped {"prompt": "...", "answer": "..."}. Return {"items": []} \
        if there is nothing worth asking. No other text.
        """
    }

    /// Checks one already-extracted card's definition for the same
    /// "assignment logistics, not a definition" shape `PairParser`'s own
    /// deterministic filters catch by keyword/pattern -- this is the
    /// semantic backstop for the cases those miss (a rubric mention
    /// phrased as if it were content, a document-specific label, a vague
    /// fragment that reads grammatically fine but explains nothing).
    ///
    /// Two judgments, kept explicitly separate, because collapsing them
    /// into one is what caused a real bug: the model would take a bad
    /// card and just smooth over/summarize whatever text it was given --
    /// on Tyler's real College Writing course, "Con" (a garbled 3-point
    /// list about animal testing) came back truncated to its first
    /// clause, and "Topic Sentence"/"Thesis" came back nearly verbatim
    /// unchanged, none of them an actual definition of the term. First
    /// judge whether the TERM itself is a real, general course concept at
    /// all (independent of how bad its extracted definition is) -- a
    /// student's own essay-draft heading or an assignment instruction
    /// isn't one, no matter how it's phrased. Only for a term that
    /// passes that bar does a `refine` verdict ask for a *brand-new*
    /// general definition from the model's own subject knowledge, with
    /// summarizing/paraphrasing the specific extracted text explicitly
    /// ruled out.
    static func validateContextPrompt(
        front: String, back: String, noteContext: String, courseName: String
    ) -> String {
        """
        You are checking flashcards auto-extracted from a student's notes for the course \
        "\(courseName)". A flashcard's front is a term and its back should be a general, \
        academically accurate definition of that term -- the kind of definition that belongs in a \
        course glossary, true regardless of which specific assignment or example it came from.

        Term: \(front)
        Extracted definition: \(back)

        For reference, the note this was extracted from:
        \(noteContext.prefix(2000))

        First, decide: is "\(front)" itself a real, general concept a student in "\(courseName)" would \
        need to know -- the kind of term that belongs in a glossary -- or is it just a label specific \
        to this one document (a draft's section heading, an assignment instruction, a personal \
        narrative, a fragment)? Judge the TERM itself, not the quality of its extracted definition -- a \
        real term can still have a bad extracted definition.

        If "\(front)" is NOT a real general concept -- it only makes sense as a label for this \
        document's own specific content -- respond {"verdict": "reject"}.

        If "\(front)" IS a real general concept:
        - If the extracted definition already states the general concept accurately, respond \
        {"verdict": "valid"}.
        - Otherwise respond {"verdict": "refine", "refinedBack": "..."} with a brand-new, general, \
        academically accurate definition of the concept, written from your own knowledge of the \
        subject. Do NOT summarize, paraphrase, or shorten the extracted text or the note's specific \
        example -- state what the term actually means in general, the way a glossary would, even if \
        that differs from what the specific extracted text or note said.

        Respond with ONLY one JSON object shaped {"verdict": "...", "refinedBack": "..."} \
        ("refinedBack" only needed when verdict is "refine"). No other text.
        """
    }

    static func distractorPrompt(correctAnswer: String, deckContext: [String], count: Int) -> String {
        let examples = deckContext.prefix(20).map { "- \($0)" }.joined(separator: "\n")
        return """
        The correct answer to a flashcard question is: "\(correctAnswer)"

        Here are other real answers from the same deck, for style and topic grounding:
        \(examples)

        Generate \(count) plausible but definitely incorrect distractor answers for a multiple-choice \
        question, in the same style and length as the correct answer. They must be clearly wrong to \
        someone who knows the material, not near-duplicates of the correct answer.

        Respond with ONLY one JSON object shaped {"items": [...]}, where items holds \(count) \
        strings. No other text.
        """
    }

    /// The whole-note overview pass. Three things set it apart from every
    /// other prompt in this file, and all three are deliberate.
    ///
    /// First, `noteContext` is interpolated whole -- no `.prefix(N)`. Every
    /// other prompt caps its context because a per-card refinement that
    /// sees 2,000 of a note's 5,000 characters is slightly worse. A
    /// whole-note overview that sees the same 2,000 is simply wrong, and
    /// silently so: it describes the first third of a lecture while
    /// presenting itself as describing the lecture. `OverviewChunker` has
    /// already guaranteed what arrives here fits.
    ///
    /// Second, it insists on single-line strings everywhere. The one truly
    /// multi-line artifact in this feature, the Mermaid diagram, is asked
    /// for separately and in plain text by `diagramPrompt`, because an
    /// unescaped newline inside a JSON string is where a local 7B model's
    /// response actually breaks.
    ///
    /// Third -- and this is the one that inverts every other prompt in this
    /// file -- it asks the model to *explain* rather than to stay inside
    /// the note's own words. The flashcard prompts are grounded hard for
    /// good reason: a card is memorised, so a fact the lecture never taught
    /// is a liability. An overview is read, and a model told to work only
    /// from the note's wording produces a reformatted copy of the student's
    /// notes -- which is exactly what the first version of this shipped,
    /// and exactly what it was supposed to prevent. The boundary that
    /// replaces it is topical rather than verbal: explain the concepts this
    /// note raises, however well you can, but do not wander onto concepts
    /// it doesn't raise.
    static func overviewPrompt(
        noteTitle: String, courseName: String, noteContext: String,
        includeFormulas: Bool, partLabel: String? = nil
    ) -> String {
        let partLine = partLabel.map { label in
            """
            This note is long, so you are being shown one piece of it: \(label). Cover only what \
            this piece raises -- the other pieces are being handled separately, so do not try to \
            cover the whole note here.


            """
        } ?? ""
        let formulaSection = includeFormulas
            ? """
            - formulas: every formula, equation or named rule the note states, with what its \
            symbols stand for.

            """
            : ""
        let formulaShape = includeFormulas
            ? ", \"formulas\": [{\"name\": \"...\", \"latex\": \"...\", \"plain\": \"...\", \"meaning\": \"...\"}]"
            : ""
        return """
        You are writing a short lesson for the course "\(courseName)", in the style of \
        3Blue1Brown: curious, visual, and built so the reader discovers each idea instead of \
        being told it. A student took the notes below and wants to truly understand them -- not \
        a summary, and not their notes handed back in different words.

        How to write it:
        - Start from a concrete question or puzzle the lecture answers, something that makes the \
        reader want to know.
        - Show a concrete case with real numbers before the general rule. Let the reader see the \
        pattern, then give it its name.
        - Explain why each idea has to be true, not just that it is. Say what someone would \
        notice, and why that forces the conclusion.
        - Talk to the reader: use you and we, and phrases like notice that, or what if.
        - Every section heading is a full claim that states the insight, like Swapping two \
        equations cannot change the answer -- never a bare topic like Interchange.
        - Keep paragraphs to two to four sentences, two or three paragraphs per section.
        - Write math in plain text, like x + 5y = 7 or R2 -> R2 - 2R1.
        - Use the note's own examples as the concrete case. Never invent a story, character or \
        metaphor -- no treasure, maps, detectives, recipes or games.
        - You may draw on what you know about the subject to explain the concepts in the note. Do \
        not introduce concepts the note never raises.
        - Never repeat the note's own sentences. If a line could be pasted into the notes without \
        anyone noticing, rewrite it.

        Here is one section in the right voice, for a different course, to show the tone:
        {"heading": "A free parking pass still has a price", "paragraphs": ["Suppose your campus \
        hands out parking passes for zero dollars. Are they free? Watch what happens at 8:55 on \
        a Monday: students circle the lot, arrive early, and give up sleep to get a space.", \
        "That lost time is the real price. When money cannot ration something, something else \
        does, and the cost of a choice is whatever you give up to make it."], "terms": \
        [{"term": "Opportunity cost", "definition": "The value of the best option you give up \
        when you choose."}], "check": {"question": "If the lot doubled in size, what would \
        happen to the time students spend circling, and why?", "answer": "It would fall, because \
        spaces would be less scarce, so less time is needed to win one."}}

        \(partLine)Produce:
        - title: the lesson's title, a short claim that captures the lecture's central insight.
        - hook: two or three sentences opening with the question or puzzle this lecture answers.
        - objectives: 2 to 4 things the reader will be able to do afterwards, each starting with \
        a verb.
        - sections: 3 to 5 sections in the order a learner should meet them. Each has a claim \
        heading, paragraphs, the key terms first introduced there, and one check: a question that \
        makes the reader apply the idea, with a short answer explaining the reasoning.
        - takeaways: 3 to 5 sentences, each one idea worth remembering.
        \(formulaSection)
        Every string must be a single line of plain text: no line breaks, no markdown syntax, no \
        backslashes, and no quotation marks inside the text. Word each key term the way the note \
        words it, so it matches the student's flashcards. If a part has nothing in it, return an \
        empty array for it -- that is a normal and expected result, not a failure.

        Note title: \(noteTitle)

        Note:
        \(noteContext)

        Respond with ONLY one JSON object shaped {"title": "...", "hook": "...", "objectives": \
        ["..."], "sections": [{"heading": "...", "paragraphs": ["..."], "terms": [{"term": \
        "...", "definition": "..."}], "check": {"question": "...", "answer": "..."}}], \
        "takeaways": ["..."]\(formulaShape)}. No other text.
        """
    }

    /// Stage one: decide what the lesson teaches, in order, as claims.
    ///
    /// Coverage and headings are the two things the single-shot prompt got
    /// wrong on a real note -- it taught three of eight parts, under topic
    /// headings -- so this prompt does nothing else. Good-and-bad heading
    /// pairs are given explicitly because "write a claim, not a topic" in
    /// the abstract didn't take; a 7B follows a contrast far better than a
    /// rule.
    /// The opening every call about one note shares, byte for byte, with
    /// the note itself first and the instructions after.
    ///
    /// Ollama keeps the last prompt it read and skips re-reading whatever a
    /// new prompt starts with in common. A note's lesson is six or seven
    /// calls over the same text, and with the note buried after each call's
    /// own instructions no two prompts shared more than their first few
    /// tokens -- so every call re-read the whole note. Measured on a real
    /// 950-word lecture: 7.8s to read it cold, 3.0s once the opening matched.
    static func noteOpening(courseName: String, noteContext: String) -> String {
        """
        These are a student's lecture notes from the course "\(courseName)".

        Notes:
        \(noteContext)

        ---

        """
    }

    /// The fact-check. The model is asked for *quoted* problems only -- a
    /// fix is applied by finding its exact `original` in the section, so a
    /// reviewer that paraphrases changes nothing rather than something
    /// random -- and told plainly that finding nothing is the usual result,
    /// or it will invent problems to report.
    static func reviewPrompt(noteContext: String, section: OverviewSection) -> String {
        var lines = ["Heading: \(section.heading)"]
        lines += section.paragraphs.map { "Paragraph: \($0)" }
        lines += section.terms.map { "Term: \($0.term) -- \($0.text)" }
        if let check = section.check {
            lines.append("Question: \(check.question)")
            lines.append("Answer: \(check.answer)")
        }
        if let example = section.example {
            for step in example.steps {
                lines.append("Example step: \(step.action)" + (step.result.map { " -> \($0)" } ?? ""))
            }
        }
        let written = lines.joined(separator: "\n")
        return noteOpening(courseName: "this course", noteContext: noteContext) + """
        You are checking a lesson section a student will study from, written about the notes \
        above. Find only statements that are false: they contradict the notes, get the subject's \
        facts or math wrong, or give a wrong answer to the question. A true statement the notes \
        don't happen to mention is NOT an error -- leave it alone. Style, wording and missing \
        detail are not errors either. Most sections have no errors, and at most one or two \
        sentences in a section are ever wrong -- an empty list is the normal result.

        The section:
        \(written)

        For each false statement, copy the sentence exactly, character for character, as \
        original, and give corrected: the sentence rewritten to be true. Use an empty string only \
        when the sentence cannot be fixed and should be removed.

        Respond with ONLY one JSON object shaped {"items": [{"original": "...", "corrected": \
        "..."}]}. No other text.
        """
    }

    /// Repetition across a whole lesson. Asked as a yes/no question ("is
    /// anything repeated?") a 9B answered no even for a lesson with three
    /// sections on the same inheritance problem. Asked to grade every
    /// section's overlap with its closest earlier one, it has to look.
    static func repetitionPrompt(document: OverviewDocument) -> String {
        let sections = document.sections.enumerated().map { index, section in
            "Section \(index + 1): \(section.heading)\n" + String(section.paragraphs.joined(separator: " ").prefix(500))
        }.joined(separator: "\n\n")
        return """
        Below are the sections of one lesson.

        \(sections)

        For every section after the first, find the earlier section whose content it overlaps \
        most, and grade how much of this section just repeats that one: most, some or little. \
        Respond with ONLY one JSON object shaped {"overlaps": [{"section": 2, "closest": 1, \
        "repeats": "little"}]}. No other text.
        """
    }

    static func lessonPlanPrompt(
        noteTitle: String, courseName: String, noteContext: String,
        includeFormulas: Bool, partLabel: String? = nil
    ) -> String {
        let isMath = NoteMath.isMathematical(noteContext)
        let partLine = partLabel.map {
            "You are being shown one piece of a longer note: \($0). Plan only what this piece teaches.\n\n"
        } ?? ""
        let formulaShape = includeFormulas
            ? ", \"formulas\": [{\"name\": \"...\", \"latex\": \"...\", \"plain\": \"...\", \"meaning\": \"...\"}]"
            : ""
        let hookRule = isMath
            ? "posed through the math itself"
            : "posed through the notes' own examples"
        return noteOpening(courseName: courseName, noteContext: noteContext) + """
        You are planning a short lesson on the notes above, taught in the style of 3Blue1Brown. \
        List the ideas they teach, in the order a learner should meet them.

        Cover every idea and every method the notes teach or demonstrate -- if the notes work an \
        example, the lesson should teach the method behind it. Skip course logistics entirely: \
        grading, office hours, schedules and background polls are not ideas.

        Each section heading must be a full claim that states the insight, never a bare topic. \
        Examples from other courses, to show the pattern -- write your own for these notes:
        - Bad: Opportunity Cost. Good: Every choice costs you the best thing you did not pick.
        - Bad: Natural Selection. Good: Traits spread when they help their owners leave more \
        offspring.
        - Bad: Momentum. Good: In a collision, the total push can move between objects but never \
        vanish.
        The title follows the same rule: a claim, never a phrase like Understanding X or \
        Introduction to Y.

        \(partLine)Produce:
        - title: a short claim capturing the lecture's central insight.
        - hook: one real question this lecture answers, \(hookRule), then a sentence on why it \
        matters. A single question, not a list of them. No stories, characters or metaphors.
        - objectives: 2 to 4 things the reader will be able to do afterwards, each starting with a \
        verb.
        - sections: 4 or 5, each with a claim heading of at most twelve words and a covers field \
        naming exactly which part of the notes it teaches, including any example equations or \
        numbers it should use. Combine closely related parts rather than giving each its own; no \
        two sections may teach the same idea.
        - takeaways: 3 to 5 sentences, each one idea worth remembering.

        Every string is a single line of plain text: no line breaks, no markdown, no backslashes, \
        no quotation marks inside the text.

        Note title: \(noteTitle)

        Respond with ONLY one JSON object shaped {"title": "...", "hook": "...", "objectives": \
        ["..."], "sections": [{"heading": "...", "covers": "..."}], "takeaways": \
        ["..."]\(formulaShape)}. No other text.
        """
    }

    /// Stage two: teach one claim well.
    ///
    /// The concrete case is pinned to the note's own examples, and invented
    /// stories are ruled out by name. The single-shot prompt, told to "use
    /// an analogy", produced a treasure-hunt framing for a linear algebra
    /// lecture -- the opposite of 3Blue1Brown, whose concreteness comes from
    /// the mathematical objects themselves, never from a story wrapped
    /// around them.
    static func sectionPrompt(
        courseName: String, noteContext: String, heading: String, covers: String,
        lessonHeadings: [String]
    ) -> String {
        let outline = lessonHeadings.map { "- \($0)" }.joined(separator: "\n")
        // Rules about equations and row operations only make sense for a
        // math note. Given to a lecture on AI agents they read as an
        // instruction to find some math, and the model obliged.
        let concreteRules = NoteMath.isMathematical(noteContext)
            ? """
            - Use only equations and numbers that appear in the notes. Do not make up new ones.
            - Do not compute the solution of a system or the result of a row operation yourself. \
            The lesson draws the notes' matrices and steps through every row operation in a figure \
            beside this section, with exact numbers. Point the reader at it, like step through the \
            figure and watch the -1 in row 3, and never try to describe a matrix's entries in a \
            sentence -- nobody can follow a matrix written out in prose.
            - Write math as notation in plain text, like x + 5y = 7, R2 -> R2 - 2R1, x3, a11 or \
            (-5, 3, 0). Never spell it out in words like negative five comma three or x sub three.
            - Never invent a story, character or metaphor -- no treasure, maps, detectives, recipes \
            or games. The concrete case is always actual math.
            """
            : """
            - Use only examples, names and numbers that appear in the notes. Do not make up new ones.
            - This is not a math course: never turn the notes into equations, matrices or formulas \
            they do not already contain.
            - Never invent a story, character or metaphor -- no treasure, maps, detectives, recipes \
            or games. The concrete case is always something the notes actually describe.
            """
        // Matrices and arrows only make sense for math; a process diagram
        // suits a procedure in any course.
        let visualShapes = NoteMath.isMathematical(noteContext)
            ? """
            A matrix or table: {"kind": "matrix", "rows": [["a11", "a12"], ["a21", "a22"]], \
            "bar": 1, "highlightColumns": [0]} -- entries short numbers or symbols, bar is how many \
            columns sit right of an augmentation bar, highlight what the step changes or uses. \
            Vectors in the plane: {"kind": "vectors", "vectors": [{"label": "u", "x": 2, "y": 1, \
            "weight": 3}], "combine": true} -- only 2D vectors whose numbers are in the notes; \
            combine draws the weighted sum tip to tail. A process: {"kind": "flow", "nodes": \
            ["...", "..."], "highlight": 1}.
            """
            : """
            A process diagram: {"kind": "flow", "nodes": ["Request arrives", "Controller picks a \
            view", "View renders"], "highlight": 1} -- two to five short stages, highlight the one \
            this step is at.
            """
        return noteOpening(courseName: courseName, noteContext: noteContext) + """
        You are writing one section of a lesson on the notes above, in the style of 3Blue1Brown: \
        the reader should see why the idea is true, not just be told it.

        The whole lesson, for context:
        \(outline)

        Write only this section:
        Claim: \(heading)
        It teaches: \(covers)

        How to write it:
        - Two or three paragraphs, each two to four sentences.
        - Open with a specific example from the notes. Show what happens to it, then name the \
        general idea. Say what this section adds -- the lesson's other sections cover their own \
        claims, so don't repeat them.
        \(concreteRules)
        - Explain why the claim has to be true, and point at what the reader should see.
        - Vary how paragraphs begin. Never open two paragraphs the same way, and don't lean on \
        stock openers like Notice that, Look at, Consider, Imagine or What if.
        - Talk to the reader as you and we.
        - You may use what you know about the subject to explain this claim, but stay on it.
        - Never copy the notes' sentences. If a line could be pasted into the notes without \
        anyone noticing, rewrite it.
        - terms: at most three key terms this section introduces, each defined in one sentence \
        and worded the way the notes word it. For each, also give example: one concrete case from \
        the notes that is this, and nonExample: a near miss that is not this, and exactly what \
        disqualifies it -- the boundary is how a definition is learned. Leave either empty if the \
        notes give nothing to base it on. An empty list is fine.
        - example: if this part of the notes works through something step by step -- a \
        calculation, a derivation, an algorithm, a procedure, a process -- give those steps here \
        instead of narrating them in a paragraph. A title naming what is worked, a setup stating \
        the starting point, two to six steps each with a label of two to four words, the action \
        taken, the result it produced copied from the notes, and why that step, then the outcome. \
        Use only steps and values the notes actually show. Use null if the notes don't work one \
        through here.
        - visual: for any step where a picture would make it clearer to someone new to the \
        subject, add one. \(visualShapes) Use null for a step a picture wouldn't help.
        - check: one question that makes the reader think, of whichever kind fits this section \
        best: predict an outcome, spot the mistake in a plausible but wrong statement, apply the \
        idea to a case from the notes, or explain why. Don't default to what would happen if. \
        Not one that requires solving new equations. Give an answer that explains the reasoning \
        in one or two sentences.
        - claim: last of all, one sentence of at most twelve words stating the single insight of \
        what you just wrote, like Every choice costs you the best thing you did not pick. A full \
        sentence, never a topic name.

        Every string is a single line of plain text: no line breaks, no markdown, no backslashes, \
        no quotation marks inside the text.

        Respond with ONLY one JSON object shaped {"paragraphs": ["..."], "terms": [{"term": \
        "...", "definition": "...", "example": "...", "nonExample": "..."}], "example": {"title": \
        "...", "setup": "...", "steps": [{"label": "...", "action": "...", "result": "...", "why": \
        "...", "visual": null}], \
        "outcome": "..."}, "check": {"question": "...", "answer": "..."}, "claim": "..."}. No other \
        text.
        """
    }

    /// The figures pass: numbers only.
    ///
    /// The model is never asked to draw anything or to do any arithmetic --
    /// only to copy equations and row operations out of the note, and to
    /// say which section each figure belongs beside. `OverviewFigures`
    /// computes every line, intersection and intermediate matrix from those
    /// numbers, so a 7B that would fumble a row reduction still produces a
    /// correct picture. The worked example is deliberately one the note
    /// itself would plausibly contain, so the model learns the exact shape
    /// of a row operation rather than inventing its own notation.
    static func figuresPrompt(
        noteTitle: String, courseName: String, noteContext: String, sectionHeadings: [String]
    ) -> String {
        let numbered = sectionHeadings.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        return noteOpening(courseName: courseName, noteContext: noteContext) + """
        You are choosing interactive figures for a lesson on the notes above. The lesson has \
        these sections:
        \(numbered)

        There are exactly two kinds of figure. Only use one when the note below actually contains \
        the numbers it needs -- copy them from the notes, do not invent them.

        - systemOfLines: two equations in x and y, drawn as two lines crossing at the solution, \
        optionally stepped through row operations. Give equations as [a, b, c] meaning a*x + b*y \
        = c. Give each step as an object with op set to replace, swap or scale. For replace, \
        target row becomes target + multiplier times source. For swap, target and source trade \
        places. For scale, target row is multiplied by multiplier. Rows are numbered 1 and 2.
        - linearTransform: a 2 by 2 matrix, drawn as the plane it stretches and turns. Give the \
        matrix as two rows.

        Use at most two figures, and at most one per section. Put each in the section whose idea \
        it shows. Write fractions as numbers, like -0.5 or -1/9 in quotes. If the note has no \
        equations or matrices, return an empty list -- that is a normal and expected result.

        Example, for a different note that solves x + y = 3 and x - y = 1 by elimination -- use \
        the numbers from the note below, never these:
        {"figures": [{"section": 2, "kind": "systemOfLines", "caption": "Each row operation \
        turns a line, but the crossing point never moves.", "equations": [[1, 1, 3], [1, -1, \
        1]], "steps": [{"op": "replace", "target": 2, "source": 1, "multiplier": -1}, {"op": \
        "scale", "target": 2, "multiplier": "-1/2"}]}]}

        Note title: \(noteTitle)

        Respond with ONLY one JSON object shaped {"figures": [...]}. No other text.
        """
    }

    /// The diagram pass, run over an already-summarized note rather than
    /// its raw text -- the model draws the relationships it has just told
    /// us about, which is a far easier question than "read this lecture and
    /// draw it," and keeps the call small enough to be worth repeating on
    /// demand when a diagram comes back unparseable.
    ///
    /// The subset named below is exactly what `MermaidParser` accepts, and
    /// the prompt says outright that anything outside it is discarded. A
    /// local 7B reliably writes Mermaid, but left unconstrained it reaches
    /// for subgraph, classDef and style, none of which a SwiftUI Canvas is
    /// going to draw.
    /// The rules half, split out so `FoundationModelsGenerator` can send
    /// the identical constraints as its session instructions. Both
    /// generators must describe the same subset, because one parser reads
    /// whatever either of them produces.
    static func diagramInstructions(courseName: String) -> String {
        """
        You are a student's study assistant, drawing one concept diagram for a lecture note from \
        the course "\(courseName)". Draw only what the outline you are given states -- every box \
        and every arrow must correspond to something in it. Do not add a concept, a step, or a \
        link the outline doesn't contain.

        Answer in Mermaid, using only this subset, because anything outside it is discarded:
        - The first line is exactly one of: graph TD, graph LR, or mindmap. Use graph TD for a \
        process, a hierarchy, or a cause-and-effect chain. Use graph LR for a left-to-right \
        sequence. Use mindmap for a topic and its sub-topics with no real flow between them.
        - Every box needs its own short name, made of letters and digits with no spaces, which \
        you invent from what the box says. Write the name, then the wording in square brackets.
        - Give every box a different name. Never reuse a name, and never use the word "id" as a \
        name.
        - Draw a link by writing one box's name, then -->, then another box's name. Use --> and \
        nothing else. To label a link, put the label between two bars right after the arrow.
        - Never link a box to itself.
        - Box wording is plain text: no quotation marks, no parentheses, no line breaks.
        - Each box holds at most six words. Never put a whole sentence in a box -- name the idea, \
        and let the arrows say how the ideas connect.
        - In a mindmap, write one node per line as plain text with no brackets and no names, \
        indented two spaces further than its parent. The first line after mindmap is the root.
        - Use between 4 and 12 boxes. Do not write subgraph, end, style, classDef, click, or a \
        comment, and do not use any other diagram type.

        Here is a complete, correct answer for a different lecture, to show the shape:

        graph TD
        scarcity[Wants exceed resources] --> choice[Every choice costs something]
        choice --> oppcost[Opportunity cost is the best forgone option]
        choice -->|measured at the margin| marginal[Compare one more unit, not totals]
        oppcost --> policy[Judge policies by results, not intentions]

        Notice each box has its own name -- scarcity, choice, oppcost, marginal, policy -- and \
        no name is used twice.

        If the outline has nothing worth drawing -- a note that is just a list of unrelated \
        definitions is the ordinary case for this -- reply with the single word NONE. An empty \
        result is a normal and expected outcome, not a failure.

        Respond with ONLY the Mermaid source, beginning with its first line, or the single word \
        NONE. No code fences, no explanation. No other text.
        """
    }

    static func diagramPrompt(
        noteTitle: String, courseName: String, conceptOutline: String
    ) -> String {
        """
        \(diagramInstructions(courseName: courseName))

        Note title: \(noteTitle)

        Outline:
        \(conceptOutline)
        """
    }
}
