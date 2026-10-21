import SwiftUI
import AppKit
import GRASPCore

/// General, AI and Account. Every AI setting lives in AI -- which model
/// runs, the cloud key, the local server, and the AI-only features -- so
/// switching between local and cloud is one place, not four. Tools that act
/// on the whole library (import, duplicates, hidden courses) are on the
/// Library page in the sidebar, not in here.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettingsTab()
                // The sparkle is the AI mark, so it is yellow whether or
                // not its tab is the selected one.
                .tabItem { Label { Text("AI") } icon: { Image(nsImage: Self.yellowSparkle) } }
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .tint(GRASPColor.accent)
    }

    /// The sparkle as a non-template image in the brand yellow, which the
    /// toolbar's tab strip draws as is instead of tinting.
    private static let yellowSparkle: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            .applying(.init(paletteColors: [NSColor(red: 1, green: 0.831, blue: 0.231, alpha: 1)]))
        let image = NSImage(systemSymbolName: AIGlyph.symbol, accessibilityDescription: "AI")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

// MARK: - Page pieces

/// A settings tab's page: the app's ground, a column of grouped boxes. It
/// replaces the system's grouped form, which drew in the system's grey and
/// its own type.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GRASPColor.canvas)
        .font(.graspBody)
        .foregroundStyle(GRASPColor.textPrimary)
        .tint(GRASPColor.accent)
        .toggleStyle(GRASPSwitchStyle())
        .buttonStyle(GRASPQuietButton())
        .textFieldStyle(GRASPFieldStyle())
    }
}

/// A heading in Bricolage over a box of rows split by hairlines.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.graspUI(size: 12, weight: .semibold))
                        .foregroundStyle(GRASPColor.accent)
                }
                Text(title)
                    .font(.graspDisplay(17, heavy: false))
                    .tracking(-0.2)
                    .foregroundStyle(GRASPColor.textPrimary)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous)
                    .strokeBorder(GRASPColor.hairline, lineWidth: 1)
            )
        }
    }
}

/// One row in a group: padded, with a hairline above all but the first.
private struct SettingsRow<Content: View>: View {
    var showsDivider = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A number you step: the words on the left, the stepper at the right edge.
private struct StepperRow: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let text: String

    var body: some View {
        HStack {
            Text(text).monospacedDigit()
            Spacer()
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}

/// A muted line of explanation under a control.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .graspType(.meta)
            .foregroundStyle(GRASPColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An outlined pill that turns coral only when the pointer is on it, for
/// the few actions that remove something.
private struct DangerOnHoverButton: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.graspUI(size: 13.5, weight: .medium))
            .foregroundStyle(hovering ? GRASPColor.rejected : GRASPColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(Capsule().fill(hovering ? GRASPColor.rejectedSoft : .clear))
            .overlay(Capsule().strokeBorder(hovering ? GRASPColor.rejected.opacity(0.6) : GRASPColor.textPrimary.opacity(0.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Motion.fade, value: hovering)
    }
}

/// A web link in the page's own look: gold text, underlined on hover.
private struct LinkText: View {
    let title: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .underline(hovering, color: GRASPColor.accent)
        }
        .buttonStyle(.plain)
        .font(.graspUI(size: 12.5, weight: .medium))
        .foregroundStyle(GRASPColor.accent)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppStore.self) private var store
    // Shared with HomeView's goal bar and the study session's focus timer
    // through `@AppStorage`'s own store, rather than threaded through
    // AppStore -- these are view preferences, not app data.
    @AppStorage("dailyCardGoal") private var dailyGoal = 20
    @AppStorage("focusWorkMinutes") private var focusWorkMinutes = 25
    @AppStorage("focusBreakMinutes") private var focusBreakMinutes = 5
    @AppStorage("focusCardTarget") private var focusCardTarget = 20

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Study goals") {
                SettingsRow(showsDivider: false) {
                    StepperRow(value: $dailyGoal, range: 0...500, step: 5, text: dailyGoal == 0 ? "No daily goal" : "\(dailyGoal) cards a day")
                    Footnote("Sets the progress bar on Home and what counts as a full day. Your study streak counts any day with at least one review, whatever the goal, so a light day still keeps it alive.")
                }
            }

