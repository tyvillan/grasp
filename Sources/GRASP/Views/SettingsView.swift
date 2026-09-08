import SwiftUI
import AppKit
import GRASPCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.switchProfile) private var switchProfile

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
            Section("Vault") {
                TextField("Vault path", text: $store.vaultPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseVault() }
                Text("GRASP only reads from this folder -- it never writes to your Obsidian vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .padding(20)
        .frame(width: 460)
        .task { await store.refreshGeneratorStatus() }
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
