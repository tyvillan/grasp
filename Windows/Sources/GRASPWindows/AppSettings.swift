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

    /// How the notes folder is read, as the Mac's `AppStore.NotesLayout`.
    enum NotesLayout: String, Codable, CaseIterable {
        case automatic, vault, folders, none

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .vault: return "Obsidian vault"
            case .folders: return "Any folder"
            case .none: return "None"
            }
        }
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
    /// How the notes folder is read; Automatic picks the vault layout when
    /// it finds a College folder inside.
    var notesLayout: NotesLayout = .automatic { didSet { save() } }
    /// The term new courses from "Any folder" go under ("Fall 2026").
    var notesTimeframe = "" { didSet { save() } }
    /// Tests add questions the local model writes from your notes, as the
    /// Mac's "AI test questions" setting does.
    var aiTestQuestions = false { didSet { save() } }
    /// Test setup's two sources, as on the Mac: "Quiz me on flashcards" (on
    /// by default) and "Include questions" (the deck's saved questions; on
    /// by default when AI test questions were on, which used to add them).
    var testFlashcards = true { didSet { save() } }
    var testQuestions = false { didSet { save() } }
    /// The focus timer's work and break lengths and its per-interval card
    /// target (0 hides it), with the Mac's defaults.
    var focusWorkMinutes = 25 { didSet { save() } }
    var focusBreakMinutes = 5 { didSet { save() } }
    var focusCardTarget = 20 { didSet { save() } }
    /// Home's ticked plan steps, "yyyy-MM-dd|id,id": today's only, as the
    /// Mac's `todayPlanChecked`.
    var todayPlanChecked = "" { didSet { save() } }

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
        var todayPlanChecked: String?
        var notesLayout: NotesLayout?
        var notesTimeframe: String?
        var testFlashcards: Bool?
        var testQuestions: Bool?
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
        todayPlanChecked = stored.todayPlanChecked ?? ""
        notesLayout = stored.notesLayout ?? notesLayout
        notesTimeframe = stored.notesTimeframe ?? ""
        testFlashcards = stored.testFlashcards ?? true
        testQuestions = stored.testQuestions ?? aiTestQuestions
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
                            focusBreakMinutes: focusBreakMinutes, focusCardTarget: focusCardTarget,
                            todayPlanChecked: todayPlanChecked, notesLayout: notesLayout,
                            notesTimeframe: notesTimeframe, testFlashcards: testFlashcards,
                            testQuestions: testQuestions)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not atomic: Windows refuses the rename an atomic write ends with
        // while anything (Defender, the indexer) has the file open.
        try? data.write(to: file)
    }
}
