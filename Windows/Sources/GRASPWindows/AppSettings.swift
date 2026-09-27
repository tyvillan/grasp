import Foundation
import Observation

/// This profile's preferences: the Windows counterpart of the Mac's
/// per-profile `UserDefaults` suite. Kept as `settings.json` in the
/// profile's own folder, so each profile has its own and they never sync
/// (preferences are about this PC, not the library).
@Observable
final class AppSettings {
    enum CalendarMode: String, Codable, CaseIterable {
        case month = "Month", week = "Week", agenda = "Agenda"
    }

    /// Cards a day that count as a full day; 0 means no goal. The Mac's
    /// "Study Goals" setting, with the same default.
    var dailyGoal = 20 { didSet { save() } }
    /// Whether weeks start on Monday rather than Sunday, on the calendar.
    var weekStartsOnMonday = false { didSet { save() } }
    /// Which view the calendar opens in.
    var calendarMode: CalendarMode = .month { didSet { save() } }
    /// The notes folder "Import now" re-imports; nil until one is chosen.
    var notesFolder: String? { didSet { save() } }
    /// Tests add questions the local model writes from your notes, as the
    /// Mac's "AI test questions" setting does.
    var aiTestQuestions = false { didSet { save() } }
    /// The focus timer's work and break lengths and its per-interval card
    /// target (0 hides it), with the Mac's defaults.
    var focusWorkMinutes = 25 { didSet { save() } }
    var focusBreakMinutes = 5 { didSet { save() } }
    var focusCardTarget = 20 { didSet { save() } }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var isLoading = false

    private struct Stored: Codable {
        var dailyGoal: Int?
        var weekStartsOnMonday: Bool?
        var calendarMode: CalendarMode?
        var notesFolder: String?
        var aiTestQuestions: Bool?
        var focusWorkMinutes: Int?
        var focusBreakMinutes: Int?
        var focusCardTarget: Int?
    }

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        isLoading = true
        defer { isLoading = false }
        dailyGoal = stored.dailyGoal ?? dailyGoal
        weekStartsOnMonday = stored.weekStartsOnMonday ?? weekStartsOnMonday
        calendarMode = stored.calendarMode ?? calendarMode
        notesFolder = stored.notesFolder
        aiTestQuestions = stored.aiTestQuestions ?? aiTestQuestions
        focusWorkMinutes = stored.focusWorkMinutes ?? focusWorkMinutes
        focusBreakMinutes = stored.focusBreakMinutes ?? focusBreakMinutes
        focusCardTarget = stored.focusCardTarget ?? focusCardTarget
    }

    /// The calendar the app's date grids use, starting the week on the
    /// chosen day.
    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStartsOnMonday ? 2 : 1
        return calendar
    }

    private func save() {
        guard !isLoading else { return }
        let stored = Stored(dailyGoal: dailyGoal, weekStartsOnMonday: weekStartsOnMonday,
                            calendarMode: calendarMode, notesFolder: notesFolder,
                            aiTestQuestions: aiTestQuestions, focusWorkMinutes: focusWorkMinutes,
                            focusBreakMinutes: focusBreakMinutes, focusCardTarget: focusCardTarget)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not atomic: Windows refuses the rename an atomic write ends with
        // while anything (Defender, the indexer) has the file open.
        try? data.write(to: file)
    }
}
