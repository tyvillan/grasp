import Foundation
import GRDB

/// Why a draft was dropped, in words a person can read.
struct DraftRejected: Error { let reason: String }

/// Checks problems that aren't code. A number or matrix is recomputed by a
/// short script the model wrote, which is run here, and kept only if the
/// script and the model agree. A multiple-choice problem is kept only if a
/// second request, not shown the key, picks the same option.
public enum ProblemBuilder {
    private static func rejected(_ reason: String) -> DraftRejected { DraftRejected(reason: reason) }

    /// Runs the model's script and returns what it printed.
    private static func scriptOutput(_ draft: GeneratedProblem, using executor: (any CodeExecuting)?) async throws -> String {
        guard let script = draft.script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw rejected("there was no script to check the answer with")
        }
        guard let executor, executor.canRun(.python) else { throw rejected("python isn't available to check the answer") }
        if CodeSafety.readsInput(script) { throw rejected("the script asked for input") }
        // A script indented as a whole is still one program.
        let result = await executor.run(CodeQuestion.dedented(script), language: .python)
        guard result.succeeded else {
            throw rejected("the checking script " + (result.compiled ? "failed" : "didn't run") +
                           (result.stderr.isEmpty ? "" : ": " + String(result.stderr.suffix(80))))
        }
        return result.stdout
    }

    static func check(_ draft: GeneratedProblem, subject: ProblemSubject, using generator: any CardGenerator,
                      executor: (any CodeExecuting)?) async throws -> ProblemQuestion {
        let prompt = PlainMath.clean(draft.prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = draft
        draft.choices = PlainMath.clean(draft.choices)
        draft.explanation = draft.explanation.map(PlainMath.clean)
        // The problem has to say what to find: some words outside the
        // matrices and equations, not just a bare matrix.
        let words = prompt.components(separatedBy: "\n")
            .filter { !($0.trimmingCharacters(in: .whitespaces).hasPrefix("[") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("|")) }
            .joined(separator: " ").split(whereSeparator: { !$0.isLetter }).count
        guard words >= 4 else { throw rejected("the problem didn't say what to find") }
        switch draft.kind {
        case .multipleChoice:
            guard draft.choices.count == 4, let correct = draft.correct else { throw rejected("the options weren't four choices with one answer") }
            guard let second = await generator.solveMultipleChoice(prompt: prompt, choices: draft.choices) else {
                throw rejected("a second opinion on the answer wasn't available")
            }
            guard second == correct else { throw rejected("a second pass chose a different answer") }
            return ProblemQuestion(kind: .multipleChoice, subject: subject, prompt: prompt, choices: draft.choices,
                                   correct: correct, explanation: draft.explanation)
        case .number:
            guard let claimed = ProblemAnswerGrading.parseNumber(draft.claimedAnswer) else { throw rejected("the answer wasn't a number") }
            let output = try await scriptOutput(draft, using: executor)
            guard let computed = ProblemAnswerGrading.parseNumber(output), computed.isFinite, abs(computed) < 1e9
            else { throw rejected("the script didn't print a number") }
            guard ProblemAnswerGrading.isClose(claimed, to: computed) else {
                throw rejected("the model's answer and the script's disagreed")
            }
            return ProblemQuestion(kind: .number, subject: subject, prompt: prompt, number: computed,
                                   unit: draft.unit, explanation: draft.explanation)
        case .matrix:
            guard let claimed = ProblemAnswerGrading.parseMatrix(draft.claimedAnswer) else { throw rejected("the answer wasn't a matrix") }
            let output = try await scriptOutput(draft, using: executor)
            guard let computed = ProblemAnswerGrading.parseMatrix(output), computed.count <= 4,
                  computed.allSatisfy({ $0.count <= 4 && $0.allSatisfy(\.isFinite) })
            else { throw rejected("the script didn't print a small matrix") }
            guard computed.count == claimed.count, zip(computed, claimed).allSatisfy({ a, b in
                a.count == b.count && zip(a, b).allSatisfy { ProblemAnswerGrading.isClose($0, to: $1) }
            }) else { throw rejected("the model's matrix and the script's disagreed") }
            return ProblemQuestion(kind: .matrix, subject: subject, prompt: prompt, matrix: computed,
                                   explanation: draft.explanation)
        }
    }
}

/// Writes practice for a deck: code questions where the notes hold code,
/// worked problems where they don't, each checked before it is kept.
public enum PracticeBuilder {
    struct Source: Sendable {
        let material: Material
        let deck: Deck
        let courseName: String
        let text: String
        let subject: ProblemSubject
        let language: CodeLanguage?
    }

