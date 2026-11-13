import Foundation
import GRDB

// MARK: - Plain text comparison

/// Whether two question prompts ask the same thing.
public enum QuestionText {
    private static let filler: Set<String> = [
        "the", "a", "an", "of", "to", "in", "is", "are", "and", "or", "for", "on", "that", "this", "it", "as", "by",
        "with", "which", "what", "does", "do", "be", "from", "at", "was", "were", "following",
    ]

    /// The words that carry the meaning, lowercased.
    public static func tokens(_ text: String) -> Set<String> {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return Set(words.filter { !filler.contains($0) })
    }

    /// The same question, worded the same way or nearly: identical words once
    /// filler is dropped, or four in five words shared.
    public static func isRepeat(_ a: String, _ b: String) -> Bool {
        let first = tokens(a), second = tokens(b)
        guard first.count >= 3, second.count >= 3 else { return first == second && !first.isEmpty }
        let shared = Double(first.intersection(second).count)
        let all = Double(first.union(second).count)
        return shared / all >= 0.8
    }
}

// MARK: - What was dropped

/// Why a written question was not kept, in the three words a student reads.
public enum DropReason: String, Sendable, Equatable, CaseIterable {
    case repeated, unclear, failedCheck

    public func label(_ count: Int) -> String {
        switch self {
        case .repeated: return count == 1 ? "repeat" : "repeats"
        case .unclear: return "unclear"
        case .failedCheck: return "failed a check"
        }
    }
}

public struct DraftDrop: Identifiable, Sendable, Equatable {
    public let id: String
    /// The question as the model wrote it, shortened.
    public let text: String
    public let reason: DropReason
    /// One plain sentence on why.
    public let detail: String

    public init(text: String, reason: DropReason, detail: String) {
        self.id = UUID().uuidString
        self.text = String(text.prefix(160))
        self.reason = reason
        self.detail = detail
    }
}

public struct DraftOutcome: Sendable, Equatable {
    public var saved = 0
    public var drops: [DraftDrop] = []
    /// Nothing selected can be written here (code or math with no tools).
    public var cannotRun = false
    public var noNotes = false
    public var wasCancelled = false
    public var modelUnreachable = false
    public init() {}

    /// "3 dropped: 2 repeats, 1 unclear", or nil when nothing was dropped.
    public var droppedSummary: String? {
        guard !drops.isEmpty else { return nil }
        let parts = DropReason.allCases.compactMap { reason -> String? in
            let n = drops.filter { $0.reason == reason }.count
            return n == 0 ? nil : "\(n) \(reason.label(n))"
        }
        return "\(drops.count) dropped: " + parts.joined(separator: ", ")
    }
}

/// A note a deck's questions can be written from.
public struct DraftNote: Identifiable, Sendable, Equatable {
    public let id: String          // the note's material id
    public let title: String
    public let subject: ProblemSubject
    public let language: CodeLanguage?
}

// MARK: - Drafting

/// Writes questions for a deck as drafts, through the pipeline that was
/// already there and its checks, unchanged: the model writes, a second pass
/// or a script or a compiler checks, the deterministic quality rules and a
/// repeat check run, and only what passed is kept, as a draft that stays on
/// this device until it is approved.
public enum QuestionDrafter {
    public struct Request: Sendable {
        public var deckIds: [String]
        /// nil: every note of the decks.
        public var materialIds: Set<String>?
        public var count: Int
        public var multipleChoice: Bool
        public var written: Bool
        public var codeKinds: [CodeQuestionKind]
        public var mathKinds: [ProblemKind]

        public init(deckIds: [String], materialIds: Set<String>? = nil, count: Int = 10, multipleChoice: Bool = true,
                    written: Bool = true, codeKinds: [CodeQuestionKind] = [], mathKinds: [ProblemKind] = []) {
            self.deckIds = deckIds; self.materialIds = materialIds; self.count = count
            self.multipleChoice = multipleChoice; self.written = written
            self.codeKinds = codeKinds; self.mathKinds = mathKinds
        }
    }

    /// The notes behind these decks, with what each one is about.
    public static func notes(inDecks deckIds: [String], db: Database) throws -> [DraftNote] {
        let sources = try PracticeBuilder.sources(forDecks: deckIds, style: nil, wordBudget: 40, db: db)
        let titles = try Study.noteTitles(forMaterials: sources.map(\.material.id), db: db)
        return sources.map {
            DraftNote(id: $0.material.id, title: titles[$0.material.id] ?? $0.material.title,
                      subject: $0.subject, language: $0.language)
        }
    }

