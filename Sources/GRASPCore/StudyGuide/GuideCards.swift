import Foundation
import GRDB

/// A study guide's worked examples as flashcards, so they sit in "All Cards"
/// and in Study, Learn and Test beside the lecture cards. Never automatic:
/// the student asks for it, once per guide, and asking again adds nothing.
///
/// One card per example that has an answer. A lettered multiple-choice
/// question keeps its five choices on the front and the chosen option's own
/// words on the back, so a typed answer is graded on the words. Anything
/// else (a multi-part question, a classify list) is the question as written
/// and the answer as written. Cards are active, in their own deck, and
/// linked to the guide's note.
public enum GuideCards {
    public struct Result: Sendable, Equatable {
        /// Cards made by this call.
        public var added = 0
        /// Examples that already have a card, kept or deleted: a second
        /// call never brings back one the student removed.
        public var alreadyThere = 0
        /// Examples with no answer, or that lean on a table or figure in
        /// the file, which a card can't show.
        public var skipped = 0
        public var deckId: String?
        public var deckName = ""
    }

    /// The front and back a card made from `example` would have, or nil
    /// when the example can't be a card.
    public static func cardText(for example: StudyGuideDocument.Example) -> (front: String, back: String)? {
        let question = example.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let answer = example.answer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty, !answer.isEmpty, example.usesFigure != true else { return nil }
        if let choice = GuideExamples.choiceItem(question: question, answer: answer) {
            return (choice.typedPrompt, choice.correctText)
        }
        return (question, answer)
    }

    /// The deck's name: the exam it prepares for, else the guide's own title.
    static func deckName(for guide: StudyGuide, db: Database) throws -> String {
        let exam = try guide.examEventId.flatMap { try CalendarEvent.fetchOne(db, key: $0) }
        return (exam?.title ?? guide.title) + " practice"
    }

    @discardableResult
    public static func addCards(guideId: String, db: Database) throws -> Result {
        var result = Result()
        guard let guide = try StudyGuide.fetchOne(db, key: guideId), let document = guide.document() else { return result }
        let deckName = try deckName(for: guide, db: db)
        result.deckName = deckName

        let existing = try Card.filter(Column("materialId") == guide.materialId).fetchAll(db)
        var known = Set(existing.map(\.front))
        var pending: [(front: String, back: String)] = []
        for example in document.parts.flatMap(\.examples) {
            guard let text = cardText(for: example) else { result.skipped += 1; continue }
            if known.contains(text.front) { result.alreadyThere += 1; continue }
            known.insert(text.front)
            pending.append(text)
        }

        var deck = try Deck.filter(Column("courseId") == guide.courseId && Column("name") == deckName
                                   && Column("deletedAt") == nil).fetchOne(db)
        if deck == nil, !pending.isEmpty {
            let id = try LibraryActions.createDeck(courseId: guide.courseId, name: deckName, db: db)
            deck = try Deck.fetchOne(db, key: id)
        }
        result.deckId = deck?.id
        guard let deck else { return result }

        var sortIndex = try Int.fetchOne(db, sql:
            "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM deckCard WHERE deckId = ?", arguments: [deck.id]) ?? 0
        for text in pending {
            let card = Card(materialId: guide.materialId, front: text.front, back: text.back,
                            hasMath: text.back.contains("\\(") || text.back.contains("\\["),
                            origin: .manual, status: .active)
            try card.insert(db)
            try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: sortIndex).insert(db)
            sortIndex += 1
            result.added += 1
        }
        return result
    }
}