    /// The notes behind these decks, each with what to write from it.
    /// `style` forces a subject; nil reads it from each note.
    static func sources(forDecks deckIds: [String], style: ProblemSubject?, wordBudget: Int,
                        db: Database) throws -> [Source] {
        var result: [Source] = []
        for material in try OverviewQueries.materials(forDecks: deckIds, db: db) {
            guard let note = try NoteText.fetchOne(db, key: material.id) else { continue }
            let deckRow = try Row.fetchOne(db, sql: """
                SELECT deckCard.deckId AS deckId FROM deckCard
                JOIN card ON card.id = deckCard.cardId
                WHERE card.materialId = ? AND deckCard.deckId IN (\(databaseQuestionMarks(count: deckIds.count)))
                LIMIT 1
                """, arguments: StatementArguments([material.id] + deckIds))
            guard let deckId = deckRow?["deckId"] as String?, let deck = try Deck.fetchOne(db, key: deckId),
                  let course = try Course.fetchOne(db, key: material.courseId) else { continue }

            let snippets = NoteCode.snippets(in: note.raw)
            let tagged = snippets.compactMap { CodeLanguage.named($0.language) }
            let codeLanguage = CodeQuestionBuilder.mostCommon(tagged)
                ?? CodeQuestionBuilder.guessLanguage(snippets.map(\.code).joined(separator: "\n"))
            let subject: ProblemSubject
            if let style {
                subject = style
            } else if codeLanguage != nil {
                subject = .code
            } else {
                subject = ProblemSubject.detect(notes: note.reflowed, courseName: course.name, deckName: deck.name)
            }
            let words = note.reflowed.split(separator: " ", omittingEmptySubsequences: true)
            var text = words.prefix(wordBudget).joined(separator: " ")
            if subject == .code {
                guard let codeLanguage else { continue }
                text += "\n\nCode from the notes:\n" + snippets.prefix(4).map { "```\n\($0.code)\n```" }.joined(separator: "\n")
                result.append(Source(material: material, deck: deck, courseName: course.name, text: text,
                                     subject: .code, language: codeLanguage))
            } else {
                result.append(Source(material: material, deck: deck, courseName: course.name, text: text,
                                     subject: subject, language: nil))
            }
        }
        return result
    }

    /// Counts what has been saved across notes written at the same time.
    private actor Tally {
        var saved = 0
        var rejected = 0
        var reasons: [String: Int] = [:]
        func add() { saved += 1 }
        func reject(_ reason: String?) {
            rejected += 1
            if let reason { reasons[reason, default: 0] += 1 }
        }
    }

    public struct Request: Sendable {
        public var deckIds: [String]
        /// nil: read each note.
        public var style: ProblemSubject?
        public var codeKinds: [CodeQuestionKind]
        public var problemKinds: [ProblemKind]
        public var count: Int

        public init(deckIds: [String], style: ProblemSubject? = nil,
                    codeKinds: [CodeQuestionKind] = CodeQuestionKind.allCases,
                    problemKinds: [ProblemKind] = ProblemKind.allCases, count: Int) {
            self.deckIds = deckIds; self.style = style; self.codeKinds = codeKinds
            self.problemKinds = problemKinds; self.count = count
        }
    }

