import Foundation
import Observation

/// The two soft asks. Each is shown once ever, per device, and any choice
/// (Send feedback, Not now, Don't ask again) ends that ask for good.
///
///  - `.firstTest`: after the person's first finished Test.
///  - `.week`: seven days after this build's first launch.
///
/// They never appear during Study, Learn or a Test, and never over a sheet.
/// Someone whose library already had courses or cards at first launch of this
/// build (the maintainer) is never asked: both are marked shown.
enum FeedbackAsk: String, Sendable {
    case firstTest, week

    var message: String {
        switch self {
        case .firstTest: return "You finished your first test. How did it go?"
        case .week: return "You've had GRASP for a week. How is it going?"
        }
    }
}

@MainActor @Observable
final class FeedbackAsks {
    private let defaults: UserDefaults
    private let now: () -> Date

    /// The ask on screen right now, if any.
    private(set) var showing: FeedbackAsk?

    static let firstLaunchKey = "feedbackFirstLaunch"
    static let testFinishedKey = "feedbackFirstTestFinished"
    static let firstTestShownKey = "feedbackAskFirstTestShown"
    static let weekShownKey = "feedbackAskWeekShown"
    static let optedOutKey = "feedbackAskOptedOut"
    static let weekInterval: TimeInterval = 7 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Called once when the app opens. Starts the seven days, and marks both
    /// asks shown for a library that already has content.
    func recordLaunch(libraryHasData: Bool) {
        if defaults.object(forKey: Self.firstLaunchKey) == nil {
            defaults.set(now(), forKey: Self.firstLaunchKey)
            if libraryHasData {
                defaults.set(true, forKey: Self.firstTestShownKey)
                defaults.set(true, forKey: Self.weekShownKey)
            }
        }
    }

    /// A Test was finished. Only the first one counts.
    func noteTestFinished() {
        if !defaults.bool(forKey: Self.testFinishedKey) { defaults.set(true, forKey: Self.testFinishedKey) }
    }

    /// The ask that is due, or nil. `busy` is true during Study, Learn or a
    /// Test; `sheetShowing` when anything is presented over the screen.
    func due(busy: Bool, sheetShowing: Bool) -> FeedbackAsk? {
        guard !busy, !sheetShowing, !defaults.bool(forKey: Self.optedOutKey) else { return nil }
        if defaults.bool(forKey: Self.testFinishedKey), !defaults.bool(forKey: Self.firstTestShownKey) { return .firstTest }
        if let first = defaults.object(forKey: Self.firstLaunchKey) as? Date,
           now().timeIntervalSince(first) >= Self.weekInterval,
           !defaults.bool(forKey: Self.weekShownKey) { return .week }
        return nil
    }

    /// Shows the due ask, and counts it as shown at once, so it can never
    /// come back even if the app closes with it on screen.
    @discardableResult
    func showIfDue(busy: Bool, sheetShowing: Bool) -> FeedbackAsk? {
        guard showing == nil, let ask = due(busy: busy, sheetShowing: sheetShowing) else { return nil }
        defaults.set(true, forKey: ask == .firstTest ? Self.firstTestShownKey : Self.weekShownKey)
        showing = ask
        return ask
    }

    /// Any choice on the card ends it.
    func dismiss() { showing = nil }

    /// "Don't ask again": neither ask is ever shown.
    func neverAskAgain() {
        defaults.set(true, forKey: Self.optedOutKey)
        defaults.set(true, forKey: Self.firstTestShownKey)
        defaults.set(true, forKey: Self.weekShownKey)
        showing = nil
    }

    #if DEBUG
    /// Debug launch flag: show an ask now, whatever the rules say.
    func forceShow(_ ask: FeedbackAsk) { showing = ask }
    #endif
}
