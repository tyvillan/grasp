import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Understanding meter")
struct UnderstandingMeterTests {
    typealias Pip = UnderstandingState.Pip

    @Test("every learn level maps to its pips and words")
    func levels() {
        let cases: [(LearnEngine.Level?, [Pip], String, String)] = [
            (nil, [.empty, .empty, .empty], "New", "New"),
            (.new, [.empty, .empty, .empty], "New", "New"),
            (.recognition, [.solid, .empty, .empty], "Recognition", "Recognition, 1 of 3 steps"),
            (.recall, [.solid, .solid, .empty], "Recall", "Recall, 2 of 3 steps"),
            (.mastered, [.solid, .solid, .solid], "Understood", "Understood, 3 of 3 steps"),
            (.familiar, [.dotted, .dotted, .empty], "Self-rated", "Self-rated, not yet tested"),
        ]
        for (level, pips, word, label) in cases {
            let state = UnderstandingState.of(level: level)
            #expect(state.pips == pips, "\(String(describing: level))")
            #expect(state.word == word)
            #expect(state.accessibilityLabel == label)
        }
    }

    @Test("a card asked and missed is not the same as one never asked")
    func askedAndMissed() {
        let missed = UnderstandingState.of(level: .new, asked: true)
        #expect(missed.asked)
        #expect(missed.word == "Not yet")
        #expect(missed.accessibilityLabel == "Not yet recognized, 0 of 3 steps")
        #expect(!UnderstandingState.of(level: .new, asked: false).asked)
        #expect(UnderstandingState.of(level: nil).asked == false)
    }

    @Test("self-rated is never counted as solid")
    func selfRated() {
        let state = UnderstandingState.of(level: .familiar)
        #expect(state.solidCount == 0)
        #expect(state.isSelfRated)
        #expect(!state.isMastered)
        #expect(UnderstandingState.of(level: .mastered).solidCount == 3)
    }

    private func card(_ id: String, _ note: String?, _ level: LearnEngine.Level?, asked: Bool? = nil) -> DeckUnderstanding.Card {
        .init(id: id, materialId: note, state: .of(level: level, asked: asked))
    }

    @Test("an empty deck has no cards and says so")
    func emptyDeck() {
        let d = DeckUnderstanding.distribution(of: [])
        #expect(d.total == 0)
        #expect(d.line == "No cards yet")
        #expect(DeckUnderstanding.weakestNotes(of: []).isEmpty)
        #expect(DeckUnderstanding.practiceCards(of: []).isEmpty)
    }

    @Test("all new, all solid, and mixed decks count and read correctly")
    func distributions() {
        let allNew = (0..<4).map { card("n\($0)", "a", nil) }
        #expect(DeckUnderstanding.distribution(of: allNew).notAsked == 4)
        #expect(DeckUnderstanding.distribution(of: allNew).line == "4 not asked")

        let allSolid = (0..<3).map { card("s\($0)", "a", .mastered) }
        let solid = DeckUnderstanding.distribution(of: allSolid)
        #expect(solid.solid == 3 && solid.solidShare == 1)
        #expect(DeckUnderstanding.weakestNotes(of: allSolid).isEmpty)

        let mixed = [card("1", "a", .mastered), card("2", "a", .recall), card("3", "a", .recognition),
                     card("4", "a", .familiar), card("5", "a", nil), card("6", "a", .new, asked: true)]
        let d = DeckUnderstanding.distribution(of: mixed)
        #expect(d == { var x = DeckUnderstanding.Distribution(); x.solid = 1; x.recall = 1; x.recognition = 1; x.selfRated = 1; x.notAsked = 2; return x }())
        #expect(d.line == "1 understood, 1 recall, 1 recognition, 1 self-rated, 2 not asked")
    }

