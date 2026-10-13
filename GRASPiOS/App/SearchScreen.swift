import SwiftUI
import GRASPCore

/// Full-text search across every note's text -- the same index as the Mac.
struct SearchScreen: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var results: [AppStore.SearchResult] = []

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("Search your notes", systemImage: "magnifyingglass",
                                       description: Text("Find any word or phrase across every lecture you've imported."))
                    .listRowBackground(Color.clear)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
            ForEach(results) { result in
                NavigationLink {
                    NoteScreen(materialId: result.materialId)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary)
                        Text(snippet(result.snippet))
                            .graspType(.meta).foregroundStyle(GRASPColor.textSecondary).lineLimit(3)
                    }
                }
                .graspSection()
            }
        }
        .graspList()
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        // The system keeps a title small and centred over a list that never
        // scrolls, so the title and the field are drawn here, like the other
        // tabs' large titles.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Search")
                    .font(.graspDisplay(34))
                    .tracking(-0.7)
                    .foregroundStyle(GRASPColor.textPrimary)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.graspUI(size: 14))
                        .foregroundStyle(GRASPColor.textTertiary)
                    TextField("Words in your notes", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .font(.graspBody)
                        .foregroundStyle(GRASPColor.textPrimary)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(GRASPColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(GRASPColor.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(GRASPColor.hairline, lineWidth: 1))
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(GRASPColor.canvas)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: query) { _, newValue in
            results = (try? store.searchNotes(query: newValue)) ?? []
        }
    }

    /// The match markers from the index, as bold.
    private func snippet(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            var piece = AttributedString(current)
            if bold {
                piece.font = .caption.weight(.semibold)
                piece.foregroundColor = GRASPColor.accent
            }
            result += piece
            current = ""
        }
        for character in raw {
            switch character {
            case "\u{2}": flush(); bold = true
            case "\u{3}": flush(); bold = false
            default: current.append(character)
            }
        }
        flush()
        return result
    }
}

/// A new hand-typed card in a deck.
struct CardCreator: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckChoices: [Deck]
    @State var deckId: String?
    @State private var front = ""
    @State private var back = ""

    var body: some View {
        NavigationStack {
            Form {
                if deckChoices.count > 1 {
                    Section {
                        Picker("Deck", selection: $deckId) {
                            ForEach(deckChoices) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    .graspSection()
                }
                Section("Front") { TextField("Term or question", text: $front, axis: .vertical) }
                    .graspSection()
                Section("Back") { TextField("Definition or answer", text: $back, axis: .vertical).lineLimit(3...12) }
                    .graspSection()
            }
            .graspList()
            .navigationTitle("New Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let deckId {
                            _ = try? store.createManualCard(
                                front: front.trimmingCharacters(in: .whitespacesAndNewlines),
                                back: back.trimmingCharacters(in: .whitespacesAndNewlines),
                                deckId: deckId
                            )
                        }
                        dismiss()
                    }
                    .disabled(deckId == nil || front.trimmingCharacters(in: .whitespaces).isEmpty
                              || back.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
