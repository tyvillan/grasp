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
    @State private var learnLevels: [String: LearnEngine.Level] = [:]
    @State private var masteryFilter: MasteryFilter = .all

    private enum MasteryFilter: String, CaseIterable, Identifiable {
        case all = "All", needsReview = "Needs Review", understood = "Understood"
        var id: String { rawValue }
    }

    private var draftCount: Int { cards.filter { $0.status == .draft }.count }
    private var activeCount: Int { cards.filter { $0.status == .active }.count }
    private var dueCount: Int { (try? store.dueCards(inDeck: deckId).count) ?? 0 }

    private var visibleCards: [Card] {
        guard masteryFilter != .all else { return cards }
        return cards.filter { card in
            guard card.status == .active else { return false }
            let isUnderstood = learnLevels[card.id] == .mastered
            return masteryFilter == .understood ? isUnderstood : !isUnderstood
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            deckHeader
            if draftCount > 0 { draftNotice }
            if activeCount > 0 {
                Picker("", selection: $masteryFilter) {
                    ForEach(MasteryFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 300, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            List {
                ForEach(visibleCards) { card in
                    CardRow(
                        card: card,
                        mastery: learnLevels[card.id] ?? .new,
                        onApprove: { setStatus(card, .active) },
                        onSuspend: { setStatus(card, card.status == .suspended ? .active : .suspended) },
                        onEdit: { editingCard = card },
                        onViewNote: { viewingMaterialId = card.materialId },
                        onDelete: { pendingDeleteCard = card }
                    )
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .background(GRASPColor.canvas)
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

    /// Deck name, its one-line composition, and the three study modes.
    /// Study is the prominent action whenever anything is actually due --
    /// the others stay quiet, so the header states what to do next rather
    /// than presenting three equal-weight buttons and leaving the choice
    /// entirely open every time the deck is opened.
    private var deckHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(deckName)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(2)
                compositionLine
            }

            // Order is fixed; only which button is prominent changes with
            // state, so the controls never move under the pointer.
            HStack(spacing: 8) {
                modeButton("Study", "rectangle.stack.fill", prominent: dueCount > 0) { isStudying = true }
                    .disabled(dueCount == 0)
                modeButton("Learn", "graduationcap.fill", prominent: dueCount == 0 && activeCount > 0) {
                    isLearning = true
                }
                .disabled(activeCount == 0)
                modeButton("Test", "checklist", prominent: false) { testPhase = .setup }
                    .disabled(activeCount == 0)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
        }
    }

    /// Reads as a sentence -- "231 cards · 12 due · 40 understood" -- with
    /// only the figure that needs attention carrying the accent.
    private var compositionLine: some View {
        HStack(spacing: 5) {
            Text("\(activeCount) card\(activeCount == 1 ? "" : "s")")
                .foregroundStyle(GRASPColor.textSecondary)
            if dueCount > 0 {
                Text("·").foregroundStyle(GRASPColor.textTertiary)
                Text("\(dueCount) due").foregroundStyle(GRASPColor.accent)
            }
            let understood = learnLevels.values.filter { $0 == .mastered }.count
            if understood > 0 {
                Text("·").foregroundStyle(GRASPColor.textTertiary)
                Text("\(understood) understood").foregroundStyle(GRASPColor.success)
            }
        }
        .graspType(.meta)
        .monospacedDigit()
    }

    @ViewBuilder
    private func modeButton(
        _ title: String, _ symbol: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(title)
        }
        if prominent {
            Button(action: action) { label }.buttonStyle(GRASPProminentButton())
        } else {
            Button(action: action) { label }.buttonStyle(GRASPQuietButton())
        }
    }

    /// Drafts are a gate, not an error -- an inset strip in the accent,
    /// tucked directly under the header it qualifies, rather than a
    /// full-width alert bar competing with the deck title.
    private var draftNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(GRASPColor.accent)
            Text("\(draftCount) card\(draftCount == 1 ? "" : "s") awaiting review")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
            Spacer(minLength: 8)
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
                .buttonStyle(.link)
                .disabled(isRefining)
            }
            Button("Approve all") {
                try? store.approveAllDrafts(inDeck: deckId)
                load()
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.accentSoft.opacity(0.55))
        .background(alignment: .bottom) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
        }
    }

    private func load() {
        cards = (try? store.cards(inDeck: deckId)) ?? []
        learnLevels = (try? store.learnLevels(forDeck: deckId)) ?? [:]
    }

    private func setStatus(_ card: Card, _ status: CardStatus) {
        try? store.setCardStatus(card.id, status: status)
        load()
    }
}

private struct MaterialIdentifier: Identifiable { let id: String }

private struct CardRow: View {
    let card: Card
    let mastery: LearnEngine.Level
    let onApprove: () -> Void
    let onSuspend: () -> Void
    let onEdit: () -> Void
    let onViewNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // A hairline rule down the left of each card, tinted by
            // mastery: understood teal, still-to-review amber, draft
            // grey. It's the one place a colored rail earns its keep --
            // it lets a long list be scanned for what still needs work
            // without reading a single word.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(railTint)
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.front)
                    .graspType(.rowTitle)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.back)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if card.status == .active { masteryBadge }
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
        .padding(.vertical, 7)
        .contextMenu {
            if card.status == .draft { Button("Approve", action: onApprove) }
            Button(card.status == .suspended ? "Reactivate" : "Suspend", action: onSuspend)
            Button("Edit", action: onEdit)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var railTint: Color {
        switch card.status {
        case .draft: return GRASPColor.hairlineStrong
        case .suspended: return GRASPColor.hairline
        case .active: return mastery == .mastered ? GRASPColor.success : GRASPColor.accentMuted
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch card.status {
        case .draft:
            Label("Draft", systemImage: "circle.dashed")
                .labelStyle(.iconOnly).foregroundStyle(GRASPColor.accent)
                .help("Awaiting review")
        case .suspended:
            Label("Suspended", systemImage: "pause.circle")
                .labelStyle(.iconOnly).foregroundStyle(GRASPColor.textTertiary)
                .help("Suspended")
        case .active:
            EmptyView()
        }
    }

    private var masteryBadge: some View {
        Group {
            if mastery == .mastered {
                Label("Understood", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(GRASPColor.success)
            } else {
                Label("Needs Review", systemImage: "circle")
                    .foregroundStyle(GRASPColor.accent)
            }
        }
        .labelStyle(.iconOnly)
        .help(mastery == .mastered ? "Understood" : "Needs Review")
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