    @Test("weakest notes are ranked by share solid, then by size, with cards without a note in Other")
    func weakest() {
        var cards: [DeckUnderstanding.Card] = []
        // note a: 1 of 4 solid (0.25)
        cards += [card("a1", "a", .mastered), card("a2", "a", nil), card("a3", "a", nil), card("a4", "a", nil)]
        // note b: 1 of 2 solid (0.5)
        cards += [card("b1", "b", .mastered), card("b2", "b", .recall)]
        // note c: 1 of 4 solid (0.25), same share as a, same size, comes later
        cards += [card("c1", "c", .mastered), card("c2", "c", nil), card("c3", "c", nil), card("c4", "c", nil)]
        // note d: 1 of 8 solid, the weakest
        cards += [card("d1", "d", .mastered)] + (2...8).map { card("d\($0)", "d", nil) }
        // no note
        cards += [card("o1", nil, nil), card("o2", nil, .recognition)]
        // note e: all solid, left out
        cards += [card("e1", "e", .mastered)]

        let weak = DeckUnderstanding.weakestNotes(of: cards)
        #expect(weak.map(\.materialId) == [nil, "d", "a", "c", "b"])
        #expect(weak[0].id == "other")
        #expect(weak[0].summary == "0 of 2 understood")
        #expect(weak[1].summary == "1 of 8 understood")
        #expect(DeckUnderstanding.weakestNotes(of: cards, limit: 2).count == 2)
        #expect(!weak.contains { $0.materialId == "e" })
    }

    @Test("ties break by card count, then by first appearance")
    func ties() {
        let cards = [card("x1", "x", nil), card("y1", "y", nil), card("y2", "y", nil), card("z1", "z", nil)]
        let weak = DeckUnderstanding.weakestNotes(of: cards)
        #expect(weak.map(\.materialId) == ["y", "x", "z"])
    }

    @Test("practice cards skip mastered, put missed first, and stop at the cap")
    func practice() {
        let cards = [card("m", "a", .mastered), card("f", "a", .familiar), card("r", "a", .recall),
                     card("g", "a", .recognition), card("n", "a", nil), card("x", "a", .new, asked: true)]
        #expect(DeckUnderstanding.practiceCards(of: cards) == ["x", "n", "g", "r", "f"])
        let many = (0..<20).map { card("c\($0)", "a", nil) }
        #expect(DeckUnderstanding.practiceCards(of: many).count == 8)
        #expect(DeckUnderstanding.practiceCards(of: many, limit: 3).count == 3)
    }

