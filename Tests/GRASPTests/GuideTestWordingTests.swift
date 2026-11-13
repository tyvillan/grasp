import Testing
@testable import GRASP

@Suite("Guide test wording")
struct GuideTestWordingTests {
    @Test("a question with no card says Answer, a card's question says Card says")
    func expectedLabel() {
        #expect(TypedAnswerFeedback.expectedLabel(hasCard: false) == "Answer")
        #expect(TypedAnswerFeedback.expectedLabel(hasCard: true) == "Card says")
    }

    @Test("the results line names flashcard intervals only when cards were asked")
    func footnote() {
        #expect(TestResultsView.footnote(hasCards: true).hasPrefix("Cards you got right"))
        #expect(!TestResultsView.footnote(hasCards: false).lowercased().contains("card"))
    }

    @Test("a guide's setup text says nothing about code or flashcards, and has no dashes")
    func setup() {
        let text = TestSetupSheet.guideSetupMessage
        #expect(!text.lowercased().contains("code") && !text.lowercased().contains("card"))
        #expect(!text.contains("--") && !text.contains("\u{2014}") && !text.contains("\u{2013}"))
    }
}
