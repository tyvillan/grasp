import Foundation
import GRDB
import GRASPCore

/// What the tutorial needs from the app, kept apart from the model so the
/// model stays free of the database.
extension AppStore {
    /// True when the library has any course or any card, archived or not.
    /// If it cannot be read, say yes: the tutorial then stays away.
    var libraryHasCoursesOrCards: Bool {
        (try? database.queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM course) OR EXISTS(SELECT 1 FROM card)") ?? true
        }) ?? true
    }

    /// Opens the tutorial for a first-time user, once, when a profile opens.
    func startTutorialIfFirstTime() {
        #if DEBUG
        if TutorialDebug.apply(to: tutorial) { return }
        #endif
        tutorial.launchIfFirstTime(libraryHasData: libraryHasCoursesOrCards,
                                   linkedToAccount: profile.account != nil)
    }

    /// The first course (in the order the app shows them) that has a deck, for
    /// the steps that need a real deck page behind them.
    func firstCourseWithDeck() -> Course? {
        let ordered = coursesBySemester.values.flatMap { $0 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ordered.first { hasDecks(inCourse: $0.id) }
    }
}

#if DEBUG
/// Launch flags for checking the tutorial without a real first run. Debug
/// builds only; a release build has none of this.
///   GRASP_TUTORIAL=1          open the tutorial on launch, seen or not
///   GRASP_TUTORIAL_STEP=n     start on step n (1 to 8)
///   GRASP_TUTORIAL_EMPTY=1    act as if the library had no deck page
/// On the iPhone set them with `SIMCTL_CHILD_` in front.
enum TutorialDebug {
    static func apply(to flow: TutorialFlow) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["GRASP_TUTORIAL"] == "1" else { return false }
        flow.ignoresDeckPage = env["GRASP_TUTORIAL_EMPTY"] == "1"
        flow.start(at: (Int(env["GRASP_TUTORIAL_STEP"] ?? "") ?? 1) - 1)
        return true
    }
}
#endif

#if os(macOS)
import AppKit

enum TutorialLauncher {
    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true { return true }
        return ["General", "AI", "Account"].contains(window.title)
    }

    /// Starts the tutorial from the top and brings the main window forward,
    /// closing the Settings window if that is where it was asked for.
    static func replay(_ flow: TutorialFlow) {
        for window in NSApp.windows where isSettingsWindow(window) { window.performClose(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            main.makeKeyAndOrderFront(nil)
        }
        flow.start()
    }
}
#endif
