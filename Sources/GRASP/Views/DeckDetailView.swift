import SwiftUI
import GRASPCore

/// The card review queue for one deck: every parsed pair lands here as a
/// draft, and nothing enters study until approved -- with a deterministic
/// parser (and later a small local model) that gate is not optional, since
/// roughly a third of parser output needs a human glance or a quick edit.
struct DeckDetailView: View {
    @Environment(AppStore.self) private var store
    let deckId: String
    @State private var cards: [Card] = []
    @State private var editingCard: Card?
    @State private var viewingMaterialId: String?
    @State private var pendingDeleteCard: Card?
    @State private var deckName = "Deck"
    @State private var isStudying = false
    @State private var isLearning = false
    @State private var testPhase: TestPhase?
    @State private var isGeneratorAvailable = false
    @State private var isRefining = false

    private var draftCount: Int { cards.filter { $0.status == .draft }.count }
    private var activeCount: Int { cards.filter { $0.status == .active }.count }
    private var dueCount: Int { (try? store.dueCards(inDeck: deckId).count) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if dueCount > 0 {
                    Text("\(dueCount) due").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isLearning = true
                } label: {
                    Label("Learn", systemImage: "graduationcap.fill")
                }
                .disabled(activeCount == 0)
                Button {
                    isStudying = true
                } label: {
                    Label("Study", systemImage: "rectangle.stack.fill")
                }
                .disabled(dueCount == 0)
                Button {
                    testPhase = .setup
                } label: {
                    Label("Test", systemImage: "checklist")
                }
                .disabled(activeCount == 0)
            }
            .font(.callout)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.thinMaterial)
            if draftCount > 0 {
                HStack {
                    Text("\(draftCount) card\(draftCount == 1 ? "" : "s") awaiting review")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isGeneratorAvailable {
                        Button {
                            Task {
                                isRefining = true
                                _ = await store.refineDraftCards(inDeck: deckId)
                                isRefining = false
                                load()
                            }
                        } label: {
                            if isRefining {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Refine with AI")
                            }
                        }
                        .disabled(isRefining)
                    }
                    Button("Approve All") {
                        try? store.approveAllDrafts(inDeck: deckId)
                        load()
                    }
                }
                .font(.callout)
                .padding(.horizontal).padding(.vertical, 8)
                .background(.thinMaterial)
            }
            List {
                ForEach(cards) { card in
                    CardRow(
                        card: card,
                        onApprove: { setStatus(card, .active) },
                        onSuspend: { setStatus(card, card.status == .suspended ? .active : .suspended) },
                        onEdit: { editingCard = card },
                        onViewNote: { viewingMaterialId = card.materialId },
                        onDelete: { pendingDeleteCard = card }
                    )
                }
            }
        }
        .navigationTitle(deckName)
        .task(id: deckId) {
            deckName = ((try? store.deck(deckId)) ?? nil)?.name ?? "Deck"
            load()
        }
        .task {
            await store.refreshGeneratorStatus()
            isGeneratorAvailable = store.isGeneratorAvailable
        }
        .sheet(isPresented: $isStudying, onDismiss: load) {
            FlashcardStudyView(deckId: deckId, deckName: deckName)
        }
        .sheet(isPresented: $isLearning, onDismiss: load) {
            LearnRoundView(deckId: deckId, deckName: deckName)
        }
        .sheet(item: $testPhase, onDismiss: load) { phase in
            switch phase {
            case .setup:
                TestSetupSheet(deckId: deckId, deckName: deckName) { attemptId, questions in
                    testPhase = .running(attemptId: attemptId, questions: questions)
                }
            case .running(let attemptId, let questions):
                TestRunView(attemptId: attemptId, deckName: deckName, questions: questions) {
                    let result = (try? store.finishTest(attemptId: attemptId)) ?? (0, questions.count)
                    testPhase = .results(correct: result.correct, total: result.total, questions: questions)
                }
            case .results(let correct, let total, let questions):
                TestResultsView(deckName: deckName, correct: correct, total: total, questions: questions)
            }
        }
        .sheet(item: $editingCard) { card in
            CardEditSheet(card: card) { updated in
                try? store.updateCard(updated)
                load()
            }
        }
        .sheet(item: Binding(
            get: { viewingMaterialId.map { MaterialIdentifier(id: $0) } },
            set: { viewingMaterialId = $0?.id }
        )) { wrapped in
            NoteViewerView(materialId: wrapped.id)
        }
        .alert(
            "Delete this card?",
            isPresented: Binding(
                get: { pendingDeleteCard != nil },
                set: { if !$0 { pendingDeleteCard = nil } }
            ),
            presenting: pendingDeleteCard
        ) { card in
            Button("Delete", role: .destructive) {
                try? store.deleteCard(card.id)
                load()
            }
            Button("Cancel", role: .cancel) {}
        } message: { card in
            Text(card.front)
        }
    }

    private func load() {
        cards = (try? store.cards(inDeck: deckId)) ?? []
    }

    private func setStatus(_ card: Card, _ status: CardStatus) {
        try? store.setCardStatus(card.id, status: status)
        load()
    }
}

private struct MaterialIdentifier: Identifiable { let id: String }

private struct CardRow: View {
    let card: Card
    let onApprove: () -> Void
    let onSuspend: () -> Void
    let onEdit: () -> Void
    let onViewNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.front).font(.body.weight(.medium))
                Text(card.back).font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
            Menu {
                if card.status == .draft {
                    Button("Approve", action: onApprove)
                }
                Button(card.status == .suspended ? "Reactivate" : "Suspend", action: onSuspend)
                Button("Edit", action: onEdit)
                if card.materialId != nil {
                    Button("View Source Note", action: onViewNote)
                }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if card.status == .draft { Button("Approve", action: onApprove) }
            Button(card.status == .suspended ? "Reactivate" : "Suspend", action: onSuspend)
            Button("Edit", action: onEdit)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch card.status {
        case .draft:
            Label("Draft", systemImage: "circle.dashed").labelStyle(.iconOnly).foregroundStyle(.orange)
        case .suspended:
            Label("Suspended", systemImage: "pause.circle").labelStyle(.iconOnly).foregroundStyle(.secondary)
        case .active:
            EmptyView()
        }
    }
}

private struct CardEditSheet: View {
    @State var card: Card
    let onSave: (Card) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Card").font(.headline)
            Text("Front").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $card.front).frame(height: 60).border(.separator)
            Text("Back").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $card.back).frame(height: 100).border(.separator)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var saved = card
                    saved.origin = .manual
                    saved.updatedAt = Date()
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
