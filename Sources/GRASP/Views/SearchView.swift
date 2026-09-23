import SwiftUI
import GRASPCore

/// Full-text search across every imported note, not just the currently
/// selected course -- backed by the `noteFTS` table populated at import
/// time. Opening a result shows the same note viewer a card's "View
/// Source Note" action uses.
struct SearchView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isQueryFocused: Bool
    @State private var query = ""
    @State private var results: [AppStore.SearchResult] = []
    @State private var viewingMaterialId: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(GRASPColor.textTertiary)
                    TextField("Search your notes", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isQueryFocused)
                        .onChange(of: query) { runSearch() }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            results = []
                            isQueryFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(GRASPColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                // A visible way out of the search sheet that doesn't
                // require reaching for Escape every time.
                Button("Cancel") { dismiss() }
                    .buttonStyle(GRASPQuietButton())
            }
            .padding()
            Divider()
            List(results) { result in
                Button {
                    viewingMaterialId = result.materialId
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(highlighted(result.title, terms: searchTerms))
                            .font(.body.weight(.medium))
                        Text(highlightedSnippet(result.snippet))
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
        .onAppear { isQueryFocused = true }
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

    /// The raw words behind the FTS query (lowercased, no trailing `*`),
    /// used to highlight matches in `result.title` -- unlike the snippet,
    /// the title comes straight from `material.title`, not through
    /// SQLite's `snippet()`, so it carries no `**...**` markers of its own.
    private var searchTerms: [String] {
        query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    /// `snippet(noteFTS, ...)` wraps each match in the control characters
    /// U+0002 and U+0003 (see `AppStore.searchNotes`). They used to be
    /// `**`, which a third of the notes use for their own bold text -- a
    /// note's markers threw the alternation off and lit up non-matches.
    private func highlightedSnippet(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var isMatch = false
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            var piece = AttributedString(current.replacingOccurrences(of: "**", with: ""))
            if isMatch {
                piece.foregroundColor = GRASPColor.textPrimary
                piece.backgroundColor = GRASPColor.accentSoft
                piece.font = .callout.weight(.semibold)
            }
            result += piece
            current = ""
        }
        for character in snippet {
            switch character {
            case "\u{2}": flush(); isMatch = true
            case "\u{3}": flush(); isMatch = false
            default: current.append(character)
            }
        }
        flush()
        return result
    }

    /// Highlights every case-insensitive occurrence of each search term in
    /// `text`. Falls back to plain text if `text` and its lowercased form
    /// don't line up character-for-character (a rare Unicode case-folding
    /// edge case) rather than risk highlighting the wrong span.
    private func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        guard !terms.isEmpty else { return attributed }
        let lowered = text.lowercased()
        guard lowered.count == text.count else { return attributed }

        for term in terms where !term.isEmpty {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let matchRange = lowered.range(of: term, range: searchRange) {
                let start = lowered.distance(from: lowered.startIndex, to: matchRange.lowerBound)
                let length = lowered.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
                if let attrStart = attributed.characters.index(
                    attributed.characters.startIndex, offsetBy: start, limitedBy: attributed.characters.endIndex
                ), let attrEnd = attributed.characters.index(
                    attrStart, offsetBy: length, limitedBy: attributed.characters.endIndex
                ) {
                    attributed[attrStart..<attrEnd].foregroundColor = GRASPColor.textPrimary
                    attributed[attrStart..<attrEnd].backgroundColor = GRASPColor.accentSoft
                }
                searchRange = matchRange.upperBound..<lowered.endIndex
            }
        }
        return attributed
    }
}

private struct MaterialIdentifier: Identifiable { let id: String }
