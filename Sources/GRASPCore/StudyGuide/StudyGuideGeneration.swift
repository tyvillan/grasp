import Foundation
import GRDB

/// One part of a generated practice guide: what a model wrote for one deck.
public struct GeneratedGuidePart: Sendable {
    public var part: StudyGuideDocument.Part?

    public init(part: StudyGuideDocument.Part?) { self.part = part }

    public static let empty = GeneratedGuidePart(part: nil)
}

// MARK: - The prompt and its parser (shared by Ollama and the cloud)

extension OllamaGenerator {
    static func studyGuidePartPrompt(
        deckName: String, courseName: String, noteContext: String, cardTerms: [String], problemCount: Int
    ) -> String {
        let terms = cardTerms.prefix(25).joined(separator: "; ")
        return """
        You are writing one part of a practice study guide for a student's exam in \(courseName). \
        This part covers: \(deckName). Using only the notes below, write material to practice \
        for a test on it:
        - skills: 3 to 5 things the student should be able to do afterwards, one sentence each, \
        starting with a verb.
        - problems: exactly \(problemCount) practice problems of the kind an exam on this material \
        asks. Each states everything needed, numbers included, then gives the worked solution as \
        short steps in order, then the final answer. Use concrete numbers and cases; every fact a \
        problem relies on must come from the notes. Do not copy the note's own examples word for word.
        - questions: 3 short sample test questions with their answers. A multiple-choice question \
        lists its options A) to D) inside the question.
        - terms: up to 6 key terms, each with a one-sentence definition.
        - traps: 2 or 3 mistakes students commonly make on this material, one sentence each.
        Never add outside facts. Anything the notes don't support is an empty list. Write every value \
        as plain text on one line: no line breaks, markdown, backslashes or quotation marks.

        Terms the student already has cards for: \(terms.isEmpty ? "(none)" : terms)

        Notes:
        \(noteContext)

        Respond with ONLY one JSON object shaped {"skills": ["..."], "problems": [{"question": \
        "...", "steps": ["..."], "answer": "..."}], "questions": [{"question": "...", "answer": \
        "..."}], "terms": [{"term": "...", "definition": "..."}], "traps": ["..."]}. No other text.
        """
    }

