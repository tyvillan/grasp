import Testing
import Foundation
import GRDB
@testable import GRASPCore

// Rules (a) to (e) from the generation-quality audit. The examples are the
// real ones found in the library.

// MARK: - (a) Refusals and filler

@Suite("Card quality: refusal answers")
struct RefusalAnswerTests {
    @Test("each phrase from the audit is a refusal, in any case")
    func phrases() {
        let refusals = [
            "A transformation or concept not explicitly defined in the provided notes.",
            "A combined condition for linear transformations, though not explicitly defined with that exact algebraic formula in the notes.",
            "This is NOT DEFINED IN THE PROVIDED material.",
            "The term is not mentioned in the notes.",
            "Not mentioned in the lecture.",
            "That is not specified in the notes.",
            "The answer cannot be determined from the text.",
            "It can't be determined from the provided context.",
            "There is no information about this in the note.",
            "No information available.",
            "No information provided in the notes.",
            "Insufficient information is provided to answer.",
            "Not enough information to say.",
            "The notes do not define this term.",
            "The provided text does not mention it.",
            "I cannot answer this from the notes.",
            "As an AI, I don't have the notes.",
        ]
        for text in refusals {
            #expect(CardQuality.isRefusal(text), "should be a refusal: \(text)")
        }
    }

    @Test("a bare reply of that kind is a refusal")
    func bareReplies() {
        for text in ["No information", "N/A", "Unknown", "Not specified.", "Not defined", "None provided", "Cannot be determined"] {
            #expect(CardQuality.isRefusal(text), "should be a refusal: \(text)")
        }
    }

    @Test("a real answer that happens to use the words is not")
    func realAnswersPass() {
        let answers = [
            "A lossless code is one that discards no information.",
            "The chain rule applies when a function is defined in terms of another function.",
            "A variable that is not defined in the current scope raises a NameError.",
            "Slope is defined as dy/dx, representing rise over run.",
            "An unknown quantity in an equation, usually written x.",
            "The notes app stores text; it does not mention graphs.",
            "Entropy measures the average information per symbol.",
            "Not-a-number (NaN) is the result of 0/0.",
        ]
        for text in answers {
            #expect(!CardQuality.isRefusal(text), "should pass: \(text)")
        }
    }

    @Test("an empty answer is not called a refusal (other checks handle empty)")
    func emptyAnswer() {
        #expect(!CardQuality.isRefusal(""))
        #expect(!CardQuality.isRefusal("   "))
    }

    @Test("the problem for a card reports a refusal first")
    func cardProblem() {
        #expect(CardQuality.problem(front: "Unit square", back: "A transformation or concept not explicitly defined in the provided notes.") == .refusal)
        #expect(CardQuality.problem(front: "Unit square", back: "The square with corners at (0,0) and (1,1).") == nil)
    }
}

// MARK: - (b) "Which of the following" with no options

@Suite("Card quality: questions that ask to choose with no options")
struct MissingOptionsTests {
    @Test("a choose-from-options question with no options is flagged")
    func missing() {
        let prompts = [
            "Which of the following is a key difference between the Data layer and the Presentation layer in a three-layer architecture?",
            "Which one of the following is the base case?",
            "Select all that apply: which are mutable types?",
            "Choose the correct statement about composition.",
            "Choose the best description of polymorphism.",
            "Which of these is a sorting algorithm?",
            "WHICH OF THE FOLLOWING IS TRUE?",
        ]
        for prompt in prompts {
            #expect(CardQuality.hasMissingOptions(prompt), "should be flagged: \(prompt)")
        }
    }

    @Test("the same question with options is fine")
    func withOptions() {
        let lettered = "Which of the following is a sorting algorithm?\nA) Dijkstra\nB) Quicksort\nC) Prim"
        let numbered = "Which of the following is true?\n1. A stack is FIFO\n2. A queue is FIFO"
        let bullets = "Choose the correct statement.\n- Arrays are fixed size\n- Lists are fixed size"
        let inline = "Which of the following is a sorting algorithm? (a) Dijkstra (b) Quicksort (c) Prim"
        for prompt in [lettered, numbered, bullets, inline] {
            #expect(!CardQuality.hasMissingOptions(prompt), "should pass: \(prompt)")
        }
    }

