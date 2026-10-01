import SwiftUI
import AppKit
import GRASPCore

/// General, AI and Advanced. Every AI setting lives in AI -- which model
/// runs, the cloud key, the local server, and the AI-only features -- so
/// switching between local and cloud is one place, not four.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppStore.self) private var store
    @Environment(\.switchProfile) private var switchProfile
    @State private var showingArchivedCourses = false
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

            Section("Hidden Courses") {
                SettingsManagementRow(
                    title: "Archived Courses", count: store.archivedCourses.count
                ) { showingArchivedCourses = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 580)
        .sheet(isPresented: $showingArchivedCourses) { ArchivedCoursesSheet() }
    }
}

/// Which model runs (local, cloud, or cloud with local behind it), the
/// Gemini key, the local Ollama server, and the features that only exist
/// with AI.
private struct AISettingsTab: View {
    @Environment(AppStore.self) private var store
    @State private var showingOllamaSetup = false
    @State private var keyDraft = ""
    @State private var pendingMode: AIMode?
    @AppStorage(AIPreferences.cloudModelKey, store: .standard) private var cloudModel = ""
    /// Owned by the store: closing Settings mid-sweep used to leave it
    /// running with no Stop button, and reopening offered a second one.
    private var sweepActivity: AIActivity? { store.aiJob(AppStore.sweepJobKey)?.activity }
    @State private var contextSweepResult: AppStore.ContextCheckSummary?

    var body: some View {
        @Bindable var store = store
        Form {
            modelSection
            cloudSection
            localSection
            featuresSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .task {
            await store.refreshOllamaStatus()
            if store.hasCloudKey || AIKeyStore.read() != nil { await store.testCloudConnection() }
            await store.refreshGeneratorStatus()
        }
        .sheet(isPresented: $showingOllamaSetup) {
            OllamaSetupSheet(onStartService: startOllamaAndRecheck)
        }
        .alert("Send your notes to Google?", isPresented: Binding(
            get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }
        )) {
            Button("Use Gemini") {
                AIPreferences.hasAcceptedCloudNotice = true
                if let pendingMode { store.setAIMode(pendingMode) }
                pendingMode = nil
            }
            Button("Cancel", role: .cancel) { pendingMode = nil }
        } message: {
            Text(Self.freeTierNotice + " You can switch back to Local at any time.")
        }
        .sheet(isPresented: Binding(get: { contextSweepResult != nil }, set: { if !$0 { contextSweepResult = nil } })) {
            if let contextSweepResult {
                ResultSheet(
                    icon: "checkmark.shield",
                    title: "Off-Topic Card Check Complete",
                    leadText: contextSweepResult.isEmpty
                        ? "Every card checked out fine -- nothing looked like assignment text or an off-topic fragment. (If no AI model is set up, nothing was checked at all -- see Model above.)"
                        : nil,
                    sections: contextSweepSections(contextSweepResult)
                )
            }
        }
    }

    static let freeTierNotice = "Cloud mode sends the text of your notes to Google Gemini. Its free tier may use what you send to improve Google's products, and people at Google may read it."

    // MARK: Model

