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

    @Test("a card-less AI question merges with card-built questions and survives a shuffle")
    func aiQuestionSurvivesMergeAndShuffle() {
        var rng = SystemRandomNumberGenerator()
        let config = TestBuilder.Config(questionCount: 5)
        let cardQuestions = TestBuilder.build(from: Self.cards(count: 10), config: config, using: &rng)
        let aiQuestion = LearnEngine.RoundQuestion(
            cardId: nil, prompt: "AI-authored question", correctAnswer: "AI-authored answer", type: .written
        )
        var merged = cardQuestions + [aiQuestion]
        merged.shuffle(using: &rng)

        #expect(merged.count == cardQuestions.count + 1)
        let survived = try! #require(merged.first { $0.cardId == nil })
        #expect(survived.prompt == "AI-authored question")
        #expect(survived.correctAnswer == "AI-authored answer")
        #expect(survived.type == .written)
        // Every card-backed question still has a unique, stable id distinct
        // from the AI question's freshly-synthesized one.
        #expect(Set(merged.map(\.id)).count == merged.count)
    }

    // MARK: - Question-style prompts are never True/False

    private static func mixedCards() -> [(cardId: String, front: String, back: String)] {
        let questions = ["Which tool connects an AI to outside apps?", "What does a hallucination mean",
                         "How is Culture Fit defined", "Why does token count matter",
                         "According to the notes, which model is suggested", "Who wrote the report",
                         "When is the exam held", "Where are the files stored", "Name the three components"]
        let statements = (0..<12).map { "Term \($0)" }
        return (questions + statements).enumerated().map {
            (cardId: "card-\($0.offset)", front: $0.element, back: "Definition \($0.offset)")
        }
    }

    @Test("a question-style prompt is never asked as true/false, over many random builds")
    func questionPromptsNeverTrueFalse() {
        for _ in 0..<60 {
            var rng = SystemRandomNumberGenerator()
            let questions = TestBuilder.build(from: Self.mixedCards(), config: .init(questionCount: 21), using: &rng)
            #expect(questions.count == 21)
            for question in questions where question.type == .trueFalse {
                #expect(!LearnEngine.isQuestionPrompt(question.prompt))
            }
        }
    }

    @Test("statement prompts can still be true/false")
    func statementsStayTrueFalse() {
        var rng = SystemRandomNumberGenerator()
        let questions = TestBuilder.build(from: Self.cards(count: 30), config: .init(questionCount: 30), using: &rng)
        #expect(questions.contains { $0.type == .trueFalse })
    }

    @Test("with every prompt a question, the types still come out balanced across the two left")
    func balancedWhenAllQuestions() {
        let cards = (0..<30).map { (cardId: "q-\($0)", front: "What is term \($0)?", back: "Definition \($0)") }
        var rng = SystemRandomNumberGenerator()
        let questions = TestBuilder.build(from: cards, config: .init(questionCount: 30), using: &rng)
        #expect(questions.allSatisfy { $0.type != .trueFalse })
        let mc = questions.filter { $0.type == .multipleChoice }.count
        let written = questions.filter { $0.type == .written }.count
        #expect(mc + written == 30)
        #expect(abs(mc - written) <= 1)
    }

    @Test("a mixed deck keeps the three types within one of even when question prompts are swapped out")
    func cycleStaysBalancedOnMixedDeck() {
        var rng = SystemRandomNumberGenerator()
        let questions = TestBuilder.build(from: Self.mixedCards(), config: .init(questionCount: 21), using: &rng)
        let counts = [LearnEngine.QuestionType.multipleChoice, .written, .trueFalse]
            .map { type in questions.filter { $0.type == type }.count }
        // Question prompts that land on a True/False slot go to the other
        // two types, so those two carry the extra and True/False the fewer.
        #expect(counts[0] + counts[1] + counts[2] == 21)
        #expect(abs(counts[0] - counts[1]) <= 2)
        #expect(counts[2] <= 7)
    }

    @Test("true/false only: question prompts are left out rather than asked")
    func trueFalseOnlyDropsQuestions() {
        var rng = SystemRandomNumberGenerator()
        let config = TestBuilder.Config(questionCount: 30, allowMultipleChoice: false, allowWritten: false, allowTrueFalse: true)
        let questions = TestBuilder.build(from: Self.mixedCards(), config: config, using: &rng)
        #expect(questions.count == 12)
        #expect(questions.allSatisfy { $0.type == .trueFalse && !LearnEngine.isQuestionPrompt($0.prompt) })
    }

    @Test("what counts as a question prompt")
    func questionDetection() {
        #expect(LearnEngine.isQuestionPrompt("Which tool is best?"))
        #expect(LearnEngine.isQuestionPrompt("  what happens at 90% usage"))
        #expect(LearnEngine.isQuestionPrompt("According to the lecture notes, which tool is suggested"))
        #expect(LearnEngine.isQuestionPrompt("Explain the pigeonhole principle"))
        #expect(LearnEngine.isQuestionPrompt("Is a matrix invertible?"))
        #expect(!LearnEngine.isQuestionPrompt("Additivity condition"))
        #expect(!LearnEngine.isQuestionPrompt("Context vault"))
        #expect(!LearnEngine.isQuestionPrompt("Whichever-first scheduling"))
        #expect(!LearnEngine.isQuestionPrompt(""))
    }
}
