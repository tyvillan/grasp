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
    @State private var showingMenu = false

    var body: some View {
        Button {
            showingMenu = true
        } label: {
            Avatar(name: store.profile.name, size: 28, fontSize: 12)
        }
        .buttonStyle(.plain)
        .help(store.profile.name)
        .popover(isPresented: $showingMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Avatar(name: store.profile.name, size: 40, fontSize: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.profile.name).font(.headline)
                        Text("Local profile").font(.caption).foregroundStyle(GRASPColor.textSecondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    MenuRow(title: "Settings…", icon: "gearshape") {
                        showingMenu = false
                        openSettings()
                    }
                    MenuRow(title: "Switch Profile / Sign Out", icon: "arrow.left.arrow.right") {
                        showingMenu = false
                        switchProfile()
                    }
                }
            }
            .padding(16)
            .frame(width: 240)
            .background(GRASPColor.surfaceRaised)
        }
    }
}

private struct MenuRow: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