    @Test("a question that is not a choose-from-options one is fine")
    func ordinaryQuestions() {
        for prompt in ["What is the difference between a getter and a setter?", "Which principle says a class has one job?",
                       "Choose a name for each variable.".replacingOccurrences(of: "Choose a", with: "Pick a")] {
            #expect(!CardQuality.hasMissingOptions(prompt), "should pass: \(prompt)")
        }
    }

    @Test("a written test question and a card front are both checked")
    func bothPaths() {
        #expect(CardQuality.problem(prompt: "Which of the following is a key difference between X and Y?", answer: "Z is lower.") == .missingOptions)
        #expect(CardQuality.problem(front: "Which of the following is a sorting algorithm?", back: "Quicksort") == .missingOptions)
        #expect(CardQuality.problem(prompt: "What is encapsulation?", answer: "Hiding data behind methods.") == nil)
    }

    @Test("a refusal answer is caught on a test question too")
    func refusalOnQuestion() {
        #expect(CardQuality.problem(prompt: "What is a martingale?", answer: "Not defined in the provided notes.") == .refusal)
    }
}

// MARK: - (c) Placeholder fronts

@Suite("Card quality: fronts that are only a heading or label")
struct PlaceholderFrontTests {
    @Test("assignment and heading labels from the audit are placeholders")
    func labels() {
        let fronts = [
            "HOMEWORK 2", "HOMEWORK 4", "Homework 12", "Task", "Run A", "Run B", "Part 3", "Part B", "Problem 5",
            "Lecture 7", "Week 4", "part2", "Example 2.1.4", "Case II", "Task 2 - Exponent operator", "Exercise 3: (35 points) Shopping List", "Exercise 1: Custom Module (100 points)", "Exercise 2: Bonus (10 points)",
            "Week 3: SOLID principles", "Section 1.2", "Quiz 3", "Lab 5", "Instructions", "Deliverables",
            "Submission Format", "Report Contents", "**HOMEWORK 2**", "Problem 5.", "chapter 9",
        ]
        for front in fronts {
            #expect(CardQuality.isPlaceholderFront(front), "should be a placeholder: \(front)")
        }
    }

    @Test("a short front that is a real term passes")
    func realTermsPass() {
        let fronts = [
            "Set", "Eigenvalue", "Pivot", "Union", "Abstraction", "Class", "Stack", "Queue", "Thread", "Process",
            "Task scheduler", "Problem solving", "Part of speech", "Run time complexity", "Test statistic",
            "Step function", "Case study", "Unit vector", "Exercise physiology", "Lecture notes", "Weekly review",
            "Lab report format", "Random variable", "setf", "stepper", "File mode w", "Set A", "Table of contents", "Page rank", "Homework policy for late work", "What is a task?",
            "Problem 5: Prove that every bounded monotone sequence of real numbers converges to a limit",
        ]
        for front in fronts {
            #expect(!CardQuality.isPlaceholderFront(front), "should pass: \(front)")
        }
    }

    @Test("the card problem reports a placeholder front")
    func cardProblem() {
        #expect(CardQuality.problem(front: "HOMEWORK 2", back: "A structured submission requirement.") == .placeholderFront)
        #expect(CardQuality.problem(front: "Eigenvalue", back: "A scalar λ with Ax = λx for some nonzero x.") == nil)
    }
}

// MARK: - (d) Near duplicates

