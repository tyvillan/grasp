import SwiftUI
import GRASPCore

@main
struct GRASPApp: App {
    @State private var store: AppStore?

    /// Skips the profile picker straight to the first existing profile --
    /// only when `GRASP_SKIP_PICKER=1` is explicitly set in the
    /// environment. Exists for screenshotting/QA where clicking through
    /// the picker isn't possible; off unless that variable is set, so it
    /// never affects a normal launch.
    private func autoSelectedProfile() -> Profile? {
        guard ProcessInfo.processInfo.environment["GRASP_SKIP_PICKER"] == "1" else { return nil }
        let support = (try? GRASPDatabase.supportDirectory()) ?? FileManager.default.temporaryDirectory
        return (try? ProfileStore.loadOrMigrate(supportDirectory: support))?.first
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                ContentView()
                    .environment(store)
                    .defaultAppStorage(store.preferences)
                    .environment(\.switchProfile) { self.store = nil }
                    .frame(minWidth: 800, minHeight: 500)
            } else {
                ProfilePickerView { profile in
                    store = AppStore(profile: profile)
                }
                .task {
                    if let profile = autoSelectedProfile() { store = AppStore(profile: profile) }
                }
            }
        }
        .windowStyle(.automatic)

        Settings {
            if let store {
                SettingsView()
                    .environment(store)
                    .defaultAppStorage(store.preferences)
                    .environment(\.switchProfile) { self.store = nil }
            }
        }
    }
}
