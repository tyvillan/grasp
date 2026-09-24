import SwiftUI
import GRASPCore

/// Read-only view of the source note behind a card -- the reflowed text,
/// since that's what the parser actually saw, with the original preserved
/// underneath for when the reflow looks suspicious.
struct NoteViewerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let materialId: String
    @State private var material: GRASPCore.Material?
    @State private var noteText: NoteText?
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(material?.title ?? "Note").font(.headline)
                Spacer()
                Toggle("Raw", isOn: $showRaw).toggleStyle(.button)
                Button("Close") { dismiss() }
            }
            ScrollView {
                Text((showRaw ? noteText?.raw : noteText?.reflowed) ?? "")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let path = material?.relativePath {
                Text(path)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(20)
        .macSheetFrame(width: 560, height: 480)
        .task(id: materialId) {
            material = try? store.material(materialId)
            noteText = try? store.noteText(forMaterial: materialId)
        }
    }
}