@Suite("Card quality: near duplicates")
struct NearDuplicateTests {
    @Test("exact duplicates are caught")
    func exact() {
        #expect(CardQuality.areNearDuplicates(
            front: "What is the intersection of two sets?",
            back: "The intersection of two sets is the set of all elements that are common to both sets.",
            otherFront: "What is the intersection of two sets?",
            otherBack: "The intersection of two sets is the set of all elements that are common to both sets."))
    }

    @Test("a reworded duplicate is caught")
    func reworded() {
        // The real pair: the same term asked two ways, the same answer.
        #expect(CardQuality.areNearDuplicates(
            front: "What is an intersection?",
            back: "The intersection of two sets is the set of all elements that are common to both sets.",
            otherFront: "What is the intersection of two sets?",
            otherBack: "The intersection of two sets is the set of all elements common to both of the sets."))
        // Same term, a longer front, an answer reworded.
        #expect(CardQuality.areNearDuplicates(
            front: "Polymorphism",
            back: "Allows methods with the same name to behave differently depending on the object they are called on.",
            otherFront: "Polymorphism in Python",
            otherBack: "Allowing methods with the same name to behave differently depending on the object they are called on."))
        // Same words, front order changed.
        #expect(CardQuality.areNearDuplicates(
            front: "Time complexity of binary search",
            back: "Binary search takes O(log n) time because each step halves the remaining range of the sorted array.",
            otherFront: "Binary search time complexity",
            otherBack: "Each step of a binary search halves the remaining range of the sorted array, so it takes O(log n) time."))
    }

    @Test("two cards with the same front but genuinely different answers are both kept")
    func sameFrontDifferentAnswers() {
        #expect(!CardQuality.areNearDuplicates(
            front: "Mean",
            back: "The sum of the values divided by how many there are, used to describe the centre of a data set.",
            otherFront: "Mean",
            otherBack: "In a geometric sequence, the number between two terms whose ratio to each neighbour is equal."))
        #expect(!CardQuality.areNearDuplicates(
            front: "Set", back: "Collection of objects",
            otherFront: "Set", otherBack: "A well-defined group of distinct elements written in braces"))
    }

    @Test("sibling terms that differ by one word are both kept")
    func siblings() {
        let pairs: [(String, String, String, String)] = [
            ("Left inverse", "A matrix that multiplies on the left of another to give the identity matrix.",
             "Right inverse", "A matrix that multiplies on the right of another to give the identity matrix."),
            ("Perfectly elastic supply", "Sellers can avoid the tax entirely, so buyers bear 100% of it.",
             "Perfectly inelastic supply", "Sellers cannot avoid the tax, so they bear 100% of it."),
            ("Default private access", "Every member of a class is private unless something states otherwise.",
             "Default public access", "Every member of a struct is public unless something states otherwise."),
            ("Pet Object 1", "ID: 1, name: Fluffy, type: cat, weight: 6.2, age: 8",
             "Pet Object 2", "ID: 2, name: Frank, type: cat, weight: 8.0, age: 3"),
            ("File mode w", "The argument to open that requests write access, replacing the existing contents of the file.",
             "File mode r", "The argument to open that requests read access to an existing file, which must be there."),
            ("File mode a", "The argument to open that appends new content to the end of the file.",
             "File mode w", "The argument to open that requests write access to the file, replacing its content."),
            ("While loop", "A loop testing its condition before each pass, so it may run zero times.",
             "Do-while loop", "A loop testing its condition after each pass, so it runs at least once."),
        ]
        for (f1, b1, f2, b2) in pairs {
            #expect(!CardQuality.areNearDuplicates(front: f1, back: b1, otherFront: f2, otherBack: b2), "\(f1) / \(f2)")
        }
    }

    @Test("short different answers are never duplicates, even for the same front")
    func shortAnswers() {
        #expect(!CardQuality.areNearDuplicates(front: "Binary search", back: "O(log n)",
                                               otherFront: "Binary search", otherBack: "O(n)"))
        #expect(CardQuality.areNearDuplicates(front: "Set", back: "Collection of objects (elements of a set)",
                                              otherFront: "Set Notation and Relations",
                                              otherBack: "Collection of objects (elements of a set)"))
    }

    @Test("a duplicate inside the generation index is found, semantic only when asked")
    func indexSemantic() {
        var index = DuplicateDetector.Index([])
        index.insert(id: "a", front: "What is the intersection of two sets?",
                     back: "The intersection of two sets is the set of all elements that are common to both sets.")
        let front = "What is an intersection?"
        let back = "The intersection of two sets is the set of all elements common to both of the sets."
        #expect(index.matchId(front: front, back: back) == nil)
        #expect(index.matchId(front: front, back: back, semantic: true) == "a")
        #expect(index.matchId(front: "What is the union of two sets?",
                              back: "The union of two sets is the set of all elements that are in A, in B, or in both.",
                              semantic: true) == nil)
    }
}

