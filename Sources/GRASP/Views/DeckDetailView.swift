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
    /// Imports a study guide for an exam in this course (`ContentView`
    /// owns the file panel, as for `onAddFiles`).
    var onAddStudyGuide: () -> Void = {}
    /// Called after this deck is deleted, so the deck list can move off it.
    var onDeckDeleted: () -> Void = {}
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
    /// Which refine the confirmation sheet is open for: only the drafts
    /// (from the awaiting-review strip) or every card in the deck.
    @State private var refineConfirmation: RefineScope?
    private enum RefineScope: String, Identifiable {
        case drafts, everything
        var id: String { rawValue }
    }
    @State private var fillGapsResult: Int?
    @State private var showingGenerateSheet = false
    @State private var showingCodeQuestions = false
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

    enum MasteryFilter: String, CaseIterable, Identifiable {
        case all = "All", needsReview = "Needs review", understood = "Understood"
        var id: String { rawValue }
    }

    /// Which half of the deck is on screen. The deck header, the draft
    /// notice and the duplicate notice sit above this and are shared by
    /// both -- they're facts about the deck, not about either view of it.
    @State private var contentTab: ContentTab = .cards
    @Namespace private var tabSwitch

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
    @State private var problemCount = 0
    /// Notes whose overview was written before the note last changed.
    @State private var staleOverviewCount = 0
    /// Notes in scope with an overview or one that could be written.
    @State private var overviewNoteCount = 0
    /// Set by the Overview toolbar ("Rewrite with AI", "Rewrite out-of-date
    /// overviews"); the Overview tab picks it up and asks before writing.
    @State private var overviewRequest: OverviewRewriteRequest?
    @State private var deletingDeck: Deck?
    @State private var deletingDeckCardCount = 0
    /// While set, approving the previewed draft moves on to the next one.
    @State private var reviewingDrafts = false
    @State private var unfinishedTest: Study.UnfinishedTest?

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
                .font(.graspUI(size: 14))
                .foregroundStyle(GRASPColor.textSecondary)
        }
        .menuStyle(.borderlessButton)
        // A borderless menu tints its icon with the window's yellow.
        .tint(GRASPColor.textSecondary)
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
                        FilterPills(selection: $masteryFilter)
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
                        onApprove: { approveFromPreview(card) },
                        onViewNote: { viewingMaterialId = card.materialId },
                        onClose: { previewCardId = nil; reviewingDrafts = false }
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
            switch contentTab {
            case .cards:
                cardsTab
            case .overview:
                DeckOverviewView(scope: scope, rewriteRequest: $overviewRequest) { cardId in
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
        // The toolbar's menus belong to the view they were opened in.
        .onChange(of: contentTab) { MenuAnchor.closeOpenMenu() }
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
                TestSetupSheet(deckIds: scopeDeckIds, deckName: deckName, onResume: { id in
                    testPhase = TestPhase.resuming(id, store: store)
                }) { attemptId, questions, aiWarning in
                    testPhase = .running(attemptId: attemptId, questions: questions, aiWarning: aiWarning)
                }
            case .running(let attemptId, let questions, let aiWarning, let answered):
                TestRunView(attemptId: attemptId, deckName: deckName, questions: questions, aiWarning: aiWarning,
                        answered: answered) { graded in
                    _ = try? store.finishTest(attemptId: attemptId)
                    testPhase = .results(attemptId: attemptId, graded: graded)
                }
            case .results(let attemptId, let graded):
                TestResultsView(deckName: deckName, attemptId: attemptId, graded: graded, deckIds: scopeDeckIds) { id, questions in
                    testPhase = .running(attemptId: id, questions: questions, aiWarning: nil)
                }
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
        .sheet(isPresented: $showingCodeQuestions, onDismiss: load) {
            PracticeProblemsSheet(deckIds: scopeDeckIds, scopeName: deckName, courseId: courseId)
        }
        .sheet(item: $refineConfirmation) { scope in
            RefineDeckConfirmationSheet(
                cardCount: refineCount(scope), includesApproved: scope == .everything,
                onConfirm: { startRefineDeckWithAI(includeApproved: scope == .everything) }
            )
        }
        .sheet(isPresented: Binding(get: { refineDeckResult != nil }, set: { if !$0 { refineDeckResult = nil } })) {
            if let refineDeckResult {
                ResultSheet(
                    icon: "checkmark.seal",
                    title: "Refine Deck with AI Complete",
                    leadText: refineDeckResult.isEmpty
                        ? "Every card checked out fine -- nothing looked like assignment text or an off-topic fragment, and nothing needed a wording cleanup."
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
                        .font(.graspDisplay(30))
                        .tracking(-0.6)
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
                    contentTabSwitch
                }
            }

            // Study modes on the left; on the right, what this view can do
            // -- the AI button, Add (Cards) or Edit (Overview), and ⋯. One
            // row when it fits, otherwise two rather than clipping.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    studyModeButtons
                    Spacer(minLength: 16)
                    viewActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { studyModeButtons; Spacer(minLength: 0) }
                    HStack(spacing: 8) { viewActions; Spacer(minLength: 0) }
                }
            }
            .background {
                // ⇧⌘N for New card, also while the Add menu is closed.
                Button("New card") { isCreatingCard = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
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
        modeButton("Study", "rectangle.stack.fill", prominent: true) { isStudying = true }
            .disabled(dueCount == 0)
        modeButton("Learn", "graduationcap.fill", prominent: false) {
            isLearning = true
        }
        .disabled(activeCount == 0)
        if let unfinishedTest {
            modeButton("Continue Test (\(unfinishedTest.answered)/\(unfinishedTest.total))", "play.fill", prominent: false) {
                testPhase = TestPhase.resuming(unfinishedTest.attemptId, store: store)
            }
            .help("Pick up the test you left, at the next question")
        }
        modeButton("Test", "checklist", prominent: false) { testPhase = .setup }
            .disabled(activeCount == 0)
            .help("A graded quiz on this deck's cards")
    }

    /// The right side of the toolbar, which follows the Cards / Overview
    /// switch: the AI button, then Add or Edit, then ⋯.
    @ViewBuilder
    private var viewActions: some View {
        aiButton
        if contentTab == .cards { addMenuButton } else { editMenuButton }
        overflowMenu
    }

    /// AI is GRASP's headline feature, so it gets its own button: an
    /// outlined pill (never filled -- Study is the one yellow button) with
    /// the yellow sparkle. Cards: write practice questions. Overview:
    /// rewrite the overviews.
    private var aiButton: some View {
        let onCards = contentTab == .cards
        return Button {
            if onCards { showingCodeQuestions = true } else { requestOverviewRewrite(.all) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: AIGlyph.symbol)
                    .font(.graspUI(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.accent)
                Text(onCards ? "Generate questions" : "Rewrite with AI")
            }
        }
        .buttonStyle(GRASPQuietButton())
        .disabled(!onCards && (!isGeneratorAvailable || overviewNoteCount == 0))
        .help(onCards
              ? "Write practice questions from this deck's notes -- code to complete, calculations, matrices -- that tests mix in"
              : isGeneratorAvailable ? "Rewrite every overview in this \(filesNoun.lowercased()) with AI"
                                     : "Set up an AI model in Settings to write overviews")
    }

    private func requestOverviewRewrite(_ request: OverviewRewriteRequest) {
        contentTab = .overview
        overviewRequest = request
    }

    /// Housekeeping, the same in both views. Delete is last, separated, in
    /// coral.
    private var overflowMenu: some View {
        let noun = filesNoun
        return PillMenu(title: "More", systemImage: "ellipsis", showsTitle: false) {
            var items: [PillMenuItem] = [
                .action(draftCount > 0 ? "Approve all drafts (\(draftCount))" : "Approve all drafts",
                        systemImage: "checkmark.circle", disabled: draftCount == 0) {
                    try? store.approveAllDrafts(inDecks: scopeDeckIds)
                    load()
                },
                .action("Show files in this \(noun.lowercased())…", systemImage: "doc.on.doc") {
                    showingDeckFiles = true
                },
                .action(problemCount > 0 ? "Problems (\(problemCount))" : "Problems", systemImage: "function") {
                    showingCodeQuestions = true
                },
            ]
            if !duplicateGroups.isEmpty {
                items.append(.action("Review duplicates…", systemImage: "square.on.square") {
                    showingDuplicateReview = true
                })
            }
            if case .deck(let id) = scope {
                items.append(.divider)
                items.append(.action("Delete deck…", systemImage: "trash", destructive: true) {
                    beginDeleteDeck(id)
                })
            }
            return items
        }
        .sheet(isPresented: $showingDeckFiles) {
            DeckFilesSheet(deckIds: scopeDeckIds, scopeName: deckName, scopeNoun: noun.lowercased())
        }
        .sheet(item: $deletingDeck) { deck in
            DeckDeleteSheet(deck: deck, cardCount: deletingDeckCardCount, siblings: siblingDecks) { targetId in
                try? store.deleteDeck(deck.id, migrateCardsTo: targetId)
                onDeckDeleted()
            }
        }
    }

    /// The items both menus end with: files and study guides can be added
    /// from either view, since Overview doesn't show the cards.
    private var addSourceItems: [PillMenuItem] {
        [
            .action("Add files to this \(filesNoun.lowercased())…", systemImage: "doc.badge.plus",
                    disabled: store.isImporting) { onAddFiles() },
            .action("New study guide…", systemImage: "graduationcap",
                    help: "Add a study guide for an exam in this course") { onAddStudyGuide() },
        ]
    }

    /// Cards view: everything that puts cards or questions into the deck.
    private var addMenuButton: some View {
        PillMenu(title: "Add", systemImage: "plus", isBusy: store.isImporting) {
            let aiBusy = aiActivity != nil
            var items: [PillMenuItem] = [
                .action("Generate questions with AI", ai: true,
                        help: "Practice questions from this deck's notes, checked before they're kept") {
                    showingCodeQuestions = true
                },
                .action(isGeneratingCards ? "Adding cards…" : "Add more cards with AI", ai: true,
                        disabled: !isGeneratorAvailable || isGeneratingCards || aiBusy,
                        help: isGeneratorAvailable ? "New draft flashcards from this deck's notes"
                                                   : "Set up an AI model in Settings first") {
                    showingGenerateSheet = true
                },
                .action(isRefiningDeck ? "Refining…" : "Refine deck with AI", ai: true,
                        disabled: !isGeneratorAvailable || isRefiningDeck || aiBusy || refineCount(.everything) == 0,
                        help: "Checks every card against its own note and cleans up wording") {
                    refineConfirmation = .everything
                },
                .action("New card…", systemImage: "square.and.pencil",
                        shortcut: (key: "n", modifiers: [.command, .shift])) { isCreatingCard = true },
                .divider,
            ]
            items += addSourceItems
            return items
        }
        .help("Generate questions, add cards, files or a study guide")
    }

    /// Overview view: rewriting the overviews, and adding sources.
    private var editMenuButton: some View {
        PillMenu(title: "Edit", systemImage: "pencil", isBusy: store.isImporting) {
            var items: [PillMenuItem] = [
                .action("Rewrite with AI", ai: true,
                        disabled: !isGeneratorAvailable || overviewNoteCount == 0,
                        help: "Rewrite every overview in this \(filesNoun.lowercased())") {
                    requestOverviewRewrite(.all)
                },
                .action(staleOverviewCount > 0 ? "Rewrite out-of-date overviews (\(staleOverviewCount))"
                                               : "Rewrite out-of-date overviews", ai: true,
                        disabled: !isGeneratorAvailable || staleOverviewCount == 0,
                        help: "Only the notes that changed since their overview was written") {
                    requestOverviewRewrite(.stale)
                },
                .divider,
            ]
            items += addSourceItems
            return items
        }
        .help("Rewrite overviews, add files or a study guide")
    }

    /// The same flow as the deck list's Delete: an empty deck goes at once,
    /// one with cards asks where they should go.
    private func beginDeleteDeck(_ id: String) {
        guard let deck = (try? store.deck(id)) ?? nil else { return }
        let count = (try? store.deckCardCount(id)) ?? 0
        if count == 0 {
            try? store.deleteDeck(id, migrateCardsTo: nil)
            onDeckDeleted()
        } else {
            deletingDeckCardCount = count
            deletingDeck = deck
        }
    }

    /// The Cards / Overview switch: two large, labelled buttons rather than
    /// a small segmented control, since it changes what the whole pane is.
    private var contentTabSwitch: some View {
        HStack(spacing: 4) {
            ForEach(ContentTab.allCases) { tab in
                let selected = contentTab == tab
                Button {
                    withAnimation(Motion.snappy) { contentTab = tab }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab == .cards ? "rectangle.stack.fill" : "doc.text.fill")
                            .font(.graspUI(size: 13))
                        Text(tab.rawValue)
                            .font(.graspUI(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(selected ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background {
                        if selected {
                            Capsule().fill(GRASPColor.surfaceRaised)
                                .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong))
                                .matchedGeometryEffect(id: "content-tab", in: tabSwitch)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(GRASPColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(GRASPColor.hairline))
    }

    /// Reads as a sentence -- "231 cards · 12 due · 40 understood" -- with
    /// only the figure that needs attention carrying the accent.
    private var compositionLine: some View {
        HStack(spacing: 5) {
            // Approved cards and drafts counted separately: "0 cards" over a
            // list of 11 drafts waiting for review read as a contradiction.
            if activeCount > 0 || draftCount == 0 {
                Text("\(activeCount) card\(activeCount == 1 ? "" : "s")")
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            if draftCount > 0 {
                if activeCount > 0 { Text("·").foregroundStyle(GRASPColor.textTertiary) }
                Text("\(draftCount) draft\(draftCount == 1 ? "" : "s") to review")
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            if dueCount > 0 {
                Text("·").foregroundStyle(GRASPColor.textTertiary)
                Text("\(dueCount) due").foregroundStyle(GRASPColor.textPrimary)
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
            Image(systemName: symbol).font(.graspUI(size: 11))
            Text(title)
        }
        if prominent {
            Button(action: action) { label }.buttonStyle(GRASPProminentButton())
        } else {
            Button(action: action) { label }.buttonStyle(GRASPQuietButton())
        }
    }

    /// "Files" or "Course" -- where added files land: a single deck, or
    /// the course as a whole for "All Cards".
    private var filesNoun: String {
        if case .deck = scope { return "Deck" }
        return "Course"
    }

    private func refineCount(_ scope: RefineScope) -> Int {
        scope == .drafts ? draftCount : draftCount + activeCount
    }

    private func startRefineDeckWithAI(includeApproved: Bool) {
        let generation = scopeGeneration
        let deckIds = scopeDeckIds
        let run = AIActivity(headline: "Refining \(deckName) with AI", purpose: "refine")
        store.runAIJob(cardJobKey, activity: run) { [store] run in
            let result = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await store.refineDeckWithAI(inDecks: deckIds, includeApproved: includeApproved)
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

    /// What needs attention in the cards, in one line at the top of the
    /// list -- drafts waiting for review, possible duplicates -- with one
    /// action. It scrolls away with the cards rather than staying pinned.
    /// (The Overview has its own strip, for overviews out of date.)
    private var statusStrip: some View {
        var parts: [String] = []
        if draftCount > 0 { parts.append("\(draftCount) draft\(draftCount == 1 ? "" : "s") to review") }
        if !duplicateGroups.isEmpty {
            parts.append("\(duplicateGroups.count) possible duplicate\(duplicateGroups.count == 1 ? "" : "s")")
        }
        return HStack(spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.graspUI(size: 12))
                .foregroundStyle(GRASPColor.textTertiary)
            Text(parts.joined(separator: " · "))
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if draftCount > 0 {
                Button("Review drafts") { startReviewingDrafts() }
                    .buttonStyle(GRASPQuietButton())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
    }

    /// Opens the first draft in the preview; approving it there moves on to
    /// the next, until none are left.
    private func startReviewingDrafts() {
        masteryFilter = .all
        guard let first = visibleCards.first(where: { $0.status == .draft }) else { return }
        reviewingDrafts = true
        selectedCardIds = [first.id]
        previewCardId = first.id
    }

    private func approveFromPreview(_ card: Card) {
        setStatus(card, .active)
        guard reviewingDrafts else { return }
        if let next = visibleCards.first(where: { $0.status == .draft }) {
            selectedCardIds = [next.id]
            previewCardId = next.id
        } else {
            reviewingDrafts = false
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
            if draftCount > 0 || !duplicateGroups.isEmpty {
                statusStrip
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }
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
                // GRASP draws the selection itself -- a soft yellow wash --
                // because the table's own highlight is the system accent
                // (blue) and ignores `.tint`. Selection behaviour (shift- and
                // cmd-click, the context menu's selection) is still the
                // table's; only the drawing changes.
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selectedCardIds.contains(card.id) ? GRASPColor.accentSoft : .clear)
                        .padding(.horizontal, 4)
                )
                .background(TableHighlightRemover())
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
        case .exam(let id, let examEventId):
            courseId = id
            deckName = store.calendarEvent(examEventId)?.title ?? "Exam"
        }
        load()
    }

    private func load() {
        switch scope {
        case .deck(let id):
            scopeDeckIds = [id]
        case .course, .exam:
            // Re-derived every load, not just once per `.task(id: scope)`
            // -- a deck created or deleted in this course (or mapped to
            // this exam) while it's already open must be picked up on the
            // very next `store.revision` change, the same way a card being
            // added or removed already is.
            scopeDeckIds = store.deckIds(in: scope)
        }
        cards = (try? store.cards(inDecks: scopeDeckIds)) ?? []
        learnLevels = (try? store.learnLevels(forDecks: scopeDeckIds)) ?? [:]
        dueCount = (try? store.dueCards(inDecks: scopeDeckIds).count) ?? 0
        problemCount = store.codeQuestionCount(inDecks: scopeDeckIds)
        unfinishedTest = store.unfinishedTest(forDecks: scopeDeckIds)
        if let courseId {
            let allDecksInCourse = (try? store.decks(inCourse: courseId)) ?? []
            switch scope {
            case .deck(let id):
                siblingDecks = allDecksInCourse.filter { $0.id != id }
            case .course, .exam:
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
        let overview = hasSourceNotes ? try? store.deckOverview(inDecks: scopeDeckIds) : nil
        staleOverviewCount = overview?.staleEntries.count ?? 0
        overviewNoteCount = (overview?.entries.count ?? 0) + (overview?.writable.count ?? 0)
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
    let cardCount: Int
    let includesApproved: Bool
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.graspUI(size: 26))
                    .foregroundStyle(GRASPColor.accent)
                Text(includesApproved
                     ? "Refine \(cardCount) Card\(cardCount == 1 ? "" : "s") with AI?"
                     : "Refine \(cardCount) Draft Card\(cardCount == 1 ? "" : "s") with AI?")
                    .font(.graspUI(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
                Text(includesApproved
                     ? "Checks every card in this deck, drafts and approved, against its own note and this course. Review history is kept."
                     : "Checks every draft against its own note and this course.")
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

            if let quotaWarning = AIQuotaEstimate.warning(
                needed: AIQuotaEstimate.contextCheckRequests(cards: cardCount)
                    + AIQuotaEstimate.refineRequests(cards: cardCount),
                mode: AIPreferences.mode
            ), AIKeyStore.read() != nil {
                Label(quotaWarning, systemImage: "gauge.with.dots.needle.67percent")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                .font(.graspUI(size: 12, weight: .semibold))
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
            Text("Add More Cards with AI").font(.graspHeadline)
            Text("The AI looks for concepts your notes mention but that don't have a card yet.")
                .font(.graspCallout)
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
                Text("Focus on (optional)").font(.graspCaption).foregroundStyle(.secondary)
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
                    .font(.graspUI(size: 10, weight: .semibold))
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
                .font(.graspUI(size: 19, weight: .medium))
                .foregroundStyle(GRASPColor.textPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            if isFlipped {
                Rectangle()
                    .fill(GRASPColor.hairlineStrong)
                    .frame(width: 28, height: 1)
                    .padding(.vertical, 16)

                Text(card.back)
                    .font(.graspUI(size: 15))
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
        )
        .contentShape(Rectangle())
        .onTapGesture { isFlipped.toggle() }
    }

    private var flipHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.tap")
                .font(.graspUI(size: 9))
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
        case .draft: PreviewChip(text: "Draft", tint: GRASPColor.textSecondary, tintSoft: GRASPColor.inset)
        case .suspended: PreviewChip(text: "Rejected", tint: GRASPColor.rejected, tintSoft: GRASPColor.rejectedSoft)
        case .active: EmptyView()
        }
    }

    private var masteryChip: some View {
        Group {
            if mastery == .mastered {
                PreviewChip(text: "Understood", tint: GRASPColor.success, tintSoft: GRASPColor.successSoft)
            } else {
                PreviewChip(text: "Needs review", tint: GRASPColor.textSecondary, tintSoft: GRASPColor.inset)
            }
        }
    }

    /// Permanent, not tied to `.draft` status -- this is the fact worth
    /// remembering about a card long after it's approved: its content
    /// wasn't in the note verbatim, the AI proposed it.
    @ViewBuilder private var originChip: some View {
        if card.origin == .aiGenerated {
            PreviewChip(
                text: "AI-generated", tint: GRASPColor.textSecondary, tintSoft: GRASPColor.inset, icon: "sparkles"
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
                .font(.graspUI(size: 12))
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
/// Turns off the system selection highlight of the table a SwiftUI `List`
/// is drawn with, so the list can draw its own (`listRowBackground`).
/// Placed inside a row: it finds the enclosing `NSTableView` once it's in a
/// window. Idempotent, and changes nothing but how selection is drawn.
private struct TableHighlightRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            if let table = view as? NSTableView, table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// All / Needs review / Understood as small text pills. The selected one
/// is raised, not yellow -- yellow on this screen belongs to Study.
private struct FilterPills: View {
    @Binding var selection: DeckDetailView.MasteryFilter
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DeckDetailView.MasteryFilter.allCases) { filter in
                let selected = selection == filter
                Button {
                    withAnimation(Motion.choose(Motion.snappy, reduceMotion: reduceMotion)) { selection = filter }
                } label: {
                    Text(filter.rawValue)
                        .font(.graspUI(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? GRASPColor.textPrimary : GRASPColor.textTertiary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule().fill(GRASPColor.surfaceRaised)
                                    .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong))
                                    .matchedGeometryEffect(id: "filter", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(GRASPColor.inset))
    }
}

/// A card whose term is an attachment's filename ("FAUCafeCode.zip") shows
/// the name as words ("FAU Cafe Code") with the file as a muted source
/// label. Only archive and document extensions count: "__init__.py",
/// "locustfile.py" or "cin.ignore" are real concepts that happen to have a
/// dot in them. Display only -- the card itself is unchanged.
enum CardTermDisplay {
    private static let attachmentExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx",
        "key", "pages", "numbers",
    ]

    static func split(_ front: String) -> (term: String, file: String?) {
        let trimmed = front.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), let dot = trimmed.lastIndex(of: "."),
              attachmentExtensions.contains(trimmed[trimmed.index(after: dot)...].lowercased())
        else { return (front, nil) }
        let stem = String(trimmed[..<dot])
        let words = humanize(stem)
        return words.isEmpty ? (front, nil) : (words, trimmed)
    }

    /// "FAUCafeCode" -> "FAU Cafe Code", "solid_principles-v2" -> "solid principles v2".
    private static func humanize(_ stem: String) -> String {
        var words: [String] = []
        var current = ""
        let chars = Array(stem)
        for (i, c) in chars.enumerated() {
            if c == "_" || c == "-" || c == "." {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let prev = current.last
            // A new word at lower->Upper ("cafeCode") and at the last capital
            // of an acronym before a lowercase letter ("FAUCafe").
            if c.isUppercase, let prev,
               prev.isLowercase || prev.isNumber || (prev.isUppercase && (next?.isLowercase ?? false)) {
                words.append(current); current = ""
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }
}

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
                let term = CardTermDisplay.split(card.front)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(term.term)
                        .graspType(.rowTitle)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let file = term.file {
                        Label(file, systemImage: "paperclip")
                            .font(.graspUI(size: 11.5))
                            .foregroundStyle(GRASPColor.textTertiary)
                            .lineLimit(1)
                            .help("Source file: \(file)")
                    }
                }
                Text(card.back)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Status marks stay; the actions (preview, approve, the menu)
            // appear only while the pointer is on the row. Their space is
            // reserved, so the row doesn't jump when they show.
            if card.status == .active && mastery == .mastered { masteryBadge }
            contextRefinedBadge
            originBadge
            previewButton
            approveButton
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
            .menuIndicator(.hidden)
            .tint(GRASPColor.textSecondary)
            .frame(width: 28)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .help("Card actions")
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
                .font(.graspUI(size: 12))
                .foregroundStyle(GRASPColor.textSecondary)
                .frame(width: 24, height: 24)
                .background(GRASPColor.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Preview")
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }

    /// Approve, for a draft -- on hover, beside Preview.
    @ViewBuilder private var approveButton: some View {
        if card.status == .draft {
            Button(action: onApprove) {
                Image(systemName: "checkmark")
                    .font(.graspUI(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.success)
                    .frame(width: 24, height: 24)
                    .background(GRASPColor.surface, in: Circle())
                    .overlay(Circle().strokeBorder(GRASPColor.success.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .help("Approve")
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
    }

    /// The sole approval-status signal on a row -- amber for pending
    /// (awaiting review), a muted rose for rejected (suspended), and the
    /// existing mastery-based tint for an approved/active card. Replaces a
    /// second, redundant circular icon that used to sit beside this same
    /// bar and say the same thing.
    private var railTint: Color {
        switch card.status {
        case .draft: return GRASPColor.hairlineStrong
        case .suspended: return GRASPColor.rejected
        case .active: return mastery == .mastered ? GRASPColor.success : GRASPColor.textTertiary
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
                Label("Needs review", systemImage: "circle")
                    .foregroundStyle(GRASPColor.textTertiary)
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
                .labelStyle(.iconOnly).foregroundStyle(GRASPColor.textTertiary)
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
                .font(.graspUI(size: 12, weight: .semibold))

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
/// underlying delete is a soft one.
///
/// Each group has three possible outcomes: keep one card (the others fold
/// into it), keep all of them (the group is left alone), or keep none --
/// tapping the card that's selected deselects it, and the whole group is
/// deleted. Cards are soft-deleted either way, so review history survives
/// and a re-import of the same notes doesn't bring them back.
struct DuplicateReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groups: [AppStore.DuplicateGroup]
    let onMerge: (_ merges: [AppStore.DuplicateMerge]) -> Void

    private enum Choice: Equatable {
        case keep(String)
        case keepAll
        case deleteAll
    }

    @State private var choices: [String: Choice] = [:]
    @State private var confirmingDelete = false

    private func choice(for group: AppStore.DuplicateGroup) -> Choice {
        choices[group.id] ?? defaultChoice(for: group)
    }

    /// Cards folded into a kept card.
    private var mergedCount: Int {
        groups.reduce(0) { total, group in
            guard case .keep(let id) = choice(for: group) else { return total }
            return total + group.cards.filter { $0.id != id }.count
        }
    }

    /// Cards in groups where nothing is kept.
    private var deletedCount: Int {
        groups.reduce(0) { total, group in
            choice(for: group) == .deleteAll ? total + group.cards.count : total
        }
    }

    private var summary: String {
        var parts: [String] = []
        if mergedCount > 0 { parts.append("\(mergedCount) merged into the card kept") }
        if deletedCount > 0 { parts.append("\(deletedCount) deleted outright") }
        return parts.isEmpty ? "Nothing will change" : parts.joined(separator: ", ")
    }

    private var actionTitle: String {
        switch (mergedCount > 0, deletedCount > 0) {
        case (true, true): return "Merge and Delete"
        case (false, true): return "Delete \(deletedCount) Cards"
        default: return "Merge \(mergedCount) Cards"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Duplicates").font(.graspHeadline)
                Text("\(groups.count) group\(groups.count == 1 ? "" : "s") found. Pick the card to keep in each group, "
                     + "or tap the selected card again to keep none and delete them all.")
                    .font(.graspCallout)
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
                Text(summary)
                    .font(.graspCaption)
                    .foregroundStyle(deletedCount > 0 ? GRASPColor.rejected : .secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(actionTitle, role: .destructive) {
                    if deletedCount > 0 { confirmingDelete = true } else { apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mergedCount + deletedCount == 0)
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .confirmationDialog(
            "Delete \(deletedCount) card\(deletedCount == 1 ? "" : "s") you chose to keep none of?",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete \(deletedCount) Card\(deletedCount == 1 ? "" : "s")", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They leave every deck. Their review history is kept, and importing the same notes again won't bring them back.")
        }
    }

    private func apply() {
        let merges = groups.compactMap { group -> AppStore.DuplicateMerge? in
            switch choice(for: group) {
            case .keepAll:
                return nil
            case .deleteAll:
                return AppStore.DuplicateMerge(survivorId: nil, losingIds: group.cards.map(\.id))
            case .keep(let id):
                let losers = group.cards.filter { $0.id != id }.map(\.id)
                return losers.isEmpty ? nil : AppStore.DuplicateMerge(survivorId: id, losingIds: losers)
            }
        }
        onMerge(merges)
        dismiss()
    }

    private func groupBlock(_ group: AppStore.DuplicateGroup) -> some View {
        let current = choice(for: group)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.cards.count) near-identical cards").font(.graspSubheadline.weight(.medium))
                if group.hasCompetingHistory {
                    Text("· multiple have review history").font(.graspCaption).foregroundStyle(.orange)
                }
                Spacer()
                if current == .deleteAll {
                    Label("All \(group.cards.count) will be deleted", systemImage: "trash")
                        .font(.graspCaption.weight(.semibold))
                        .foregroundStyle(GRASPColor.rejected)
                }
            }
            VStack(spacing: 6) {
                ForEach(group.cards) { card in
                    memberRow(card, group: group, current: current)
                }
                HStack(spacing: 14) {
                    Button(current == .keepAll ? "Keeping all" : "Keep all instead") {
                        choices[group.id] = .keepAll
                    }
                    Button(current == .deleteAll ? "Deleting all" : "Delete all") {
                        choices[group.id] = .deleteAll
                    }
                    .foregroundStyle(GRASPColor.rejected)
                    Spacer()
                }
                .buttonStyle(.link)
                .font(.graspCaption)
            }
        }
        .padding(12)
        .background(current == .deleteAll ? GRASPColor.rejectedSoft.opacity(0.5) : GRASPColor.surface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(current == .deleteAll ? GRASPColor.rejected.opacity(0.5) : GRASPColor.hairline))
    }

    private func memberRow(_ card: Card, group: AppStore.DuplicateGroup, current: Choice) -> some View {
        let isKept = current == .keep(card.id)
        let isDeleted = current == .deleteAll
        return Button {
            // Tapping the card that's kept deselects it: keep none.
            choices[group.id] = isKept ? .deleteAll : .keep(card.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isKept ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isKept ? GRASPColor.accent : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.front).font(.graspCallout.weight(.medium)).strikethrough(isDeleted)
                    Text(card.back).font(.graspCaption).foregroundStyle(.secondary).lineLimit(3)
                    Text(memberMeta(card))
                        .font(.graspCaption2)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isKept ? GRASPColor.textPrimary : GRASPColor.textTertiary)
            .opacity(isKept || isDeleted ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    private func memberMeta(_ card: Card) -> String {
        var parts = [card.status == .draft ? "Pending" : card.status == .suspended ? "Rejected" : "Approved"]
        parts.append(card.reps == 0 ? "no reviews" : "\(card.reps) review\(card.reps == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// A group where two or more cards already carry real review history
    /// defaults to "keep all" rather than the smart pick -- there's no
    /// safe automatic guess about which study history to discard, so this
    /// forces a deliberate choice instead of a silent one.
    private func defaultChoice(for group: AppStore.DuplicateGroup) -> Choice {
        group.hasCompetingHistory ? .keepAll : .keep(group.suggestedKeepId)
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
            Text("New Card").font(.graspHeadline)

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

            Text("Front").font(.graspCaption).foregroundStyle(.secondary)
            TextEditor(text: $front).frame(height: 60).border(.separator)
            Text("Back").font(.graspCaption).foregroundStyle(.secondary)
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
            Text("Edit Card").font(.graspHeadline)
            Text("Front").font(.graspCaption).foregroundStyle(.secondary)
            TextEditor(text: $card.front).frame(height: 60).border(.separator)
            Text("Back").font(.graspCaption).foregroundStyle(.secondary)
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
