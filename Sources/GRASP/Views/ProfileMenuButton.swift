import SwiftUI
import GRASPCore

/// The avatar button in the top-right of the toolbar: shows who's signed
/// in and opens a small account panel to switch/sign out of the current
/// local profile or jump to Settings -- the same two actions Quizlet's
/// own avatar menu exposes, just backed by local profiles instead of a
/// server account.
struct ProfileMenuButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.switchProfile) private var switchProfile
    @Environment(\.openSettings) private var openSettings
    /// The sidebar's footer shows the name beside the avatar.
    var showsName = false
    @State private var anchor = MenuAnchor()
    @State private var hovering = false

    var body: some View {
        Button {
            anchor.present([
                .header(store.profile.name),
                .action("Settings…", systemImage: "gearshape", shortcut: (",", .command)) { openSettings() },
                .divider,
                .action("Switch profile / sign out", systemImage: "arrow.left.arrow.right") { switchProfile() },
            ])
        } label: {
            HStack(spacing: 10) {
                Avatar(name: store.profile.name, size: 28, fontSize: 12)
                if showsName {
                    Text(store.profile.name.split(separator: " ").first.map(String.init) ?? store.profile.name)
                        .font(.graspUI(size: 13.5, weight: .medium))
                        .foregroundStyle(hovering ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorHost(anchor: anchor))
        .onHover { hovering = $0 }
        .help(store.profile.name)
    }
}
