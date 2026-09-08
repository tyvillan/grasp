import SwiftUI
import GRASPCore

/// Full-text search across every imported note, not just the currently
/// selected course -- backed by the `noteFTS` table populated at import
/// time. Opening a result shows the same note viewer a card's "View
/// Source Note" action uses.
struct SearchView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var results: [AppStore.SearchResult] = []
    @State private var viewingMaterialId: String?

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search your notes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding()
                .onChange(of: query) { runSearch() }
            Divider()
            List(results) { result in
                Button {
                    viewingMaterialId = result.materialId
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).font(.body.weight(.medium))
                        Text(result.snippet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .sheet(item: Binding(
            get: { viewingMaterialId.map { MaterialIdentifier(id: $0) } },
            set: { viewingMaterialId = $0?.id }
        )) { wrapped in
            NoteViewerView(materialId: wrapped.id)
        }
    }

    private func runSearch() {
        results = (try? store.searchNotes(query: query)) ?? []
    }
}

private struct MaterialIdentifier: Identifiable { let id: String }
