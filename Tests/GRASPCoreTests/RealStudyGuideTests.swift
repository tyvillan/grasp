import Testing
import Foundation
@testable import GRASPCore

/// The two real guides the parser was built from, for ECO 2023's first
/// midterm. Their text is course material, so it isn't in the repo: it's
/// read from `~/Library/Developer/grasp-fixtures/` (saved there with
/// `grasp-check extract`), and these tests skip on any machine without it,
/// like the suites that need the real notes vault.
enum RealStudyGuideFixtures {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/grasp-fixtures")
    static let professorFile = directory.appendingPathComponent("eco-exam1-professor.txt")
    static let studentFile = directory.appendingPathComponent("eco-exam1-student.txt")

    static var exist: Bool {
        FileManager.default.fileExists(atPath: professorFile.path)
            && FileManager.default.fileExists(atPath: studentFile.path)
    }

    /// Pages as `grasp-check extract` saved them: separated by a blank line.
    static func pages(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n\n")
    }
}

@Suite("RealStudyGuides", .enabled(if: RealStudyGuideFixtures.exist))
struct RealStudyGuideTests {
    private typealias Fixtures = RealStudyGuideFixtures

    @Test("the professor's OCR'd guide: five parts, their counts, skills, traps and examples")
    func professor() throws {
        let guide = StudyGuideParser.parse(pages: try Fixtures.pages(Fixtures.professorFile))
        #expect(guide.examDate == "2026-09-29")
        #expect(guide.questionCount == 40)
        #expect(guide.format == ["40 multiple-choice questions", "open note"])
        #expect(guide.parts.map(\.title) == [
            "The Economic Way of Thinking", "Demand and Marginal Personal Worth",
            "Elasticity and the Applications of Demand", "Gains from Exchange", "Markets and Coordination",
        ])
        #expect(guide.parts.map(\.questionCount) == [6, 7, 11, 8, 8])
        #expect(guide.parts.map(\.skills.count) == [5, 6, 9, 8, 8])
        #expect(guide.parts.map(\.traps.count) == [5, 4, 0, 2, 3])
        #expect(guide.parts.map(\.examples.count) == [3, 3, 4, 2, 4])
        let examples = guide.parts.flatMap(\.examples)
        #expect(examples.allSatisfy { $0.isPractice })
        #expect(examples.map(\.label) == (1...16).map { "Example \($0)" })
        #expect(examples.allSatisfy { $0.question.contains("?") })
    }

    @Test("the student's own guide: the same parts, with its terms, formulas and worked examples")
    func student() throws {
        let guide = StudyGuideParser.parse(pages: try Fixtures.pages(Fixtures.studentFile))
        #expect(guide.parts.count == 5)
        #expect(guide.parts[2].title == "Elasticity and Applications of Demand")
        #expect(guide.parts.flatMap(\.terms).count >= 30)
        #expect(guide.parts[1].formulas.contains("Spending = Price × Quantity"))
        let mia = try #require(guide.parts[3].examples.first)
        #expect(mia.steps.count == 4)
        #expect(mia.answer?.hasPrefix("Total gain from trade is $7.") == true)
    }

    @Test("the two guides' parts line up one to one")
    func partsLineUp() throws {
        let professor = StudyGuideParser.parse(pages: try Fixtures.pages(Fixtures.professorFile))
        let student = StudyGuideParser.parse(pages: try Fixtures.pages(Fixtures.studentFile))
        for (a, b) in zip(professor.parts, student.parts) {
            #expect(StudyGuideMatcher.samePart(a, b), "\(a.title) / \(b.title)")
        }
    }

    @Test("read together, the two guides show each shared problem once, with no OCR slips")
    func together() throws {
        let professor = StudyGuideParser.parse(pages: try Fixtures.pages(Fixtures.professorFile))
        let student = StudyGuideParser.parse(pages: try Fixtures.pages(Fixtures.studentFile))
        #expect(professor.parts.flatMap(\.examples).filter { $0.usesFigure == true }.compactMap(\.label)
                == ["Example 4", "Example 5", "Example 12", "Example 14"])
        #expect(student.parts.flatMap(\.examples).allSatisfy { $0.usesFigure != true })
        let all = (professor.parts + student.parts).flatMap(\.examples)
        let text = all.map { $0.question + " " + ($0.answer ?? "") }.joined(separator: "\n")
        #expect(!text.contains("(o "))
        #expect(!text.contains(", o)"))
        #expect(!text.contains("$20o"))
        #expect(professor.parts[0].examples[2].question.components(separatedBy: "\n").count == 4)

        // The student reworks five of the professor's problems: the wedding,
        // the island, the driving-age claims, the smoothies, the amp.
        var duplicates: [String] = []
        for (p, s) in zip(professor.parts, student.parts) {
            for a in p.examples {
                for b in s.examples where StudyGuideActions.isSameProblem(a, b) {
                    duplicates.append(a.label ?? "")
                }
            }
        }
        #expect(duplicates == ["Example 1", "Example 2", "Example 3", "Example 4", "Example 11"])
    }
}
