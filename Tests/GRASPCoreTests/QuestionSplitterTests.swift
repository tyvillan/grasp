import Foundation
import Testing
@testable import GRASPCore

@Suite("Splitting a page into questions")
struct QuestionSplitterTests {
    @Test("numbered multiple choice questions with lettered options")
    func numberedMultipleChoice() {
        let page = """
        1. What is the capital of France?
        A) Berlin
        B) Paris
        C) Rome
        D) Madrid
        2. Which gas do plants take in?
        a. Oxygen
        b. Carbon dioxide
        c. Helium
        """
        let questions = QuestionSplitter.split(page)
        #expect(questions.count == 2)
        #expect(questions[0].number == 1 && questions[0].stem == "What is the capital of France?")
        #expect(questions[0].options == ["Berlin", "Paris", "Rome", "Madrid"])
        #expect(questions[1].number == 2 && questions[1].options == ["Oxygen", "Carbon dioxide", "Helium"])
    }

    @Test("a stem and an option that wrap onto the next line stay whole")
    func wrappedLines() {
        let page = """
        1. Which of the following best describes the
        process by which plants make food?
        A) Photosynthesis, using light
        energy from the sun
        B) Respiration
        """
        let q = QuestionSplitter.split(page)
        #expect(q.count == 1)
        #expect(q[0].stem == "Which of the following best describes the process by which plants make food?")
        #expect(q[0].options == ["Photosynthesis, using light energy from the sun", "Respiration"])
    }

    @Test("an answer printed under a question is read, as a letter or as words")
    func answerUnderQuestion() {
        let page = """
        1. What is 2 + 2?
        A) 3
        B) 4
        Answer: B
        2. Name the powerhouse of the cell.
        Answer: the mitochondria
        """
        let q = QuestionSplitter.split(page)
        #expect(q.count == 2)
        #expect(q[0].answerLetter == "B" && q[0].options == ["3", "4"])
        #expect(q[1].answerLetter == nil && q[1].answerText == "the mitochondria")
    }

    @Test("an answer key at the end is matched to its questions")
    func answerKey() {
        let page = """
        1. First question here?
        A) one
        B) two
        2. Second question here?
        A) one
        B) two
        Answer Key
        1. B  2. A
        """
        let q = QuestionSplitter.split(page)
        #expect(q.count == 2)
        #expect(q[0].answerLetter == "B" && q[1].answerLetter == "A")
    }

    @Test("Q3 and Question 4 styles start questions too")
    func otherNumbering() {
        let page = """
        Q1. Define opportunity cost.
        Q2) State the law of demand.
        Question 3: What is a sunk cost?
        """
        let q = QuestionSplitter.split(page)
        #expect(q.map(\.number) == [1, 2, 3])
        #expect(q[2].stem == "What is a sunk cost?")
    }

    @Test("text with no numbering is one question")
    func unnumbered() {
        let q = QuestionSplitter.split("Explain why the sky is blue\nin two sentences.")
        #expect(q.count == 1 && q[0].number == nil)
        #expect(q[0].stem == "Explain why the sky is blue in two sentences.")
    }

    @Test("a numbered list of options is not mistaken for new questions")
    func numberedOptions() {
        let page = """
        1. Which is the largest planet?
        A) Mars
        B) Jupiter
        2. Which is the smallest planet?
        A) Mercury
        B) Venus
        """
        #expect(QuestionSplitter.split(page).count == 2)
    }

    @Test("a single lettered line is part of the stem, not a list of options")
    func singleLetterLine() {
        let q = QuestionSplitter.split("1. Choose the statement that is false.\nA. only one option line")
        #expect(q.count == 1 && q[0].options.isEmpty)
    }

    @Test("empty text gives no questions")
    func empty() {
        #expect(QuestionSplitter.split("  \n \n").isEmpty)
    }
}
