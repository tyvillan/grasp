import SwiftUI

/// Lets any view (Settings, in particular) ask `GRASPApp` to drop back
/// to the profile picker without quitting the app.
private struct SwitchProfileKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var switchProfile: () -> Void {
        get { self[SwitchProfileKey.self] }
        set { self[SwitchProfileKey.self] = newValue }
    }
}
