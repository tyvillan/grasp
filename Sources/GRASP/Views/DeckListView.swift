import SwiftUI
import GRASPCore

/// Decks for one course, chapter-ordered where a chapter exists (auto decks
/// carry `sortIndex` derived from that), else alphabetical.
struct DeckListView: View {
    @Environment(AppStore.self) private var store
    let courseId: String
    @Binding var selectedDeckId: String?
    @State private var decks: [Deck] = []
    @State private var showingExams = false

    var body: some View {
        List(selection: $selectedDeckId) {
            ForEach(decks) { deck in
                let counts = store.deckCounts[deck.id] ?? (0, 0)
                DeckRow(name: deck.name, cardCount: counts.cardCount, dueCount: counts.dueCount)
                    .tag(deck.id)
            }
        }
        .overlay {
            if decks.isEmpty {
                ContentUnavailableView(
                    "No decks yet",
                    systemImage: "tray",
                    description: Text("Import the vault to generate decks from this course's notes.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingExams = true
                } label: {
                    Label("Exams", systemImage: "calendar")
                }
            }
        }
        .sheet(isPresented: $showingExams) {
            ExamsSheet(courseId: courseId)
        }
        .task(id: courseId) { load() }
        .onChange(of: store.deckCounts.count) { load() }
    }

    private func load() {
        decks = (try? store.decks(inCourse: courseId)) ?? []
    }
}

private struct DeckRow: View {
    let name: String
    let cardCount: Int
    let dueCount: Int

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            if dueCount > 0 {
                Text("\(dueCount)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
            Text("\(cardCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