    private var modelSection: some View {
        Section("Model") {
            Picker("Runs on", selection: Binding(
                get: { store.aiMode },
                set: { mode in
                    if mode.usesCloud && !AIPreferences.hasAcceptedCloudNotice {
                        pendingMode = mode
                    } else {
                        store.setAIMode(mode)
                    }
                }
            )) {
                ForEach(AIMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline) {
                Text(store.generatorStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await store.refreshGeneratorStatus() } }
                    .font(.caption)
            }
            Text(modeExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeExplanation: String {
        switch store.aiMode {
        case .local:
            return "Everything runs on this Mac -- Ollama if it's running, else Apple's on-device model. Nothing leaves your Mac. With no model at all, cards come from the parser only."
        case .cloud:
            return "Everything runs on Google Gemini: much stronger lessons and cards than a local model, and quick. When today's free limit runs out, AI features stop until it resets at midnight Pacific."
        case .automatic:
            return "Gemini when it can, your local model when it can't: if Gemini is busy, offline or out of today's free requests, the job carries on locally from where it was."
        }
    }

    // MARK: Cloud

    private var cloudSection: some View {
        Section("Cloud: \(CloudProvider.name)") {
            if store.hasCloudKey {
                HStack(spacing: 8) {
                    StatusBadge(text: cloudStatusText, isPositive: cloudIsHealthy)
                    Spacer()
                    Button {
                        Task { await store.testCloudConnection() }
                    } label: {
                        if store.isCheckingCloud { ProgressView().controlSize(.small) } else { Text("Test Connection") }
                    }
                    .disabled(store.isCheckingCloud)
                    Button("Remove Key", role: .destructive) { Task { await store.removeCloudKey() } }
                }
                if !store.cloudModels.isEmpty {
                    Picker("Model", selection: $cloudModel) {
                        Text("Automatic (\(store.cloudModels.first ?? CloudProvider.fallbackModel))").tag("")
                        ForEach(store.cloudModels, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: cloudModel) { _, new in store.setCloudModel(new) }
                }
                usageRow
            } else {
                if let problem = store.cloudKeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(GRASPColor.rejected)
                }
                HStack(spacing: 8) {
                    SecureField("Paste your Gemini API key", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let key = keyDraft
                        keyDraft = ""
                        Task { await store.saveCloudKey(key) }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Link("Get a free key at Google AI Studio", destination: CloudProvider.keyPageURL)
                    .font(.caption)
                Text("Stored in your Keychain, never in your library or synced to GRASP's server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label(Self.freeTierNotice, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cloudIsHealthy: Bool {
        if case .ok = store.cloudCheck, CloudUsage.shared.pausedUntil == nil { return true }
        return false
    }

    private var cloudStatusText: String {
        _ = store.cloudUsageRevision
        if CloudUsage.shared.pausedUntil != nil { return "Free Limit Reached" }
        switch store.cloudCheck {
        case .ok: return "Connected"
        case .badKey: return "Key Not Accepted"
        case .quotaUsedUp: return "Free Limit Reached"
        case .offline: return "Can't Reach Google"
        case .failed: return "Check Failed"
        case nil: return store.isCheckingCloud ? "Checking…" : "Not Checked"
        }
    }

    private var usageRow: some View {
        _ = store.cloudUsageRevision
        let used = CloudUsage.shared.requestsToday
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Today")
                Spacer()
                Text("\(used) of about \(CloudProvider.estimatedRequestsPerDay) free requests")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressBar(value: min(used, CloudProvider.estimatedRequestsPerDay), total: CloudProvider.estimatedRequestsPerDay)
            HStack(spacing: 4) {
                Text("An estimate: Google sets each project's own limit, and resets it at midnight Pacific.")
                Link("See yours", destination: CloudProvider.usagePageURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let last = CloudUsage.shared.lastFallback, store.aiMode == .automatic {
                Text("Last switch to local: \(last)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Local

    private var localSection: some View {
        Section("Local: Ollama") {
            ollamaStatusRow
            ollamaDetailText
            if !store.ollamaStatus.isRunning {
                Button("Setup Local AI…") { showingOllamaSetup = true }
            }
        }
    }

    // MARK: Features

    private var featuresSection: some View {
        @Bindable var store = store
        return Section("AI Features") {
            Toggle("Include AI-generated practice questions in tests", isOn: $store.isAITestQuestionsEnabled)
            Text("Custom Tests mix in a few fresh, written questions grounded in your notes. They're generated each time and never saved as cards or scheduled.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let sweepActivity {
                AIProgressStrip(
                    activity: sweepActivity,
                    onStop: { store.stopAIJob(AppStore.sweepJobKey) },
                    stopHelp: "Stops now. Cards already checked keep their changes; the rest are left as they are.",
                    isInline: true
                )
            } else {
                Button("Check All Cards for Off-Topic Content…") { sweepAllCardsForContext() }
            }
            Text("Goes card by card against its own source note: a definition that reads like assignment instructions or a vague fragment is rewritten from the note's text, or removed if the note doesn't support one. Every change is listed afterwards and can be undone from the card's \"AI Refined\" badge.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let warning = AIQuotaEstimate.warning(
                needed: AIQuotaEstimate.contextCheckRequests(cards: store.deckCounts.values.reduce(0) { $0 + $1.cardCount }),
                mode: store.aiMode
            ), store.hasCloudKey {
                Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
        .sheet(isPresented: $showingExcludedFolders) { ExcludedFoldersSheet() }
        .sheet(isPresented: $showingDuplicateReview) {
            DuplicateReviewSheet(groups: duplicateGroups) { merges in
                try? store.mergeDuplicates(merges)
            }
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
            Text("Ollama runs a small language model on this Mac, so AI features work offline and your notes never leave it.")
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
/// Lets a Google account add a password, for signing in where Google
/// sign-in isn't available yet (GRASP on Windows).
private struct PasswordForOtherDevices: View {
    let userId: String
    @State private var password = ""
    @State private var working = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password for other devices").font(.headline)
            Text("GRASP on Windows signs in with email and password. Set a password here, then sign in there with this account's email.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField("New password (at least 6 characters)", text: $password)
                Button("Set Password") { save() }
                    .disabled(working || password.count < 6)
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(failed ? .red : .secondary)
            }
        }
    }

    private func save() {
        working = true
        Task {
            do {
                try await AccountService.shared.setPassword(password, userId: userId)
                result = "Password set. Use it with this account's email on Windows."
                failed = false
                password = ""
            } catch {
                result = "Couldn't set the password: \(error.localizedDescription)"
                failed = true
            }
            working = false
        }
    }
}

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
                if account.provider == "google" {
                    PasswordForOtherDevices(userId: account.userId)
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
