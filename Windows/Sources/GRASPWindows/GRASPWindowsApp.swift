import DefaultBackend
import Foundation
import GRASPCore
import SwiftCrossUI

@main
struct GRASPWindowsApp: App {
    @State var opened = Result { try Library() }

    var body: some Scene {
        WindowGroup("GRASP") {
            switch opened {
            case .success(let library):
                ContentView(library: library)
            case .failure(let error):
                VStack(spacing: 8) {
                    Text("GRASP couldn't open your library").font(.title2)
                    Text(String(describing: error))
                }
                .padding(24)
            }
        }
        .defaultSize(width: 1040, height: 700)
    }
}

struct ContentView: View {
    let library: Library
    @State var selectedDeckId: String?
    @Environment(\.chooseFile) var chooseFile

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Decks").font(.headline)
                if library.decks.isEmpty {
                    Text("No decks yet. Import a notes folder, or try the sample notes.")
                        .foregroundColor(.gray)
                } else {
                    List(library.decks, selection: $selectedDeckId) { deck in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deck.name)
                            Text(deckSubtitle(deck)).font(.caption).foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Spacer()
                Button("Import notes folder…") {
                    Task {
                        guard let folder = await chooseFile(
                            title: "Choose your notes folder",
                            defaultButtonLabel: "Import",
                            allowSelectingFiles: false,
                            allowSelectingDirectories: true
                        ) else { return }
                        await library.importVault(at: folder)
                    }
                }
                .disabled(library.isImporting)
                Button("Try sample notes") {
                    Task { await library.importSample() }
                }
                .disabled(library.isImporting)
                if library.isImporting {
                    ProgressView("Importing…")
                } else if let status = library.status {
                    Text(status).font(.caption)
                }
                AccountPanel(account: library.account)
            }
            .padding(12)
            .frame(minWidth: 240)
        } detail: {
            // Nothing picked yet: show the first deck rather than a blank pane.
            if let deck = library.decks.first(where: { $0.id == selectedDeckId }) ?? library.decks.first {
                DeckView(library: library, deck: deck)
            } else {
                VStack(spacing: 8) {
                    Text("GRASP").font(.largeTitle)
                    Text("Pick a deck to study it.").foregroundColor(.gray)
                }
                .padding(24)
            }
        }
    }

    private func deckSubtitle(_ deck: DeckRow) -> String {
        var parts = [deck.courseName, "\(deck.total) cards"]
        if deck.due > 0 { parts.append("\(deck.due) due") }
        if deck.drafts > 0 { parts.append("\(deck.drafts) drafts") }
        return parts.joined(separator: " · ")
    }
}

/// A deck: approve its drafts, study what's due, and see the row
/// reduction from its notes.
struct DeckView: View {
    let library: Library
    let deck: DeckRow
    @State var session: [Card]? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deck.courseName.uppercased()).font(.caption).foregroundColor(.gray)
                    Text(deck.name).font(.title)
                }

                if let cards = session {
                    StudySessionView(library: library, cards: cards) { session = nil }
                } else {
                    HStack(spacing: 10) {
                        Button(deck.due == 0 ? "Nothing due" : "Study \(deck.due) due") {
                            session = library.dueCards(inDeck: deck.id)
                        }
                        .disabled(deck.due == 0)
                        if deck.drafts > 0 {
                            Button("Approve \(deck.drafts) drafts") {
                                library.approveDrafts(inDeck: deck.id)
                            }
                        }
                    }
                    if deck.drafts > 0 && deck.due == 0 {
                        Text("New cards start as drafts. Approve them to study them.")
                            .foregroundColor(.gray)
                    }
                }

                if let reduction = library.rowReduction(inDeck: deck.id) {
                    RowReductionView(reduction: reduction)
                }
            }
            .padding(24)
        }
    }
}
