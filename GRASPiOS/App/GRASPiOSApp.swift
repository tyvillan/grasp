import SwiftUI
import GRASPCore

/// GRASP on iPhone. The same library as the Mac -- one account, synced --
/// built on the shared store, sync engine and study code in
/// `Sources/GRASP/Shared` and GRASPCore. Only the screens are the phone's
/// own.
@main
struct GRASPiOSApp: App {
    @State private var store: AppStore?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceChoice.storageKey, store: .standard) private var appearance = AppearanceChoice.dark.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    MainTabView(onSwitchProfile: { self.store = nil })
                        .environment(store)
                        .defaultAppStorage(store.preferences)
                } else {
                    WelcomeView { profile in
                        store = AppStore(profile: profile)
                    }
                    .task {
                        guard DebugLaunch.skipWelcome,
                              let profile = (try? ProfileStore.loadOrMigrate(
                                  supportDirectory: AppPaths.supportDirectory()))?.first
                        else { return }
                        store = AppStore(profile: profile)
                    }
                }
            }
            .tint(GRASPColor.accent)
            .preferredColorScheme((AppearanceChoice(rawValue: appearance) ?? .dark).colorScheme)
            .onOpenURL { url in
                if let link = WidgetLink(url: url) {
                    WidgetRouter.shared.pending = link
                } else {
                    Task { await AccountService.shared.handle(url: url) }
                }
            }
            // The debounced publish after a last review may not get to run
            // once the app is suspended.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, let store { WidgetPublisher.shared.publish(from: store) }
            }
        }
    }
}
