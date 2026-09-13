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

    var body: some View {
        Form {
            Section("Profile") {
                HStack {
                    Text(store.profile.name)
                    Spacer()
                    Button("Switch Profile…") { switchProfile() }
                }
            }

            Section("Card Generation") {
                HStack {
                    Text(store.generatorStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await store.refreshGeneratorStatus() } }
                        .font(.caption)
                }
                Text("With no local model, cards come from the deterministic parser only -- fully usable, just more editing in the review queue. Install Ollama and pull a model (e.g. qwen2.5:7b-instruct) to enable AI refinement.")
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
                Text("Connected, but no models are pulled yet -- run \"ollama pull qwen2.5:7b-instruct\" in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(models.count) model\(models.count == 1 ? "" : "s") installed: \(models.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
        .sheet(isPresented: $showingExcludedFolders) { ExcludedFoldersSheet() }
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
