import Foundation

/// Where tapping a widget takes you: `grasp://widget/<destination>`.
///
/// Shares the `grasp://` scheme with sign-in callbacks; the `widget` host
/// is what tells the two apart. Compiled into the widget extensions
/// directly, like `WidgetSnapshot`, so it stays Foundation-only.
public nonisolated enum WidgetLink: Hashable, Sendable {
    case today
    case calendar
    case deck(String)

    public static let host = "widget"

    public var url: URL {
        var components = URLComponents()
        components.scheme = "grasp"
        components.host = Self.host
        switch self {
        case .today: components.path = "/today"
        case .calendar: components.path = "/calendar"
        case .deck(let id): components.path = "/deck/\(id)"
        }
        return components.url ?? URL(string: "grasp://widget/today")!
    }

    public init?(url: URL) {
        guard url.scheme == "grasp", url.host == Self.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch parts.first {
        case "today": self = .today
        case "calendar": self = .calendar
        case "deck" where parts.count >= 2 && !parts[1].isEmpty: self = .deck(parts[1])
        default: return nil
        }
    }
}
