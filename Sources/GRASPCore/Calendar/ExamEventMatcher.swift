import Foundation

/// Decides which of a calendar's events are actually exams, and which
/// course each one belongs to.
///
/// Kept deliberately free of EventKit: this takes a title and a list of
/// courses, so the rules that decide "is "ECON 201 Midterm" an exam, and
/// whose?" are testable without a calendar, a permission prompt, or a Mac
/// with any particular events on it. The EventKit half (`CalendarSync`)
/// only fetches and hands titles here.
public enum ExamEventMatcher {

    // MARK: - Is this an exam?

    /// Phrases that mean "a graded thing you sit", strongest first. Order
    /// matters: "final exam" must be read as an exam before "final" is
    /// considered, and a "quiz" is a lighter thing than a "midterm" even
    /// though both bias scheduling.
    private static let examPhrases = [
        "final exam", "midterm exam", "midterm", "final", "exam", "test",
    ]
    private static let quizPhrases = ["quiz", "pop quiz"]

    /// Words that look exam-ish but describe preparing for one rather than
    /// sitting it. Without these, a calendar full of "ECON 201 exam review
    /// session" entries would each create a second, fake exam date and
    /// start capping FSRS intervals to the wrong day.
    ///
    /// Deliberately narrower than a first pass at this list: "study" and
    /// "prep" alone are common enough outside that meaning -- a room named
    /// "Study Hall B12" trailing a real "Final Exam" title, say -- that
    /// vetoing on them cost more real exams than it caught fake ones.
    /// "study group" stays, since that compound is unambiguous on its own.
    private static let preparationPhrases = [
        "review", "practice", "office hours", "tutoring", "study group", "revision",
    ]

    /// The kind this title implies, or nil if it isn't about an exam at
    /// all. Only `.exam` and `.quiz` are ever returned -- a deadline or a
    /// study block is never something to infer from someone else's
    /// calendar entry.
    public static func examKind(forTitle title: String) -> CalendarEventKind? {
        // Padded so every check below is a whole-word match -- otherwise
        // "exam" matches inside "example", "test" inside "contest" or
        // "latest", and "final" inside "finally", each misfiring on
        // ordinary titles that have nothing to do with an exam.
        let text = " " + normalized(title) + " "
        func hasPhrase(_ phrase: String) -> Bool { text.contains(" \(phrase) ") }

        guard !preparationPhrases.contains(where: hasPhrase) else { return nil }
        if quizPhrases.contains(where: hasPhrase) { return .quiz }
        if examPhrases.contains(where: hasPhrase) { return .exam }
        return nil
    }

    // MARK: - Whose exam is it?

    /// A course code as written anywhere in a title: two to four letters,
    /// an optional space or dash, three or four digits, and an optional
    /// letter. Matches "ECON 201", "COP3014", "MAC-2311", and lab-course
    /// codes like "COP 3275C" -- which the old pattern couldn't, there
    /// being no word boundary between the 5 and the C, so every exam for
    /// such a course went unmatched.
    private static let codePattern = try? NSRegularExpression(
        pattern: "\\b([A-Za-z]{2,4})[ \\-]?([0-9]{3,4}[A-Za-z]?)\\b"
    )

    /// How alike a title and a course name have to be, when there's no
    /// course code to go on, before this claims they're the same course.
    /// High on purpose: a wrong match silently attaches an exam -- and the
    /// interval capping that comes with it -- to the wrong course's cards,
    /// which is worse than leaving it unmatched for someone to assign by
    /// hand.
    public static let nameSimilarityThreshold = 0.82

    /// The id of the course this title is about, or nil when nothing
    /// matches confidently.
    ///
    /// Three passes, most reliable first: an explicit course code, then a
    /// course name appearing verbatim in the title, then fuzzy similarity
    /// against the longest word-run in the title. Anything less certain
    /// than that is left for the person to match themselves.
    public static func matchCourse(
        title: String, courses: [(id: String, name: String, code: String?)]
    ) -> String? {
        let text = normalized(title)

        if let code = courseCode(in: title) {
            for course in courses {
                guard let courseCode = course.code, !courseCode.isEmpty else { continue }
                if sameCode(compactCode(courseCode), code) { return course.id }
            }
            // A title carrying a code that matches no course is a stronger
            // signal than any name similarity: it names some *other*
            // class. Falling through to fuzzy matching here is how an
            // "ECON 202" exam ends up filed under "ECON 201".
            let known = Set(courses.compactMap { $0.code.map(compactCode) })
            if !known.isEmpty { return nil }
        }

        for course in courses where text.contains(normalized(course.name)) && !course.name.isEmpty {
            return course.id
        }

        var best: (id: String, score: Double)?
        for course in courses {
            let name = normalized(course.name)
            guard !name.isEmpty else { continue }
            let score = AnswerGrading.similarityRatio(text, name)
            if score >= nameSimilarityThreshold, score > (best?.score ?? 0) {
                best = (course.id, score)
            }
        }
        return best?.id
    }

    /// The course code written in a title, normalized to letters+digits
    /// ("ECON 201" and "econ201" both become "econ201").
    public static func courseCode(in title: String) -> String? {
        guard let codePattern else { return nil }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = codePattern.firstMatch(in: title, range: range),
              let letters = Range(match.range(at: 1), in: title),
              let digits = Range(match.range(at: 2), in: title)
        else { return nil }
        return (title[letters] + title[digits]).lowercased()
    }

    /// Equal, or equal once a trailing section letter is dropped -- an exam
    /// titled "COP 3275 Midterm" is still the COP 3275C exam.
    private static func sameCode(_ a: String, _ b: String) -> Bool {
        a == b || withoutSuffix(a) == withoutSuffix(b)
    }

    private static func withoutSuffix(_ code: String) -> String {
        guard let last = code.last, last.isLetter,
              let beforeLast = code.dropLast().last, beforeLast.isNumber
        else { return code }
        return String(code.dropLast())
    }

    private static func compactCode(_ code: String) -> String {
        code.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
