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
    /// Chosen on the Study finish screen; run once that sheet has closed.
    @State private var pendingNextStep: StudyNextStep?
    @State private var learnFocus: Set<String> = []
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
    /// Why the last "Generate cards" run failed, shown as a strip with
    /// Retry -- a failure is never reported as "No Gaps Found". The request
    /// is kept for the retry.
    @State private var additionFailure: String?
    @State private var lastAddition: (maxPerNote: Int?, topic: String?)?
    /// Cards the current (or last) generation run has written, newest
    /// first -- shown at the top of the list, so a run is visible where the
    /// eye already is. Cleared when the scope changes.
    @State private var recentAIIds: [String] = []
    /// Of those, the ones that have landed but whose row hasn't slid in yet.
    @State private var hiddenNewIds: Set<String> = []
    /// Every card id the live view has seen, so only arrivals animate.
    @State private var seenIds: Set<String> = []
    /// The batch of arrivals still sliding in. Left out of every count until
    /// the whole batch is on screen (`DeckCardCounts`).
    @State private var countHeldIds: Set<String> = []
    /// The deck pane's width, to switch the toolbar to icons when it is tight.
    /// Worked out from the window, not measured from this view: a pane whose
    /// contents won't shrink would only ever measure as wide as they are.
    @Environment(\.deckPaneWidth) private var paneWidth
    /// Title of the note the newest card came from.
    @State private var liveSourceTitle: String?
    /// Note titles for AI-made cards' "from <note>" line.
    @State private var sourceTitles: [String: String] = [:]
    /// Flags on parser-made drafts ("Looks like a duplicate of ...", "This
    /// front looks like a heading."). Shown, never acted on.
    @State private var reviewNotes: [String: String] = [:]
    /// False until the first `load()` -- an empty deck's state must not
    /// flash while the cards are still being read.
    @State private var hasLoaded = false
    /// Notes in this course, for the empty deck's "Add files" state.
    @State private var courseFileCount = 0
    /// Why the last empty-deck generation didn't produce cards.
    @State private var generationNotice: GenerationNotice?
    private struct GenerationNotice { let message: String; let isError: Bool }
    private var reduceMotion: Bool { Motion.isReduced }
    @State private var showingGenerateSheet = false
    @State private var learnLevels: [String: LearnEngine.Level] = [:]
    /// The meter's view of each card, and the note filter a "Weakest
    /// notes" row sets (nil: not filtering; `.some(nil)` is the "Other" group).
    @State private var understanding: [DeckUnderstanding.Card] = []
    @State private var noteFilter: String??
    /// Suspended cards' states, so their rows can show the meter in red.
    @State private var suspendedStates: [String: UnderstandingState] = [:]
    /// Readable titles for the weakest-notes rows.
    @State private var noteTitles: [String: String] = [:]
    private var understandingById: [String: UnderstandingState] {
        Dictionary(understanding.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
            .merging(suspendedStates) { first, _ in first }
    }
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
        case all = "All", drafts = "Drafts", due = "Due", understood = "Understood"
        var id: String { rawValue }
    }

    /// Which half of the deck is on screen. The deck header, the draft
    /// notice and the duplicate notice sit above this and are shared by
    /// both -- they're facts about the deck, not about either view of it.
    /// The last tab used, across decks and launches; Cards the first time.
    @State private var contentTab: ContentTab = ContentTab(
        rawValue: UserDefaults.standard.string(forKey: "deckContentTab") ?? "") ?? .cards
    @Namespace private var tabSwitch
    /// Opens the editor for a new question on the Questions tab.
    @State private var isWritingQuestion = false
    /// Opens "Generate questions with AI" on the Questions tab.
    @State private var isGeneratingQuestions = false

    private enum ContentTab: String, CaseIterable, Identifiable {
        case overview = "Overview", cards = "Cards", questions = "Questions"
        var id: String { rawValue }

        /// The tooltip, which says what the tab holds.
        var help: String {
            switch self {
            case .overview: return "Overview: a summary of the notes behind this deck"
            case .cards: return "Cards: the flashcards in this deck"
            case .questions: return "Questions: practice questions for tests"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "doc.text.fill"
            case .cards: return "rectangle.stack.fill"
            case .questions: return "list.bullet.clipboard"
            }
        }
    }

    /// Overview needs source notes to summarise, so a deck without any
    /// shows Cards and Questions only.
    private var availableTabs: [ContentTab] {
        ContentTab.allCases.filter { $0 != .overview || hasSourceNotes }
    }

    /// Free -- `cards` is already loaded. A deck whose cards were all typed
    /// by hand has no note to summarise, so the tab never appears at all:
    /// there'd be no action to offer behind it, and this app hides an
    /// affordance rather than showing a disabled one.
    private var hasSourceNotes: Bool { cards.contains { $0.materialId != nil } }

    /// One source for every number on the page.
    private var counts: DeckCardCounts {
        DeckCardCounts.make(cards: cards, levels: learnLevels, held: countHeldIds)
    }
    /// A deck with no cards, and nothing being written into it.
    private var showsEmptyDeck: Bool { hasLoaded && cards.isEmpty && !isGeneratingCards && contentTab == .cards }
    private var draftCount: Int { counts.drafts }
    private var activeCount: Int { counts.active }
    /// A tight pane (the window narrowed, or the deck list open beside it)
    /// puts the toolbar's buttons in icons.
    private var isCompact: Bool { paneWidth < 640 }

    /// This course's running deck-wide AI job, which the store owns so it
    /// survives this view being swapped out mid-run.
    private var cardJobKey: String { store.cardJobKey(courseId: courseId) }
    private var aiActivity: AIActivity? { store.aiJob(cardJobKey)?.activity }
    private var isRefiningDeck: Bool { aiActivity?.purpose == "refine" }
    private var isGeneratingCards: Bool { aiActivity?.purpose == "add" }
    /// Refreshed in `load()`. As a computed property it ran the whole due
    /// query four times per render -- on every selection click.
    @State private var dueCount = 0
    /// Saved questions a test could ask, and drafts waiting for review.
    @State private var activeQuestionCount = 0
    @State private var draftQuestionCount = 0
    /// Notes whose overview was written before the note last changed.
    @State private var staleOverviewCount = 0
    /// Notes in scope with an overview or one that could be written.
    @State private var overviewNoteCount = 0
    /// Set by the Overview toolbar ("Rewrite with AI", "Rewrite out-of-date
    /// overviews"); the Overview tab picks it up and asks before writing.
    @State private var overviewRequest: OverviewRewriteRequest?
    @State private var deletingDeck: Deck?
    /// Suspending (or bringing back) the whole deck asks first.
    @State private var confirmingSuspendDeck = false
    @State private var confirmingReactivateDeck = false
    @State private var renamingDeck: Deck?
    @State private var datingDeck: Deck?
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
        let revealed = hiddenNewIds.isEmpty ? cards : cards.filter { !hiddenNewIds.contains($0.id) }
        return sortedCards(revealed.filter(matchesFilter))
    }

    private func matchesFilter(_ card: Card) -> Bool {
        if let note = noteFilter, card.materialId != note { return false }
        switch masteryFilter {
        case .all: return true
        case .drafts: return card.status == .draft
        case .due: return card.status == .active && card.due <= Date()
        case .understood: return card.status == .active && learnLevels[card.id] == .mastered
        }
    }

    /// The numbers on the filter pills. Over every loaded card, so a pill
    /// says what it will show.
    private var filterCounts: [MasteryFilter: Int] {
        let c = counts
        return [.all: c.all, .drafts: c.drafts, .due: c.due, .understood: c.understood]
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
            // A generation run's cards lead the list, newest first, until
            // the scope changes -- they would otherwise land at the very
            // end of the deck, out of sight.
            guard !recentAIIds.isEmpty else { return cards }
            let recent = Set(recentAIIds)
            let byId = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return recentAIIds.compactMap { byId[$0] } + cards.filter { !recent.contains($0.id) }
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
                UnderstandingSummary(
                    cards: understanding, noteTitles: noteTitles,
                    onOpenNote: { noteFilter = .some($0); masteryFilter = .all },
                    onPractice: { ids in learnFocus = Set(ids); isLearning = true }
                )
                .padding(.horizontal, 18)
                .padding(.top, 14)
                if let note = noteFilter {
                    HStack(spacing: 8) {
                        Text("Showing cards from \(note.flatMap { noteTitles[$0] } ?? "Other")")
                            .font(.graspUI(size: 12.5))
                            .foregroundStyle(GRASPColor.textSecondary)
                            .lineLimit(1)
                        Button("Show all") { noteFilter = nil }
                            .buttonStyle(.plain)
                            .font(.graspUI(size: 12.5, weight: .medium))
                            .foregroundStyle(GRASPColor.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }
                HStack {
                    FilterPills(selection: $masteryFilter, counts: filterCounts)
                    Spacer()
                    cardSortMenu
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
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
            // Card generation has its own strip, at the top of the list.
            Group {
                if let aiActivity, !isGeneratingCards {
                    AIProgressStrip(
                        activity: aiActivity,
                        onStop: { store.stopAIJob(cardJobKey) },
                        stopHelp: "Stops now. Cards already finished keep their changes; "
                            + "the one in progress is left as it was."
                    )
                    .transition(.opacity)
                }
            }
            .animation(Motion.base, value: aiActivity != nil && !isGeneratingCards)
            switch contentTab {
            case .cards:
                if showsEmptyDeck {
                    emptyDeckState
                } else {
                    cardsTab
                }
            case .overview:
                DeckOverviewView(scope: scope, rewriteRequest: $overviewRequest) { cardId in
                    contentTab = .cards
                    selectedCardIds = [cardId]
                    previewCardId = cardId
                }
            case .questions:
                ScrollView {
                    QuestionsTab(deckIds: scopeDeckIds, courseId: courseId, isWriting: $isWritingQuestion,
                                 isGenerating: $isGeneratingQuestions, decks: scopeDecksForQuestions, scopeName: deckName)
                        .frame(maxWidth: .infinity)
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
        .onChange(of: contentTab) { _, tab in
            MenuAnchor.closeOpenMenu()
            UserDefaults.standard.set(tab.rawValue, forKey: "deckContentTab")
        }
        .onChange(of: hasSourceNotes) { _, hasNotes in
            if !hasNotes, contentTab == .overview { contentTab = .cards }
        }
        .onChange(of: hasLoaded) { _, loaded in
            if loaded, !hasSourceNotes, contentTab == .overview { contentTab = .cards }
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
        .task(id: isGeneratingCards) { await watchGeneration() }
        .sheet(isPresented: $isStudying, onDismiss: {
            load()
            guard let step = pendingNextStep else { return }
            pendingNextStep = nil
            switch step {
            case .learnMissed(let ids): learnFocus = ids; isLearning = true
            case .test: testPhase = .setup
            }
        }) {
            FlashcardStudyView(deckIds: scopeDeckIds, deckName: deckName) { pendingNextStep = $0 }
        }
        .sheet(isPresented: $isLearning, onDismiss: { learnFocus = []; load() }) {
            LearnRoundView(deckIds: scopeDeckIds, deckName: deckName, focusCardIds: learnFocus)
        }
        .sheet(item: $testPhase, onDismiss: load) { phase in
            switch phase {
            case .setup:
                TestSetupSheet(deckIds: scopeDeckIds, deckName: deckName, onResume: { id in
                    $testPhase.advance(to: TestPhase.resuming(id, store: store), store: store)
                }) { attemptId, questions, aiWarning in
                    $testPhase.advance(to: .running(attemptId: attemptId, questions: questions, aiWarning: aiWarning), store: store)
                }
            case .running(let attemptId, let questions, let aiWarning, let answered):
                TestRunView(attemptId: attemptId, deckName: deckName, questions: questions, aiWarning: aiWarning,
                        answered: answered) { graded in
                    _ = try? store.finishTest(attemptId: attemptId)
                    $testPhase.advance(to: .results(attemptId: attemptId, graded: graded), store: store)
                }
            case .results(let attemptId, let graded):
                TestResultsView(deckName: deckName, attemptId: attemptId, graded: graded, deckIds: scopeDeckIds) { id, questions in
                    $testPhase.advance(to: .running(attemptId: id, questions: questions, aiWarning: nil), store: store)
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
                    title: fillGapsResult == 0 ? "No New Cards to Add" : "Cards Added",
                    leadText: fillGapsResult > 0
                        ? "Added \(fillGapsResult) new card\(fillGapsResult == 1 ? "" : "s"), marked as AI-generated and awaiting your review."
                        : "No new cards to add. The AI didn't find any concepts in these notes that aren't already covered by a card."
                )
            }
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
                        ? "Every card checked out fine. Nothing looked like assignment text or an off-topic fragment, and nothing needed a wording cleanup."
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
                // The counts that used to sit under the name live in the
                // filter pills and the strips below; saying them again here
                // is three places for one number.
                Text(deckName)
                    .font(.graspDisplay(30))
                    .tracking(-0.6)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                // In the pane header rather than the filter row below it:
                // this picker changes what the whole pane *is*, which is
                // the job `CalendarView`'s Month/Week/Agenda picker already
                // does from the same position. The filter row is also gated
                // on having cards, and Overview has to stay reachable for a
                // deck whose cards are all still drafts.
                // Words when they fit (they do at 800 pt), icons when the
                // pane is too tight for the title and the words together.
                ViewThatFits(in: .horizontal) {
                    contentTabSwitch(labeled: true)
                    contentTabSwitch(labeled: false)
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
            .fixedSize(horizontal: false, vertical: true)
            .background {
                // ⇧⌘N for New card, also while the Add menu is closed.
                Button("New card") { isCreatingCard = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            if let why = studyUnavailableNote ?? testUnavailableNote {
                Text(why)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// One short line for why Study or Learn is dimmed, when it is. Reads
    /// the same as the iPhone's, plus the empty deck.
    private var studyUnavailableNote: String? {
        guard hasLoaded, contentTab == .cards, !isGeneratingCards else { return nil }
        let c = counts
        if c.all == 0 { return "No cards yet. Write some from your notes to start studying." }
        if c.active == 0 {
            // A deck of only drafts says it in the drafts strip instead.
            return c.drafts > 0 ? nil : "Nothing active to study. Reactivate suspended cards."
        }
        if dueCount == 0 { return "Nothing due right now. Learn or Test any time." }
        return nil
    }

    private var testAvailability: Study.TestAvailability {
        Study.testAvailability(activeCards: activeCount, activeQuestions: activeQuestionCount, draftCards: draftCount)
    }

    private var testHelp: String {
        if case .unavailable(let why) = testAvailability { return why }
        return "Take a test on this deck's flashcards, saved questions, or both"
    }

    /// The reason Test is dimmed, in one muted line, when it is.
    private var testUnavailableNote: String? {
        guard hasLoaded, case .unavailable(let why) = testAvailability else { return nil }
        return why
    }

    /// Only drafts, nothing approved: Study and Learn are dimmed because
    /// there is nothing to study yet, and approving is the one next step.
    private var isDraftsOnly: Bool { draftCount > 0 && activeCount == 0 }

    @ViewBuilder
    private var studyModeButtons: some View {
        modeButton("Study", "rectangle.stack.fill", prominent: true, help: "Study the cards that are due, one at a time") { isStudying = true }
            .disabled(dueCount == 0)
        modeButton("Learn", "graduationcap.fill", prominent: false, help: "Learn this deck in short rounds") {
            isLearning = true
        }
        .disabled(activeCount == 0)
        if let unfinishedTest {
            modeButton("Continue Test (\(unfinishedTest.answered)/\(unfinishedTest.total))", "play.fill", prominent: false,
                       help: "Pick up the test you left, at the next question") {
                testPhase = TestPhase.resuming(unfinishedTest.attemptId, store: store)
            }
        }
        // Test is available whenever the deck has approved cards or active
        // saved questions; with neither it says what to add.
        modeButton("Test", "checklist", prominent: false, help: testHelp) { testPhase = .setup }
            .disabled(!testAvailability.isAvailable)
    }

    /// The right side of the toolbar, which follows the Cards / Overview
    /// switch: the AI button, then Add or Edit, then ⋯.
    @ViewBuilder
    private var viewActions: some View {
        // The empty deck's own button is the one way to generate there.
        // Questions has no AI button: its generation sits in its Add menu.
        if !showsEmptyDeck, contentTab != .questions { aiButton }
        switch contentTab {
        case .cards: addMenuButton
        case .overview: editMenuButton
        case .questions: questionsAddMenuButton
        }
        overflowMenu
    }

    /// AI is GRASP's headline feature, so it gets its own button: an
    /// outlined pill (never filled -- Study is the one yellow button) with
    /// the yellow sparkle. Cards: generate cards. Overview:
    /// rewrite the overviews.
    private var aiButton: some View {
        let onCards = contentTab == .cards
        return Button {
            if onCards { showingGenerateSheet = true } else { requestOverviewRewrite(.all) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: AIGlyph.symbol)
                    .font(.graspUI(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.accent)
                if !isCompact {
                    Text(onCards ? (isGeneratingCards ? "Generating…" : "Generate cards") : "Rewrite with AI")
                        .lineLimit(1).fixedSize()
                }
            }
        }
        .accessibilityLabel(onCards ? "Generate cards" : "Rewrite with AI")
        .buttonStyle(GRASPQuietButton())
        .disabled(onCards
                  ? (!isGeneratorAvailable || aiActivity != nil)
                  : (!isGeneratorAvailable || overviewNoteCount == 0))
        .help(onCards
              ? (isGeneratorAvailable ? "Generate cards: new drafts written from this \(filesNoun.lowercased())'s notes, shown here as they arrive"
                                      : "Set up an AI model in Settings first")
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
            ]
            if !duplicateGroups.isEmpty {
                items.append(.action("Review duplicates…", systemImage: "square.on.square") {
                    showingDuplicateReview = true
                })
            }
            // Editing the deck itself -- the same actions as its row's
            // right-click menu in the deck list. All Cards is the whole
            // course, not a deck, so it has none of these.
            if case .deck(let id) = scope, let deck = (try? store.deck(id)) ?? nil {
                items.append(.divider)
                items.append(.action("Rename deck…", systemImage: "pencil") { renamingDeck = deck })
                items.append(.action(deck.manualLessonDate == nil ? "Set lecture date…" : "Change lecture date…",
                                     systemImage: "calendar") { datingDeck = deck })
                // Suspend: every approved card goes back to a draft, so the
                // deck stops coming up in Study, Learn and Tests.
                if counts.active > 0 {
                    items.append(.action("Suspend deck…", systemImage: "pause.circle",
                                         help: "Put its cards back to drafts so they stop coming up") {
                        confirmingSuspendDeck = true
                    })
                } else if counts.drafts + counts.suspended > 0 {
                    items.append(.action("Reactivate deck…", systemImage: "play.circle",
                                         help: "Bring its cards back so they come up again") {
                        confirmingReactivateDeck = true
                    })
                }
                items.append(.divider)
                items.append(.action("Delete deck…", systemImage: "trash", destructive: true) {
                    beginDeleteDeck(id)
                })
            }
            return items
        }
        .sheet(item: $renamingDeck) { deck in
            DeckRenameSheet(deck: deck, onRenamed: loadScopeIdentity)
        }
        .sheet(item: $datingDeck) { deck in
            DeckLectureDateSheet(deck: deck, onSaved: load)
        }
        .sheet(isPresented: $showingDeckFiles) {
            DeckFilesSheet(deckIds: scopeDeckIds, scopeName: deckName, scopeNoun: noun.lowercased())
        }
        .sheet(isPresented: $confirmingSuspendDeck) {
            ConfirmationSheet(
                icon: "pause.circle", title: "Suspend \(deckName)?",
                message: "\(counts.active) card\(counts.active == 1 ? "" : "s") go back to drafts, so they won't come up in Study, Learn or Tests. Your progress is kept. Approve them again to bring them back.",
                confirmTitle: "Suspend deck", isDestructive: false
            ) {
                try? store.suspendDeck(inDecks: scopeDeckIds)
                load()
            }
        }
        .sheet(isPresented: $confirmingReactivateDeck) {
            ConfirmationSheet(
                icon: "play.circle", title: "Reactivate \(deckName)?",
                message: "\(counts.drafts + counts.suspended) card\((counts.drafts + counts.suspended) == 1 ? "" : "s") become active again, so they come up in Study, Learn and Tests.",
                confirmTitle: "Reactivate deck", isDestructive: false
            ) {
                try? store.reactivateDeck(inDecks: scopeDeckIds)
                load()
            }
        }
        .sheet(item: $deletingDeck) { deck in
            DeckDeleteSheet(deck: deck, siblings: siblingDecks) { targetId in
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

    /// Cards view: everything that puts cards or practice problems into the deck.
    private var addMenuButton: some View {
        PillMenu(title: "Add", systemImage: "plus", isBusy: store.isImporting, showsTitle: !isCompact) {
            let aiBusy = aiActivity != nil
            var items: [PillMenuItem] = [
                .action("Generate cards with AI…", ai: true,
                        disabled: !isGeneratorAvailable || aiBusy,
                        help: "New draft cards for concepts this deck's notes mention that have no card yet") {
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
        .help("Generate cards, add a card, practice problems, files or a study guide")
    }

    /// Questions view: write a question now; the other two ways in are coming.
    /// Outlined like the other Add menus (Study stays the one yellow button).
    private var questionsAddMenuButton: some View {
        PillMenu(title: "Add", systemImage: "plus", showsTitle: !isCompact) {
            [
                .action("Write a question", systemImage: "square.and.pencil",
                        help: "Multiple choice, written or true / false") { isWritingQuestion = true },
                .action("Generate questions with AI…", ai: true,
                        disabled: !isGeneratorAvailable || questionJobRunning,
                        help: isGeneratorAvailable ? "Draft questions written from this deck's notes, for you to review"
                                                   : "Set up an AI model in Settings first") {
                    isGeneratingQuestions = true
                },
                .divider,
                .action("From a photo (coming soon)", systemImage: "camera", disabled: true, help: "Coming soon") {},
            ]
        }
        .help("Write a question")
    }

    private var questionJobRunning: Bool { store.aiJob(store.questionDraftJobKey(courseId: courseId)) != nil }

    /// The decks a new question can go in: this deck, or every deck of an
    /// "All Cards" view.
    private var scopeDecksForQuestions: [Deck] {
        scopeDeckIds.compactMap { (try? store.deck($0)) ?? nil }
    }

    /// Overview view: rewriting the overviews, and adding sources.
    private var editMenuButton: some View {
        PillMenu(title: "Edit", systemImage: "pencil", isBusy: store.isImporting, showsTitle: !isCompact) {
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
            deletingDeck = deck
        }
    }

    /// The Cards / Overview switch: two large, labelled buttons rather than
    /// a small segmented control, since it changes what the whole pane is.
    private func contentTabSwitch(labeled: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(availableTabs) { tab in
                let selected = contentTab == tab
                Button {
                    withAnimation(Motion.thumb) { contentTab = tab }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol)
                            .font(.graspUI(size: 13))
                        if labeled {
                            Text(tab.rawValue)
                                .font(.graspUI(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if tab == .questions, draftQuestionCount > 0 {
                            // Drafts waiting for review.
                            Text("\(draftQuestionCount)")
                                .font(.graspUI(size: 11, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(GRASPColor.textPrimary)
                                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                                .background(GRASPColor.surfaceRaised, in: Capsule())
                                .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong))
                                .accessibilityLabel("\(draftQuestionCount) to review")
                        }
                    }
                    .foregroundStyle(selected ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                    .padding(.horizontal, labeled ? 16 : 12)
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
                .accessibilityLabel(tab.rawValue)
                .help(tab.help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(GRASPColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(GRASPColor.hairline))
    }

    @ViewBuilder
    private func modeButton(
        _ title: String, _ symbol: String, prominent: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: symbol).font(.graspUI(size: 11))
            if !isCompact { Text(title).lineLimit(1).fixedSize() }
        }
        if prominent {
            Button(action: action) { label }.buttonStyle(GRASPProminentButton())
                .accessibilityLabel(title).accessibilityHint(help).help(help)
        } else {
            Button(action: action) { label }.buttonStyle(GRASPQuietButton())
                .accessibilityLabel(title).accessibilityHint(help).help(help)
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
                        + "and a source note to check against. One of those isn't available right now."
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
        additionFailure = nil
        lastAddition = (maxPerNote, topic)
        store.runAIJob(cardJobKey, activity: run) { [store] run in
            let outcome = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                if let maxPerNote {
                    await store.addCards(inDecks: deckIds, maxPerNote: maxPerNote, topic: topic)
                } else {
                    await store.addCards(inDecks: deckIds, topic: topic)
                }
            }
            // Bail before touching anything scope-dependent (`cards`,
            // `scopeDeckIds`, ...) if the user has since switched to a
            // different deck or course -- otherwise this stale result
            // would silently overwrite what's now on screen with data for
            // a scope that's no longer even visible.
            guard generation == scopeGeneration else { return }
            // Cards that landed were shown arriving, and the drafts strip
            // carries the count. "No gaps" is only for a run that looked and
            // found nothing; anything that went wrong is the strip's Retry.
            switch outcome {
            case .added:
                break
            case .nothingToAdd:
                if !run.stopRequested { fillGapsResult = 0 }
            case .failed(let failure):
                if !run.stopRequested || failure != .generatorUnavailable {
                    additionFailure = AppStore.message(for: failure)
                }
            }
            load()
        }
    }

    /// What needs attention in the cards, in one line at the top of the
    /// list -- drafts waiting for review, possible duplicates -- with one
    /// action. It scrolls away with the cards rather than staying pinned.
    /// (The Overview has its own strip, for overviews out of date.)
    private var statusStrip: some View {
        var parts: [String] = []
        if isDraftsOnly {
            parts.append("\(draftCount) draft\(draftCount == 1 ? "" : "s") to review. Approve them to start studying.")
        } else if draftCount > 0 {
            parts.append("\(draftCount) draft\(draftCount == 1 ? "" : "s") to review")
        }
        if !duplicateGroups.isEmpty {
            parts.append("\(duplicateGroups.count) possible duplicate\(duplicateGroups.count == 1 ? "" : "s")")
        }
        return HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
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
            if isDraftsOnly {
                // The page's one filled button: Study and Learn are dimmed.
                Button("Approve all") {
                    try? store.approveAllDrafts(inDecks: scopeDeckIds)
                    load()
                }
                .buttonStyle(GRASPProminentButton())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
    }

    /// The "Generate cards" run failed: what went wrong, with Retry --
    /// the same look as the live strip, in place of it.
    private func additionFailureStrip(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.graspUI(size: 13))
                .foregroundStyle(GRASPColor.rejected)
            Text(message)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry") {
                let request = lastAddition
                runGenerate(maxPerNote: request?.maxPerNote, topic: request?.topic)
            }
            .buttonStyle(GRASPQuietButton())
            .disabled(!isGeneratorAvailable || aiActivity != nil)
            Button {
                additionFailure = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.graspUI(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
    }

    // MARK: - Empty deck

    /// The deck to write into: the open one, or a course's first deck.
    private var generationTargetDeckId: String? {
        if case .deck(let id) = scope { return id }
        return scopeDeckIds.first
    }

    /// A deck with no cards at all: no list header, filters or strip -- one
    /// large action and a quiet way out.
    private var emptyDeckState: some View {
        let hasFiles = courseFileCount > 0
        let canGenerate = hasFiles && isGeneratorAvailable && generationTargetDeckId != nil
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                if hasFiles {
                    // The one filled button on an empty deck: Study is
                    // disabled here, so this is the page's yellow.
                    Button {
                        generateFromCourse()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: AIGlyph.symbol)
                                .font(.graspUI(size: 17, weight: .semibold))
                            Text("Generate cards from your notes")
                                .font(.graspUI(size: 16, weight: .semibold))
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 6)
                        .frame(minHeight: 48)
                    }
                    .buttonStyle(GRASPProminentButton())
                    .disabled(!canGenerate)
                    Text(isGeneratorAvailable
                         ? "Uses the files in this course"
                         : "Set up an AI model in Settings → AI to write cards")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                } else {
                    Button {
                        onAddFiles()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.badge.plus")
                                .font(.graspUI(size: 16, weight: .semibold))
                            Text("Add files")
                                .font(.graspUI(size: 16, weight: .semibold))
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 6)
                        .frame(minHeight: 48)
                    }
                    .buttonStyle(GRASPQuietButton())
                    HStack(spacing: 6) {
                        Image(systemName: AIGlyph.symbol).font(.graspUI(size: 10, weight: .semibold))
                        Text("Generate cards")
                    }
                    .font(.graspUI(size: 13.5, weight: .medium))
                    .foregroundStyle(GRASPColor.textTertiary.opacity(0.7))
                    Text("Add this course's notes first. Cards are written from them.")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                if let generationNotice {
                    HStack(spacing: 10) {
                        Image(systemName: generationNotice.isError ? "exclamationmark.circle" : "info.circle")
                            .font(.graspUI(size: 12))
                            .foregroundStyle(GRASPColor.textTertiary)
                        Text(generationNotice.message)
                            .graspType(.body)
                            .foregroundStyle(GRASPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if hasFiles {
                            Button("Retry") { generateFromCourse() }
                                .buttonStyle(GRASPQuietButton())
                                .disabled(!canGenerate)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
                    .frame(maxWidth: 480)
                    .padding(.top, 6)
                }
                Button("Add a card manually") { isCreatingCard = true }
                    .buttonStyle(.plain)
                    .font(.graspUI(size: 13, weight: .medium))
                    .foregroundStyle(GRASPColor.textSecondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// Writes the deck's first cards from the course's notes. Same strip as
    /// "Generate cards"; failures come back as a notice with Retry.
    private func generateFromCourse() {
        guard let courseId, let deckId = generationTargetDeckId else { return }
        let generation = scopeGeneration
        generationNotice = nil
        let run = AIActivity(headline: "Writing cards for \(deckName) with AI", purpose: "add")
        store.runAIJob(cardJobKey, activity: run) { [store] run in
            let notice: GenerationNotice?
            do {
                let outcome = try await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                    try await store.generateCards(fromCourse: courseId, intoDeck: deckId)
                }
                switch outcome {
                case .noMaterials:
                    courseFileCount = 0
                    notice = nil
                case .generated(let created, _, _):
                    notice = created == 0 && !run.stopRequested
                        ? GenerationNotice(message: "The AI didn't find anything to ask about in these notes.", isError: false)
                        : nil
                }
            } catch let error as CardAI.CourseGenerationError {
                switch error {
                case .generatorUnavailable:
                    notice = GenerationNotice(message: "No AI model is reachable. Check Settings → AI, then retry.", isError: true)
                case .noReadableNotes:
                    notice = GenerationNotice(message: "GRASP couldn't read any text in this course's files.", isError: true)
                case .deckMissing:
                    notice = GenerationNotice(message: "This deck no longer exists.", isError: true)
                case .writeFailed(let created, _):
                    notice = GenerationNotice(
                        message: (created > 0 ? "Stopped after \(created) card\(created == 1 ? "" : "s"). " : "")
                            + "Couldn't save the cards. Try again, and restart GRASP if it keeps happening.",
                        isError: true)
                }
            } catch {
                notice = GenerationNotice(message: PlainError.message(error, couldnt: "write cards"), isError: true)
            }
            guard generation == scopeGeneration else { return }
            generationNotice = notice
            load()
        }
    }

    /// While cards are being written: a pulsing sparkle, where from, how
    /// many so far, and Stop. Replaces the drafts strip until the run ends,
    /// when the drafts strip returns with the final count.
    private var generatingStrip: some View {
        let written = DeckCardCounts.newCount(recent: recentAIIds, held: countHeldIds)
        return HStack(spacing: 10) {
            Image(systemName: AIGlyph.symbol)
                .font(.graspUI(size: 13, weight: .semibold))
                .foregroundStyle(GRASPColor.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text(liveSourceTitle.map { "Generating cards from \($0)…" } ?? "Generating cards from your notes…")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(written) new card\(written == 1 ? "" : "s")")
                .graspType(.meta)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(written)))
                .foregroundStyle(GRASPColor.textSecondary)
            Button(aiActivity?.stopRequested == true ? "Stopping…" : "Stop") {
                store.stopAIJob(cardJobKey)
            }
            .buttonStyle(GRASPQuietButton())
            .disabled(aiActivity?.stopRequested == true)
            .help("Stops now. Cards already written are kept.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
    }

    /// Watches the database while a generation job runs. The core hands
    /// back one count at the end, but writes each note's cards as the note
    /// finishes, so reading the deck about twice a second shows them
    /// arriving. Each batch slides in one row at a time (about 60 ms apart,
    /// the whole batch within 1.5 s); with Reduce Motion they just appear.
    private func watchGeneration() async {
        guard isGeneratingCards else {
            // Run over: anything still waiting appears now.
            withAnimation(nil) { hiddenNewIds.removeAll() }
            countHeldIds.removeAll()
            return
        }
        seenIds = Set(cards.map(\.id))
        recentAIIds = []
        liveSourceTitle = nil
        let generation = scopeGeneration
        while !Task.isCancelled, isGeneratingCards, generation == scopeGeneration {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, generation == scopeGeneration else { break }
            guard let fresh = try? store.cards(inDecks: scopeDeckIds) else { continue }
            let arrivals = fresh.filter { !seenIds.contains($0.id) }
            guard !arrivals.isEmpty else { continue }
            seenIds.formUnion(arrivals.map(\.id))
            let ordered = arrivals.sorted { $0.createdAt > $1.createdAt }
            if let source = ordered.first(where: { $0.materialId != nil })?.materialId,
               let title = (try? store.material(source)) ?? nil {
                liveSourceTitle = title.title
            }
            hiddenNewIds.formUnion(ordered.map(\.id))
            countHeldIds.formUnion(ordered.map(\.id))
            recentAIIds = ordered.map(\.id) + recentAIIds
            cards = fresh
            loadSourceTitles()
            reviewNotes = CardQuality.reviewNotes(for: fresh)
            let step = min(0.06, 1.5 / Double(ordered.count))
            for card in ordered.reversed() {
                if reduceMotion {
                    hiddenNewIds.remove(card.id)
                } else {
                    withAnimation(Motion.glide) { _ = hiddenNewIds.remove(card.id) }
                    try? await Task.sleep(for: .seconds(step))
                }
            }
            // The whole batch is on screen: the counts move together -- the
            // strip, the filter pills and the deck list.
            countHeldIds.subtract(ordered.map(\.id))
            store.refreshDeckCounts()
        }
        countHeldIds.removeAll()
    }

    /// Opens the first draft in the preview; approving it there moves on to
    /// the next, until none are left.
    private func startReviewingDrafts() {
        masteryFilter = .drafts
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
            if isGeneratingCards {
                generatingStrip
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            } else if let additionFailure {
                additionFailureStrip(additionFailure)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            } else if draftCount > 0 || !duplicateGroups.isEmpty {
                statusStrip
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }
            ForEach(cards) { card in
                CardRow(
                    card: card,
                    isSelected: selectedCardIds.contains(card.id),
                    selectionActive: !selectedCardIds.isEmpty,
                    sourceTitle: card.materialId.flatMap { sourceTitles[$0] },
                    reviewNote: reviewNotes[card.id],
                    mastery: learnLevels[card.id] ?? .new,
                    understanding: understandingById[card.id] ?? .of(level: nil),
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
                // GRASP draws the selection itself -- a raised neutral
                // surface with a yellow check -- because the table's own
                // highlight is the system accent (blue) and ignores
                // `.tint`. Selection behaviour (shift- and cmd-click, the
                // context menu's selection) is still the table's; only the
                // drawing changes.
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selectedCardIds.contains(card.id) ? GRASPColor.surfaceRaised : .clear)
                        .padding(.horizontal, 4)
                )
                .background(TableHighlightRemover())
                .transition(Motion.slide(from: .top))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // The last rows scroll clear of the floating bar.
        .contentMargins(.bottom, selectedCardIds.isEmpty ? 0 : 76, for: .scrollContent)
        .overlay(alignment: .bottom) { floatingApproveBar }
        .animation(Motion.glide, value: selectedCardIds.isEmpty)
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
    /// Drafts among the selected rows -- what "Approve N selected" acts on.
    private var selectedDraftIds: [String] {
        visibleCards.filter { selectedCardIds.contains($0.id) && $0.status == .draft }.map(\.id)
    }

    /// Floats over the foot of the list while any rows are selected: the
    /// batch actions in one place -- Approve (when drafts are among them),
    /// Suspend, Move to…, Delete -- drawn in the app's own controls.
    @ViewBuilder private var floatingApproveBar: some View {
        let selected = orderedSelection
        let drafts = selectedDraftIds
        if !selected.isEmpty {
            HStack(spacing: 8) {
                Text("\(selected.count) selected")
                    .graspType(.meta)
                    .monospacedDigit()
                    .foregroundStyle(GRASPColor.textSecondary)
                    .padding(.trailing, 4)
                if !drafts.isEmpty {
                    Button("Approve \(drafts.count)") {
                        try? store.bulkSetStatus(drafts, status: .active)
                        selectedCardIds.removeAll()
                        load()
                    }
                    .buttonStyle(GRASPQuietButton())
                    .fixedSize()
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Approve the \(drafts.count) selected draft\(drafts.count == 1 ? "" : "s") (⌘↩)")
                }
                Button("Suspend") {
                    try? store.bulkSetStatus(selected, status: .suspended)
                    selectedCardIds.removeAll()
                    load()
                }
                .buttonStyle(GRASPQuietButton())
                .fixedSize()
                if !siblingDecks.isEmpty {
                    PillMenu(title: "Move to…") {
                        siblingDecks.map { deck in
                            PillMenuItem.action(deck.name) {
                                try? store.bulkMoveCards(selected, toDeck: deck.id)
                                selectedCardIds.removeAll()
                                load()
                            }
                        }
                    }
                    .fixedSize()
                }
                Button("Delete", role: .destructive) { pendingBulkDelete = selected }
                    .buttonStyle(GRASPQuietButton())
                    .fixedSize()
                Button {
                    selectedCardIds.removeAll()
                } label: {
                    Image(systemName: "xmark")
                        .font(.graspUI(size: 11, weight: .semibold))
                        .foregroundStyle(GRASPColor.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Clear the selection")
                .accessibilityLabel("Clear selection")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(GRASPColor.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
            .padding(.bottom, 16)
            .transition(Motion.slide(from: .bottom))
        }
    }

    /// Resolves `deckName`/`courseId` from `scope`'s identity -- run once
    /// per scope change via `.task(id: scope)`, not on every `load()`,
    /// since neither depends on live card data.
    private func loadScopeIdentity() {
        scopeGeneration += 1
        // A filter is about the deck it was chosen in.
        masteryFilter = .all
        recentAIIds = []
        hiddenNewIds = []
        countHeldIds = []
        additionFailure = nil
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

    private func loadSourceTitles() {
        let ids = Set(cards.compactMap(\.materialId))
        for id in ids where sourceTitles[id] == nil {
            if let material = (try? store.material(id)) ?? nil { sourceTitles[id] = material.title }
        }
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
        reviewNotes = CardQuality.reviewNotes(for: cards)
        learnLevels = (try? store.learnLevels(forDecks: scopeDeckIds)) ?? [:]
        understanding = (try? store.understanding(forDecks: scopeDeckIds)) ?? []
        noteTitles = store.noteTitles(forMaterials: Array(Set(understanding.compactMap(\.materialId))))
        suspendedStates = store.suspendedUnderstanding(forDecks: scopeDeckIds)
        hasLoaded = true
        loadSourceTitles()
        // A Drafts filter with no drafts left would show an empty list.
        if masteryFilter == .drafts, !cards.contains(where: { $0.status == .draft }) { masteryFilter = .all }
        dueCount = (try? store.dueCards(inDecks: scopeDeckIds).count) ?? 0
        activeQuestionCount = store.activeQuestionCount(inDecks: scopeDeckIds)
        draftQuestionCount = store.questionDraftCount(inDecks: scopeDeckIds)
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
        if cards.isEmpty, let courseId {
            courseFileCount = (try? store.materialCount(inCourse: courseId)) ?? 0
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
        GRASPSheet(
            eyebrow: "Refine with AI",
            title: includesApproved
                ? "Refine \(cardCount) card\(cardCount == 1 ? "" : "s")?"
                : "Refine \(cardCount) draft\(cardCount == 1 ? "" : "s")?",
            message: includesApproved
                ? "Checks every card in this deck, drafts and approved, against its own note and this course. Review history is kept."
                : "Checks every draft against its own note and this course.",
            icon: AIGlyph.symbol, width: 460
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    effectRow(
                        icon: "trash", tint: GRASPColor.rejected,
                        text: "Removes cards that aren't real course concepts, such as assignment text or a document-specific label."
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
                .popupGroup(padding: 14)

                Text("This can't be undone in bulk. A removed card is gone, though a rewritten one can be reverted individually from its \"AI Refined\" badge afterward.")
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
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button("Refine deck") {
                onConfirm()
                dismiss()
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
        }
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
        GRASPSheet(
            eyebrow: "Generate with AI", title: "Generate cards",
            message: "The AI writes new draft cards for concepts your notes mention that don't have a card yet. They arrive in the list as they're written.",
            icon: AIGlyph.symbol, width: 440
        ) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("How many")
                    GRASPSegmented(
                        selection: $amountMode,
                        options: [(.suggested, "Let the AI decide"), (.custom, "Set a limit")],
                        fillsWidth: true
                    )
                    if amountMode == .custom {
                        HStack {
                            Text("Up to \(customAmount) card\(customAmount == 1 ? "" : "s") per note")
                                .monospacedDigit()
                            Spacer()
                            Stepper("", value: $customAmount, in: 1...10).labelsHidden()
                        }
                        .popupGroup(padding: 10)
                        .transition(.opacity)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Focus on (optional)")
                    TextField("e.g. mitosis phases", text: $topic)
                }
            }
            .animation(Motion.snappy, value: amountMode)
        } footer: {
            Button("Cancel") { dismiss() }
            Button {
                let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                onGenerate(amountMode == .custom ? customAmount : nil, trimmedTopic.isEmpty ? nil : trimmedTopic)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: AIGlyph.symbol).font(.graspUI(size: 11, weight: .semibold))
                    Text("Generate cards")
                }
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
        }
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

    /// The same meter and colours as the card rows, with its word.
    private var masteryChip: some View {
        PipMeter(state: .of(level: mastery, asked: mastery != .new), size: .card, showsWord: true)
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
    let counts: [DeckDetailView.MasteryFilter: Int]
    @Namespace private var pill
    private var reduceMotion: Bool { Motion.isReduced }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DeckDetailView.MasteryFilter.allCases) { filter in
                let selected = selection == filter
                Button {
                    withAnimation(Motion.thumb) { selection = filter }
                } label: {
                    Text("\(filter.rawValue) \(counts[filter] ?? 0)")
                        .font(.graspUI(size: 12.5, weight: selected ? .semibold : .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
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
    /// While any row is selected every row keeps a slot at its left for a
    /// round checkbox: yellow check when selected, an empty ring when not.
    let isSelected: Bool
    let selectionActive: Bool
    /// The note an AI-made card came from, when known.
    let sourceTitle: String?
    /// A flag on a parser-made draft, when it looks like a duplicate or a heading.
    let reviewNote: String?
    let mastery: LearnEngine.Level
    /// The understanding meter's state for an active card.
    let understanding: UnderstandingState
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
    private enum ActionFocus { case preview, approve }
    @FocusState private var actionFocus: ActionFocus?
    /// The status gives way to the actions while the pointer is on the row
    /// or keyboard focus is on one of them (so Tab reveals them too).
    private var isActive: Bool { isHovering || actionFocus != nil || showingContextRefinementDetail }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if selectionActive {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.graspUI(size: 16))
                    .foregroundStyle(isSelected ? GRASPColor.accent : GRASPColor.hairlineStrong)
                    .frame(width: 18)
                    .padding(.top, 1)
                    .transition(.opacity)
                    .accessibilityLabel(isSelected ? "Selected" : "Not selected")
            }
            // The left column says where the card stands. An approved
            // card shows its understanding pips; a draft or a suspended
            // card keeps the 2 pt rail (hairline, or coral). Fixed width so
            // every row's text lines up.
            Group {
                if card.status == .active || card.status == .suspended {
                    PipMeter(state: understanding, size: .row, isSuspended: card.status == .suspended)
                        .padding(.top, 5)
                        .help(understanding.accessibilityLabel)
                } else {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(railTint)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .help(railHelp ?? "")
                }
            }
            .frame(width: 27, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                let term = CardTermDisplay.split(card.front)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // The one AI mark: a yellow sparkle on a draft the AI
                    // wrote. Approving it takes the sparkle away; the
                    // "from <note>" line below stays.
                    if card.origin == .aiGenerated && card.status == .draft {
                        Image(systemName: AIGlyph.symbol)
                            .font(.graspUI(size: 11, weight: .semibold))
                            .foregroundStyle(GRASPColor.accent)
                            .help("Written by the AI. Check it against your notes")
                    }
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
                if card.origin == .aiGenerated, let sourceTitle {
                    Button(action: onViewNote) {
                        Text("from \(sourceTitle)")
                            .font(.graspUI(size: 12))
                            .foregroundStyle(GRASPColor.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Open this note")
                    .padding(.top, 1)
                }
                if let reviewNote {
                    Text(reviewNote)
                        .font(.graspUI(size: 12))
                        .foregroundStyle(GRASPColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            contextRefinedBadge
            // One muted word -- "Due today", "in 3d", "New", "Draft" -- that
            // cross-fades to the actions on hover or keyboard focus. The
            // slot is a fixed width, so nothing in the row moves.
            ZStack(alignment: .trailing) {
                Text(CardRowStatus.text(for: card, hasProgress: card.status == .active && understanding.hasProgress))
                    .font(.graspUI(size: 12))
                    .foregroundStyle(GRASPColor.textTertiary)
                    .lineLimit(1)
                    .opacity(isActive ? 0 : 1)
                    .animation(isActive ? Motion.swapOut : Motion.swapIn, value: isActive)
                HStack(spacing: 6) {
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
                .help("Card actions")
                }
                .opacity(isActive ? 1 : 0)
                .animation(isActive ? Motion.swapIn : Motion.swapOut, value: isActive)
                .allowsHitTesting(isActive)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .animation(Motion.fade, value: selectionActive)
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
        .focused($actionFocus, equals: .preview)
        .help("Preview")
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
            .focused($actionFocus, equals: .approve)
            .help("Approve")
        }
    }

    /// The sole approval-status signal on a row -- amber for pending
    /// (awaiting review), a muted rose for rejected (suspended), and the
    /// existing mastery-based tint for an approved/active card. Replaces a
    /// second, redundant circular icon that used to sit beside this same
    /// bar and say the same thing.
    private var railTint: Color {
        card.status == .suspended ? GRASPColor.rejected : GRASPColor.hairlineStrong
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
            } else if mastery == .familiar {
                Label("Familiar", systemImage: "checkmark.circle")
                    .foregroundStyle(GRASPColor.textSecondary)
            } else {
                Label("Needs review", systemImage: "circle")
                    .foregroundStyle(GRASPColor.textTertiary)
            }
        }
        .labelStyle(.iconOnly)
        .help(mastery == .mastered ? "Understood" : (mastery == .familiar ? "Familiar" : "Needs Review"))
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
                .help("AI-generated, not directly from your notes. Worth double-checking")
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
                    .labelStyle(.iconOnly).foregroundStyle(GRASPColor.textTertiary)
            }
            .buttonStyle(.plain)
            .help("AI refined: this definition was checked against its note and rewritten. Click to compare with the original.")
            .accessibilityLabel("AI refined definition. Compare with the original.")
            .popover(isPresented: $showingContextRefinementDetail, arrowEdge: .bottom) {
                contextRefinementDetail
            }
        }
    }

    private var contextRefinementDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BrandDot(size: 6)
                Text("AI refined")
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(GRASPColor.textSecondary)
                Spacer()
                Image(systemName: "checkmark.shield")
                    .font(.graspUI(size: 12, weight: .semibold))
                    .foregroundStyle(GRASPColor.success)
            }

            Text("The original extraction looked like assignment text or an off-topic fragment. The AI rewrote it using this card's own source note.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                FieldLabel("Original")
                Text(card.originalBack ?? "")
                    .graspType(.body).foregroundStyle(GRASPColor.textSecondary)
                    .strikethrough(color: GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .popupGroup(padding: 10)
            VStack(alignment: .leading, spacing: 3) {
                FieldLabel("Now")
                Text(card.back)
                    .graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .popupGroup(padding: 10)

            HStack {
                Spacer()
                Button("Revert to original") {
                    onRevertContextRefinement()
                    showingContextRefinementDetail = false
                }
                .buttonStyle(GRASPQuietButton())
            }
        }
        .padding(16)
        .frame(width: 340)
        .graspPopupBackground()
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
        GRASPSheet(
            eyebrow: "Duplicates",
            title: "\(groups.count) group\(groups.count == 1 ? "" : "s") of near-identical cards",
            message: "Pick the card to keep in each group, or click the kept card again to keep none and delete them all.",
            icon: "square.on.square", width: 600
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        groupBlock(group)
                    }
                }
            }
            .frame(height: 360)
        } footer: {
            Text(summary)
                .graspType(.meta)
                .foregroundStyle(deletedCount > 0 ? GRASPColor.rejected : GRASPColor.textTertiary)
            Spacer()
            Button("Cancel") { dismiss() }
            Button(actionTitle) {
                if deletedCount > 0 { confirmingDelete = true } else { apply() }
            }
            .buttonStyle(GRASPProminentButton(tint: deletedCount > 0 ? GRASPColor.rejected : GRASPColor.brand))
            .keyboardShortcut(.defaultAction)
            .disabled(mergedCount + deletedCount == 0)
        }
        .sheet(isPresented: $confirmingDelete) {
            ConfirmationSheet(
                icon: "trash",
                title: "Delete \(deletedCount) card\(deletedCount == 1 ? "" : "s")?",
                message: "These are the groups you chose to keep none of. They leave every deck. Their review history is kept, and importing the same notes again won't bring them back.",
                confirmTitle: "Delete \(deletedCount) card\(deletedCount == 1 ? "" : "s")"
            ) { apply() }
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
                Text("\(group.cards.count) near-identical cards")
                    .font(.graspUI(size: 13, weight: .semibold))
                    .foregroundStyle(GRASPColor.textPrimary)
                if group.hasCompetingHistory {
                    Text("· more than one has review history").graspType(.meta).foregroundStyle(GRASPColor.accent)
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
                    .foregroundStyle(current == .keepAll ? GRASPColor.textPrimary : GRASPColor.accent)
                    Button(current == .deleteAll ? "Deleting all" : "Delete all") {
                        choices[group.id] = .deleteAll
                    }
                    .foregroundStyle(GRASPColor.rejected)
                    Spacer()
                }
                .buttonStyle(.plain)
                .font(.graspUI(size: 12, weight: .semibold))
                .padding(.top, 2)
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
                Circle()
                    .strokeBorder(isKept ? GRASPColor.brand : GRASPColor.hairlineStrong, lineWidth: isKept ? 5 : 1)
                    .background(Circle().fill(isKept ? GRASPColor.ink : GRASPColor.surfaceRaised))
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.front).font(.graspUI(size: 13.5, weight: .medium)).strikethrough(isDeleted)
                    Text(card.back).graspType(.meta).foregroundStyle(GRASPColor.textSecondary).lineLimit(3)
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
        GRASPSheet(eyebrow: "Card", title: "New card", width: 480) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: GRASPSpace.m) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Course")
                        GRASPDropdown(
                            selection: $selectedCourseId,
                            groups: store.coursePickerGroups().map { group in
                                .init(title: group.title, options: group.courses.map { ($0.id as String?, $0.name) })
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Deck")
                        GRASPDropdown(
                            selection: $selectedDeckId,
                            options: decksInCourse.map { ($0.id as String?, $0.name) },
                            placeholder: "No decks"
                        )
                        .disabled(decksInCourse.isEmpty)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Front")
                    TextEditor(text: $front).graspEditorChrome(minHeight: 56)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Back")
                    TextEditor(text: $back).graspEditorChrome(minHeight: 96)
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button("Create card") {
                guard let deckId = selectedDeckId else { return }
                try? store.createManualCard(
                    front: front.trimmingCharacters(in: .whitespacesAndNewlines),
                    back: back.trimmingCharacters(in: .whitespacesAndNewlines),
                    deckId: deckId
                )
                dismiss()
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(
                selectedDeckId == nil
                    || front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
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
        GRASPSheet(eyebrow: "Card", title: "Edit card", width: 480) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Front")
                    TextEditor(text: $card.front).graspEditorChrome(minHeight: 56)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Back")
                    TextEditor(text: $card.back).graspEditorChrome(minHeight: 110)
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button("Save") {
                onSave(card)
                dismiss()
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