    /// A string, or a number or boolean written as one -- models answer
    /// "42" and 42 interchangeably.
    private struct Flexible: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            let box = try decoder.singleValueContainer()
            if let string = try? box.decode(String.self) { text = string }
            else if let int = try? box.decode(Int.self) { text = String(int) }
            else if let double = try? box.decode(Double.self) {
                text = double.rounded() == double ? String(Int(double)) : String(double)
            }
            else if let bool = try? box.decode(Bool.self) { text = bool ? "true" : "false" }
            else { text = nil }
        }
    }

    /// A list of strings, or one string a model forgot to wrap in a list.
    private struct FlexibleList: Decodable {
        let items: [String]
        init(from decoder: Decoder) throws {
            let box = try decoder.singleValueContainer()
            if let list = try? box.decode([Flexible].self) {
                items = list.compactMap(\.text)
            } else if let one = try? box.decode(Flexible.self), let text = one.text {
                items = text.split(whereSeparator: \.isNewline).map(String.init)
            } else {
                items = []
            }
        }
    }

    private struct PartDTO: Decodable {
        var skills: FlexibleList?
        var problems: [Problem]?
        var questions: [Problem]?
        var terms: [Term]?
        var traps: FlexibleList?

        struct Problem: Decodable {
            var question: Flexible?
            var steps: FlexibleList?
            var answer: Flexible?
        }
        struct Term: Decodable {
            var term: Flexible?
            var definition: Flexible?
        }
    }

    /// "B - producing inside the frontier" is a multiple-choice answer, but
    /// models often drop the options from the question. With no A) to D)
    /// in it, the letter points at nothing, so only the explanation stays.
    static func withoutDanglingChoice(_ answer: String, for question: String) -> String {
        let hasOptions = question.range(of: #"(^|[\s(])[Aa][\)\.:]\s"#, options: .regularExpression) != nil
        guard !hasOptions,
              let letter = answer.range(of: #"^\(?[A-Da-d]\s*[\)\.\-–—:]\s*"#, options: .regularExpression)
        else { return answer }
        let rest = answer[letter.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? answer : rest
    }

    /// Reads a model's answer into a guide part, keeping only what is
    /// usable: a practice problem needs a question and an answer to check
    /// against, a term needs both halves. Nil when nothing usable remains.
    static func parseStudyGuidePart(_ raw: String, title: String, problemLimit: Int) -> StudyGuideDocument.Part? {
        guard let data = salvageJSON(raw).data(using: .utf8),
              let dto = try? JSONDecoder().decode(PartDTO.self, from: data)
        else { return nil }

        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let trimmed = PlainMath.clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func cleaned(_ list: FlexibleList?) -> [String] { (list?.items ?? []).compactMap(clean) }

        var examples: [StudyGuideDocument.Example] = []
        for problem in (dto.problems ?? []).prefix(max(1, problemLimit)) {
            guard let question = clean(problem.question?.text), let answer = clean(problem.answer?.text) else { continue }
            examples.append(.init(label: "Practice \(examples.count + 1)", question: question,
                                  steps: cleaned(problem.steps), answer: answer))
        }
        var sample = 0
        for item in (dto.questions ?? []).prefix(5) {
            guard let question = clean(item.question?.text), let answer = clean(item.answer?.text) else { continue }
            sample += 1
            examples.append(.init(label: "Sample question \(sample)", question: question, steps: [],
                                  answer: withoutDanglingChoice(answer, for: question)))
        }
        let terms = (dto.terms ?? []).prefix(8).compactMap { entry -> StudyGuideDocument.Term? in
            guard let term = clean(entry.term?.text), let definition = clean(entry.definition?.text) else { return nil }
            return .init(term: term, definition: definition)
        }
        let skills = cleaned(dto.skills)
        guard !examples.isEmpty || !skills.isEmpty else { return nil }
        return StudyGuideDocument.Part(
            title: title, skills: skills, traps: cleaned(dto.traps), examples: examples, terms: terms
        )
    }
}

// MARK: - Building a guide from decks

/// Writes practice study guides from decks: one guide per course, one part
/// per deck. Shared by every app; the caller owns the generator, the
/// progress reporting and where the result is shown.
public enum StudyGuideBuilder {
    public struct Outcome: Sendable, Equatable {
        public var guideIds: [String] = []
        /// Decks the model wrote nothing usable for, by name.
        public var skippedDecks: [String] = []
        public var partsWritten = 0
        public var wasCancelled = false

        public init() {}
    }

    /// What goes to the model for one deck.
    struct DeckSource: Sendable {
        let deck: Deck
        let text: String
        let terms: [String]
    }

    /// The deck's notes (each cut to its share of the budget) and its card
    /// terms. Nil when the deck has no note text to write from.
    static func source(for deck: Deck, wordBudget: Int, db: Database) throws -> DeckSource? {
        let materials = try OverviewQueries.materials(forDecks: [deck.id], db: db)
        let share = max(150, wordBudget / max(1, materials.count))
        var sections: [String] = []
        for material in materials {
            guard let note = try NoteText.fetchOne(db, key: material.id),
                  !note.reflowed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let text: String
            switch OverviewChunker.plan(reflowed: note.reflowed, wordCount: note.wordCount,
                                        hasMath: note.hasMath, wordBudget: share) {
            case .chunks(let chunks): text = chunks.first?.text ?? note.reflowed
            case .tooShort: text = note.reflowed
            case .tooLong: text = String(note.reflowed.prefix(share * 7))
            }
            sections.append(sections.isEmpty && materials.count == 1
                            ? text : "## \(DeckOverviewReader.lessonHeading(for: material).title)\n\(text)")
        }
        guard !sections.isEmpty else { return nil }
        let terms = try Card.fetchAll(db, sql: """
            SELECT card.* FROM card JOIN deckCard ON deckCard.cardId = card.id
            WHERE deckCard.deckId = ? AND card.deletedAt IS NULL AND card.status = 'active'
            ORDER BY deckCard.sortIndex
            """, arguments: [deck.id]).map(\.front)
        return DeckSource(deck: deck, text: sections.joined(separator: "\n\n"), terms: terms)
    }

    /// Writes the guides. `progress` (when given) gets one step per deck.
    /// Cooperative cancellation stops after the deck in flight; whatever
    /// was finished for a course is still saved.
    public static func generate(
        courseIds: [String], deckIds: [String], problemsPerDeck: Int, examEventId: String?,
        using generator: any CardGenerator, database: GRASPDatabase, now: Date = Date()
    ) async throws -> Outcome {
        let progress = AIProgress.current
        let allDecks = try await database.queue.read { db in
            try Deck.fetchAll(db).filter { deckIds.contains($0.id) && $0.deletedAt == nil }
        }
        let origin = OverviewOrigin.of(generator)
        let parser = "ai:" + (origin?.model ?? origin?.origin.rawValue ?? "model")
        progress?.expect(allDecks.count)

        // An exam belongs to one course: only that course's guide is
        // attached to it.
        let examCourseId = try await examEventId.asyncFlatMap { id in
            try await database.queue.read { try CalendarEvent.fetchOne($0, key: id)?.courseId }
        }
        var outcome = Outcome()
        for courseId in courseIds {
            let decks = Deck.ordered(allDecks.filter { $0.courseId == courseId })
            guard !decks.isEmpty,
                  let course = try await database.queue.read({ try Course.fetchOne($0, key: courseId) })
            else { continue }

            var parts: [(part: StudyGuideDocument.Part, deckId: String)] = []
            for deck in decks {
                if Task.isCancelled { outcome.wasCancelled = true; break }
                progress?.begin("Writing practice for \(deck.name)")
                defer { progress?.advance() }
                let source = try await database.queue.read {
                    try Self.source(for: deck, wordBudget: generator.overviewContextWordBudget, db: $0)
                }
                guard let source else { outcome.skippedDecks.append(deck.name); continue }
                let generated = await generator.generateStudyGuidePart(
                    deckName: deck.name, courseName: course.name, noteContext: source.text,
                    cardTerms: source.terms, problemCount: problemsPerDeck
                )
                guard var part = generated.part else { outcome.skippedDecks.append(deck.name); continue }
                part.title = deck.name
                parts.append((part, deck.id))
            }
            if outcome.wasCancelled && parts.isEmpty { break }
            guard !parts.isEmpty else { continue }

            let stamp = now.formatted(.dateTime.month(.abbreviated).day())
            let title = "\(course.name) practice set · \(stamp)"
            let document = StudyGuideDocument(
                title: title, parts: parts.enumerated().map { index, entry in
                    var part = entry.part
                    part.number = index + 1
                    return part
                }
            )
            let guide = StudyGuide(
                courseId: courseId,
                examEventId: examEventId != nil && (examCourseId == nil || examCourseId == courseId) ? examEventId : nil,
                title: title,
                bodyJSON: try StudyGuideCoding.encode(document), parser: parser,
                createdAt: now, updatedAt: now
            )
            let deckIdsInOrder = parts.map(\.deckId)
            try await database.queue.write { db in
                try guide.insert(db)
                for (index, deckId) in deckIdsInOrder.enumerated() {
                    try StudyGuidePartDeck(guideId: guide.id, partIndex: index, deckId: deckId).insert(db)
                }
            }
            outcome.guideIds.append(guide.id)
            outcome.partsWritten += parts.count
            if outcome.wasCancelled { break }
        }
        return outcome
    }
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        switch self {
        case .some(let value): return try await transform(value)
        case .none: return nil
        }
    }
}
