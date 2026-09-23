import SwiftUI
import AppKit
import GRASPCore

/// Two tabs, General and Advanced -- the standard macOS Settings shape.
/// Vault Path and Excluded Folders moved to Advanced: both are "how the
/// importer behaves" plumbing rather than day-to-day settings, and neither
/// needs to compete with Profile/Card Generation for the first thing a
/// person sees. `vaultPath` itself is still the same `AppStore` property
/// either tab reads and writes -- moving which tab shows the field changes
/// nothing about how it's stored or how the importer reads it.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppStore.self) private var store
    @Environment(\.switchProfile) private var switchProfile
    @State private var showingArchivedCourses = false
    @State private var showingOllamaSetup = false
    // Shared with HomeView's goal bar and the study session's focus timer
    // through `@AppStorage`'s own store, rather than threaded through
    // AppStore -- these are view preferences, not app data.
    @AppStorage("dailyCardGoal") private var dailyGoal = 20
    @AppStorage("focusWorkMinutes") private var focusWorkMinutes = 25
    @AppStorage("focusBreakMinutes") private var focusBreakMinutes = 5
    @AppStorage("focusCardTarget") private var focusCardTarget = 20

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Profile") {
                HStack {
                    Text(store.profile.name)
                    Spacer()
                    Button("Switch Profile…") { switchProfile() }
                }
            }

            AccountSyncSection()

            Section("Card Generation") {
                HStack {
                    Text(store.generatorStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await store.refreshGeneratorStatus() } }
                        .font(.caption)
                }
                Text("With no local model, cards come from the deterministic parser only -- fully usable, just more editing in the review queue. Install Ollama and pull a model (e.g. qwen3.5:9b) to enable AI refinement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Study Goals") {
                Stepper(value: $dailyGoal, in: 0...500, step: 5) {
                    Text(dailyGoal == 0 ? "No daily goal" : "\(dailyGoal) cards a day")
                        .monospacedDigit()
                }
                Text("Sets the progress bar on Home and what counts as a full day. Your study streak counts any day with at least one review, whatever the goal -- so a light day still keeps it alive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Focus Timer") {
                Stepper(value: $focusWorkMinutes, in: 5...90, step: 5) {
                    Text("\(focusWorkMinutes) min work interval").monospacedDigit()
                }
                Stepper(value: $focusBreakMinutes, in: 1...30) {
                    Text("\(focusBreakMinutes) min break").monospacedDigit()
                }
                Stepper(value: $focusCardTarget, in: 0...200, step: 5) {
                    Text(focusCardTarget == 0 ? "No card target" : "\(focusCardTarget) cards per interval")
                        .monospacedDigit()
                }
                Text("Used by the focus timer in a flashcard session. It never pauses or interrupts you -- when an interval is up the bar changes colour and waits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI-Generated Test Questions") {
                Toggle("Include AI-generated practice questions in tests", isOn: $store.isAITestQuestionsEnabled)
                Text("When enabled, Custom Tests mix in a few fresh, written questions grounded in your notes alongside your real cards. These are generated fresh each time and never saved as cards, added to the review queue, or scheduled by FSRS. Uses the same AI connection as Card Generation above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ollama Local Server") {
                ollamaStatusRow
                ollamaDetailText
                if !store.ollamaStatus.isRunning {
                    Button("Setup Local AI…") { showingOllamaSetup = true }
                }
            }

            Section("Hidden Courses") {
                SettingsManagementRow(
                    title: "Archived Courses", count: store.archivedCourses.count
                ) { showingArchivedCourses = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .task {
            await store.refreshGeneratorStatus()
            await store.refreshOllamaStatus()
        }
        .sheet(isPresented: $showingArchivedCourses) { ArchivedCoursesSheet() }
        .sheet(isPresented: $showingOllamaSetup) {
            OllamaSetupSheet(onStartService: startOllamaAndRecheck)
        }
    }

    private var ollamaStatusRow: some View {
        HStack(spacing: 8) {
            StatusBadge(
                text: store.ollamaStatus.isRunning ? "Ollama Running" : "Ollama Not Detected",
                isPositive: store.ollamaStatus.isRunning
            )
            Spacer()
            Button {
                Task { await store.refreshOllamaStatus() }
            } label: {
                if store.isCheckingOllama {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isCheckingOllama)
            .help("Check again")
        }
    }

    @ViewBuilder
    private var ollamaDetailText: some View {
        if store.ollamaStatus.isRunning {
            let models = store.ollamaStatus.models
            if models.isEmpty {
                Text("Connected, but no models are pulled yet -- run \"ollama pull qwen3.5:9b\" in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                OllamaModelPicker(installed: models)
            }
        } else {
            Text("GRASP couldn't reach a local Ollama server on this Mac. Install it, or start it if it's already installed, to enable on-device AI refinement.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Launching either the menu-bar app or the bare CLI daemon isn't
    /// instant -- a re-check fired the same moment would almost always
    /// still see nothing listening, so this gives it a couple seconds
    /// before asking.
    private func startOllamaAndRecheck() {
        OllamaLauncher.startService()
        Task {
            try? await Task.sleep(for: .seconds(2))
            await store.refreshOllamaStatus()
        }
    }
}

private struct AdvancedSettingsTab: View {
    @Environment(AppStore.self) private var store
    @State private var showingExcludedFolders = false
    @State private var showingDuplicateReview = false
    @State private var duplicateGroups: [AppStore.DuplicateGroup] = []
    /// Only meaningful right after a scan that found nothing -- a scan
    /// that found groups opens the review sheet instead, so this never
    /// needs to report a positive count itself.
    @State private var duplicateScanFoundNone = false
    /// Owned by the store: closing Settings mid-sweep used to leave it
    /// running with no Stop button, and reopening offered a second one.
    private var sweepActivity: AIActivity? { store.aiJob(AppStore.sweepJobKey)?.activity }
    private var isSweepingContext: Bool { sweepActivity != nil }
    @State private var contextSweepResult: AppStore.ContextCheckSummary?

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Vault") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vault Path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("", text: $store.vaultPath)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { chooseVault() }
                    }
                }
                Text("GRASP only reads from this folder -- it never writes to your Obsidian vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Excluded Folders") {
                SettingsManagementRow(
                    title: "Excluded Folders", count: store.excludedFolders.count
                ) { showingExcludedFolders = true }
            }

            Section("Duplicate Cards") {
                HStack {
                    Button("Scan All Courses for Duplicates…") { scanForDuplicatesAcrossAllCourses() }
                    if duplicateScanFoundNone {
                        Text("No duplicates found").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Looks for near-identical cards across every course, not just within one -- catches the same material imported under two different course folders. Nothing is removed automatically: you review each group and pick which card survives, same as \"Review Duplicates\" inside a single course.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Off-Topic Card Check") {
                if let sweepActivity {
                    AIProgressStrip(
                        activity: sweepActivity,
                        onStop: { store.stopAIJob(AppStore.sweepJobKey) },
                        stopHelp: "Stops now. Cards already checked keep their changes; "
                            + "the rest are left as they are.",
                        isInline: true
                    )
                } else {
                    Button("Check All Cards for Off-Topic Content…") { sweepAllCardsForContext() }
                        .disabled(isSweepingContext)
                }
                Text("One-time sweep of every card you already have, going card by card against its own source note with the local AI model: a definition that reads like assignment instructions or a vague fragment gets rewritten from the note's own text, or removed if the note doesn't support a real one either. Applies immediately -- there's no per-card review step -- but every change is listed in the result and can be undone individually from the \"AI Refined\" badge on the card itself. Needs a local AI model (Ollama or Apple's on-device model) to do anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
        .sheet(isPresented: $showingExcludedFolders) { ExcludedFoldersSheet() }
        .sheet(isPresented: $showingDuplicateReview) {
            DuplicateReviewSheet(groups: duplicateGroups) { merges in
                try? store.mergeDuplicates(merges)
            }
        }
        .sheet(isPresented: Binding(get: { contextSweepResult != nil }, set: { if !$0 { contextSweepResult = nil } })) {
            if let contextSweepResult {
                ResultSheet(
                    icon: "checkmark.shield",
                    title: "Off-Topic Card Check Complete",
                    leadText: contextSweepResult.isEmpty
                        ? "Every card checked out fine -- nothing looked like assignment text or an off-topic fragment. (If you have no local AI model set up, nothing was checked at all -- see Card Generation above.)"
                        : nil,
                    sections: contextSweepSections(contextSweepResult)
                )
            }
        }
    }

    private func contextSweepSections(_ result: AppStore.ContextCheckSummary) -> [ResultSheet.Section] {
        var sections: [ResultSheet.Section] = []
        if !result.refined.isEmpty {
            sections.append(.init(
                icon: "arrow.triangle.2.circlepath", tint: GRASPColor.success, title: "Rewrote",
                items: result.refined.map { "\($0.front) (\($0.courseName))" }
            ))
        }
        if !result.removed.isEmpty {
            sections.append(.init(
                icon: "trash", tint: GRASPColor.rejected, title: "Removed",
                items: result.removed.map { "\($0.front) (\($0.courseName))" }
            ))
        }
        return sections
    }

    private func sweepAllCardsForContext() {
        let run = AIActivity(headline: "Checking every card against its note")
        store.runAIJob(AppStore.sweepJobKey, activity: run) { [store] run in
            let result = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await store.sweepAllCardsForContext()
            }
            if !(run.stopRequested && result.isEmpty) { contextSweepResult = result }
        }
    }

    private func scanForDuplicatesAcrossAllCourses() {
        duplicateScanFoundNone = false
        let groups = (try? store.duplicateGroupsAcrossAllCourses()) ?? []
        if groups.isEmpty {
            duplicateScanFoundNone = true
        } else {
            duplicateGroups = groups
            showingDuplicateReview = true
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.vaultPath)
        if panel.runModal() == .OK, let url = panel.url {
            store.vaultPath = url.path
        }
    }
}

/// A colored capsule for a two-state fact -- the same tint/tintSoft
/// language `DeckDetailView`'s card chips use, reused here rather than a
/// plain colored dot, so a status this prominent gets the same visual
/// weight as everywhere else in the app that reports a state at a glance.
private struct StatusBadge: View {
    let text: String
    let isPositive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isPositive ? GRASPColor.success : GRASPColor.rejected)
                .frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isPositive ? GRASPColor.success : GRASPColor.rejected)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isPositive ? GRASPColor.successSoft : GRASPColor.rejectedSoft, in: Capsule())
    }
}

private struct SettingsManagementRow: View {
    let title: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

/// The "not detected" path's quick setup: two independent actions, not a
/// wizard -- someone who already has Ollama installed just wants the
/// second button, and shouldn't have to click through an install step
/// first. Re-checking after "Start" happens back in `GeneralSettingsTab`,
/// not here, so this sheet stays a dumb presenter of the two actions.
private struct OllamaSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onStartService: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Local AI").font(.headline)
            Text("Ollama runs a small language model on this Mac so card refinement and \"Add More Cards with AI\" work fully offline.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    OllamaLauncher.openDownloadPage()
                } label: {
                    Label("Download & Install Ollama", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                Text("Opens the official installer page in your browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    onStartService()
                    dismiss()
                } label: {
                    Label("Start Local Ollama Service", systemImage: "play.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                Text("Already installed? This launches it in the background and re-checks the connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Every course `setCourseArchived` has hidden, with a one-click way back.
/// The only place an archived course is still visible at all -- neither the
/// sidebar nor the dashboard shows it, by design.
private struct ArchivedCoursesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Archived Courses").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if store.archivedCourses.isEmpty {
                ContentUnavailableView(
                    "No Archived Courses", systemImage: "archivebox",
                    description: Text("Courses you archive from the sidebar or dashboard appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.archivedCourses) { course in
                    HStack {
                        Text(course.name)
                        Spacer(minLength: 8)
                        Button("Unarchive") {
                            try? store.setCourseArchived(course.id, archived: false)
                        }
                    }
                }
                Text("Hidden from the sidebar and dashboard, but their notes and cards are untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .frame(width: 440, height: 380)
    }
}

/// Every vault folder `AppStore.removeCourseAndExclude` has permanently
/// skipped, with a one-click way back -- the same reversal that also
/// happens automatically the moment matching files are added back to a
/// course by hand (see `VaultScanner.importPaths`).
private struct ExcludedFoldersSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Excluded Folders").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if store.excludedFolders.isEmpty {
                ContentUnavailableView(
                    "No Excluded Folders", systemImage: "folder.badge.minus",
                    description: Text("Choosing \"Delete\" on a vault-backed course excludes its folder here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.excludedFolders, id: \.self) { path in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button("Re-include") { try? store.includeFolder(path) }
                    }
                }
                Text("Skipped entirely on your next vault import. Adding files back to one of these folders re-includes it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .frame(width: 480, height: 380)
    }
}

/// Which installed model writes lessons and refines cards. "Automatic"
/// stores nothing, so it keeps tracking `OllamaModelChoice.recommended` as
/// that improves; picking a model pins it. A pinned model that's later
/// removed falls back to automatic on its own, rather than failing every
/// request against a name the server no longer has.
private struct OllamaModelPicker: View {
    let installed: [String]
    // The shared defaults, deliberately: which model to use is about what's
    // installed on this Mac, not whose profile is open -- and it's read
    // from there by `CardGenerators.select()`.
    @AppStorage(OllamaModelChoice.defaultsKey, store: .standard) private var chosen = ""

    private var automaticName: String? {
        OllamaModelChoice.resolve(preferred: nil, installed: installed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Model", selection: $chosen) {
                Text(automaticName.map { "Automatic (\($0))" } ?? "Automatic").tag("")
                ForEach(installed, id: \.self) { Text($0).tag($0) }
            }
            if !chosen.isEmpty, !installed.contains(chosen) {
                Text("\(chosen) isn't installed any more, so GRASP is using \(automaticName ?? "another model").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Used for lessons, card refinement and AI test questions. Larger models write better lessons but take longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings' view of sync for the open profile: who it's signed in as, how
/// the last sync went, and signing in or out.
private struct AccountSyncSection: View {
    @Environment(AppStore.self) private var store
    @State private var confirmingSignOut = false
    @State private var pendingLink: SignedInAccount?
    @State private var linkError: String?

    var body: some View {
        let sync = store.sync!
        Section("Account & Sync") {
            if let account = sync.account {
                LabeledContent("Signed in as", value: account.email ?? "Your account")
                HStack {
                    statusText(sync)
                    Spacer()
                    Button("Sync Now") { sync.syncNow() }
                        .disabled(sync.state == .syncing || sync.state == .signedOut)
                }
                if sync.state == .signedOut {
                    Text("This Mac's sign-in has expired. Sign in again to keep syncing -- nothing here is lost.")
                        .font(.caption).foregroundStyle(.secondary)
                    SignInButtons { signedIn in sync.resume(signedIn) }
                }
                Button("Sign Out…", role: .destructive) { confirmingSignOut = true }
            } else {
                Text("This profile's library is only on this Mac. Sign in to sync it with your other devices -- it's uploaded to your account, and anything you sign in to later gets a copy.")
                    .font(.caption).foregroundStyle(.secondary)
                SignInButtons { signedIn in link(signedIn) }
                if let linkError {
                    Text(linkError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        // An emailed sign-in link opened while this section asked for it.
        .onChange(of: AccountService.shared.completedFromLink) { _, _ in
            guard let signedIn = AccountService.shared.consumeCompletedFromLink() else { return }
            if sync.account == nil { link(signedIn) } else { sync.resume(signedIn) }
        }
        .confirmationDialog("Sign out of sync?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) { Task { await sync.signOut() } }
        } message: {
            Text("Your library stays on this Mac as a local profile. It stops syncing, and your other devices keep their own copies.")
        }
        .confirmationDialog(
            "Your account already has a library",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } })
        ) {
            Button("Combine Them") {
                if let pendingLink { finishLink(pendingLink) }
            }
            Button("Cancel", role: .cancel) { pendingLink = nil }
        } message: {
            Text("This profile's library will be added to the one already in your account. If both came from the same notes you'll get duplicate cards -- to use your account's library on this Mac instead, switch profile and sign in from there.")
        }
    }

    @ViewBuilder
    private func statusText(_ sync: SyncController) -> some View {
        switch sync.state {
        case .syncing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…") }
        case .failed(let message):
            Text(message).foregroundStyle(.red).font(.caption)
        case .notConfigured:
            Text("Sign-in isn't set up in this copy of GRASP.").font(.caption).foregroundStyle(.secondary)
        default:
            if let last = sync.lastSyncedAt {
                Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Not synced yet").foregroundStyle(.secondary)
            }
        }
    }

    /// Links this profile, checking first whether the account already has
    /// someone else's library that this one would be merged into.
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
