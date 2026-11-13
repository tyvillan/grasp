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
    /// Deck screen: start on this filter chip (drafts, due, understood).
    static var filter: String? { env["GRASP_OPEN_FILTER"] }
    /// Deck screen: enter Select mode with the first three drafts ticked.
    static var select: Bool { env["GRASP_SELECT"] == "1" }
    /// Deck screen: run a pretend generation that writes one AI draft
    /// every second, to watch the live strip.
    static var simulateGeneration: Bool { env["GRASP_SIM_GENERATE"] == "1" }
    /// Deck screen: open the Approve All confirmation (nothing is approved).
    static var confirmApproveAll: Bool { env["GRASP_CONFIRM_APPROVE"] == "1" }
    /// Deck screen, Questions tab: show the Add menu's items in a popover,
    /// because a menu cannot be opened without a tap and the headless
    /// simulator has none. For screenshots only.
    static var showAddMenu: Bool { env["GRASP_SHOW_ADD_MENU"] == "1" }
    #else
    static let skipWelcome = false
    static let course: String? = nil
    static let deck: String? = nil
    static let mode: String? = nil
    static let tab: String? = nil
    static let filter: String? = nil
    static let select = false
    static let simulateGeneration = false
    static let confirmApproveAll = false
    static let showAddMenu = false
    #endif
}
