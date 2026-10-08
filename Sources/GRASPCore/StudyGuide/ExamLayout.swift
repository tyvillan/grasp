import Foundation

/// How an exam page is arranged for reading: every skill once, grouped by
/// topic, and the document's parts sorted into topics, practice and
/// assignments. Presentation only; nothing here changes what is stored.
public enum ExamLayout {
    public enum Topic: String, CaseIterable, Sendable {
        case functions, control, dataIO, structsFiles, classes, other

        public var label: String {
            switch self {
            case .functions: return "Functions"
            case .control: return "Loops and decisions"
            case .dataIO: return "Data types and input/output"
            case .structsFiles: return "Structs and files"
            case .classes: return "Classes and OOP"
            case .other: return "Other"
            }
        }

        fileprivate var keywords: [String] {
            switch self {
            case .classes: return ["class", "constructor", "accessor", "mutator", "getter", "setter", "private member",
                                   "object oriented", "object-oriented", "oop programming", "encapsulat", "inherit"]
            case .functions: return ["function", "parameter", "call by", "call-by", "pass by", "prototype", "return type",
                                     "separate compilation", "header file", ".h,"]
            case .structsFiles: return ["struct", "file input", "ifstream", "ofstream", "dot operator", "file i/o", "file output"]
            case .control: return ["loop", "while", "for ", "if/", "if ", "else", "condition", "flow of control", "yes or no",
                                   "math", "expression", "switch", "boolean logic"]
            case .dataIO: return ["data type", "variable", "cin", "cout", "input and output", "i/o", "format", "magic formula",
                                  "string", "double", "char", "int,", "bool", "declaration", "precision"]
            case .other: return []
            }
        }
    }

    public static func topic(for skill: String) -> Topic {
        let text = skill.lowercased()
        for topic in [Topic.classes, .functions, .structsFiles, .control, .dataIO]
        where topic.keywords.contains(where: { text.contains($0) }) { return topic }
        return .other
    }

    /// The same skill worded the same way in two parts is one skill.
    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public struct Bucket: Sendable {
        public let topic: Topic
        public let skills: [StudyGuideActions.Skill]
    }

    /// Every distinct skill in the parts, grouped by topic in a fixed order.
    /// nil when most skills fit no topic (a subject these keywords don't
    /// know), so the page falls back to the document's own parts.
    public static func bucketSkills(_ parts: [StudyGuideActions.PagePart]) -> [Bucket]? {
        var seen = Set<String>()
        var grouped: [Topic: [StudyGuideActions.Skill]] = [:]
        var total = 0
        for skill in parts.flatMap(\.skills) where seen.insert(key(skill.text)).inserted {
            grouped[topic(for: skill.text), default: []].append(skill)
            total += 1
        }
        guard total >= 4, Double(grouped[.other]?.count ?? 0) / Double(total) < 0.5 else { return nil }
        return Topic.allCases.compactMap { topic in
            grouped[topic].map { Bucket(topic: topic, skills: $0) }
        }
    }

    public enum Band: Int, CaseIterable, Sendable {
        case topics, practice, assignments

        public var label: String {
            switch self {
            case .topics: return "Topics"
            case .practice: return "Practice"
            case .assignments: return "Assignments"
            }
        }
    }

    public static func band(for part: StudyGuideActions.PagePart) -> Band {
        let title = part.title.lowercased()
        if title.contains("assignment") { return .assignments }
        if part.examples.contains(where: { $0.example.isPractice })
            || ["practice", "sample", "kinds of exam question", "kinds of question"].contains(where: title.contains) {
            return .practice
        }
        return .topics
    }

    /// A definition the guide already gives for this skill: a term whose
    /// name appears in the skill's wording, or the other way round. The
    /// longest match wins, so "default constructor" beats "constructor".
    public static func definition(for skill: String,
                                  terms: [StudyGuideDocument.Term]) -> StudyGuideDocument.Term? {
        let text = skill.lowercased()
        return terms
            .filter { !$0.definition.isEmpty && $0.term.count >= 4 }
            .filter { text.contains($0.term.lowercased()) || $0.term.lowercased().contains(text) }
            .max { $0.term.count < $1.term.count }
    }
}
