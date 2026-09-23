import Foundation

/// Pure exam-date scheduling rules, applied on top of FSRS: capping a
/// card's next interval so it resurfaces before an exam rather than after
/// it (useless timing otherwise), and flagging the final week so the due
/// queue can prioritize weak retention over plain due-date order.
public enum ExamBias {
    /// If FSRS would schedule a card's next review after the exam, that
    /// review cannot help for this exam -- cap it to the day before
    /// instead, so it lands with at least one look before the test.
    ///
    /// Inside the last day the day before is already in the past, and
    /// capping to it made every card graded that day overdue the moment it
    /// was graded -- "due today" never went down, and each session served
    /// the same cards again. Then the review lands a few hours before the
    /// exam instead, never sooner than an hour from now, and never after
    /// the exam starts.
    public static func capDue(_ due: Date, examDate: Date, now: Date = Date()) -> Date {
        guard due > examDate else { return due }
        let dayBefore = examDate.addingTimeInterval(-1 * 86400)
        if dayBefore > now { return dayBefore }
        let soon = max(now.addingTimeInterval(3600), examDate.addingTimeInterval(-6 * 3600))
        return min(soon, examDate)
    }

    public static let finalWeekWindow: TimeInterval = 7 * 86400

    /// True from 7 days out through the exam date itself (not after).
    public static func isInFinalWeek(now: Date, examDate: Date) -> Bool {
        let interval = examDate.timeIntervalSince(now)
        return interval >= 0 && interval <= finalWeekWindow
    }
}
