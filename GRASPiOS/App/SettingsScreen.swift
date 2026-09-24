import SwiftUI
import GRASPCore

/// Profile, sync, and study preferences.
struct SettingsScreen: View {
    let onSwitchProfile: () -> Void
    @Environment(AppStore.self) private var store
    @AppStorage("dailyCardGoal") private var dailyGoal = 20
    @AppStorage(AppearanceChoice.storageKey, store: .standard) private var appearance = AppearanceChoice.dark.rawValue
    @State private var confirmingSignOut = false
    @State private var pendingLink: SignedInAccount?
    @State private var linkError: String?

    var body: some View {
        let sync = store.sync!
        @Bindable var store = store
        Form {
            Section("Profile") {
                LabeledContent("Name", value: store.profile.name)
                Button("Switch Profile", action: onSwitchProfile)
            }
            .graspSection()

            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            .graspSection()

            Section {
                if let account = sync.account {
                    LabeledContent("Signed in as", value: account.email ?? "Your account")
                    LabeledContent("Status") { statusText(sync) }
                    Button("Sync Now") { sync.syncNow() }
                        .disabled(sync.state == .syncing || sync.state == .signedOut)
                    if sync.state == .signedOut {
                        Text("This iPhone's sign-in has expired. Sign in again to keep syncing.")
                            .font(.footnote).foregroundStyle(.secondary)
                        SignInButtons { sync.resume($0) }
                            .frame(maxWidth: .infinity)
                    }
                    Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                } else {
                    Text("This profile is only on this iPhone. Sign in to sync it with your Mac and other devices.")
                        .font(.footnote).foregroundStyle(.secondary)
                    SignInButtons { link($0) }
                        .frame(maxWidth: .infinity)
                    if let linkError {
                        Text(linkError).font(.footnote).foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Account & Sync")
            }
            .graspSection()

            Section("Study") {
                Stepper("Daily goal: \(dailyGoal) cards", value: $dailyGoal, in: 5...200, step: 5)
            }
            .graspSection()

            Section {
                LabeledContent("Model", value: store.generatorStatus)
                Toggle("AI questions in tests", isOn: $store.isAITestQuestionsEnabled)
            } header: {
                Text("AI")
            } footer: {
                Text(store.isGeneratorAvailable
                     ? "Writing overviews, refining cards and adding cards use Apple's on-device model -- nothing leaves your iPhone."
                     : "AI features need Apple Intelligence (iPhone 15 Pro or later, turned on in Settings). Everything else works without it, and overviews written on your Mac sync here.")
            }
            .graspSection()
            .task { await store.refreshGeneratorStatus() }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }
            .graspSection()
        }
        .graspList()
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of sync?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await sync.signOut() } }
        } message: {
            Text("Your library stays on this iPhone as a local profile and stops syncing.")
        }
        .confirmationDialog(
            "Your account already has a library",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            titleVisibility: .visible
        ) {
            Button("Combine Them") { if let pendingLink { finishLink(pendingLink) } }
            Button("Cancel", role: .cancel) { pendingLink = nil }
        } message: {
            Text("This profile's cards will be added to your account's library. To use your account's library on this iPhone instead, switch profile and sign in from there.")
        }
        .onChange(of: AccountService.shared.completedFromLink) { _, _ in
            guard let signedIn = AccountService.shared.consumeCompletedFromLink() else { return }
            if sync.account == nil { link(signedIn) } else { sync.resume(signedIn) }
        }
    }

    @ViewBuilder
    private func statusText(_ sync: SyncController) -> some View {
        switch sync.state {
        case .syncing:
            HStack(spacing: 6) { ProgressView(); Text("Syncing…") }
        case .failed(let message):
            Text(message).foregroundStyle(.red).font(.footnote)
        case .signedOut:
            Text("Signed out").foregroundStyle(.red)
        default:
            if let last = sync.lastSyncedAt {
                Text("Synced \(last.formatted(.relative(presentation: .named)))")
            } else {
                Text("Not synced yet")
            }
        }
    }

    private func link(_ signedIn: SignedInAccount) {
        Task {
            if await AccountService.shared.accountHasData(userId: signedIn.userId) == true {
                pendingLink = signedIn
            } else {
                finishLink(signedIn)
            }
        }
    }

    private func finishLink(_ signedIn: SignedInAccount) {
        pendingLink = nil
        do {
            try store.sync.link(signedIn, uploadLibrary: true)
        } catch {
            linkError = "Couldn't turn on sync: \(error.localizedDescription)"
        }
    }
}