// MARK: - (e) Flags on parser-made cards

@Suite("Card quality: flags on parser-made cards")
struct ReviewNoteTests {
    private func card(_ front: String, _ back: String, origin: CardOrigin = .parser,
                      status: CardStatus = .draft) -> Card {
        Card(materialId: nil, front: front, back: back, origin: origin, status: status)
    }

    @Test("a heading front and a later duplicate are flagged, nothing else is")
    func flags() {
        let heading = card("HOMEWORK 2", "A structured submission requirement.")
        let first = card("What is the intersection of two sets?",
                         "The intersection of two sets is the set of all elements that are common to both sets.")
        let copy = card("What is an intersection?",
                        "The intersection of two sets is the set of all elements common to both of the sets.")
        let other = card("Union", "The set of all elements that are in A, in B, or in both.")
        let notes = CardQuality.reviewNotes(for: [heading, first, copy, other])
        #expect(notes[heading.id] == "This front looks like a heading.")
        #expect(notes[copy.id]?.hasPrefix("Looks like a duplicate of ") == true)
        #expect(notes[copy.id]?.contains("What is the intersection of two sets?") == true)
        #expect(notes[first.id] == nil)
        #expect(notes[other.id] == nil)
    }

    @Test("only parser-made drafts are flagged; approved, manual and AI cards are not")
    func onlyParserDrafts() {
        let back = "The intersection of two sets is the set of all elements that are common to both sets."
        let first = card("Intersection", back)
        let approved = card("Intersection", back, status: .active)
        let manual = card("Intersection", back, origin: .manual)
        let ai = card("Intersection", back, origin: .aiGenerated)
        let draft = card("HOMEWORK 2", "x y z", origin: .parser, status: .active)
        let notes = CardQuality.reviewNotes(for: [first, approved, manual, ai, draft])
        #expect(notes.isEmpty)
    }

    @Test("a large deck is flagged quickly and siblings are left alone")
    func largeDeck() {
        var cards: [Card] = []
        for i in 0..<600 {
            cards.append(card("Term \(i) alpha", "Definition number \(i) about topic \(i % 17) with words \(i * 7) and \(i * 13)."))
        }
        let started = ContinuousClock.now
        let notes = CardQuality.reviewNotes(for: cards)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(notes.isEmpty)
    }
}

// MARK: - Where the checks are applied

