import Foundation
import GRDB

/// Ties a parsed guide to the rest of the library: which file is a guide at
/// all, which exam it's for, and which lecture decks each of its parts
/// covers. All of it is a best guess the student can correct.
public enum StudyGuideMatcher {
    // MARK: - Is this file a study guide?

    static let guideMarkers = ["study guide", "review packet", "review sheet", "exam review",
                               "midterm review", "final review", "test review", "exam prep"]
    static let numberedReview = try! NSRegularExpression(
        pattern: #"\b(exam|midterm|final|test|quiz)\s*\d{0,2}\s*(review|prep|guide)\b"#,
        options: [.caseInsensitive]
    )

    /// Decided from the filename, where a student or professor states a
    /// document's role: "ECO 2023 - Exam 1 Study Guide",
    /// "Microeconomics Exam 1 Review Professor", "Exam 1 Review Packet".
    public static func isStudyGuide(title: String) -> Bool {
        let spaced = title.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if guideMarkers.contains(where: spaced.contains) { return true }
        return StudyGuideParser.match(numberedReview, spaced) != nil
    }

    // MARK: - Which exam?

    static let examNumber = try! NSRegularExpression(
        pattern: #"\b(exam|midterm|test|quiz|unit)\s*(\d{1,2})\b"#, options: [.caseInsensitive]
    )

    /// "Exam 1" and "Midterm 1" name the same exam in how courses talk;
    /// "Quiz 1" is a different thing.
    static func examOrdinal(_ text: String) -> (kind: String, number: Int)? {
        guard let parts = StudyGuideParser.match(examNumber, text),
              let word = parts[0]?.lowercased(), let number = parts[1].flatMap(Int.init)
        else { return nil }
        return (["exam", "midterm", "test"].contains(word) ? "exam" : word, number)
    }

    /// The course's exam this guide prepares for, in order of certainty:
    /// the date the guide states, then "Exam 1" in both titles, then the
    /// nearest exam still to come. nil when the course has no exams.
    public static func exam(
        for document: StudyGuideDocument, guideTitle: String, courseId: String,
        now: Date = Date(), calendar: Calendar = .current, db: Database
    ) throws -> CalendarEvent? {
        let exams = try CalendarEvent
            .filter(Column("courseId") == courseId)
            .filter(CalendarEventKind.examLike.map(\.rawValue).contains(Column("kind")))
            .order(Column("startsAt"))
            .fetchAll(db)
        guard !exams.isEmpty else { return nil }

        if let day = document.examDate {
            if let onDay = exams.first(where: { dayString($0.startsAt, calendar: calendar) == day }) {
                return onDay
            }
        }
        let named = [guideTitle, document.title ?? ""].lazy.compactMap(examOrdinal).first
        if let named, let match = exams.first(where: {
            guard let ordinal = examOrdinal($0.title) else { return false }
            return ordinal.kind == named.kind && ordinal.number == named.number
        }) {
            return match
        }
        let today = calendar.startOfDay(for: now)
        return exams.first { $0.startsAt >= today }
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Which decks does each part cover?

    static let stopWords: Set<String> = [
        "the", "and", "of", "a", "an", "in", "to", "from", "for", "on", "with", "vs", "part",
        "lecture", "summary", "notes", "session", "pointer", "wrap", "up", "pt", "intro",
        "introduction", "week", "module", "chapter", "unit", "topic", "review",
    ]

    /// The words that carry a title's meaning: "2026-08-27_Lecture-01_The-
    /// Economic-Way-of-Thinking" and "The Economic Way of Thinking" both
    /// come down to {economic, way, thinking}.
    static func contentWords(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
        return Set(words)
    }

    /// Share of the part title's words that the lecture's title also has.
    static func coverage(part: Set<String>, lecture: Set<String>) -> Double {
        guard !part.isEmpty else { return 0 }
        return Double(part.intersection(lecture).count) / Double(part.count)
    }

    static let matchThreshold = 0.75

    /// For each part, the course's decks whose lecture notes are about the
    /// same thing, judged by the words the part's title shares with the
    /// titles of the notes behind the deck (or the deck's own name). A part
    /// no lecture has reached yet maps to nothing.
    public static func decks(for document: StudyGuideDocument, courseId: String,
                             db: Database) throws -> [Int: [String]] {
        let decks = try Deck
            .filter(Column("courseId") == courseId)
            .filter(Column("deletedAt") == nil)
            .fetchAll(db)
        var lectureWords: [String: [Set<String>]] = [:]
        for deck in decks {
            let materials = try OverviewQueries.materials(forDecks: [deck.id], db: db)
            lectureWords[deck.id] = [contentWords(deck.name)]
                + materials.map { contentWords([$0.title, $0.topic ?? ""].joined(separator: " ")) }
        }
        var result: [Int: [String]] = [:]
        for (index, part) in document.parts.enumerated() {
            let words = contentWords(part.title)
            let matched = decks.filter { deck in
                (lectureWords[deck.id] ?? []).contains { coverage(part: words, lecture: $0) >= matchThreshold }
            }
            if !matched.isEmpty { result[index] = matched.map(\.id) }
        }
        return result
    }

    /// Two guides' parts are the same part when they share a number and
    /// most of their title's words ("Elasticity and Applications of Demand"
    /// and "Elasticity and the Applications of Demand").
    public static func samePart(_ a: StudyGuideDocument.Part, _ b: StudyGuideDocument.Part) -> Bool {
        let aw = contentWords(a.title), bw = contentWords(b.title)
        let overlap = coverage(part: aw.count <= bw.count ? aw : bw, lecture: aw.count <= bw.count ? bw : aw)
        if let an = a.number, let bn = b.number, an == bn { return overlap >= 0.5 }
        return overlap >= matchThreshold
    }
}
