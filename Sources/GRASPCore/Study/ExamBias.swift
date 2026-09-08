import Foundation

/// Pure exam-date scheduling rules, applied on top of FSRS: capping a
/// card's next interval so it resurfaces before an exam rather than after
/// it (useless timing otherwise), and flagging the final week so the due
/// queue can prioritize weak retention over plain due-date order.
public enum ExamBias {
    /// If FSRS would schedule a card's next review after the exam, that
    /// review cannot help for this exam -- cap it to the day before
    /// instead, so it lands with at least one look before the test.
    public static func capDue(_ due: Date, examDate: Date) -> Date {
        guard due > examDate else { return due }
        return examDate.addingTimeInterval(-1 * 86400)
    }

    public static let finalWeekWindow: TimeInterval = 7 * 86400

    /// True from 7 days out through the exam date itself (not after).
    public static func isInFinalWeek(now: Date, examDate: Date) -> Bool {
        let interval = examDate.timeIntervalSince(now)
        return interval >= 0 && interval <= finalWeekWindow
    }
}