    /// Writes up to `request.count` checked questions. Several notes are
    /// written at once (three, with a cloud model; one, locally, where
    /// the model is the bottleneck), and each question is checked and saved
    /// the moment it is ready.
    public static func generate(_ request: Request, using generator: any CardGenerator,
                                executor: any CodeExecuting, database: GRASPDatabase) async -> CodeQuestionBuilder.Outcome {
        var outcome = CodeQuestionBuilder.Outcome()
        let progress = AIProgress.current
        guard request.count > 0 else { return outcome }
        let budget = max(300, min(generator.overviewContextWordBudget, 900))
        let deckIds = request.deckIds
        let style = request.style
        let sources = (try? await database.queue.read { try sources(forDecks: deckIds, style: style, wordBudget: budget, db: $0) }) ?? []
        guard !sources.isEmpty else { outcome.notCodeDecks = ["these decks"]; return outcome }

        // Code needs a compiler; math and economics need Python for their
        // checking scripts; concepts need neither.
        let usable = sources.filter { source in
            if let language = source.language { return executor.canRun(language) }
            if source.subject == .concepts { return true }
            return executor.canRun(.python)
        }
        guard !usable.isEmpty else { outcome.cannotRun = true; return outcome }

        let terms = (try? await database.queue.read { db in
            try Card.fetchAll(db, sql: """
                SELECT card.* FROM card JOIN deckCard ON deckCard.cardId = card.id
                WHERE deckCard.deckId IN (\(databaseQuestionMarks(count: deckIds.count)))
                AND card.deletedAt IS NULL AND card.status = 'active' LIMIT 30
                """, arguments: StatementArguments(deckIds)).map(\.front)
        }) ?? []

        progress?.expect(usable.count)
        let perNote = max(2, Int((Double(request.count) / Double(usable.count)).rounded(.up)))
        let tally = Tally()
        let modelName = OverviewOrigin.of(generator)?.model
        let width = OverviewOrigin.of(generator)?.origin == .cloud ? 3 : 1

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func start(_ source: Source) {
                group.addTask {
                    if Task.isCancelled { return }
                    if await tally.saved >= request.count { return }
                    progress?.begin("Writing practice from \(source.material.title)")
                    defer { progress?.advance() }
                    let wanted = min(perNote, request.count - (await tally.saved))
                    guard wanted > 0 else { return }

                    var checked: [(body: String, kind: String, language: String, verifiedBy: String, code: CodeQuestion?, problem: ProblemQuestion?)] = []
                    if source.subject == .code, let language = source.language {
                        let drafts = await generator.generateCodeQuestions(
                            deckName: source.deck.name, courseName: source.courseName, noteContext: source.text,
                            cardTerms: terms, language: language, kinds: request.codeKinds, count: wanted)
                        for (index, draft) in drafts.enumerated() {
                            if Task.isCancelled { break }
                            progress?.setNote("Checking \(index + 1) of \(drafts.count) from \(source.material.title)")
                            guard request.codeKinds.contains(draft.kind) else { await tally.reject(nil); continue }
                            do {
                                let question = try await CodeQuestionBuilder.check(draft, language: language, using: executor)
                                if let body = question.encoded() {
                                    checked.append((body, question.kind.rawValue, language.rawValue,
                                                    language == .cpp ? "compiled and ran with clang++" : "ran with python3",
                                                    question, nil))
                                }
                            } catch {
                                await tally.reject((error as? DraftRejected)?.reason)
                            }
                        }
                    } else {
                        let drafts = await generator.generateProblems(
                            deckName: source.deck.name, courseName: source.courseName, noteContext: source.text,
                            cardTerms: terms, subject: source.subject, kinds: request.problemKinds, count: wanted)
                        for (index, draft) in drafts.enumerated() {
                            if Task.isCancelled { break }
                            progress?.setNote("Checking \(index + 1) of \(drafts.count) from \(source.material.title)")
                            guard request.problemKinds.contains(draft.kind) else { await tally.reject(nil); continue }
                            do {
                                let problem = try await ProblemBuilder.check(draft, subject: source.subject,
                                                                              using: generator, executor: executor)
                                if let body = problem.encoded() {
                                    checked.append((body, problem.kind.rawValue, source.subject.rawValue,
                                                    draft.kind == .multipleChoice ? "a second pass agreed on the answer"
                                                        : "recomputed with a script", nil, problem))
                                }
                            } catch {
                                await tally.reject((error as? DraftRejected)?.reason)
                            }
                        }
                    }
                    for item in checked {
                        guard await tally.saved < request.count else { break }
                        let record: TestQuestion
                        if let code = item.code {
                            record = TestQuestion(courseId: source.material.courseId, deckId: source.deck.id,
                                                  materialId: source.material.id, kind: code.kind, language: code.language,
                                                  bodyJSON: item.body, sourceContentHash: source.material.contentHash,
                                                  verifiedBy: item.verifiedBy, model: modelName)
                        } else if let problem = item.problem {
                            record = TestQuestion(courseId: source.material.courseId, deckId: source.deck.id,
                                                  materialId: source.material.id, problem: problem, bodyJSON: item.body,
                                                  sourceContentHash: source.material.contentHash,
                                                  verifiedBy: item.verifiedBy, model: modelName)
                        } else { continue }
                        if (try? await database.queue.write({ try record.insert($0) })) != nil { await tally.add() }
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
        outcome.rejected = await tally.rejected
        outcome.reasons = await tally.reasons
        outcome.wasCancelled = Task.isCancelled
        return outcome
    }
}
