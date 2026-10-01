import SwiftUI
import GRASPCore

/// Which model runs, the Gemini key, and the AI-only features -- the iPhone's
/// counterpart to the Mac's Settings → AI. "Local" here is Apple's
/// on-device model; there's no Ollama on a phone.
struct AISettingsScreen: View {
    @Environment(AppStore.self) private var store
    @State private var keyDraft = ""
    @State private var pendingMode: AIMode?
    @AppStorage(AIPreferences.cloudModelKey, store: .standard) private var cloudModel = ""

    static let freeTierNotice = "Cloud mode sends the text of your notes to Google Gemini. Its free tier may use what you send to improve Google's products, and people at Google may read it."

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
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
                LabeledContent("Using", value: store.generatorStatus)
            } header: {
                Text("Model")
            } footer: {
                Text(modeExplanation)
            }
            .graspSection()

            Section {
                if store.hasCloudKey {
                    LabeledContent("Status") {
                        if store.isCheckingCloud { ProgressView() } else { Text(cloudStatusText) }
                    }
                    Button("Test Connection") { Task { await store.testCloudConnection() } }
                        .disabled(store.isCheckingCloud)
                    if !store.cloudModels.isEmpty {
                        Picker("Model", selection: $cloudModel) {
                            Text("Automatic (\(store.cloudModels.first ?? CloudProvider.fallbackModel))").tag("")
                            ForEach(store.cloudModels, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: cloudModel) { _, new in store.setCloudModel(new) }
                    }
                    LabeledContent("Today", value: usageText)
                    Button("Remove Key", role: .destructive) { Task { await store.removeCloudKey() } }
                } else {
                    SecureField("Paste your Gemini API key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Key") {
                        let key = keyDraft
                        keyDraft = ""
                        Task { await store.saveCloudKey(key) }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a free key at Google AI Studio", destination: CloudProvider.keyPageURL)
                }
            } header: {
                Text("Cloud: \(CloudProvider.name)")
            } footer: {
                Text(Self.freeTierNotice + " The key is kept in your Keychain"
                     + (store.hasCloudKey ? "." : "; one saved on your Mac with iCloud Keychain shows up here on its own."))
            }
            .graspSection()

            Section {
                Toggle("AI questions in tests", isOn: $store.isAITestQuestionsEnabled)
            } header: {
                Text("AI Features")
            } footer: {
                Text("Tests mix in a few fresh written questions grounded in your notes. They're never saved as cards.")
            }
            .graspSection()
        }
        .graspList()
        .navigationTitle("AI")
        .task {
            if AIKeyStore.read() != nil { await store.testCloudConnection() }
            await store.refreshGeneratorStatus()
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
    }

    private var modeExplanation: String {
        switch store.aiMode {
        case .local:
            return store.isGeneratorAvailable
                ? "Everything runs on Apple's on-device model -- nothing leaves your iPhone."
                : "Local AI needs Apple Intelligence (iPhone 15 Pro or later, turned on in Settings). Overviews written on your Mac still sync here."
        case .cloud:
            return "Everything runs on Google Gemini: much stronger overviews and cards than the on-device model. When today's free limit runs out, AI features stop until midnight Pacific."
        case .automatic:
            return "Gemini when it can, Apple's on-device model when it can't -- busy, offline, or out of today's free requests."
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
        case nil: return "Not checked"
        }
    }

    private var usageText: String {
        _ = store.cloudUsageRevision
        return "\(CloudUsage.shared.requestsToday) of ~\(CloudProvider.estimatedRequestsPerDay) requests"
    }
}
