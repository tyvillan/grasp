import Foundation
import GRDB
import Testing
@testable import GRASPCore

@Suite("ExamPack")
struct ExamPackTests {
    private let questions = """
    COP 3275C Sample Midterm exam questions
    1. Write the prototype for a double function called AvgMax that has 3 integer input (value) parameters (n1, n2 and
    n3), one integer (reference) parameter (max).
    2. What is the output of the following code?
    for (int i = 0; i < 2; i++)
    cout << i;
    """
    private let solutions = """
    COP 3275C Sample Midterm exam questions and solutions
    1. Write the prototype for a double function called AvgMax that has 3 integer input (value)
    parameters (n1, n2 and n3), one integer (reference) parameter (max).
    double AvgMax(int, int, int, int&);
    2. What is the output of the following code?
    for (int i = 0; i < 2; i++)
    cout << i;
    //sample solution
    01
    """
    private let review = """
    Review Sheet for COP 3275C Midterm Exam
    Topics from the first six modules
    #include<iostream> //cin and cout
    Call-by-reference
    • The argument MUST be a variable
    • Remember – if the argument must change inside function then pass by reference
    Skills
    • i/o in C++
    • functions, call by value and call by
    reference
    """
    private let topics = """
    Midterm Topics: Assignments 1 through 5
    Assignment 1- introduction
    Topics: C++ basics
    • Data types (char, string, double, int)
    • Variable declarations
    Assignment 2 - loops
    • while / do(while)
    """

    private func files() -> [ExamPack.SourceFile] {
        [
            .init(title: "COP 3275C Midterm sample questions", pages: [questions]),
            .init(title: "COP 3275C Midterm sample questions and solutions", pages: [solutions]),
            .init(title: "COP 3275C midterm review ", pages: [review]),
            .init(title: "COP3275C midterm topics  assignments 1 through 5 ", pages: [topics]),
        ]
    }

    @Test("a batch with practice questions beside other files is a pack; a lone file is not")
    func detectsPacks() {
        let names = ["Midterm sample questions", "Midterm sample questions and solutions", "Midterm review"]
        #expect(ExamPack.packFiles(in: names, title: { $0 }).count == 3)
        #expect(ExamPack.packFiles(in: ["Midterm review", "Exam 1 Study Guide"], title: { $0 }).isEmpty)
        #expect(ExamPack.packFiles(in: ["Midterm sample questions"], title: { $0 }).isEmpty)
    }

    @Test("the solutions file is split into question and answer using the questions-only copy")
    func pairsQuestionsWithSolutions() throws {
        let document = try #require(ExamPack.build(files()))
        let part = try #require(document.parts.first { $0.title == "Midterm sample questions" })
        #expect(part.examples.count == 2)
        #expect(part.examples[0].answer == "double AvgMax(int, int, int, int&);")
        #expect(part.examples[0].question.hasPrefix("Write the prototype"))
        // The lines wrap differently in the two copies, and the question
        // text still isn't mistaken for the answer.
        #expect(part.examples[0].question.contains("n3), one integer"))
        #expect(part.examples[1].answer == "01")
        #expect(part.examples[1].label == "Question 2")
    }

    @Test("the review sheet becomes parts with skills and remember notes")
    func readsReviewSheet() throws {
        let document = try #require(ExamPack.build(files()))
        #expect(document.title == "Review Sheet for COP 3275C Midterm Exam")
        let call = try #require(document.parts.first { $0.title == "Call-by-reference" })
        #expect(call.remember == ["if the argument must change inside function then pass by reference"])
        #expect(call.notes == ["The argument MUST be a variable"])
        let skills = try #require(document.parts.first { $0.title == "Skills to be able to do" })
        #expect(skills.skills == ["i/o in C++", "functions, call by value and call by reference"])
    }

    @Test("topics by assignment become one part each")
    func readsAssignmentTopics() throws {
        let document = try #require(ExamPack.build(files()))
        let assignments = document.parts.filter { $0.title.hasPrefix("Assignment") }
        #expect(assignments.count == 2)
        #expect(assignments[0].skills == ["Data types (char, string, double, int)", "Variable declarations"])
        #expect(assignments[1].skills == ["while / do(while)"])
    }

    @Test("a question without a solutions copy keeps the whole text and no answer")
    func unpaired() throws {
        let only = [
            ExamPack.SourceFile(title: "Loop practice questions", pages: ["1. Print stars.\n2. Print more."]),
            ExamPack.SourceFile(title: "Midterm review", pages: [review]),
        ]
        let document = try #require(ExamPack.build(only))
        let part = try #require(document.parts.first { $0.title == "Loop practice questions" })
        #expect(part.examples.count == 2)
        #expect(part.examples.allSatisfy { $0.answer == nil })
    }

    @Test("saving a pack links it to the exam and maps the review part to lecture-style decks; saving again updates in place")
    func savesAndUpdates() async throws {
        let db = try GRASPDatabase.inMemory()
        let document = try #require(ExamPack.build(files()))
        let (courseId, examId, moduleId) = try await db.queue.write { conn -> (String, String, String) in
            let course = Course(semesterId: nil, name: "Systems"); try course.insert(conn)
            let exam = CalendarEvent(courseId: course.id, kind: .exam, title: "Midterm", startsAt: Date().addingTimeInterval(86400 * 5))
            try exam.insert(conn)
            let module = Deck(courseId: course.id, name: "Module 1", chapter: "Module 1"); try module.insert(conn)
            try Deck(courseId: course.id, name: "Lab 1", chapter: "Lab 1").insert(conn)
            try Deck(courseId: course.id, name: "General").insert(conn)
            return (course.id, exam.id, module.id)
        }
        let first = try await db.queue.write { try StudyGuideActions.importExamPack(courseId: courseId, examEventId: nil, document: document, db: $0) }
        #expect(first.examEventId == examId)
        #expect(first.parser == "pack")
        let decks = try await db.queue.read {
            try StudyGuidePartDeck.filter(Column("guideId") == first.id).fetchAll($0)
        }
        #expect(decks.map(\.deckId) == [moduleId])
        #expect(decks.allSatisfy { $0.partIndex == 0 })

        let second = try await db.queue.write { try StudyGuideActions.importExamPack(courseId: courseId, examEventId: nil, document: document, db: $0) }
        #expect(second.id == first.id)
        let count = try await db.queue.read { try StudyGuide.fetchCount($0) }
        #expect(count == 1)
    }

    @Test("practice file names are cleaned into part titles")
    func titles() {
        #expect(ExamPack.practiceTitle("COP 3275C Midterm sample questions and solutions PART 2") == "Midterm sample questions Part 2")
        #expect(ExamPack.practiceTitle("Loop practice questions with solutions") == "Loop practice questions")
    }
}
