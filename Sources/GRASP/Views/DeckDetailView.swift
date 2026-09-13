import SwiftUI
import GRASPCore

/// The card review queue for a deck, or (via `scope: .course`) for every
/// deck in a course at once -- the "All Cards" master category
/// `DeckListView` pins above the real decks. Every parsed pair lands here
/// as a draft, and nothing enters study until approved -- with a
/// deterministic parser (and later a small local model) that gate is not
/// optional, since roughly a third of parser output needs a human glance or
/// a quick edit. The `.course` case is not a separate view or a parallel
/// set of models: `AppStore`'s plural query methods (`cards(inDecks:)`,
/// `dueCards(inDecks:)`, etc.) run the same queries across more decks, so
/// this same view, unchanged, already updates the instant a card -- or a
/// whole deck -- is added to or removed from the course.
struct DeckDetailView: View {
    @Environment(AppStore.self) private var store
    let scope: AppStore.DeckScope
    /// Every deck `scope` spans -- one real deck, or (for `.course`) every
    /// deck in that course. Cached here rather than recomputed inline on
    /// every read, since `load()` already re-derives it on every
    /// `store.revision` change, which is what keeps the "All Cards" master
    /// category current as decks (not just cards) come and go.
    @State private var scopeDeckIds: [String] = []
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
    @State private var isGeneratingCards = false
    @State private var fillGapsResult: Int?
    @State private var showingGenerateSheet = false
    @State private var learnLevels: [String: LearnEngine.Level] = [:]
    @State private var masteryFilter: MasteryFilter = .all
    @State private var courseId: String?
    @State private var siblingDecks: [Deck] = []
    @State private var isCreatingCard = false
    @State private var selectedCardIds: Set<Card.ID> = []
    @State private var previewCardId: String?
    @State private var pendingBulkDelete: [String]?
    @State private var duplicateGroups: [AppStore.DuplicateGroup] = []
    @State private var showingDuplicateReview = false
    /// Bumped every time `scope` changes (see `loadScopeIdentity`). `scope`
    /// itself is a plain `let`, not `@State`, so a `Task` launched from a
    /// button action captures it frozen at whatever deck/course was open
    /// the moment the button was tapped -- switching decks while that task
    /// is still in flight does not update it. Reading this counter back
    /// after an `await`, by contrast, always sees the live value (it's
    /// `@State`), so it's what an in-flight generate/refine call checks
    /// before writing its result into `cards`/`scopeDeckIds`, rather than
    /// silently overwriting whatever deck the user has since switched to.
    @State private var scopeGeneration = 0

    private enum MasteryFilter: String, CaseIterable, Identifiable {
        case all = "All", needsReview = "Needs Review", understood = "Understood"
        var id: String { rawValue }
    }

    private var draftCount: Int { cards.filter { $0.status == .draft }.count }
    private var activeCount: Int { cards.filter { $0.status == .active }.count }
    private var dueCount: Int { (try? store.dueCards(inDecks: scopeDeckIds).count) ?? 0 }

    /// The New Card sheet's default target: the current deck when scoped
    /// to one, or no default at all in the "All Cards" master category --
    /// there's no single deck to default to, so its own picker falls back
    /// to the course's first deck instead.
    private var defaultCardCreateDeckId: String? {
        if case .deck(let id) = scope { return id }
        return nil
    }

    private var visibleCards: [Card] {
        guard masteryFilter != .all else { return cards }
        return cards.filter { card in
            guard card.status == .active else { return false }
            let isUnderstood = learnLevels[card.id] == .mastered
            return masteryFilter == .understood ? isUnderstood : !isUnderstood
        }
    }

    /// Deliberately independent of `selectedCardIds`: a plain click on a
    /// row only selects it (for shift/cmd-click ranges and batch actions),
    /// it does not open the preview. The preview only opens from
    /// `CardRow`'s hover-revealed preview button, so browsing/selecting
    /// the list and looking at one card's flashcard preview are two
    /// separate gestures instead of one click doing both.
    private var previewCard: Card? {
        guard let id = previewCardId else { return nil }
        return cards.first { $0.id == id }
    }