    @Test("the database read gives a state and a note for every card, and never changes a level")
    func fromDatabase() async throws {
        let db = try GRASPDatabase.inMemory()
        let (deckId, learned) = try await db.queue.write { conn -> (String, String) in
            let course = Course(semesterId: nil, name: "C"); try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "D"); try deck.insert(conn)
            let material = Material(courseId: course.id, relativePath: "n.md", kind: .markdown, title: "N")
            try material.insert(conn)
            var ids: [String] = []
            for i in 0..<3 {
                let card = Card(materialId: i == 2 ? nil : material.id, front: "f\(i)", back: "b\(i)", origin: .manual, status: .active)
                try card.insert(conn)
                try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: i).insert(conn)
                ids.append(card.id)
            }
            try LearnState(cardId: ids[0], level: 2, consecutiveCorrect: 1, lastSeenAt: Date()).save(conn)
            try LearnState(cardId: ids[1], level: 4, consecutiveCorrect: 0, lastSeenAt: Date()).save(conn)
            return (deck.id, ids[0])
        }
        let cards = try await db.queue.read { try Study.understanding(forDecks: [deckId], db: $0) }
        #expect(cards.count == 3)
        #expect(cards.first { $0.id == learned }?.state.level == .recall)
        #expect(cards.filter { $0.state.isSelfRated }.count == 1)
        #expect(cards.filter { !$0.state.asked }.count == 1)
        #expect(cards.filter { $0.materialId == nil }.count == 1)
        let again = try await db.queue.read { try Study.learnLevels(forDecks: [deckId], db: $0) }
        #expect(again[learned] == .recall)
    }

    @Test("the display state after an answer follows the existing ladder rules")
    func afterAnswer() {
        func after(_ level: LearnEngine.Level?, _ correct: Bool, asked: Bool? = nil) -> UnderstandingState {
            UnderstandingState.of(level: level, asked: asked).afterAnswer(correct: correct)
        }
        #expect(after(.recognition, true).level == .recall)
        #expect(after(.recall, true).level == .mastered)
        #expect(after(.recall, false).level == .recognition)
        #expect(after(.mastered, true).level == .mastered)
        #expect(after(.mastered, false).level == .recall)
        #expect(after(.familiar, true).level == .mastered)
        #expect(after(.familiar, false).level == .recognition)
        #expect(after(nil, true).level == .recognition)
        #expect(after(nil, false).level == .new)
        // A miss on a never-asked card leaves it at the start, now asked.
        #expect(after(nil, false).asked)
        // It uses the engine's own function, so the two can't drift.
        for level in [LearnEngine.Level.new, .recognition, .recall, .mastered, .familiar] {
            for correct in [true, false] {
                let expected = LearnEngine.advance(level: level, consecutiveCorrect: 0, wasCorrect: correct).level
                #expect(UnderstandingState.of(level: level).afterAnswer(correct: correct).level == expected)
            }
        }
    }

    @Test("a change of level gets one line, and no change gets none")
    func captions() {
        func caption(_ from: LearnEngine.Level?, _ correct: Bool) -> String? {
            let before = UnderstandingState.of(level: from)
            return UnderstandingState.changeCaption(from: before, to: before.afterAnswer(correct: correct))
        }
        #expect(caption(.recall, true) == "Recall to understood")
        #expect(caption(.recognition, true) == "Recognition to recall")
        #expect(caption(.recall, false) == "Back to recognition")
        #expect(caption(.mastered, false) == "Back to recall")
        #expect(caption(.familiar, true) == "Self-rated to understood")
        #expect(caption(.familiar, false) == "Back to recognition")
        #expect(caption(.recognition, false) == "Back to the start")
        #expect(caption(.mastered, true) == nil)
        #expect(caption(.new, false) == nil)
    }

    @Test("a card has progress when any pip is filled or dotted")
    func progress() {
        #expect(!UnderstandingState.of(level: nil).hasProgress)
        #expect(!UnderstandingState.of(level: .new, asked: true).hasProgress)
        #expect(UnderstandingState.of(level: .recognition).hasProgress)
        #expect(UnderstandingState.of(level: .familiar).hasProgress)
        #expect(UnderstandingState.of(level: .mastered).hasProgress)
    }

    @Test("a note's title is its first heading, else its file name made readable")
    func titles() {
        let withHeading = "---\ncourse: x\n---\n\n# Module 5 \u{2014} Midterm Review Overview\n\ntext"
        #expect(NoteTitle.readable(raw: withHeading, fileName: "2026-10-06_Module-05_Midterm") == "Module 5 \u{2014} Midterm Review Overview")
        #expect(NoteTitle.readable(raw: "# 2026-08-25 \u{00B7} Module 1 \u{2014} First Day", fileName: "x") == "Module 1 \u{2014} First Day")
        #expect(NoteTitle.readable(raw: "no heading here\n\n## Second level", fileName: "x") == "Second level")
        #expect(NoteTitle.readable(raw: "```\n# comment in code\n```\ntext", fileName: "2026-09-08_Module-03_C++-Basics-and-Functions.md")
                == "Module 03 C++ Basics and Functions")
        #expect(NoteTitle.readable(raw: nil, fileName: "Module-03_Flow-of-Control-and-Functions") == "Module 03 Flow of Control and Functions")
        #expect(NoteTitle.readable(raw: "", fileName: "00_Course-Roadmap") == "Course Roadmap")
    }
}
