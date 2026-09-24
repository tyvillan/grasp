import Foundation

/// Launch options for checking screens in the simulator without tapping
/// through them, set as environment variables (`SIMCTL_CHILD_GRASP_…` via
/// `simctl launch`). Compiled out of release builds entirely.
enum DebugLaunch {
    #if DEBUG
    private static let env = ProcessInfo.processInfo.environment
    /// Open the first profile on launch.
    static var skipWelcome: Bool { env["GRASP_SKIP_PICKER"] == "1" }
    /// Open this course (by name) on launch.
    static var course: String? { env["GRASP_OPEN_COURSE"] }
    /// Then this deck (by name, or "All Cards").
    static var deck: String? { env["GRASP_OPEN_DECK"] }
    /// Then start a mode: study, learn, test, overview.
    static var mode: String? { env["GRASP_OPEN_MODE"] }
    /// Open this tab: study, settings.
    static var tab: String? { env["GRASP_TAB"] }
    #else
    static let skipWelcome = false
    static let course: String? = nil
    static let deck: String? = nil
    static let mode: String? = nil
    static let tab: String? = nil
    #endif
}
