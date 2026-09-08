import Testing
@testable import GRASPCore

@Suite("TestBuilder")
struct TestBuilderTests {
    private static func cards(count: Int) -> [(cardId: String, front: String, back: String)] {
        (0..<count).map { (cardId: "card-\($0)", front: "Term \($0)", back: "Definition \($0)") }
    }

    @Test("a test has exactly the configured question count when enough cards exist")
    func respectsQuestionCount() {
        var rng = SystemRandomNumberGenerator()
        let questions = TestBuilder.build(from: Self.cards(count: 30), config: .init(questionCount: 10), using: &rng)
        #expect(questions.count == 10)
    }

    @Test("a test is capped by the available cards, not the configured count")
    func cappedByAvailableCards() {
        var rng = SystemRandomNumberGenerator()
        let questions = TestBuilder.build(from: Self.cards(count: 3), config: .init(questionCount: 20), using: &rng)
        #expect(questions.count == 3)
    }

    @Test("disabling all question types produces no questions")
    func noEnabledTypesProducesNothing() {
        var rng = SystemRandomNumberGenerator()
        let config = TestBuilder.Config(allowMultipleChoice: false, allowWritten: false, allowTrueFalse: false)
        let questions = TestBuilder.build(from: Self.cards(count: 10), config: config, using: &rng)
        #expect(questions.isEmpty)
    }

    @Test("a written-only test produces only written questions")
    func writtenOnlyConfig() {
        var rng = SystemRandomNumberGenerator()
        let config = TestBuilder.Config(questionCount: 5, allowMultipleChoice: false, allowWritten: true, allowTrueFalse: false)
        let questions = TestBuilder.build(from: Self.cards(count: 10), config: config, using: &rng)
        #expect(questions.allSatisfy { $0.type == .written })
    }

    @Test("every multiple-choice question includes its own correct answer among the choices")
    func multipleChoiceIncludesCorrectAnswer() {
        var rng = SystemRandomNumberGenerator()
        let config = TestBuilder.Config(questionCount: 8, allowMultipleChoice: true, allowWritten: false, allowTrueFalse: false)
        let questions = TestBuilder.build(from: Self.cards(count: 12), config: config, using: &rng)
        for question in questions {
            let choices = try! #require(question.choices)
            #expect(choices.contains(question.correctAnswer))
        }
    }
}
