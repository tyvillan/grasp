import SwiftUI
import GRASPCore

/// A user-chosen display order for the card list, independent of
/// `masteryFilter` (which decides *which* cards show, not what order they
/// show in). `.deckOrder` passes `cards` through unchanged -- it's already
/// fetched in `DeckCard.sortIndex` order by `AppStore.cards(inDecks:)`, the
/// same per-deck order `bulkMoveCards` maintains when cards are dragged
/// between decks. One global preference (`@AppStorage`, mirroring
/// `DeckListView`'s own deck-sort control) rather than per-deck.
private enum CardSortOption: String, CaseIterable, Identifiable {
    case deckOrder, alphabetical, dateAdded, dueDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deckOrder: return "Default (Deck Order)"
        case .alphabetical: return "Alphabetical (A–Z)"
        case .dateAdded: return "Date Added"
        case .dueDate: return "Due Date"
        }
    }
}

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
    /// Runs the shared file/folder picker for whichever course this deck
    /// (or "All Cards") belongs to -- the actual `NSOpenPanel` + import
    /// call and its result sheet live in `ContentView`, since that's also
    /// what `CourseEmptyStateView` and "Upload Document to Course" share;
    /// this view only needs to trigger it, not own it.
    let onAddFiles: () -> Void
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
    @State private var showingDeckFiles = false
    /// The deck-wide AI job in progress (Refine Deck, Add More Cards), shown
    /// as a strip under the header. One at a time: they both work through
    /// the same drafts.
    @State private var refineDeckResult: AppStore.RefineDeckSummary?
    @State private var showingRefineDeckConfirmation = false
    @State private var fillGapsResult: Int?
    @State private var showingGenerateSheet = false
    @State private var learnLevels: [String: LearnEngine.Level] = [:]
    @State private var masteryFilter: MasteryFilter = .all
    @AppStorage("cardSortOption") private var cardSortOption: CardSortOption = .deckOrder
    @State private var courseId: String?
    @State private var siblingDecks: [Deck] = []
    @State private var isCreatingCard = false
    @State private var selectedCardIds: Set<Card.ID> = []
    @State private var previewCardId: String?
    @State private var pendingBulkDelete: [String]?
    @State private var duplicateGroups: [AppStore.DuplicateGroup] = []
    @State private var showingDuplicateReview = false
    /// Every card with a single-card refine in flight. A set: with one id,
    /// refining a second card cleared the first one's "Refining…" early.
    @State private var refiningCardIds: Set<String> = []
    @State private var cardRefineResult: CardRefineMessage?
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

    /// Which half of the deck is on screen. The deck header, the draft
    /// notice and the duplicate notice sit above this and are shared by
    /// both -- they're facts about the deck, not about either view of it.
    @State private var contentTab: ContentTab = .cards

    private enum ContentTab: String, CaseIterable, Identifiable {
        case cards = "Cards", overview = "Overview"
        var id: String { rawValue }
    }

    /// Free -- `cards` is already loaded. A deck whose cards were all typed
    /// by hand has no note to summarise, so the tab never appears at all:
    /// there'd be no action to offer behind it, and this app hides an
    /// affordance rather than showing a disabled one.
    private var hasSourceNotes: Bool { cards.contains { $0.materialId != nil } }

    private var draftCount: Int { cards.filter { $0.status == .draft }.count }
    private var activeCount: Int { cards.filter { $0.status == .active }.count }

    /// This course's running deck-wide AI job, which the store owns so it
    /// survives this view being swapped out mid-run.
    private var cardJobKey: String { store.cardJobKey(courseId: courseId) }
    private var aiActivity: AIActivity? { store.aiJob(cardJobKey)?.activity }
    private var isRefiningDeck: Bool { aiActivity?.purpose == "refine" }
    private var isGeneratingCards: Bool { aiActivity?.purpose == "add" }
    /// Refreshed in `load()`. As a computed property it ran the whole due
    /// query four times per render -- on every selection click.
    @State private var dueCount = 0

    /// The New Card sheet's default target: the current deck when scoped
    /// to one, or no default at all in the "All Cards" master category --
    /// there's no single deck to default to, so its own picker falls back
    /// to the course's first deck instead.
    private var defaultCardCreateDeckId: String? {
        if case .deck(let id) = scope { return id }
        return nil
    }

    private var visibleCards: [Card] {
        let filtered: [Card]
        // With no active cards the filter picker is hidden, so a filter
        // carried in from another deck would blank the list with no way to
        // clear it. Only active cards have a mastery level to filter on.
        if masteryFilter == .all || activeCount == 0 {
            filtered = cards
        } else {
            filtered = cards.filter { card in
                guard card.status == .active else { return false }
                let isUnderstood = learnLevels[card.id] == .mastered
                return masteryFilter == .understood ? isUnderstood : !isUnderstood
            }
        }
        return sortedCards(filtered)
    }

    private var cardSortMenu: some View {
        Menu {
            Picker("Sort Cards", selection: $cardSortOption) {
                ForEach(CardSortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 14))
                .foregroundStyle(GRASPColor.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort cards: \(cardSortOption.label)")
    }

    private func sortedCards(_ cards: [Card]) -> [Card] {
        switch cardSortOption {
        case .deckOrder:
            return cards
        case .alphabetical:
            return cards.sorted { $0.front.localizedStandardCompare($1.front) == .orderedAscending }
        case .dateAdded:
            return cards.sorted { $0.createdAt < $1.createdAt }
        case .dueDate:
            return cards.sorted { $0.due < $1.due }
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

    /// The card list and everything that belongs to it. Lifted out of
    /// `body` verbatim when the Overview tab arrived -- no behaviour
    /// change, and `body` finally fits on a screen.
    private var cardsTab: some View {
        VStack(spacing: 0) {
            if !cards.isEmpty {
                HStack {
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
                    }
                    Spacer()
                    cardSortMenu
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            if selectedCardIds.count > 1 { selectionActionBar }
            HStack(spacing: 0) {
                // The list keeps a usable width and the preview gives way,
                // down to a floor. A fixed 360pt preview took the whole pane
                // at the window's smallest size and squeezed the list to
                // nothing.
                cardList
                    .frame(minWidth: 240)
                    .layoutPriority(1)
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
                    .frame(minWidth: 240, idealWidth: 360, maxWidth: 360)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            deckHeader
            if let aiActivity {
                AIProgressStrip(
                    activity: aiActivity,
                    onStop: { store.stopAIJob(cardJobKey) },
                    stopHelp: "Stops now. Cards already finished keep their changes; "
                        + "the one in progress is left as it was."
                )
            }
            if draftCount > 0 { draftNotice }
            if !duplicateGroups.isEmpty { duplicateNotice }
            switch contentTab {
            case .cards:
                cardsTab
            case .overview:
                DeckOverviewView(scope: scope) { cardId in
                    contentTab = .cards
                    selectedCardIds = [cardId]
                    previewCardId = cardId
                }
            }
        }
        .background(GRASPColor.canvas)
        .navigationTitle(deckName)
        .task(id: scope) { loadScopeIdentity() }
        .onChange(of: store.revision) { load() }
        // Sticky across deck switches on purpose -- someone comparing two
        // lectures' overviews shouldn't have to re-pick the tab each time.
        // But a deck with no source notes hides the picker, and a hidden
        // picker can't be used to get back out of a tab with nothing in it.
        .onChange(of: hasSourceNotes) { _, hasNotes in
            if !hasNotes { contentTab = .cards }
        }
        // A card that scrolls out of view because the filter changed must
        // also drop out of the selection -- a batch action must never
        // silently act on a card that's no longer on screen.
        .onChange(of: masteryFilter) {
            selectedCardIds.formIntersection(Set(visibleCards.map(\.id)))
            if let id = previewCardId, !visibleCards.contains(where: { $0.id == id }) {
                previewCardId = nil
            }
        }
        .sheet(isPresented: Binding(get: { pendingBulkDelete != nil }, set: { if !$0 { pendingBulkDelete = nil } })) {
            if let ids = pendingBulkDelete {
                ConfirmationSheet(
                    icon: "trash", title: "Delete \(ids.count) Card\(ids.count == 1 ? "" : "s")?",
                    message: "Review history is kept, but \(ids.count == 1 ? "this card" : "these \(ids.count) cards") will no longer appear in this deck.",
                    confirmTitle: "Delete"
                ) {
                    try? store.bulkDeleteCards(ids)
                    selectedCardIds.removeAll()
                    load()
                }
            }
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
                TestSetupSheet(deckIds: scopeDeckIds, deckName: deckName) { attemptId, questions, aiWarning in
                    testPhase = .running(attemptId: attemptId, questions: questions, aiWarning: aiWarning)
                }
            case .running(let attemptId, let questions, let aiWarning):
                TestRunView(attemptId: attemptId, deckName: deckName, questions: questions, aiWarning: aiWarning) { graded in
                    _ = try? store.finishTest(attemptId: attemptId)
                    testPhase = .results(attemptId: attemptId, graded: graded)
                }
            case .results(let attemptId, let graded):
                TestResultsView(deckName: deckName, attemptId: attemptId, graded: graded)
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
            DuplicateReviewSheet(groups: duplicateGroups) { merges in
                try? store.mergeDuplicates(merges)
            }
        }
        .sheet(item: Binding(
            get: { viewingMaterialId.map { MaterialIdentifier(id: $0) } },
            set: { viewingMaterialId = $0?.id }
        )) { wrapped in
            NoteViewerView(materialId: wrapped.id)
        }
        .sheet(item: $pendingDeleteCard) { card in
            ConfirmationSheet(
                icon: "trash", title: "Delete This Card?",
                message: "\"\(card.front)\" will no longer appear in this deck. Review history is kept.",
                confirmTitle: "Delete"
            ) {
                try? store.deleteCard(card.id)
                load()
            }
        }
        .sheet(isPresented: Binding(get: { fillGapsResult != nil }, set: { if !$0 { fillGapsResult = nil } })) {
            if let fillGapsResult {
                ResultSheet(
                    icon: "sparkles",
                    title: fillGapsResult == 0 ? "No Gaps Found" : "Cards Added",
                    leadText: fillGapsResult > 0
                        ? "Added \(fillGapsResult) new card\(fillGapsResult == 1 ? "" : "s"), marked as AI-generated and awaiting your review."
                        : "The AI didn't find any concepts in these notes that aren't already covered by an existing card."
                )
            }
        }
        .sheet(isPresented: Binding(get: { refineDeckResult != nil }, set: { if !$0 { refineDeckResult = nil } })) {
            if let refineDeckResult {
                ResultSheet(
                    icon: "checkmark.seal",
                    title: "Refine Deck with AI Complete",
                    leadText: refineDeckResult.isEmpty
                        ? "Every draft checked out fine -- nothing looked like assignment text or an off-topic fragment, and nothing needed a wording cleanup."
                        : (refineDeckResult.wordingRefinedCount > 0
                           ? "Cleaned up wording on \(refineDeckResult.wordingRefinedCount) other card\(refineDeckResult.wordingRefinedCount == 1 ? "" : "s")."
                           : nil),
                    sections: refineDeckSections(refineDeckResult)
                )
            }
        }
        .sheet(item: $cardRefineResult) { message in
            ResultSheet(icon: message.icon, title: message.title, leadText: message.lead)
        }
    }

    private func refineDeckSections(_ result: AppStore.RefineDeckSummary) -> [ResultSheet.Section] {
        var sections: [ResultSheet.Section] = []
        if !result.context.refined.isEmpty {
            sections.append(.init(
                icon: "arrow.triangle.2.circlepath", tint: GRASPColor.success, title: "Rewrote",
                items: result.context.refined.map(\.front)
            ))
        }
        if !result.context.removed.isEmpty {
            sections.append(.init(
                icon: "trash", tint: GRASPColor.rejected, title: "Removed",
                items: result.context.removed.map(\.front)
            ))
        }
        return sections
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
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(deckName)
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .lineLimit(2)
                    compositionLine
                }
                Spacer(minLength: 8)
                // In the pane header rather than the filter row below it:
                // this picker changes what the whole pane *is*, which is
                // the job `CalendarView`'s Month/Week/Agenda picker already
                // does from the same position. The filter row is also gated
                // on having cards, and Overview has to stay reachable for a
                // deck whose cards are all still drafts.
                if hasSourceNotes {
                    Picker("", selection: $contentTab) {
                        ForEach(ContentTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }

            // One row when it fits; otherwise the card actions wrap under
            // the study modes rather than clipping off the edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    studyModeButtons
                    cardActionButtons
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { studyModeButtons; Spacer(minLength: 0) }
                    HStack(spacing: 8) { cardActionButtons; Spacer(minLength: 0) }
                }
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

    @ViewBuilder
    private var studyModeButtons: some View {
        modeButton("Study", "rectangle.stack.fill", prominent: false) { isStudying = true }
            .disabled(dueCount == 0)
        modeButton("Learn", "graduationcap.fill", prominent: dueCount == 0 && activeCount > 0) {
            isLearning = true
        }
        .disabled(activeCount == 0)
        modeButton("Test", "checklist", prominent: false) { testPhase = .setup }
            .disabled(activeCount == 0)
    }

    @ViewBuilder
    private var cardActionButtons: some View {
        // Creating a card belongs to the card list; offering it while
        // reading the overview puts an action in the wrong room.
        if contentTab == .cards {
            newCardButton
        }
        addFilesButton
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

    /// Moved here from the main window toolbar, where it used to sit right
    /// beside "New Deck" -- close enough in icon and position that the two
    /// were easy to mix up. Here it's scoped to the deck actually on
    /// screen (or the whole course, for "All Cards"), same as every other
    /// button in this row.
    private var addFilesButton: some View {
        // "to Course" for the "All Cards" scope -- the files land in the
        // course as a whole (wherever the scanner/manual placement puts
        // them), not literally inside a single deck, so the label should
        // say what actually happens rather than overclaim scope it doesn't
        // have when a single real deck is what's on screen.
        let noun: String = {
            if case .deck = scope { return "Deck" }
            return "Course"
        }()
        // A menu for the same reason "New Card" is one: seeing which files
        // are behind a deck is the other half of the same job, and a
        // separate button would crowd a row that's already full.
        return Menu {
            Button("Add Files to \(noun)…") { onAddFiles() }
                .disabled(store.isImporting)
            Button("Show Files in This \(noun)…") { showingDeckFiles = true }
        } label: {
            HStack(spacing: 5) {
                if store.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "doc.badge.plus").font(.system(size: 11))
                }
                Text("Files")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .font(.system(size: 13, weight: .medium))
            .tracking(-0.1)
            .foregroundStyle(GRASPColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(GRASPColor.hairlineStrong, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add files to this \(noun.lowercased()), or see which files its cards came from")
        .sheet(isPresented: $showingDeckFiles) {
            DeckFilesSheet(
                deckIds: scopeDeckIds, scopeName: deckName, scopeNoun: noun.lowercased()
            )
        }
    }

    /// Clicking "New Card" now opens a menu -- "New Card…" and "Add More
    /// Cards with AI" together, since the two are really the same job
    /// ("get more cards into this deck") by two different means, not two
    /// separate actions competing for space in the row. Collapses back to
    /// a plain one-click button with no menu at all when no generator is
    /// available -- there'd be nothing else to put in it.
    @ViewBuilder
    private var newCardButton: some View {
        if isGeneratorAvailable {
            // A plain `Menu`, not a split button -- every earlier attempt
            // at a "one click makes a card, a separate chevron opens the
            // rest" control ran into the same wall: a `Menu`'s own
            // rendering doesn't reliably respect custom styling or an
            // outer shape once any part of it is involved (a swallowed
            // chevron, a clipped merged background, an invisible icon
            // color, each a different symptom of the same thing). Making
            // the whole button the menu trigger sidesteps all of it: the
            // label here is a fully self-drawn view with its own
            // background and text color, so `Menu` has nothing left to
            // draw or restyle -- it only has to provide the tap target and
            // the popup. "New Card…" is simply the menu's first item now,
            // rather than a separate default action.
            Menu {
                Button("New Card…") { isCreatingCard = true }
                Button {
                    showingGenerateSheet = true
                } label: {
                    Label(isGeneratingCards ? "Adding Cards…" : "Add More Cards with AI", systemImage: "sparkles")
                }
                .disabled(isGeneratingCards || aiActivity != nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("New Card")
                }
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(GRASPColor.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                        .blendMode(.plusLighter)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            modeButton("New Card", "plus", prominent: true) { isCreatingCard = true }
        }
    }

    /// The single unified action that replaced the separate "Refine with
    /// AI" and "Check for Off-Topic Cards" buttons -- one pipeline, not
    /// two: prune/rewrite off-topic drafts first, then clean up wording
    /// on whatever survives (see `AppStore.refineDeckWithAI`). Placed up
    /// here with the other AI actions rather than down in the draft
    /// notice strip, so it's always visible near the deck's own header --
    /// not just when drafts happen to be showing.
    private var refineDeckWithAIButton: some View {
        Button {
            showingRefineDeckConfirmation = true
        } label: {
            HStack(spacing: 5) {
                if isRefiningDeck {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.seal").font(.system(size: 11))
                }
                Text("Refine Deck with AI")
            }
        }
        .buttonStyle(GRASPQuietButton())
        .disabled(isRefiningDeck || aiActivity != nil || draftCount == 0)
        .help(draftCount == 0
              ? "No draft cards to refine right now"
              : "Checks each draft against its own note -- rewrites or removes off-topic definitions, then cleans up wording on the rest")
        .sheet(isPresented: $showingRefineDeckConfirmation) {
            RefineDeckConfirmationSheet(draftCount: draftCount, onConfirm: startRefineDeckWithAI)
        }
    }

    private func startRefineDeckWithAI() {
        let generation = scopeGeneration
        let deckIds = scopeDeckIds
        let run = AIActivity(headline: "Refining \(deckName) with AI", purpose: "refine")
        store.runAIJob(cardJobKey, activity: run) { [store] run in
            let result = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await store.refineDeckWithAI(inDecks: deckIds)
            }
            // Same guard as `runGenerate`: don't let a run started on a
            // deck the user has since switched away from overwrite the
            // deck now on screen.
            guard generation == scopeGeneration else { return }
            // After a stop, the summary still says what was done before it
            // -- unless that was nothing, which the student already knows.
            if !(run.stopRequested && result.isEmpty) { refineDeckResult = result }
            load()
        }
    }

    /// The single-card "Refine with AI" action -- reachable from a card's
    /// own `•••` menu or its right-click menu, whether it's a draft or
    /// long since approved. No `scopeGeneration` guard here the way
    /// `startRefineDeckWithAI`/`runGenerate` have: those run over every
    /// card in scope and must not silently overwrite a *different* deck's
    /// results if the user switches away mid-run, but this touches one
    /// specific card by id -- switching decks while it's in flight can't
    /// make it land on the wrong card.
    private func refineCard(_ card: Card) {
        refiningCardIds.insert(card.id)
        Task {
            let outcome = await store.refineCard(card.id)
            refiningCardIds.remove(card.id)
            switch outcome {
            case .removed:
                cardRefineResult = CardRefineMessage(
                    icon: "trash", title: "Card Removed",
                    lead: "\"\(card.front)\" looked off-topic against its own note, "
                        + "so the AI removed it instead of leaving a bad definition in place."
                )
            case .refined:
                cardRefineResult = CardRefineMessage(
                    icon: "checkmark.seal", title: "Card Refined",
                    lead: "\"\(card.front)\" was checked against its source note and cleaned up."
                )
            case .unavailable:
                cardRefineResult = CardRefineMessage(
                    icon: "exclamationmark.triangle", title: "Couldn't Refine This Card",
                    lead: "This needs an AI connection (Ollama or Apple's on-device model) "
                        + "and a source note to check against -- one of those isn't available right now."
                )
            }
            load()
        }
    }

    /// `maxPerNote: nil` means "use `AppStore`'s own default cap" -- the
    /// "AI Suggested Amount" choice in the sheet below deliberately doesn't
    /// pass an explicit number, so it always tracks whatever that default
    /// actually is rather than a copy of it duplicated here.
    private func runGenerate(maxPerNote: Int?, topic: String?) {
        let generation = scopeGeneration
        let deckIds = scopeDeckIds
        let run = AIActivity(headline: "Adding cards to \(deckName) with AI", purpose: "add")
        store.runAIJob(cardJobKey, activity: run) { [store] run in
            let count = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                if let maxPerNote {
                    await store.generateAdditionalCards(inDecks: deckIds, maxPerNote: maxPerNote, topic: topic)
                } else {
                    await store.generateAdditionalCards(inDecks: deckIds, topic: topic)
                }
            }
            // Bail before touching anything scope-dependent (`cards`,
            // `scopeDeckIds`, ...) if the user has since switched to a
            // different deck or course -- otherwise this stale result
            // would silently overwrite what's now on screen with data for
            // a scope that's no longer even visible.
            guard generation == scopeGeneration else { return }
            if !(run.stopRequested && count == 0) { fillGapsResult = count }
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
                refineDeckWithAIButton
            }
            Button {
                try? store.approveAllDrafts(inDecks: scopeDeckIds)
                load()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle").font(.system(size: 11))
                    Text("Approve all")
                }
            }
            .buttonStyle(GRASPQuietButton())
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
        // Computed once per render, not once per row.
        let cards = visibleCards
        let selection = cards.filter { selectedCardIds.contains($0.id) }.map(\.id)
        return List(selection: $selectedCardIds) {
            ForEach(cards) { card in
                CardRow(
                    card: card,
                    mastery: learnLevels[card.id] ?? .new,
                    siblingDecks: siblingDecks,
                    isRefining: refiningCardIds.contains(card.id),
                    dragCardIds: selectedCardIds.contains(card.id) ? selection : [card.id],
                    onPreview: { previewCardId = card.id },
                    onApprove: { setStatus(card, .active) },
                    onSuspend: { setStatus(card, card.status == .suspended ? .active : .suspended) },
                    onEdit: { editingCard = card },
                    onViewNote: { viewingMaterialId = card.materialId },
                    onDelete: { pendingDeleteCard = card },
                    onMove: { target in
                        try? store.moveCard(card.id, toDeck: target)
                        load()
                    },
                    onRevertContextRefinement: {
                        try? store.revertContextRefinement(card.id)
                        load()
                    },
                    onRefine: { refineCard(card) }
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
            Button(refiningCardIds.contains(card.id) ? "Refining…" : "Refine with AI") { refineCard(card) }
                // Not while a deck-wide job is working through the same
                // cards: both would rewrite this one at once.
                .disabled(refiningCardIds.contains(card.id) || aiActivity != nil)
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
        // A filter is about the deck it was chosen in.
        masteryFilter = .all
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
        dueCount = (try? store.dueCards(inDecks: scopeDeckIds).count) ?? 0
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
        // Against what's on screen, not everything loaded: under "Needs
        // Review", suspending three cards hid them but left them selected,
        // and Delete then offered to delete "0 cards".
        let visible = Set(visibleCards.map(\.id))
        selectedCardIds.formIntersection(visible)
        if let id = previewCardId, !visible.contains(id) {
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

private struct CardRefineMessage: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let lead: String
}

/// "Refine Deck with AI"'s confirmation -- a custom sheet rather than a
/// system `.confirmationDialog`, since the three things this action can
/// do to a card (remove, rewrite, tidy wording) read far more clearly as
/// three short labeled rows than as one dense paragraph.
private struct RefineDeckConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draftCount: Int
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 26))
                    .foregroundStyle(GRASPColor.accent)
                Text("Refine \(draftCount) Draft Card\(draftCount == 1 ? "" : "s") with AI?")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
                Text("Checks every draft against its own note and this course.")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                effectRow(
                    icon: "trash", tint: GRASPColor.accent,
                    text: "Removes cards that aren't real course concepts -- assignment text, a document-specific label."
                )
                effectRow(
                    icon: "arrow.triangle.2.circlepath", tint: GRASPColor.success,
                    text: "Rewrites cards with an off-topic or inaccurate definition."
                )
                effectRow(
                    icon: "text.badge.checkmark", tint: GRASPColor.textSecondary,
                    text: "Cleans up wording on everything else."
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("This can't be undone in bulk -- a removed card is gone, though a rewritten one can be reverted individually from its \"AI Refined\" badge afterward.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Refine Deck") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(GRASPColor.canvas)
    }

    private func effectRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

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
/// Not private: the overview reader uses the same chip for its card links
/// and its "out of date" marker, and a second copy would drift.
private struct CardRow: View {
    let card: Card
    let mastery: LearnEngine.Level
    let siblingDecks: [Deck]
    let isRefining: Bool
    /// What dragging this row carries.
    let dragCardIds: [String]
    let onPreview: () -> Void
    let onApprove: () -> Void
    let onSuspend: () -> Void
    let onEdit: () -> Void
    let onViewNote: () -> Void
    let onDelete: () -> Void
    let onMove: (String) -> Void
    let onRevertContextRefinement: () -> Void
    let onRefine: () -> Void

    // Reserved space, not conditionally inserted -- toggling opacity
    // rather than adding/removing the button from the tree keeps the
    // row's width from jumping the instant the pointer arrives.
    @State private var isHovering = false
    @State private var showingContextRefinementDetail = false

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
            previewButton
            if card.status == .active { masteryBadge }
            contextRefinedBadge
            originBadge
            Menu {
                if card.status == .draft {
                    Button("Approve", action: onApprove)
                }
                Button(card.status == .suspended ? "Reactivate" : "Suspend", action: onSuspend)
                Button("Edit", action: onEdit)
                if card.materialId != nil {
                    Button("View Source Note", action: onViewNote)
                    // Not gated on card.status: an approved card is just
                    // as likely to be clumsily worded or quietly off-topic
                    // as a fresh draft, and this was previously the only
                    // way to ask for a second look at one specific card
                    // rather than the whole deck.
                    Button(isRefining ? "Refining…" : "Refine with AI", action: onRefine)
                        .disabled(isRefining)
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
        .draggable(CardTransfer(cardIds: dragCardIds)) {
            Label(dragCardIds.count == 1 ? card.front : "\(dragCardIds.count) cards",
                  systemImage: "rectangle.on.rectangle")
                .padding(8)
        }
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

    /// Marks a card whose definition was rewritten by the context-check
    /// pipeline (see `AppStore.verifyContext`) -- the original extraction
    /// looked like assignment text or an off-topic fragment, and the AI
    /// redrafted it from the same note. Tapping opens a small popover
    /// showing both versions side by side, with a one-click revert, so
    /// nothing the AI changed is hidden from view.
    @ViewBuilder private var contextRefinedBadge: some View {
        if card.isContextRefined {
            Button {
                showingContextRefinementDetail = true
            } label: {
                Label("AI Refined", systemImage: "checkmark.shield")
                    .labelStyle(.iconOnly).foregroundStyle(GRASPColor.success)
            }
            .buttonStyle(.plain)
            .help("This definition was rewritten by the context checker -- click to compare with the original")
            .popover(isPresented: $showingContextRefinementDetail) {
                contextRefinementDetail
            }
        }
    }

    private var contextRefinementDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI Refined", systemImage: "checkmark.shield")
                .foregroundStyle(GRASPColor.success)
                .font(.system(size: 12, weight: .semibold))

            Text("The original extraction looked like assignment text or an off-topic fragment. The AI rewrote it using this card's own source note.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("ORIGINAL").graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                Text(card.originalBack ?? "")
                    .graspType(.body).foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("CURRENT").graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                Text(card.back)
                    .graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Revert to Original") {
                onRevertContextRefinement()
                showingContextRefinementDetail = false
            }
            .buttonStyle(GRASPQuietButton())
        }
        .padding(16)
        .frame(width: 320)
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
struct DuplicateReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groups: [AppStore.DuplicateGroup]
    let onMerge: (_ merges: [AppStore.DuplicateMerge]) -> Void

    /// Value per group: the id to keep (folding every other member into
    /// it), or `nil` meaning "keep all of them, skip this group".
    @State private var keepChoice: [String: String?] = [:]

    private var totalToMerge: Int {
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
                Text("\(totalToMerge) card\(totalToMerge == 1 ? "" : "s") will be merged into the one kept")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Merge \(totalToMerge) Cards", role: .destructive) {
                    let merges = groups.compactMap { group -> AppStore.DuplicateMerge? in
                        guard let choice = keepChoice[group.id, default: defaultChoice(for: group)] else { return nil }
                        let losers = group.cards.filter { $0.id != choice }.map(\.id)
                        guard !losers.isEmpty else { return nil }
                        return AppStore.DuplicateMerge(survivorId: choice, losingIds: losers)
                    }
                    onMerge(merges)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(totalToMerge == 0)
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
                    onSave(card)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