@Suite("Card quality: applied when cards are generated")
struct GenerationAppliedTests {
    private final class Generator: CardGenerator, @unchecked Sendable {
        var proposals: [GeneratedCard] = []
        var refined: [GeneratedCard]?
        var verdict: ContextValidation.Verdict = .valid
        var isAvailable: Bool { get async { true } }
        var overviewContextWordBudget: Int { 1_800 }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] {
            refined ?? candidates.map { GeneratedCard(front: $0.front, back: $0.back) }
        }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] {
            proposals
        }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] { [] }
        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
            ContextValidation(verdict)
        }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                              includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                             sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
    }

    private func makeDeck() async throws -> (GRASPDatabase, deckId: String, cardId: String) {
        let db = try GRASPDatabase.inMemory()
        let ids = try await db.queue.write { conn -> (String, String) in
            let course = Course(semesterId: nil, name: "Software Design")
            try course.insert(conn)
            let deck = Deck(courseId: course.id, name: "Week 3")
            try deck.insert(conn)
            let material = Material(courseId: course.id, relativePath: "/v/w3.md", kind: .markdown, contentHash: "h", title: "W3")
            try material.insert(conn)
            let text = "Slots restrict attributes. Sets collect objects."
            try NoteText(materialId: material.id, raw: text, reflowed: text, wordCount: 6, hasMath: false).insert(conn)
            let card = Card(materialId: material.id, front: "Set", back: "Collection of objects (elements of a set)",
                            origin: .parser, status: .draft)
            try card.insert(conn)
            try DeckCard(deckId: deck.id, cardId: card.id, sortIndex: 0).insert(conn)
            return (deck.id, card.id)
        }
        return (db, ids.0, ids.1)
    }

    private func liveCards(_ db: GRASPDatabase) async throws -> [Card] {
        try await db.queue.read { try Card.filter(Column("deletedAt") == nil).fetchAll($0) }
    }

    @Test("refusals, headings, option-less choices and copies are dropped; the good card is kept")
    func dropsBadProposals() async throws {
        let (db, deckId, _) = try await makeDeck()
        let generator = Generator()
        generator.proposals = [
            GeneratedCard(front: "Unit square", back: "A transformation or concept not explicitly defined in the provided notes."),
            GeneratedCard(front: "HOMEWORK 2", back: "A structured submission requirement."),
            GeneratedCard(front: "Which of the following is a collection?", back: "A set."),
            GeneratedCard(front: "Set Notation and Relations", back: "Collection of objects (elements of a set)"),
            GeneratedCard(front: "__slots__", back: "A class attribute that fixes which instance attributes exist, so no per-instance dictionary is made."),
            // A reworded copy of the one just above, in the same batch.
            GeneratedCard(front: "What is __slots__?", back: "A class attribute that fixes which instance attributes exist, so no per-instance dictionary is created."),
        ]
        let outcome = await CardAI.generateAdditionalCardsOutcome(inDecks: [deckId], using: generator, database: db)
        #expect(outcome == .added(1))
        let fronts = try await liveCards(db).map(\.front).sorted()
        #expect(fronts == ["Set", "__slots__"])
    }

    @Test("a rewrite that says the notes don't define it is not applied")
    func refineKeepsOriginalOnRefusal() async throws {
        let (db, _, cardId) = try await makeDeck()
        let generator = Generator()
        generator.refined = [GeneratedCard(front: "Set", back: "Not explicitly defined in the provided notes.")]
        let card = try await db.queue.read { try Card.fetchOne($0, key: cardId)! }
        let changed = await CardAI.refineWording(of: [card], using: generator, database: db)
        #expect(changed == 0)
        let after = try await db.queue.read { try Card.fetchOne($0, key: cardId)! }
        #expect(after.back == "Collection of objects (elements of a set)")
        #expect(after.origin == .parser)
        // A real rewrite still lands.
        generator.refined = [GeneratedCard(front: "Set", back: "An unordered collection of distinct objects.")]
        #expect(await CardAI.refineWording(of: [card], using: generator, database: db) == 1)
    }

    @Test("a context check that proposes a refusal leaves the card alone")
    func contextCheckIgnoresRefusal() async throws {
        let (db, _, cardId) = try await makeDeck()
        let generator = Generator()
        generator.verdict = .refine(newBack: "The notes do not define this term.")
        let card = try await db.queue.read { try Card.fetchOne($0, key: cardId)! }
        let summary = await CardAI.verifyContext(of: [card], using: generator, database: db)
        #expect(summary.refined.isEmpty)
        let after = try await db.queue.read { try Card.fetchOne($0, key: cardId)! }
        #expect(after.back == "Collection of objects (elements of a set)")
        #expect(after.isContextRefined == false)
    }

    @Test("written test questions with a refusal or no options are not used")
    func testQuestionsFiltered() async throws {
        let (db, deckId, _) = try await makeDeck()
        let generator = QuestionGenerator()
        generator.questions = [
            GeneratedTestQuestion(prompt: "What is a martingale?", correctAnswer: "Not defined in the provided notes."),
            GeneratedTestQuestion(prompt: "Which of the following is a key difference between X and Y?", correctAnswer: "Z."),
            GeneratedTestQuestion(prompt: "How does a set differ from a list?", correctAnswer: "A set holds distinct elements with no order."),
        ]
        let (questions, _) = await CardAI.generateTestQuestions(
            inDecks: [deckId], maxCount: 5, using: generator, database: db)
        #expect(questions.map(\.prompt) == ["How does a set differ from a list?"])
    }

    private final class QuestionGenerator: CardGenerator, @unchecked Sendable {
        var questions: [GeneratedTestQuestion] = []
        var isAvailable: Bool { get async { true } }
        var overviewContextWordBudget: Int { 1_800 }
        func refine(_ candidates: [CandidatePair], noteContext: String) async -> [GeneratedCard] { [] }
        func distractors(for correctAnswer: String, deckContext: [String], count: Int) async -> [String] { [] }
        func generateAdditional(existing: [CandidatePair], noteContext: String, maxCount: Int, topic: String?) async -> [GeneratedCard] { [] }
        func generateTestQuestions(existing: [CandidatePair], noteContext: String, maxCount: Int) async -> [GeneratedTestQuestion] {
            questions
        }
        func validateContext(front: String, back: String, noteContext: String, courseName: String) async -> ContextValidation {
            ContextValidation(.valid)
        }
        func generateOverview(noteTitle: String, courseName: String, noteContext: String,
                              includeFormulas: Bool, partLabel: String?) async -> GeneratedOverview { .empty }
        func generateFigures(noteTitle: String, courseName: String, noteContext: String,
                             sectionHeadings: [String]) async -> [GeneratedFigure] { [] }
    }
}

