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
                Button("Send feedback") { FeedbackService.shared.isPresenting = true }
            } header: {
                Text("Feedback")
            } footer: {
                Text("Tell us what's working, what's confusing, or what you wish it did. Nothing is sent from your library, and you can send it anonymously.")
            }
            .graspSection()

            Section {
                Button("Replay tutorial") { store.tutorial.start() }
            } header: {
                Text("Tutorial")
            } footer: {
                Text("A two minute tour of the main screens. It only points at things and never changes your library.")
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
                            .font(.graspFootnote).foregroundStyle(.secondary)
                        SignInButtons { sync.resume($0) }
                            .frame(maxWidth: .infinity)
                    }
                    Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                } else {
                    Text("This profile is only on this iPhone. Sign in to sync it with your Mac and other devices.")
                        .font(.graspFootnote).foregroundStyle(.secondary)
                    SignInButtons { link($0) }
                        .frame(maxWidth: .infinity)
                    if let linkError {
                        Text(linkError).font(.graspFootnote).foregroundStyle(.red)
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
                NavigationLink {
                    AISettingsScreen()
                } label: {
                    LabeledContent("AI", value: store.aiMode.label)
                }
            } footer: {
                Text(store.generatorStatus)
            }
            .graspSection()
            .task { await store.refreshGeneratorStatus() }

            Section("Library") {
                NavigationLink {
                    ArchivedCoursesScreen()
                } label: {
                    LabeledContent("Archived Courses", value: "\(store.archivedCourses.count)")
                }
            }
            .graspSection()

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }
            .graspSection()
        }
        .graspList()
        .navigationTitle("Settings")
        .sheet(isPresented: $confirmingSignOut) {
            ConfirmationSheet(
                icon: "rectangle.portrait.and.arrow.right", title: "Sign out of sync?",
                message: "Your library stays on this iPhone as a local profile and stops syncing.",
                confirmTitle: "Sign out"
            ) { Task { await sync.signOut() } }
        }
        .sheet(isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } })) {
            ConfirmationSheet(
                icon: "arrow.triangle.merge", title: "Your account already has a library",
                message: "This profile's cards will be added to your account's library. To use your account's library on this iPhone instead, switch profile and sign in from there.",
                confirmTitle: "Combine them", isDestructive: false
            ) { if let pendingLink { finishLink(pendingLink) } }
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
            Text(message).foregroundStyle(.red).font(.graspFootnote)
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
            linkError = PlainError.message(error, couldnt: "turn on sync")
        }
    }
}

/// Courses archived on the Mac (or here), with a way back. The iPhone has no
/// sidebar to archive from, so this is where they stay reachable.
private struct ArchivedCoursesScreen: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            if store.archivedCourses.isEmpty {
                ContentUnavailableView("No Archived Courses", systemImage: "archivebox")
            }
            ForEach(store.archivedCourses) { course in
                HStack {
                    Text(course.name)
                    Spacer()
                    Button("Unarchive") { try? store.setCourseArchived(course.id, archived: false) }
                        .buttonStyle(.borderless)
                }
            }
        }
        .graspList()
        .navigationTitle("Archived Courses")
    }
}