            SettingsGroup(title: "Focus timer") {
                SettingsRow(showsDivider: false) {
                    StepperRow(value: $focusWorkMinutes, range: 5...90, step: 5, text: "\(focusWorkMinutes) min work interval")
                }
                SettingsRow {
                    StepperRow(value: $focusBreakMinutes, range: 1...30, text: "\(focusBreakMinutes) min break")
                }
                SettingsRow {
                    StepperRow(value: $focusCardTarget, range: 0...200, step: 5, text: focusCardTarget == 0 ? "No card target" : "\(focusCardTarget) cards per interval")
                    Footnote("Used by the focus timer in a flashcard session. It never pauses or interrupts you. When an interval is up the bar changes colour and waits.")
                }
            }

            SettingsGroup(title: "Feedback") {
                SettingsRow(showsDivider: false) {
                    Button("Send feedback") { FeedbackLauncher.open() }
                    Footnote("Tell us what's working, what's confusing, or what you wish it did. Nothing is sent from your library, and you can send it anonymously.")
                }
            }

            SettingsGroup(title: "Tutorial") {
                SettingsRow(showsDivider: false) {
                    Button("Replay tutorial") { TutorialLauncher.replay(store.tutorial) }
                    Footnote("A two minute tour of the main screens. It only points at things and never changes your library.")
                }
            }
        }
        .frame(width: 480, height: 700)
    }
}