// MARK: - (f) Prompt rules

@Suite("Card quality: prompt rules")
struct PromptRuleTests {
    @Test("the card-writing prompts carry the two rules")
    func rulesPresent() {
        let candidates = [CandidatePair(front: "Set", back: "Collection", sourceLine: 1)]
        let additional = OllamaGenerator.generateAdditionalPrompt(existing: candidates, noteContext: "note", maxCount: 3)
        #expect(additional.contains(CardQuality.skipRule))
        #expect(additional.contains(CardQuality.groundingRule))
        let questions = OllamaGenerator.generateTestQuestionsPrompt(existing: candidates, noteContext: "note", maxCount: 2)
        #expect(questions.contains(CardQuality.skipRule))
        #expect(questions.contains(CardQuality.groundingRule))
        let refine = OllamaGenerator.refinePrompt(candidates: candidates, noteContext: "note")
        #expect(refine.contains(CardQuality.unchangedRule))
        #expect(refine.contains(CardQuality.groundingRule))
    }
}

// MARK: - The predict-output answer `9` (audit item 5)

@Suite("Predict-output grading")
struct PredictOutputGradingTests {
    private let question = CodeQuestion(
        kind: .predictOutput, language: .python, prompt: "What does this program print?",
        code: "customers = [Customer(), LoyaltyCustomer()]\nprint([c.calculate_total(10) for c in customers])",
        expectedOutput: "[10, 9.0]")

    @Test("a part of the output, or one number from it, is not the output")
    func partialOutputRejected() {
        for given in ["9", "10", "9.0", "[10]", "[9.0]", "10, 9.0", "[10, 9.0", "idk", ""] {
            #expect(CodeAnswerGrading.grade(question, given: given) == false, "should be wrong: \(given)")
        }
    }

    @Test("the exact output is right, with trailing spaces or blank lines")
    func exactOutput() {
        for given in ["[10, 9.0]", "[10, 9.0]  ", "[10, 9.0]\n", "[10, 9.0]\n\n"] {
            #expect(CodeAnswerGrading.grade(question, given: given) == true, "should be right: \(given)")
        }
    }
}
