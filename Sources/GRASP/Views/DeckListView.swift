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
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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

/// Card count is set in tabular digits and right-aligned in a fixed slot,
/// so the column of numbers down the list lines up instead of wandering
/// with each deck's name length.
private struct DeckRow: View {
    let name: String
    let cardCount: Int
    let dueCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .graspType(.rowTitle)
                .lineLimit(1)
            Spacer(minLength: 4)
            if dueCount > 0 {
                Text("\(dueCount)")
                    .font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .foregroundStyle(GRASPColor.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(GRASPColor.accentSoft, in: Capsule())
            }
            Text("\(cardCount)")
                .graspType(.meta)
                .monospacedDigit()
                .foregroundStyle(GRASPColor.textTertiary)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