    /// One batch's running totals, shared by the notes written at once.
    private actor Tally {
        var saved = 0
        var drops: [DraftDrop] = []
        var known: [String]
        init(known: [String]) { self.known = known }

        func drop(_ text: String, _ reason: DropReason, _ detail: String) {
            drops.append(DraftDrop(text: text, reason: reason, detail: detail))
        }

        /// Registers a prompt, or says it repeats one already known.
        func claim(_ prompt: String) -> Bool {
            if known.contains(where: { QuestionText.isRepeat($0, prompt) }) { return false }
            known.append(prompt)
            return true
        }

        func kept() { saved += 1 }
    }

    private struct Item {
        var prompt: String
        var kind: String
        var language: String
        var body: String
        var verifiedBy: String
        var code: CodeQuestion?
        var problem: ProblemQuestion?
    }

    public static func generate(_ request: Request, using generator: any CardGenerator, executor: (any CodeExecuting)?,
                                database: GRASPDatabase) async -> DraftOutcome {
        var outcome = DraftOutcome()
        guard request.count > 0 else { return outcome }
        guard await generator.isAvailable else { outcome.modelUnreachable = true; return outcome }
        let progress = AIProgress.current
        let deckIds = request.deckIds
        let budget = max(300, min(generator.overviewContextWordBudget, 900))
        var sources = (try? await database.queue.read {
            try PracticeBuilder.sources(forDecks: deckIds, style: nil, wordBudget: budget, db: $0)
        }) ?? []
        if let chosen = request.materialIds { sources = sources.filter { chosen.contains($0.material.id) } }
        guard !sources.isEmpty else { outcome.noNotes = true; return outcome }

        // What each note can be asked as. Multiple choice and written need no
        // tools; code needs a compiler and math a Python, both Mac only.
        func codeApplies(_ source: PracticeBuilder.Source) -> Bool {
            guard source.subject == .code, !request.codeKinds.isEmpty, let language = source.language else { return false }
            return executor?.canRun(language) == true
        }
        func mathApplies(_ source: PracticeBuilder.Source) -> Bool {
            guard source.subject == .math || source.subject == .economics, !request.mathKinds.isEmpty else { return false }
            return executor?.canRun(.python) == true
        }
        let usable = sources.filter { request.multipleChoice || request.written || codeApplies($0) || mathApplies($0) }
        guard !usable.isEmpty else { outcome.cannotRun = true; return outcome }

        let known: [String] = (try? await database.queue.read { db in
            try QuestionBank.listing(inDecks: deckIds, db: db).map(\.promptText)
        }) ?? []
        let terms = (try? await database.queue.read { db in
            try Card.fetchAll(db, sql: """
                SELECT card.* FROM card JOIN deckCard ON deckCard.cardId = card.id
                WHERE deckCard.deckId IN (\(databaseQuestionMarks(count: deckIds.count)))
                AND card.deletedAt IS NULL AND card.status = 'active' LIMIT 30
                """, arguments: StatementArguments(deckIds)).map(\.front)
        }) ?? []

        // The note's readable title ("Module 2 · Ch. 3 — ..."), not its file name.
        let titles = (try? await database.queue.read { try Study.noteTitles(forMaterials: usable.map(\.material.id), db: $0) }) ?? [:]
        progress?.expect(usable.count)
        let perNote = max(2, Int((Double(request.count) / Double(usable.count)).rounded(.up)))
        let tally = Tally(known: known)
        let modelName = OverviewOrigin.of(generator)?.model
        let width = OverviewOrigin.of(generator)?.origin == .cloud ? 3 : 1

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func start(_ source: PracticeBuilder.Source) {
                group.addTask {
                    if Task.isCancelled { return }
                    progress?.begin("Writing questions from \(titles[source.material.id] ?? source.material.title)")
                    defer { progress?.advance() }
                    let cards = (try? await database.queue.read { db in
                        try Card.filter(Column("materialId") == source.material.id).filter(Column("deletedAt") == nil).fetchAll(db)
                    }) ?? []

                    var items: [Item] = []
                    // The kinds this note is asked for, sharing its count.
                    let kinds = [request.multipleChoice, request.written, codeApplies(source), mathApplies(source)].filter { $0 }.count
                    let each = max(1, Int((Double(perNote) / Double(max(kinds, 1))).rounded(.up)))

                    if request.multipleChoice {
                        let drafts = await generator.generateProblems(
                            deckName: source.deck.name, courseName: source.courseName, noteContext: source.text,
                            cardTerms: terms, subject: .concepts, kinds: [.multipleChoice], count: each)
                        for draft in drafts where !Task.isCancelled {
                            do {
                                let problem = try await ProblemBuilder.check(draft, subject: .concepts, using: generator, executor: executor)
                                if let body = problem.encoded() {
                                    items.append(Item(prompt: problem.prompt, kind: problem.kind.rawValue,
                                                      language: problem.subject.rawValue, body: body,
                                                      verifiedBy: "a second pass agreed on the answer", code: nil, problem: problem))
                                }
                            } catch {
                                await tally.drop(draft.prompt, .failedCheck, ((error as? DraftRejected)?.reason).map { "It " + $0 + "." } ?? "It didn't pass a check.")
                            }
                        }
                    }
                    if request.written, !Task.isCancelled {
                        let pairs = cards.map { CandidatePair(front: $0.front, back: $0.back, sourceLine: $0.sourceLine ?? 0) }
                        let written = await generator.generateTestQuestions(existing: pairs, noteContext: source.text, maxCount: each)
                        for q in written where !Task.isCancelled {
                            let problem = ProblemQuestion(kind: .written, subject: .concepts, prompt: q.prompt, explanation: q.explanation,
                                                          answer: q.correctAnswer)
                            if let body = problem.encoded() {
                                items.append(Item(prompt: q.prompt, kind: problem.kind.rawValue, language: problem.subject.rawValue,
                                                  body: body, verifiedBy: "written from the notes, not run through a second pass",
                                                  code: nil, problem: problem))
                            }
                        }
                    }
                    if codeApplies(source), let language = source.language, let executor, !Task.isCancelled {
                        let drafts = await generator.generateCodeQuestions(
                            deckName: source.deck.name, courseName: source.courseName, noteContext: source.text,
                            cardTerms: terms, language: language, kinds: request.codeKinds, count: each)
                        for draft in drafts where !Task.isCancelled {
                            do {
                                let question = try await CodeQuestionBuilder.check(draft, language: language, using: executor)
                                if let body = question.encoded() {
                                    items.append(Item(prompt: question.prompt, kind: question.kind.rawValue, language: language.rawValue,
                                                      body: body, verifiedBy: language == .cpp ? "compiled and ran with clang++" : "ran with python3",
                                                      code: question, problem: nil))
                                }
                            } catch {
                                await tally.drop(draft.prompt, .failedCheck, ((error as? DraftRejected)?.reason).map { "It " + $0 + "." } ?? "It didn't pass a check.")
                            }
                        }
                    }
                    if mathApplies(source), !Task.isCancelled {
                        let drafts = await generator.generateProblems(
                            deckName: source.deck.name, courseName: source.courseName, noteContext: source.text,
                            cardTerms: terms, subject: source.subject, kinds: request.mathKinds, count: each)
                        for draft in drafts where !Task.isCancelled {
                            guard request.mathKinds.contains(draft.kind) else { continue }
                            do {
                                let problem = try await ProblemBuilder.check(draft, subject: source.subject, using: generator, executor: executor)
                                if let body = problem.encoded() {
                                    items.append(Item(prompt: problem.prompt, kind: problem.kind.rawValue, language: source.subject.rawValue,
                                                      body: body, verifiedBy: draft.kind == .multipleChoice ? "a second pass agreed on the answer" : "recomputed with a script",
                                                      code: nil, problem: problem))
                                }
                            } catch {
                                await tally.drop(draft.prompt, .failedCheck, ((error as? DraftRejected)?.reason).map { "It " + $0 + "." } ?? "It didn't pass a check.")
                            }
                        }
                    }

                    for item in items {
                        if Task.isCancelled { break }
                        guard await tally.saved < request.count else { break }
                        if let why = item.problem.flatMap({ QuestionBank.qualityProblem($0) })
                            ?? item.code.flatMap({ CodeQuestionValidator.problem(in: $0) }) {
                            await tally.drop(item.prompt, .unclear, "It " + why + ".")
                            continue
                        }
                        guard await tally.claim(item.prompt) else {
                            await tally.drop(item.prompt, .repeated, "It asks the same thing as a question already here.")
                            continue
                        }
                        let record: TestQuestion
                        if let code = item.code {
                            record = TestQuestion(courseId: source.material.courseId, deckId: source.deck.id, materialId: source.material.id,
                                                  kind: code.kind, language: code.language, bodyJSON: item.body,
                                                  sourceContentHash: source.material.contentHash, verifiedBy: item.verifiedBy,
                                                  model: modelName, source: .ai, status: .draft)
                        } else if let problem = item.problem {
                            record = TestQuestion(courseId: source.material.courseId, deckId: source.deck.id, materialId: source.material.id,
                                                  problem: problem, bodyJSON: item.body, sourceContentHash: source.material.contentHash,
                                                  verifiedBy: item.verifiedBy, model: modelName, source: .ai, status: .draft)
                        } else { continue }
                        if (try? await database.queue.write({ try record.insert($0) })) != nil { await tally.kept() }
                    }
                }
            }
            while next < min(width, usable.count) { start(usable[next]); next += 1 }
            while await group.next() != nil {
                if next < usable.count, await tally.saved < request.count, !Task.isCancelled {
                    start(usable[next]); next += 1
                }
            }
        }
        outcome.saved = await tally.saved
        outcome.drops = await tally.drops
        outcome.wasCancelled = Task.isCancelled
        return outcome
    }
}
