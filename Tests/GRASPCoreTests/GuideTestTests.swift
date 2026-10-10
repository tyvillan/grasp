import Testing
import Foundation
import GRDB
@testable import GRASPCore

@Suite("Study guide tests")
struct GuideTestTests {
    private func page(guide: StudyGuide) -> StudyGuideActions.ExamPage {
        let part = StudyGuideActions.PagePart(
            number: 1, title: "Functions", questionCount: nil,
            sources: [.init(guideId: guide.id, partIndex: 0)], deckIds: [], skills: [], traps: [], examples: [],
            terms: [.init(term: "Prototype", definition: "A function's declaration before its definition"),
                    .init(term: "Reference parameter", definition: "An alias for the caller's variable")],
            formulas: [], remember: [], notes: ["void f(int&);"])
        return StudyGuideActions.ExamPage(
            exam: CalendarEvent(title: "Midterm", startsAt: Date()), guides: [guide], questionCount: nil,
            format: [], notes: [], parts: [part], unreadGuides: [], isPracticeSet: false)
    }

    @Test("terms and saved questions form the pool, and none of it is graded as a card")
    func pool() async throws {
        let db = try GRASPDatabase.inMemory()
        let guide = StudyGuide(courseId: "c", title: "Guide", bodyJSON: "{}")
        let page = page(guide: guide)
        try await db.queue.write { db in
            try GuideTest.save([.init(guideId: guide.id, partIndex: 0, prompt: "What does & mean in a parameter?",
                                      answer: "Pass by reference")], db: db)
        }
        let saved = try await db.queue.read { try GuideTest.saved(for: page, db: $0) }
        #expect(saved.count == 1)

        let pool = GuideTest.pool(page: page, saved: saved)
        #expect(pool.count == 3)
        #expect(pool.allSatisfy { $0.cardId.hasPrefix(GuideTest.idPrefix) })

        var rng = SystemRandomNumberGenerator()
        let questions = GuideTest.detachingPool(TestBuilder.build(
            from: pool, config: .init(questionCount: 3, allowMultipleChoice: true, allowWritten: true,
                                      allowTrueFalse: true, shuffle: true), using: &rng))
        #expect(questions.count == 3)
        #expect(questions.allSatisfy { $0.cardId == nil })
        #expect(Set(questions.map(\.id)).count == 3)
    }

    @Test("a guide's unfinished test is kept apart from a deck test over the same decks")
    func scoped() async throws {
        let db = try GRASPDatabase.inMemory()
        let question = LearnEngine.RoundQuestion(id: "q1", cardId: nil, prompt: "p", correctAnswer: "a", type: .written)
        let other = LearnEngine.RoundQuestion(id: "q2", cardId: nil, prompt: "p2", correctAnswer: "b", type: .written)
        let attempt = try await db.queue.write {
            try Study.startRetry(questions: [question, other], deckIds: [], scopeKey: "guide:x", db: $0)
        }
        #expect(try await db.queue.read { try Study.unfinishedTest(forDecks: [], scopeKey: "guide:x", db: $0) }?.attemptId == attempt)
        #expect(try await db.queue.read { try Study.unfinishedTest(forDecks: [], db: $0) } == nil)
    }
}