    /// The selection in on-screen order, never a `Set`'s unspecified
    /// iteration order -- `bulkMoveCards` uses this to assign `sortIndex`
    /// in the destination deck, and scrambling that on every batch move
    /// would be a silent, hard-to-notice bug.
    private var orderedSelection: [String] {
        visibleCards.filter { selectedCardIds.contains($0.id) }.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            deckHeader
            if draftCount > 0 { draftNotice }
            if !duplicateGroups.isEmpty { duplicateNotice }
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
            if selectedCardIds.count > 1 { selectionActionBar }
            HStack(spacing: 0) {
                cardList
                if let card = previewCard {
                    Rectangle().fill(GRASPColor.hairlineStrong).frame(width: 1)
                    CardPreviewPane(
                        card: card,
                        mastery: learnLevels[card.id] ?? .new,
                        onEdit: { editingCard = card },
                        onApprove: { setStatus(card, .active) },
                        onViewNote: { viewingMaterialId = card.materialId },
                        onClose: { previewCardId = nil }
                    )
                    .frame(width: 360)
                }
            }
        }
        .background(GRASPColor.canvas)
        .navigationTitle(deckName)
        .task(id: scope) { loadScopeIdentity() }
        .onChange(of: store.revision) { load() }
        // A card that scrolls out of view because the filter changed must
        // also drop out of the selection -- a batch action must never
        // silently act on a card that's no longer on screen.
        .onChange(of: masteryFilter) {
            selectedCardIds.formIntersection(Set(visibleCards.map(\.id)))
            if let id = previewCardId, !visibleCards.contains(where: { $0.id == id }) {
                previewCardId = nil
            }
        }
        .alert(
            "Delete \(pendingBulkDelete?.count ?? 0) cards?",
            isPresented: Binding(get: { pendingBulkDelete != nil }, set: { if !$0 { pendingBulkDelete = nil } }),
            presenting: pendingBulkDelete
        ) { ids in
            Button("Delete", role: .destructive) {
                try? store.bulkDeleteCards(ids)
                selectedCardIds.removeAll()
                load()
            }
            Button("Cancel", role: .cancel) {}
        } message: { (ids: [String]) -> Text in
            Text("Review history is kept, but these \(ids.count) cards will no longer appear in this deck.")
        }
        .task {
            await store.refreshGeneratorStatus()
            isGeneratorAvailable = store.isGeneratorAvailable
        }
        .sheet(isPresented: $isStudying, onDismiss: load) {
            FlashcardStudyView(deckIds: scopeDeckIds, deckName: deckName)
        }
        .sheet(isPresented: $isLearning, onDismiss: load) {
            LearnRoundView(deckIds: scopeDeckIds, deckName: deckName)
        }
        .sheet(item: $testPhase, onDismiss: load) { phase in
            switch phase {
            case .setup:
                TestSetupSheet(deckIds: scopeDeckIds, deckName: deckName) { attemptId, questions in
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
        .sheet(isPresented: $isCreatingCard, onDismiss: load) {
            CardCreateSheet(courseId: courseId, deckId: defaultCardCreateDeckId)
        }
        .sheet(isPresented: $showingGenerateSheet) {
            GenerateCardsSheet { maxPerNote, topic in
                runGenerate(maxPerNote: maxPerNote, topic: topic)
            }
        }
        .sheet(isPresented: $showingDuplicateReview, onDismiss: load) {
            DuplicateReviewSheet(groups: duplicateGroups) { toRemove in
                try? store.bulkDeleteCards(toRemove)
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
        .alert(
            fillGapsResult == 0 ? "No Gaps Found" : "Cards Added",
            isPresented: Binding(get: { fillGapsResult != nil }, set: { if !$0 { fillGapsResult = nil } })
        ) {
            Button("OK") {}
        } message: {
            if let fillGapsResult, fillGapsResult > 0 {
                Text("Added \(fillGapsResult) new card\(fillGapsResult == 1 ? "" : "s"), marked as AI-generated and awaiting your review.")
            } else {
                Text("The AI didn't find any concepts in these notes that aren't already covered by an existing card.")
            }
        }
    }

    /// Deck name, its one-line composition, and the four actions. Study,
    /// Learn, and Test stay in a fixed order and at a neutral weight --
    /// only New Card is accented, since it's the one action that adds
    /// something to the deck rather than drawing on it, and it's always
    /// available (an empty deck is exactly when you want it). The "what to
    /// do next" signal instead lives in `compositionLine`'s accented
    /// "N due" below.
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

            HStack(spacing: 8) {
                modeButton("Study", "rectangle.stack.fill", prominent: false) { isStudying = true }
                    .disabled(dueCount == 0)
                modeButton("Learn", "graduationcap.fill", prominent: dueCount == 0 && activeCount > 0) {
                    isLearning = true
                }
                .disabled(activeCount == 0)
                modeButton("Test", "checklist", prominent: false) { testPhase = .setup }
                    .disabled(activeCount == 0)
                modeButton("New Card", "plus", prominent: true) { isCreatingCard = true }
                if isGeneratorAvailable {
                    addCardsWithAIButton
                }
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

    /// Not `modeButton` -- this one swaps its icon for a spinner while a
    /// run is in flight, which a run over several notes' worth of
    /// sequential model round trips is slow enough to actually need.
    private var addCardsWithAIButton: some View {
        Button {
            showingGenerateSheet = true
        } label: {
            HStack(spacing: 5) {
                if isGeneratingCards {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 11))
                }
                Text("Add More Cards with AI")
            }
        }
        .buttonStyle(GRASPQuietButton())
        .disabled(isGeneratingCards)
        .help("Ask the AI to propose cards for concepts your notes mention but never turned into a card")
    }

    /// `maxPerNote: nil` means "use `AppStore`'s own default cap" -- the
    /// "AI Suggested Amount" choice in the sheet below deliberately doesn't
    /// pass an explicit number, so it always tracks whatever that default
    /// actually is rather than a copy of it duplicated here.
    private func runGenerate(maxPerNote: Int?, topic: String?) {
        isGeneratingCards = true
        let generation = scopeGeneration
        let deckIds = scopeDeckIds
        Task {
            let count: Int
            if let maxPerNote {
                count = await store.generateAdditionalCards(inDecks: deckIds, maxPerNote: maxPerNote, topic: topic)
            } else {
                count = await store.generateAdditionalCards(inDecks: deckIds, topic: topic)
            }
            isGeneratingCards = false
            // Bail before touching anything scope-dependent (`cards`,
            // `scopeDeckIds`, ...) if the user has since switched to a
            // different deck or course -- otherwise this stale result
            // would silently overwrite what's now on screen with data for
            // a scope that's no longer even visible.
            guard generation == scopeGeneration else { return }
            fillGapsResult = count
            load()
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
                    isRefining = true
                    let generation = scopeGeneration
                    let deckIds = scopeDeckIds
                    Task {
                        _ = await store.refineDraftCards(inDecks: deckIds)
                        isRefining = false
                        // Same guard as `runGenerate`: don't let a refine
                        // started on a deck the user has since switched
                        // away from overwrite the deck now on screen.
                        guard generation == scopeGeneration else { return }
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
                try? store.approveAllDrafts(inDecks: scopeDeckIds)
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

    /// Same treatment as `draftNotice`, but neutral-toned rather than
    /// accented -- a duplicate backlog isn't a gate blocking study the way
    /// unapproved drafts are, just a standing cleanup opportunity.
    private var duplicateNotice: some View {
        let cardCount = duplicateGroups.reduce(0) { $0 + $1.cards.count - 1 }
        return HStack(spacing: 10) {
            Image(systemName: "square.on.square")
                .font(.system(size: 12))
                .foregroundStyle(GRASPColor.textSecondary)
            Text("\(duplicateGroups.count) possible duplicate group\(duplicateGroups.count == 1 ? "" : "s") (\(cardCount) extra card\(cardCount == 1 ? "" : "s"))")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
            Spacer(minLength: 8)
            Button("Review Duplicates…") { showingDuplicateReview = true }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.inset)
        .background(alignment: .bottom) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
        }
    }

    /// Native macOS multi-selection, not hand-rolled: `List(selection:)`
    /// bound to a `Set` already gives click-replaces / shift-click-extends-
    /// range / cmd-click-toggles via the underlying table view, with no
    /// `NSEvent`/keyDown handling of any kind -- the exact same mechanism
    /// `DeckListView`'s single-selection deck list already relies on.
    ///
    /// `.contextMenu(forSelectionType:)` on the list (rather than a
    /// per-row `.contextMenu`) is what makes right-click do the right
    /// thing in both directions the request calls out: SwiftUI hands the
    /// menu builder the *actual set to act on* -- the current selection
    /// when the right-clicked row is already part of it, just that row's
    /// id when it isn't. Every action below is built from that `ids`
    /// parameter, never from `selectedCardIds` directly, so this holds
    /// regardless of whatever the framework does to the selection
    /// binding before the menu opens.
    private var cardList: some View {
        List(selection: $selectedCardIds) {
            ForEach(visibleCards) { card in
                CardRow(
                    card: card,
                    mastery: learnLevels[card.id] ?? .new,
                    siblingDecks: siblingDecks,
                    onPreview: { previewCardId = card.id },
                    onApprove: { setStatus(card, .active) },
                    onSuspend: { setStatus(card, card.status == .suspended ? .active : .suspended) },
                    onEdit: { editingCard = card },
                    onViewNote: { viewingMaterialId = card.materialId },
                    onDelete: { pendingDeleteCard = card },
                    onMove: { target in
                        try? store.moveCard(card.id, toDeck: target)
                        load()
                    }
                )
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Card.ID.self) { ids in
            if ids.isEmpty {
                Button("Approve All Drafts") {
                    try? store.approveAllDrafts(inDecks: scopeDeckIds)
                    load()
                }
                .disabled(draftCount == 0)
                Button("Review Duplicates…") { showingDuplicateReview = true }
                    .disabled(duplicateGroups.isEmpty)
            } else if ids.count == 1, let card = cards.first(where: { $0.id == ids.first }) {
                singleCardMenuItems(card)
            } else {
                batchMenuItems(Array(ids))
            }
        } primaryAction: { ids in
            if ids.count == 1, let card = cards.first(where: { $0.id == ids.first }) {
                editingCard = card
            }
        }
    }

    @ViewBuilder
    private func singleCardMenuItems(_ card: Card) -> some View {
        Button("Preview") { previewCardId = card.id }
        if card.status == .draft {
            Button("Approve") { setStatus(card, .active) }
        }
        Button(card.status == .suspended ? "Reactivate" : "Suspend") {
            setStatus(card, card.status == .suspended ? .active : .suspended)
        }
        Button("Edit") { editingCard = card }
        if card.materialId != nil {
            Button("View Source Note") { viewingMaterialId = card.materialId }
        }
        if !siblingDecks.isEmpty {
            Menu("Move to…") {
                ForEach(siblingDecks) { deck in
                    Button(deck.name) {
                        try? store.moveCard(card.id, toDeck: deck.id)
                        load()
                    }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { pendingDeleteCard = card }
    }

    @ViewBuilder
    private func batchMenuItems(_ ids: [String]) -> some View {
        // `ids` come from SwiftUI's selection set, not necessarily in
        // display order -- re-derive order from `visibleCards` the same
        // way `orderedSelection` does, so a batch move doesn't scramble
        // the destination deck's sortIndex.
        let ordered = visibleCards.filter { ids.contains($0.id) }.map(\.id)
        Button("Approve Selected") {
            try? store.bulkSetStatus(ordered, status: .active)
            load()
        }
        Button("Suspend Selected") {
            try? store.bulkSetStatus(ordered, status: .suspended)
            load()
        }
        if !siblingDecks.isEmpty {
            Menu("Move Selected to…") {
                ForEach(siblingDecks) { deck in
                    Button(deck.name) {
                        try? store.bulkMoveCards(ordered, toDeck: deck.id)
                        selectedCardIds.removeAll()
                        load()
                    }
                }
            }
        }
        Divider()
        Button("Delete Selected", role: .destructive) { pendingBulkDelete = ordered }
    }

    /// Surfaces the same batch actions as the context menu without
    /// requiring a right-click, since right-click alone isn't discoverable
    /// enough for something this useful.
    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedCardIds.count) selected")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
            Spacer(minLength: 8)
            Button("Approve") {
                try? store.bulkSetStatus(orderedSelection, status: .active)
                load()
            }
            .buttonStyle(.link)
            Button("Suspend") {
                try? store.bulkSetStatus(orderedSelection, status: .suspended)
                load()
            }
            .buttonStyle(.link)
            if !siblingDecks.isEmpty {
                Menu("Move to…") {
                    ForEach(siblingDecks) { deck in
                        Button(deck.name) {
                            try? store.bulkMoveCards(orderedSelection, toDeck: deck.id)
                            selectedCardIds.removeAll()
                            load()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button("Delete") { pendingBulkDelete = orderedSelection }
                .buttonStyle(.link)
                .foregroundStyle(.red)
            Button("Deselect All") { selectedCardIds.removeAll() }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.inset)
        .background(alignment: .bottom) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
        }
    }

    /// Resolves `deckName`/`courseId` from `scope`'s identity -- run once
    /// per scope change via `.task(id: scope)`, not on every `load()`,
    /// since neither depends on live card data.
    private func loadScopeIdentity() {
        scopeGeneration += 1
        switch scope {
        case .deck(let id):
            let deck = (try? store.deck(id)) ?? nil
            deckName = deck?.name ?? "Deck"
            courseId = deck?.courseId
        case .course(let id):
            courseId = id
            // Matches `DeckListView`'s pinned row verbatim -- the same
            // word everywhere it refers to this same aggregate.
            deckName = "All Cards"
        }
        load()
    }

    private func load() {
        switch scope {
        case .deck(let id):
            scopeDeckIds = [id]
        case .course(let id):
            // Re-derived every load, not just once per `.task(id: scope)`
            // -- a deck created or deleted in this course while "All
            // Cards" is already open must be picked up on the very next
            // `store.revision` change, the same way a card being added or
            // removed already is.
            scopeDeckIds = (try? store.decks(inCourse: id))?.map(\.id) ?? []
        }
        cards = (try? store.cards(inDecks: scopeDeckIds)) ?? []
        learnLevels = (try? store.learnLevels(forDecks: scopeDeckIds)) ?? [:]
        if let courseId {
            let allDecksInCourse = (try? store.decks(inCourse: courseId)) ?? []
            switch scope {
            case .deck(let id):
                siblingDecks = allDecksInCourse.filter { $0.id != id }
            case .course:
                // No single "current deck" to exclude -- every deck in the
                // course is a valid "Move to..." target from here.
                siblingDecks = allDecksInCourse
            }
        }
        selectedCardIds.formIntersection(Set(cards.map(\.id)))
        if let id = previewCardId, !cards.contains(where: { $0.id == id }) {
            previewCardId = nil
        }
        duplicateGroups = (try? store.duplicateGroups(inDecks: scopeDeckIds)) ?? []
    }

    private func setStatus(_ card: Card, _ status: CardStatus) {
        try? store.setCardStatus(card.id, status: status)
        load()
    }
}

private struct MaterialIdentifier: Identifiable { let id: String }

/// "Add More Cards with AI"'s config sheet, in the same
/// Stepper-plus-footer shape as `TestSetupSheet`. "AI Suggested Amount"
/// deliberately doesn't pass a number at all (see `runGenerate`) rather
/// than hardcoding a copy of `AppStore`'s own default cap here.
private struct GenerateCardsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onGenerate: (_ maxPerNote: Int?, _ topic: String?) -> Void

    private enum AmountMode { case suggested, custom }

    @State private var amountMode: AmountMode = .suggested
    @State private var customAmount = 3
    @State private var topic = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add More Cards with AI").font(.headline)
            Text("The AI looks for concepts your notes mention but that don't have a card yet.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Amount", selection: $amountMode) {
                Text("AI Suggested Amount").tag(AmountMode.suggested)
                Text("Custom Amount").tag(AmountMode.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if amountMode == .custom {
                Stepper(
                    "Up to \(customAmount) card\(customAmount == 1 ? "" : "s") per note",
                    value: $customAmount, in: 1...10
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Focus on (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. mitosis phases", text: $topic)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Generate") {
                    let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                    onGenerate(amountMode == .custom ? customAmount : nil, trimmedTopic.isEmpty ? nil : trimmedTopic)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// A live, non-modal preview of exactly one selected card, rendered as a
/// flip-able flashcard -- visually the same language as
/// `FlashcardStudyView`'s card canvas (a raised, bordered surface; large
/// front text; tap to reveal the back below a divider), scaled down for a
/// 360pt side panel instead of the study view's full-window canvas.
/// Deliberately not a study rep: no FSRS grading, no
/// `store.markCard`/`gradeCard` call, just a look. Lives beside the list
/// rather than in a sheet so it never blocks list navigation -- selecting
/// the next card with an arrow key just updates what's shown here.
///
/// The header's close button is the visible, discoverable way to drop back
/// to zero selection -- cmd-clicking the same row does the same thing via
/// the underlying `Set` binding, but that's not something a person would
/// find on their own.
private struct CardPreviewPane: View {
    let card: Card
    let mastery: LearnEngine.Level
    let onEdit: () -> Void
    let onApprove: () -> Void
    let onViewNote: () -> Void
    let onClose: () -> Void

    @State private var isFlipped = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                cardCanvas
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            }
            .background(GRASPColor.canvas)
            Divider()
            metaLine
            Divider()
            footer
        }
        .background(GRASPColor.canvas)
        // A newly-selected card always starts front-up -- flipping is a
        // per-look decision, not something that should carry over from
        // whatever the previously-selected card was left showing.
        .onChange(of: card.id) { isFlipped = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Preview")
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.textTertiary)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GRASPColor.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(GRASPColor.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// A raised card surface, not bare text on the pane's background --
    /// the border, shadow, and generous internal padding are what read as
    /// "a flashcard" rather than "a text label", matching the weight
    /// `FlashcardStudyView`'s full-size canvas gives the same content.
    private var cardCanvas: some View {
        VStack(spacing: 0) {
            Text(card.front)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(GRASPColor.textPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            if isFlipped {
                Rectangle()
                    .fill(GRASPColor.hairlineStrong)
                    .frame(width: 28, height: 1)
                    .padding(.vertical, 16)

                Text(card.back)
                    .font(.system(size: 15))
                    .foregroundStyle(GRASPColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            } else {
                flipHint.padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GRASPColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(GRASPColor.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFlipped.toggle() }
    }

    private var flipHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.tap")
                .font(.system(size: 9))
            Text("Tap to reveal")
        }
        .graspType(.meta)
        .foregroundStyle(GRASPColor.textTertiary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(GRASPColor.inset, in: Capsule())
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            statusChip
            masteryChip
            originChip
            Spacer(minLength: 8)
            Text(card.reps == 0 ? "Never reviewed" : "\(card.reps) review\(card.reps == 1 ? "" : "s")")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusChip: some View {
        switch card.status {
        case .draft: PreviewChip(text: "Pending", tint: GRASPColor.accent, tintSoft: GRASPColor.accentSoft)
        case .suspended: PreviewChip(text: "Rejected", tint: GRASPColor.rejected, tintSoft: GRASPColor.rejectedSoft)
        case .active: EmptyView()
        }
    }

    private var masteryChip: some View {
        Group {
            if mastery == .mastered {
                PreviewChip(text: "Understood", tint: GRASPColor.success, tintSoft: GRASPColor.successSoft)
            } else {
                PreviewChip(text: "Needs review", tint: GRASPColor.accent, tintSoft: GRASPColor.accentSoft)
            }
        }
    }

    /// Permanent, not tied to `.draft` status -- this is the fact worth
    /// remembering about a card long after it's approved: its content
    /// wasn't in the note verbatim, the AI proposed it.
    @ViewBuilder private var originChip: some View {
        if card.origin == .aiGenerated {
            PreviewChip(
                text: "AI-generated", tint: GRASPColor.accent, tintSoft: GRASPColor.accentSoft, icon: "sparkles"
            )
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(isFlipped ? "Hide Answer" : "Reveal Answer") { isFlipped.toggle() }
                .buttonStyle(GRASPQuietButton())
                .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                if card.status == .draft {
                    iconButton("checkmark.circle", help: "Approve", action: onApprove)
                }
                iconButton("pencil", help: "Edit", action: onEdit)
                if card.materialId != nil {
                    iconButton("doc.text", help: "View Source Note", action: onViewNote)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(GRASPColor.textSecondary)
                .frame(width: 26, height: 26)
                .background(GRASPColor.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A small tinted capsule for a card's status/mastery -- the same idea as
/// `DeckRow`'s due-count capsule, reused here rather than inventing a
/// second badge style for what is visually the same kind of fact.
private struct PreviewChip: View {
    let text: String
    let tint: Color
    let tintSoft: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 8))
            }
            Text(text)
        }
        .graspType(.meta)
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tintSoft, in: Capsule())
    }
}

private struct CardRow: View {
    let card: Card
    let mastery: LearnEngine.Level
    let siblingDecks: [Deck]
    let onPreview: () -> Void
    let onApprove: () -> Void
    let onSuspend: () -> Void
    let onEdit: () -> Void
    let onViewNote: () -> Void
    let onDelete: () -> Void
    let onMove: (String) -> Void

    // Reserved space, not conditionally inserted -- toggling opacity
    // rather than adding/removing the button from the tree keeps the
    // row's width from jumping the instant the pointer arrives.
    @State private var isHovering = false

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
                .help(railHelp ?? "")

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
            previewButton
            originBadge
            Menu {
                if card.status == .draft {
                    Button("Approve", action: onApprove)
                }
                Button(card.status == .suspended ? "Reactivate" : "Suspend", action: onSuspend)
                Button("Edit", action: onEdit)
                if card.materialId != nil {
                    Button("View Source Note", action: onViewNote)
                }
                if !siblingDecks.isEmpty {
                    Menu("Move to…") {
                        ForEach(siblingDecks) { deck in
                            Button(deck.name) { onMove(deck.id) }
                        }
                    }
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
        .contentShape(Rectangle())
        .draggable(CardTransfer(cardId: card.id))
        .onHover { isHovering = $0 }
    }

    /// The explicit, discoverable way to open the flashcard preview -- a
    /// plain click on the row only selects it (for shift/cmd-click ranges
    /// and batch actions), it deliberately does not also open the preview,
    /// so browsing the list can't accidentally swap out whatever's already
    /// showing in the pane.
    private var previewButton: some View {
        Button(action: onPreview) {
            Image(systemName: "eye")
                .font(.system(size: 12))
                .foregroundStyle(GRASPColor.textSecondary)
                .frame(width: 24, height: 24)
                .background(GRASPColor.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Preview")
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }

    /// The sole approval-status signal on a row -- amber for pending
    /// (awaiting review), a muted rose for rejected (suspended), and the
    /// existing mastery-based tint for an approved/active card. Replaces a
    /// second, redundant circular icon that used to sit beside this same
    /// bar and say the same thing.
    private var railTint: Color {
        switch card.status {
        case .draft: return GRASPColor.accent
        case .suspended: return GRASPColor.rejected
        case .active: return mastery == .mastered ? GRASPColor.success : GRASPColor.accentMuted
        }
    }

    private var railHelp: String? {
        switch card.status {
        case .draft: return "Pending review"
        case .suspended: return "Rejected"
        case .active: return nil
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

    /// Independent of approval status -- a card can be `.active` *and*
    /// AI-generated, so this is a second badge, not a replacement. Stays
    /// forever, not just while the card is a draft: this is the one whose
    /// content is worth checking against a source before an exam, and that
    /// stays true long after it's been approved.
    @ViewBuilder private var originBadge: some View {
        if card.origin == .aiGenerated {
            Label("AI-generated", systemImage: "sparkles")
                .labelStyle(.iconOnly).foregroundStyle(GRASPColor.accent)
                .help("AI-generated -- not directly from your notes, worth double-checking")
        }
    }
}

/// Lets the new card target any course/deck, defaulting to whichever one
/// was open when "New Card" was clicked -- "allows targeting a specific
/// course and module/category" without needing a global entry point
/// outside the deck this button already lives in.
/// Reviews each duplicate group before removing anything -- "Remove
/// Duplicates" is a quick action, but a blind bulk-delete of content
/// someone wrote flashcards from deserves a look first, even though the
/// underlying delete is a soft one. One radio-style choice per group
/// (which card survives, or "keep both" when the group's smart pick isn't
/// confident enough to guess).
private struct DuplicateReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groups: [AppStore.DuplicateGroup]
    let onRemove: (_ cardIdsToRemove: [String]) -> Void

    /// Value per group: the id to keep (removing every other member), or
    /// `nil` meaning "keep all of them, skip this group".
    @State private var keepChoice: [String: String?] = [:]

    private var totalToRemove: Int {
        groups.reduce(0) { total, group in
            guard let choice = keepChoice[group.id, default: defaultChoice(for: group)] else { return total }
            return total + group.cards.filter { $0.id != choice }.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Duplicates").font(.headline)
                Text("\(groups.count) group\(groups.count == 1 ? "" : "s") found. Pick which card in each group survives.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        groupBlock(group)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("\(totalToRemove) card\(totalToRemove == 1 ? "" : "s") will be removed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Remove \(totalToRemove) Cards", role: .destructive) {
                    let toRemove = groups.flatMap { group -> [String] in
                        guard let choice = keepChoice[group.id, default: defaultChoice(for: group)] else { return [] }
                        return group.cards.filter { $0.id != choice }.map(\.id)
                    }
                    onRemove(toRemove)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(totalToRemove == 0)
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
    }

    private func groupBlock(_ group: AppStore.DuplicateGroup) -> some View {
        let choice = keepChoice[group.id, default: defaultChoice(for: group)]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.cards.count) near-identical cards").font(.subheadline.weight(.medium))
                if group.hasCompetingHistory {
                    Text("· multiple have review history").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            VStack(spacing: 6) {
                ForEach(group.cards) { card in
                    memberRow(card, group: group, isKept: choice == card.id)
                }
                Button(choice == nil ? "Keeping both" : "Keep both instead") {
                    keepChoice[group.id] = .some(nil)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(12)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(GRASPColor.hairline))
    }

    private func memberRow(_ card: Card, group: AppStore.DuplicateGroup, isKept: Bool) -> some View {
        Button {
            keepChoice[group.id] = .some(card.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isKept ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isKept ? GRASPColor.accent : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.front).font(.callout.weight(.medium))
                    Text(card.back).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Text(memberMeta(card))
                        .font(.caption2)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isKept ? GRASPColor.textPrimary : GRASPColor.textTertiary)
            .opacity(isKept ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    private func memberMeta(_ card: Card) -> String {
        var parts = [card.status == .draft ? "Pending" : card.status == .suspended ? "Rejected" : "Approved"]
        parts.append(card.reps == 0 ? "no reviews" : "\(card.reps) review\(card.reps == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// A group where two or more cards already carry real review history
    /// defaults to "keep both" rather than the smart pick -- there's no
    /// safe automatic guess about which study history to discard, so this
    /// forces a deliberate choice instead of a silent one.
    private func defaultChoice(for group: AppStore.DuplicateGroup) -> String? {
        group.hasCompetingHistory ? nil : group.suggestedKeepId
    }
}

private struct CardCreateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var front = ""
    @State private var back = ""
    @State private var selectedCourseId: String?
    @State private var selectedDeckId: String?
    @State private var decksInCourse: [Deck] = []

    init(courseId: String?, deckId: String?) {
        _selectedCourseId = State(initialValue: courseId)
        _selectedDeckId = State(initialValue: deckId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Card").font(.headline)

            HStack(spacing: 8) {
                Picker("Course", selection: $selectedCourseId) {
                    ForEach(store.coursePickerGroups(), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.courses) { course in
                                Text(course.name).tag(course.id as String?)
                            }
                        }
                    }
                }
                Picker("Deck", selection: $selectedDeckId) {
                    ForEach(decksInCourse) { deck in
                        Text(deck.name).tag(deck.id as String?)
                    }
                }
                .disabled(decksInCourse.isEmpty)
            }

            Text("Front").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $front).frame(height: 60).border(.separator)
            Text("Back").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $back).frame(height: 100).border(.separator)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    guard let deckId = selectedDeckId else { return }
                    try? store.createManualCard(
                        front: front.trimmingCharacters(in: .whitespacesAndNewlines),
                        back: back.trimmingCharacters(in: .whitespacesAndNewlines),
                        deckId: deckId
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedDeckId == nil
                        || front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { loadDecks(for: selectedCourseId) }
        .onChange(of: selectedCourseId) { _, newValue in loadDecks(for: newValue) }
    }

    private func loadDecks(for courseId: String?) {
        guard let courseId else { decksInCourse = []; selectedDeckId = nil; return }
        decksInCourse = (try? store.decks(inCourse: courseId)) ?? []
        if !(decksInCourse.contains { $0.id == selectedDeckId }) {
            selectedDeckId = decksInCourse.first?.id
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
