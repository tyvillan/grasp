import SwiftUI
import GRASPCore

/// "Write cards from files": tick the course files the AI should read,
/// instead of all of them.
struct ChooseSourceFilesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let courseId: String
    let deckName: String
    let onChoose: (Set<String>) -> Void

    @State private var materials: [GRASPCore.Material] = []
    @State private var selected: Set<String> = []
    @State private var query = ""

    private var filtered: [GRASPCore.Material] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return materials }
        return materials.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        GRASPSheet(
            eyebrow: "Generate cards", title: "Choose files",
            message: "The AI reads only the files you tick and writes draft cards into \(deckName).",
            icon: AIGlyph.symbol, width: 540
        ) {
            VStack(alignment: .leading, spacing: GRASPSpace.m) {
                if materials.count > 6 {
                    FieldChrome {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.graspUI(size: 12))
                                .foregroundStyle(GRASPColor.textTertiary)
                            TextField("Filter by name", text: $query)
                        }
                    }
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, material in
                            if index > 0 { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                            Toggle(isOn: Binding(
                                get: { selected.contains(material.id) },
                                set: { on in if on { selected.insert(material.id) } else { selected.remove(material.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(material.title).graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                                        .lineLimit(1)
                                    if let date = material.noteDate {
                                        Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                                            .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, GRASPSpace.m)
                }
                .frame(height: 300)
                .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous)
                    .strokeBorder(GRASPColor.hairline, lineWidth: 1))
                .overlay {
                    if materials.isEmpty {
                        Text("This course has no files yet.").graspType(.body).foregroundStyle(GRASPColor.textTertiary)
                    }
                }
            }
        } footer: {
            Text(selected.isEmpty ? "Nothing ticked" : "\(selected.count) file\(selected.count == 1 ? "" : "s")")
                .graspType(.meta).monospacedDigit().foregroundStyle(GRASPColor.textTertiary)
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                onChoose(selected)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: AIGlyph.symbol).font(.graspUI(size: 11, weight: .semibold))
                    Text("Write cards")
                }
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
        .task { materials = store.courseMaterials(inCourse: courseId) }
    }
}
