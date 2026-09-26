import Foundation

/// An exam study guide, parsed into the parts it's organized by.
///
/// A guide cuts across GRASP's lecture decks: it covers one exam, spans
/// several lectures, and carries what lecture notes don't -- the exam's date
/// and format, how many questions each part gets, the skills each part
/// tests, the traps the wrong answers are built on, and worked examples with
/// answers. Two real guides shaped this type: a professor's (skills, traps,
/// question counts, "Example N -- question" with a folded answer) and a
/// student's own (definitions, formulas, "Example:" / "Question:" / "Answer:"
/// blocks, "REMEMBER" callouts). Either kind fills the fields it has.
///
/// Stored as JSON on `StudyGuide.bodyJSON`, versioned by
/// `StudyGuideDocument.schemaVersion`.
public struct StudyGuideDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    /// The heading at the top of the guide, when it has one.
    public var title: String?
    /// "yyyy-MM-dd", when the guide states the exam's date. A day, not a
    /// `Date`, so it means the same day in every time zone the library
    /// syncs to.
    public var examDate: String?
    /// Stated question count and the exam's rules ("40 multiple-choice
    /// questions", "open note").
    public var questionCount: Int?
    public var format: [String]
    /// Paragraphs from before the first part: how the exam works, how to
    /// use the guide.
    public var notes: [String]
    public var parts: [Part]

    public init(title: String? = nil, examDate: String? = nil, questionCount: Int? = nil,
                format: [String] = [], notes: [String] = [], parts: [Part] = []) {
        self.title = title
        self.examDate = examDate
        self.questionCount = questionCount
        self.format = format
        self.notes = notes
        self.parts = parts
    }

    public struct Part: Codable, Sendable, Equatable {
        /// The number the guide gives the part ("Part 3"), not its index.
        public var number: Int?
        public var title: String
        public var questionCount: Int?
        /// 1-based page of the source PDF the part starts on.
        public var page: Int?
        /// "You should be able to ..." lines.
        public var skills: [String]
        /// "Traps the wrong answers are built on" / common mistakes.
        public var traps: [String]
        public var examples: [Example]
        public var terms: [Term]
        /// Lines of the shape `Name = expression`.
        public var formulas: [String]
        /// "REMEMBER" callouts, one per line or bullet.
        public var remember: [String]
        /// Any other paragraph worth keeping ("Bring a calculator and know
        /// the midpoint formula cold").
        public var notes: [String]

        public init(number: Int? = nil, title: String, questionCount: Int? = nil, page: Int? = nil,
                    skills: [String] = [], traps: [String] = [], examples: [Example] = [],
                    terms: [Term] = [], formulas: [String] = [], remember: [String] = [],
                    notes: [String] = []) {
            self.number = number
            self.title = title
            self.questionCount = questionCount
            self.page = page
            self.skills = skills
            self.traps = traps
            self.examples = examples
            self.terms = terms
            self.formulas = formulas
            self.remember = remember
            self.notes = notes
        }
    }

    public struct Example: Codable, Sendable, Equatable {
        /// The guide's own label ("Example 7"), when it numbers them.
        public var label: String?
        /// What's given and what's asked -- everything to read before trying.
        public var question: String
        /// Worked steps, in order, when the guide shows them.
        public var steps: [String]
        /// The answer, or nil for an illustration that asks nothing.
        public var answer: String?
        /// 1-based page of the source PDF, for the tables and figures the
        /// text can't carry.
        public var page: Int?

        public init(label: String? = nil, question: String, steps: [String] = [],
                    answer: String? = nil, page: Int? = nil) {
            self.label = label
            self.question = question
            self.steps = steps
            self.answer = answer
            self.page = page
        }

        /// Something to try before looking: it asks a question and has an
        /// answer to check against.
        public var isPractice: Bool { answer != nil }
    }

    public struct Term: Codable, Sendable, Equatable {
        public var term: String
        public var definition: String

        public init(term: String, definition: String) {
            self.term = term
            self.definition = definition
        }
    }

    /// Everything the guide asks about, summed over parts, when every part
    /// states it; otherwise the guide's own total.
    public var totalQuestions: Int? {
        let counts = parts.compactMap(\.questionCount)
        if !counts.isEmpty, counts.count == parts.count { return counts.reduce(0, +) }
        return questionCount
    }

    public var isEmpty: Bool { parts.isEmpty }
}

public enum StudyGuideCoding {
    public static func encode(_ document: StudyGuideDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    public static func decode(_ json: String) -> StudyGuideDocument? {
        try? JSONDecoder().decode(StudyGuideDocument.self, from: Data(json.utf8))
    }
}