/// Who's signed in and the sync account. Switching profile lives in the
/// avatar menu at the top right, so it isn't repeated here.
private struct AccountSettingsTab: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Profile") {
                SettingsRow(showsDivider: false) {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(store.profile.name).foregroundStyle(GRASPColor.textSecondary)
                    }
                }
            }
            AccountSyncSection()
        }
        .frame(width: 480, height: 560)
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
    @AppStorage(AIPreferences.geminiPlanKey, store: .standard) private var geminiPlan = GeminiPlan.free.rawValue

    var body: some View {
        @Bindable var store = store
        SettingsPage {
            modelSection
            cloudSection
            localSection
            featuresSection
        }
        .frame(width: 480, height: 660)
        .task {
            await store.refreshOllamaStatus()
            if store.hasCloudKey || AIKeyStore.read() != nil { await store.testCloudConnection() }
            await store.refreshGeneratorStatus()
        }
        .sheet(isPresented: $showingOllamaSetup) {
            OllamaSetupSheet(onStartService: startOllamaAndRecheck)
        }
        .sheet(isPresented: Binding(
            get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }
        )) {
            ConfirmationSheet(
                icon: "cloud", title: "Send your notes to Google?",
                message: Self.freeTierNotice + " You can switch back to Local at any time.",
                confirmTitle: "Use Gemini", isDestructive: false
            ) {
                AIPreferences.hasAcceptedCloudNotice = true
                if let pendingMode { store.setAIMode(pendingMode) }
                pendingMode = nil
            }
        }
    }

    static let freeTierNotice = "Cloud mode sends the text of your notes to Google Gemini. Its free tier may use what you send to improve Google's products, and people at Google may read it."

    // MARK: Model

    private var modelSection: some View {
        SettingsGroup(title: "Model") {
            SettingsRow(showsDivider: false) {
                HStack {
                    Text("Runs on")
                    Spacer()
                    GRASPSegmented(
                        selection: Binding(
                            get: { store.aiMode },
                            set: { mode in
                                if mode.usesCloud && !AIPreferences.hasAcceptedCloudNotice {
                                    pendingMode = mode
                                } else {
                                    store.setAIMode(mode)
                                }
                            }
                        ),
                        options: AIMode.allCases.map { ($0, $0.label) }
                    )
                }
            }
            SettingsRow {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.generatorStatus)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textSecondary)
                    Spacer()
                    Button("Refresh") { Task { await store.refreshGeneratorStatus() } }
                }
                Footnote(modeExplanation)
            }
        }
    }

    private var modeExplanation: String {
        switch store.aiMode {
        case .local:
            return "Everything runs on this Mac: Ollama if it's running, else Apple's on-device model. Nothing leaves your Mac. With no model at all, cards come from the parser only."
        case .cloud:
            return "Everything runs on Google Gemini: much stronger lessons and cards than a local model, and quick. When today's free limit runs out, AI features stop until it resets at midnight Pacific."
        case .automatic:
            return "Gemini when it can, your local model when it can't: if Gemini is busy, offline or out of today's free requests, the job carries on locally from where it was."
        }
    }

    // MARK: Cloud


    private var cloudSection: some View {
        SettingsGroup(title: "Cloud: \(CloudProvider.name)") {
            if store.hasCloudKey {
                SettingsRow(showsDivider: false) {
                    HStack(spacing: 8) {
                        StatusBadge(text: cloudStatusText, tone: cloudTone)
                        Spacer()
                        Button {
                            Task { await store.testCloudConnection() }
                        } label: {
                            if store.isCheckingCloud { ProgressView().controlSize(.small) } else { Text("Test connection") }
                        }
                        .disabled(store.isCheckingCloud)
                        Button("Remove key") { Task { await store.removeCloudKey() } }
                            .buttonStyle(DangerOnHoverButton())
                    }
                }
                if !store.cloudModels.isEmpty {
                    SettingsRow {
                        HStack {
                            Text("Model")
                            Spacer()
                            GRASPPicker(
                                selection: $cloudModel,
                                options: [("", automaticModelLabel)] + store.cloudModels.map { ($0, modelLabel($0)) }
                            )
                            .frame(maxWidth: 260, alignment: .trailing)
                        }
                        .onChange(of: cloudModel) { _, new in store.setCloudModel(new) }
                        if let note = modelSwitchNote {
                            Footnote(note)
                        }
                    }
                }
                SettingsRow {
                    HStack {
                        Text("Gemini plan")
                        Spacer()
                        GRASPPicker(selection: $geminiPlan, options: [("free", "Free"), ("paid", "Paid")])
                            .frame(maxWidth: 260, alignment: .trailing)
                    }
                    Footnote(GeminiPlan.explanation(for: geminiPlan))
                }
                if let detail = cloudErrorDetail {
                    SettingsRow {
                        Label(detail, systemImage: "exclamationmark.triangle.fill")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.rejected)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SettingsRow { usageRow }
            } else {
                if let problem = store.cloudKeyProblem {
                    SettingsRow(showsDivider: false) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.rejected)
                    }
                }
                SettingsRow(showsDivider: store.cloudKeyProblem != nil) {
                    HStack(spacing: 8) {
                        SecureField("Paste your Gemini API key", text: $keyDraft)
                        Button("Save") {
                            let key = keyDraft
                            keyDraft = ""
                            Task { await store.saveCloudKey(key) }
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    LinkText(title: "Get a free key at Google AI Studio", url: CloudProvider.keyPageURL)
                    Footnote("Stored in your Keychain, never in your library or synced to GRASP's server.")
                }
            }
            SettingsRow {
                Label {
                    Text(Self.freeTierNotice)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.graspUI(size: 12))
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
        }
    }

    // The model menu follows what GRASP is actually doing: while the best
    // model is overloaded or out of requests, the one in use is marked and
    // the skipped one says why.
    private var automaticModelLabel: String {
        _ = store.cloudUsageRevision
        let best = store.cloudModels.first ?? CloudProvider.fallbackModel
        if let used = CloudUsage.shared.lastUsedModel, used != best, CloudUsage.shared.skipNote(for: best) != nil {
            return "Automatic (using \(used))"
        }
        return "Automatic (\(best))"
    }

    private func modelLabel(_ model: String) -> String {
        _ = store.cloudUsageRevision
        if let note = CloudUsage.shared.skipNote(for: model) { return "\(model), \(note)" }
        if model == CloudUsage.shared.lastUsedModel { return "\(model), in use" }
        return model
    }

    private var modelSwitchNote: String? {
        _ = store.cloudUsageRevision
        let best = cloudModel.isEmpty ? (store.cloudModels.first ?? CloudProvider.fallbackModel) : cloudModel
        guard let note = CloudUsage.shared.skipNote(for: best) else { return nil }
        if let used = CloudUsage.shared.lastUsedModel, used != best {
            return "Using \(used) because \(best) is \(note). GRASP tries \(best) again later."
        }
        return "\(best) is \(note). GRASP moves down the list when a request needs it."
    }

    /// Why the last cloud request or check didn't go through, in words.
    private var cloudErrorDetail: String? {
        guard let raw = rawCloudErrorDetail else { return nil }
        // A system error's debug description is not for reading.
        if raw.contains("Error Domain=") || raw.contains("UserInfo=") || raw.contains("(code ") {
            return "GRASP couldn't reach Google. Check your connection, then test again."
        }
        return raw
    }

    private var rawCloudErrorDetail: String? {
        _ = store.cloudUsageRevision
        if case .failed(let detail) = store.cloudCheck { return detail }
        if case .offline = store.cloudCheck {
            return CloudUsage.shared.lastTransportError ?? "GRASP couldn't reach Google. Check your connection."
        }
        if case .badKey = store.cloudCheck {
            return "Google didn't accept this key. Remove it and paste a fresh one from Google AI Studio."
        }
        return CloudUsage.shared.lastTransportError
    }

    /// Red is only for a real failure: a check in flight or not yet made
    /// is neutral.
    private var cloudTone: StatusBadge.Tone {
        _ = store.cloudUsageRevision
        if CloudUsage.shared.pausedUntil != nil { return .negative }
        switch store.cloudCheck {
        case .ok: return .positive
        case .badKey, .quotaUsedUp, .offline, .failed: return .negative
        case nil: return .neutral
        }
    }

    private var cloudStatusText: String {
        _ = store.cloudUsageRevision
        if CloudUsage.shared.pausedUntil != nil { return "Free limit reached" }
        switch store.cloudCheck {
        case .ok: return "Connected"
        case .badKey: return "Key not accepted"
        case .quotaUsedUp: return "Free limit reached"
        case .offline: return "Can't reach Google"
        case .failed: return "Check failed"
        case nil: return store.isCheckingCloud ? "Checking…" : "Not checked"
        }
    }

    private var usageRow: some View {
        _ = store.cloudUsageRevision
        let used = CloudUsage.shared.requestsToday
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today")
                Spacer()
                Text("\(used) of about \(CloudProvider.estimatedRequestsPerDay) free requests")
                    .monospacedDigit()
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            ProgressBar(value: min(used, CloudProvider.estimatedRequestsPerDay), total: CloudProvider.estimatedRequestsPerDay,
                        tint: GRASPColor.textPrimary.opacity(0.55), height: 5)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Footnote("An estimate: Google sets each project's own limit, and resets it at midnight Pacific.")
                Spacer(minLength: 0)
                LinkText(title: "See yours", url: CloudProvider.usagePageURL)
            }
            if let last = CloudUsage.shared.lastFallback, store.aiMode == .automatic {
                Footnote("Last switch to local: \(last)")
            }
        }
    }

    // MARK: Local

    private var localSection: some View {
        SettingsGroup(title: "Local: Ollama") {
            SettingsRow(showsDivider: false) { ollamaStatusRow }
            SettingsRow { ollamaDetailText }
            if !store.ollamaStatus.isRunning {
                SettingsRow {
                    Button("Set up local AI…") { showingOllamaSetup = true }
                }
            }
        }
    }

    // MARK: Features

    private var featuresSection: some View {
        @Bindable var store = store
        return SettingsGroup(title: "AI features", systemImage: AIGlyph.symbol) {
            SettingsRow(showsDivider: false) {
                Toggle("Include AI-generated practice questions in tests", isOn: $store.isAITestQuestionsEnabled)
                Footnote("Custom tests mix in a few fresh, written questions grounded in your notes. They're generated each time and never saved as cards or scheduled.")
            }
        }
    }

    private var ollamaStatusRow: some View {
        HStack(spacing: 8) {
            StatusBadge(
                text: store.ollamaStatus.isRunning ? "Ollama running" : "Ollama not detected",
                tone: store.ollamaStatus.isRunning ? .positive : .negative
            )
            Spacer()
            Button {
                Task { await store.refreshOllamaStatus() }
            } label: {
                if store.isCheckingOllama {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(.graspUI(size: 11, weight: .semibold))
                        Text("Check again")
                    }
                }
            }
            .disabled(store.isCheckingOllama)
        }
    }

    @ViewBuilder
    private var ollamaDetailText: some View {
        if store.ollamaStatus.isRunning {
            let models = store.ollamaStatus.models
            if models.isEmpty {
                Footnote("Connected, but no models are pulled yet. Run \"ollama pull qwen3.5:9b\" in Terminal.")
            } else {
                OllamaModelPicker(installed: models)
            }
        } else {
            Footnote("GRASP couldn't reach a local Ollama server on this Mac. Install it, or start it if it's already installed, to enable on-device AI refinement.")
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

/// A capsule for a fact's state. Green for good, coral for a real failure,
/// muted while it is unknown or being checked.
private struct StatusBadge: View {
    enum Tone { case positive, negative, neutral }
    let text: String
    let tone: Tone

    private var tint: Color {
        switch tone {
        case .positive: return GRASPColor.success
        case .negative: return GRASPColor.rejected
        case .neutral: return GRASPColor.textTertiary
        }
    }
    private var soft: Color {
        switch tone {
        case .positive: return GRASPColor.successSoft
        case .negative: return GRASPColor.rejectedSoft
        case .neutral: return GRASPColor.inset
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.graspUI(size: 12, weight: .semibold))
        .foregroundStyle(tone == .neutral ? GRASPColor.textSecondary : tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(soft, in: Capsule())
        .overlay(Capsule().strokeBorder(tone == .neutral ? GRASPColor.hairline : .clear, lineWidth: 1))
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
        GRASPSheet(
            eyebrow: "AI", title: "Set up local AI",
            message: "Ollama runs a small language model on this Mac, so AI features work offline and your notes never leave it.",
            icon: "cpu", width: 440
        ) {
            VStack(alignment: .leading, spacing: 10) {
                setupStep(
                    number: 1, title: "Download and install Ollama",
                    detail: "Opens the official installer page in your browser.",
                    button: "Open download page", icon: "arrow.down.circle"
                ) { OllamaLauncher.openDownloadPage() }
                setupStep(
                    number: 2, title: "Start the Ollama service",
                    detail: "Already installed? This launches it in the background and re-checks the connection.",
                    button: "Start Ollama", icon: "play.circle"
                ) {
                    onStartService()
                    dismiss()
                }
            }
        } footer: {
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func setupStep(number: Int, title: String, detail: String, button: String, icon: String,
                           action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: GRASPSpace.m) {
            Text("\(number)")
                .font(.graspDisplay(16))
                .foregroundStyle(GRASPColor.ink)
                .frame(width: 26, height: 26)
                .background(GRASPColor.brand, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.graspUI(size: 14, weight: .semibold)).foregroundStyle(GRASPColor.textPrimary)
                Text(detail).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.graspUI(size: 11, weight: .semibold))
                        Text(button)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .popupGroup(padding: 14)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model")
                Spacer()
                GRASPPicker(
                    selection: $chosen,
                    options: [("", automaticName.map { "Automatic (\($0))" } ?? "Automatic")]
                        + installed.map { ($0, $0) }
                )
                .frame(maxWidth: 260, alignment: .trailing)
            }
            if !chosen.isEmpty, !installed.contains(chosen) {
                Footnote("\(chosen) isn't installed any more, so GRASP is using \(automaticName ?? "another model").")
            } else {
                Footnote("Used for lessons, card refinement and AI test questions. Larger models write better lessons but take longer.")
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
    private let minimumLength = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("New password")
            HStack(spacing: 8) {
                SecureField("New password", text: $password)
                Button("Set password") { save() }
                    .disabled(working || password.count < minimumLength)
            }
            Footnote("At least \(minimumLength) characters.")
            if let result {
                Text(result)
                    .graspType(.meta)
                    .foregroundStyle(failed ? GRASPColor.rejected : GRASPColor.textSecondary)
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
                result = PlainError.message(error, couldnt: "set the password")
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
        Group {
            if let account = sync.account {
                SettingsGroup(title: "Sync") {
                    SettingsRow(showsDivider: false) {
                        HStack {
                            Text("Signed in as")
                            Spacer()
                            Text(account.email ?? "Your account").foregroundStyle(GRASPColor.textSecondary)
                        }
                    }
                    SettingsRow {
                        HStack {
                            statusText(sync)
                            Spacer()
                            Button("Sync now") { sync.syncNow() }
                                .disabled(sync.state == .syncing || sync.state == .signedOut)
                        }
                        if sync.state == .signedOut {
                            Footnote("This Mac's sign-in has expired. Sign in again to keep syncing. Nothing here is lost.")
                            SignInButtons { signedIn in sync.resume(signedIn) }
                        }
                    }
                }
                if account.provider == "google" {
                    SettingsGroup(title: "Password for other devices") {
                        SettingsRow(showsDivider: false) {
                            PasswordForOtherDevices(userId: account.userId)
                        }
                    }
                    Footnote("GRASP on Windows signs in with email and password. Set a password here, then sign in there with this account's email.")
                        .padding(.horizontal, 4)
                        .padding(.top, -10)
                }
                HStack {
                    Spacer()
                    Button("Sign out…") { confirmingSignOut = true }
                        .buttonStyle(DangerOnHoverButton())
                }
            } else {
                SettingsGroup(title: "Sync") {
                    SettingsRow(showsDivider: false) {
                        Footnote("This profile's library is only on this Mac. Sign in to sync it with your other devices. It's uploaded to your account, and anything you sign in to later gets a copy.")
                        SignInButtons { signedIn in link(signedIn) }
                        if let linkError {
                            Text(linkError).graspType(.meta).foregroundStyle(GRASPColor.rejected)
                        }
                    }
                }
            }
        }
        // An emailed sign-in link opened while this section asked for it.
        .onChange(of: AccountService.shared.completedFromLink) { _, _ in
            guard let signedIn = AccountService.shared.consumeCompletedFromLink() else { return }
            if sync.account == nil { link(signedIn) } else { sync.resume(signedIn) }
        }
        .sheet(isPresented: $confirmingSignOut) {
            ConfirmationSheet(
                icon: "rectangle.portrait.and.arrow.right", title: "Sign out of sync?",
                message: "Your library stays on this Mac as a local profile. It stops syncing, and your other devices keep their own copies.",
                confirmTitle: "Sign out"
            ) { Task { await sync.signOut() } }
        }
        .sheet(isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } })) {
            ConfirmationSheet(
                icon: "arrow.triangle.merge", title: "Your account already has a library",
                message: "This profile's library will be added to the one already in your account. If both came from the same notes you'll get duplicate cards. To use your account's library on this Mac instead, switch profile and sign in from there.",
                confirmTitle: "Combine them", isDestructive: false
            ) {
                if let pendingLink { finishLink(pendingLink) }
            }
        }
    }

    @ViewBuilder
    private func statusText(_ sync: SyncController) -> some View {
        switch sync.state {
        case .syncing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…").foregroundStyle(GRASPColor.textSecondary) }
        case .failed(let message):
            Text(message).foregroundStyle(GRASPColor.rejected).graspType(.meta)
        case .notConfigured:
            Footnote("Sign-in isn't set up in this copy of GRASP.")
        default:
            if let last = sync.lastSyncedAt {
                Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(GRASPColor.textSecondary)
            } else {
                Text("Not synced yet").foregroundStyle(GRASPColor.textSecondary)
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
            linkError = PlainError.message(error, couldnt: "turn on sync")
        }
    }
}
