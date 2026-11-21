import Testing
import Foundation
@testable import GRASPCore

@Suite("Weak spots")
struct WeakSpotsTests {
    private func part(_ number: Int, skills: [(String, SkillConfidence?)] = [], examples: [String] = [],
                      decks: [String] = []) -> StudyGuideActions.PagePart {
        .init(number: number, title: "Part \(number)", questionCount: nil, sources: [], deckIds: decks,
              skills: skills.enumerated().map {
                  .init(guideId: "g", skillId: "s\(number)-\($0.offset)", text: $0.element.0, rating: $0.element.1)
              },
              traps: [],
              examples: examples.enumerated().map {
                  .init(id: "e\(number)-\($0.offset)", guideId: "g",
                        example: .init(label: "Example", question: $0.element, steps: [], answer: "answer"))
              },
              terms: [], formulas: [], remember: [], notes: [])
    }

    private func state(_ level: LearnEngine.Level, asked: Bool) -> UnderstandingState {
        UnderstandingState(pips: [], asked: asked, level: level)
    }

    @Test("a part with skills rated can't-yet and missed examples ranks above a part that is only untried")
    func ranking() {
        let parts = [
            part(1, examples: ["Q one?"], decks: ["d1"]),
            part(2, skills: [("Find the tax wedge", .cantYet), ("Read a table", .shaky), ("Explain", .canDoCold)],
                 examples: ["Q two?"], decks: ["d2"]),
            part(3, skills: [("Everything known", .canDoCold)], examples: ["Q three?"]),
        ]
        let states = [
            QuestionUnderstanding.key("Q two?"): state(.new, asked: true),
            QuestionUnderstanding.key("Q three?"): state(.mastered, asked: true),
        ]
        let spots = WeakSpots.rank(parts: parts, states: states)
        #expect(spots.map(\.partNumber) == [2, 1])
        #expect(spots[0].weakSkills == ["Find the tax wedge", "Read a table"])
        #expect(spots[0].missedExamples == 1)
        #expect(spots[1].untriedExamples == 1)
        #expect(spots[0].deckIds == ["d2"])
    }

    @Test("a part that is all understood is left out, and the list is cut to the limit")
    func limits() {
        let parts = (1...8).map { part($0, skills: [("Skill", .cantYet)]) } + [part(9, skills: [("Fine", .canDoCold)])]
        let spots = WeakSpots.rank(parts: parts, states: [:], limit: 3)
        #expect(spots.count == 3)
        #expect(!WeakSpots.rank(parts: parts, states: [:], limit: 20).map(\.partNumber).contains(9))
    }

    @Test("a page restricted to some parts keeps only those")
    func restricted() {
        let page = StudyGuideActions.ExamPage(
            exam: CalendarEvent(title: "Final", startsAt: Date()), guides: [], questionCount: nil, format: [], notes: [],
            parts: [part(1), part(2), part(3)], unreadGuides: [], isPracticeSet: false)
        let narrow = page.restricted(toParts: [page.parts[1].id])
        #expect(narrow.parts.map(\.number) == [2])
    }
}
