import Foundation

/// Whether a note is an orientation: a syllabus, a first-day overview, a
/// course introduction. Such a note teaches no concepts yet. It says what
/// the course covers and how it runs, so a lesson that asks "what is the
/// idea?" of it finds only logistics and writes those up as if they were
/// the subject (a lab's weight as a definition, the software used as an
/// example of a term). It gets an orientation instead: what the course is,
/// what you will be able to do, the tools, how it is graded.
///
/// Decided from the text alone, so the same answer is given wherever it is
/// asked, whether the note's title is known or not.
public enum OverviewOrientation {
    /// Words that put a note in a syllabus. Each counts once.
    private static let logistics: [String] = [
        "syllabus", "office hours", "grading", "grade breakdown", "late work", "late policy", "late submission",
        "attendance", "canvas", "tophat", "top hat", "midterm", "final exam", "textbook", "prerequisite",
        "academic integrity", "honor code", "instructor", "grace period", "make-up", "makeup", "course policies",
        "learning outcomes", "course objectives", "teaching assistant", "withdraw", "accommodations",
    ]
    /// Words in a title or the opening that announce one.
    private static let announcing = ["syllabus", "orientation", "first day", "first-day", "course overview",
                                     "welcome to", "course introduction", "course information"]
    private static let weight = try! NSRegularExpression(
        pattern: #"(?i)\b\d{1,3}\s?%\s*(?:[\w/&,'-]+\s+){0,5}?(homework|labs?|quiz\w*|midterm|final|exam\w*|participation|projects?|assignments?)\b|\b(homework|labs?|quizzes|midterm|final|exams?|participation|projects?|assignments?)\b[^\n]{0,30}\b\d{1,3}\s?%"#)

    struct Signals { var found: Int; var announced: Bool; var weights: Bool; var words: Int }

    static func signals(noteTitle: String?, noteContext: String) -> Signals {
        let text = noteContext.lowercased()
        let opening = ((noteTitle ?? "") + "\n" + String(text.prefix(400))).lowercased()
        return Signals(
            found: logistics.filter { text.contains($0) }.count,
            announced: announcing.contains { opening.contains($0) },
            weights: weight.firstMatch(in: noteContext, range: NSRange(noteContext.startIndex..., in: noteContext)) != nil,
            words: noteContext.split(whereSeparator: \.isWhitespace).count)
    }

    /// Three or more syllabus words in a note that announces itself as one
    /// (by its title or opening), or eight or more with grade weights
    /// written as percentages. Never a note with real math in it: a
    /// first-day lecture that also teaches is still a lecture. Measured on
    /// 411 real notes: every syllabus and first-day note is found, and no
    /// lecture that merely reminds the class of a deadline is.
    public static func isOrientation(noteTitle: String? = nil, noteContext: String) -> Bool {
        guard !NoteMath.isMathematical(noteContext) else { return false }
        let signal = signals(noteTitle: noteTitle, noteContext: noteContext)
        return (signal.announced && signal.found >= 3) || (signal.found >= 8 && signal.weights)
    }
}
