import SwiftUI
import AppKit
import GRASPCore

/// Decks for one course, chapter-ordered where a chapter exists (auto decks
/// carry `sortIndex` derived from that), else alphabetical.
struct DeckListView: View {
    @Environment(AppStore.self) private var store
    let courseId: String
    @Binding var selectedDeckId: String?
    @State private var decks: [Deck] = []
    @State private var showingExams = false
    @State private var importResult: ImportResultMessage?

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
                ContentUnavailableView {
                    Label("No decks yet", systemImage: "tray")
                } description: {
                    Text("Import the vault, or add files or a folder directly to this course.")
                } actions: {
                    Button("Add Files or Folder…") { chooseAndImport() }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chooseAndImport()
                } label: {
                    if store.isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Add Files", systemImage: "doc.badge.plus")
                    }
                }
                .disabled(store.isImporting)
                .help("Add specific files or a whole folder to this course, from anywhere on disk")
            }
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
        .alert(
            importResult?.title ?? "Import complete",
            isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } }),
            presenting: importResult
        ) { _ in
            Button("OK") {}
        } message: { result in
            Text(result.body)
        }
        .task(id: courseId) { load() }
        .onChange(of: store.deckCounts.count) { load() }
    }

    private func load() {
        decks = (try? store.decks(inCourse: courseId)) ?? []
    }

    /// A native open panel with both files and folders enabled in one
    /// picker -- exactly "a folder or any specific files" in a single
    /// selection, rather than two separate flows for the two cases.
    private func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or a folder to add to this course"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task {
            let summary = await store.importFiles(urls, intoCourse: courseId)
            importResult = ImportResultMessage(summary: summary)
        }
    }
}

/// Summarizes an `ImportSummary` for the one-shot alert this view shows
/// after a manual add -- the toolbar's vault-wide Import button instead
/// leaves its summary sitting quietly in a tooltip, but a manual pick of a
/// handful of files needs an immediate "did that work" answer.
private struct ImportResultMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String

    init(summary: ImportSummary) {
        if let error = summary.errors.first {
            title = "Import failed"
            body = error
            return
        }
        if summary.filesScanned == 0 {
            title = "Nothing to import"
            body = "No supported files were found. GRASP reads Markdown, PDF, Word (.docx), and Jupyter (.ipynb) files."
            return
        }
        title = "Import complete"
        var parts: [String] = []
        parts.append("\(summary.filesImportedOrUpdated) file\(summary.filesImportedOrUpdated == 1 ? "" : "s") added")
        if summary.cardsCreated > 0 {
            parts.append("\(summary.cardsCreated) draft card\(summary.cardsCreated == 1 ? "" : "s") created")
        }
        if summary.filesUnchanged > 0 {
            parts.append("\(summary.filesUnchanged) already up to date")
        }
        body = parts.joined(separator: " · ")
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
