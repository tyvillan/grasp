import SwiftUI
import GRASPCore

/// One deck (or a course's "All Cards"): study it, browse and fix its
/// cards, or read the overview of the notes behind it.
struct DeckScreen: View {
    @Environment(AppStore.self) private var store
    let route: DeckRoute

    private enum Tab: String, CaseIterable { case cards = "Cards", overview = "Overview" }

    @State private var tab: Tab = .cards
    @State private var cards: [Card] = []
    @State private var dueCount = 0
    @State private var studying = false
    @State private var learning = false
    @State private var testPhase: TestPhase?
    @State private var pendingNextStep: StudyNextStep?
    @State private var learnFocus: Set<String> = []
    @State private var unfinishedTest: Study.UnfinishedTest?
    @State private var editing: Card?
    @State private var query = ""
    @State private var creatingCard = false
    @State private var aiMessage: String?
    private var reduceMotion: Bool { Motion.isReduced }
    @State private var learnLevels: [String: LearnEngine.Level] = [:]
    /// The meter's view of each card, and the note a "Weakest notes" row
    /// filters to (nil: not filtering; `.some(nil)` is the "Other" group).
    @State private var understanding: [DeckUnderstanding.Card] = []
    @State private var noteFilter: String??
    private var understandingById: [String: UnderstandingState] {
        Dictionary(understanding.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
    }
    @State private var filter: CardFilter = .all
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    /// Cards a generation run has written so far, newest first.
    @State private var recentAIIds: [String] = []
    @State private var seenIds: Set<String> = []
    @State private var liveSourceTitle: String?
    @State private var sourceTitles: [String: String] = [:]
    /// Flags on parser-made drafts, shown under the card. Never acted on.
    @State private var reviewNotes: [String: String] = [:]
    @State private var hasLoaded = false
    @State private var courseFileCount = 0
    @State private var notice: String?
    @State private var generationFinished = 0
    @State private var confirmingApproveAll = false
    /// Shown when Test is tapped on a deck with no approved cards yet.
    @State private var approveFirstNotice = false
    /// Why the last "Generate Cards" run failed, shown with Retry
    /// instead of the "no new cards" message.
    @State private var additionFailure: String?

    private enum CardFilter: String, CaseIterable, Identifiable {
        case all = "All", drafts = "Drafts", due = "Due", understood = "Understood"
        var id: String { rawValue }
    }

    private var courseId: String? { store.courseId(of: route.scope) }

    /// The AI job running on this course, if any -- owned by the store, so
    /// it keeps going (with its Stop button) when this screen closes.
    private var runningJob: (key: String, activity: AIActivity)? {
        for key in [store.cardJobKey(courseId: courseId), store.overviewJobKey(courseId: courseId)] {
            if let job = store.aiJob(key) { return (key, job.activity) }
        }
        return nil
    }

    private var deckIds: [String] { store.deckIds(in: route.scope) }

    /// One source for every number on the screen, the same one the Mac's
    /// deck page reads.
    private var counts: DeckCardCounts { DeckCardCounts.make(cards: cards, levels: learnLevels) }
    private var activeCount: Int { counts.active }
    private var draftCount: Int { counts.drafts }

    private func matches(_ card: Card, _ filter: CardFilter) -> Bool {
        switch filter {
        case .all: return true
        case .drafts: return card.status == .draft
        case .due: return card.status == .active && card.due <= Date()
        case .understood: return card.status == .active && learnLevels[card.id] == .mastered
        }
    }

    private func count(_ filter: CardFilter) -> Int {
        let c = counts
        switch filter {
        case .all: return c.all
        case .drafts: return c.drafts
        case .due: return c.due
        case .understood: return c.understood
        }
    }

    private var shownCards: [Card] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var base = cards.filter { matches($0, filter) }
        if let note = noteFilter { base = base.filter { $0.materialId == note } }
        if !q.isEmpty {
            base = base.filter { $0.front.localizedCaseInsensitiveContains(q) || $0.back.localizedCaseInsensitiveContains(q) }
        }
        // A generation run's cards lead the list while it's fresh.
        guard !recentAIIds.isEmpty else { return base }
        let recent = Set(recentAIIds)
        let byId = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return recentAIIds.compactMap { byId[$0] } + base.filter { !recent.contains($0.id) }
    }

    private var showsEmptyDeck: Bool { hasLoaded && cards.isEmpty && !isGeneratingCards }
    private var isGeneratingCards: Bool { runningJob?.activity.purpose == "add" }
    private var selectedDrafts: [String] {
        shownCards.filter { selection.contains($0.id) && $0.status == .draft }.map(\.id)
    }

    var body: some View {
        List(selection: $selection) {
            if let job = runningJob, !isGeneratingCards {
                Section {
                    AIProgressStrip(activity: job.activity, onStop: { store.stopAIJob(job.key) }, isInline: true)
                }
                .graspSection()
            }
            if showsEmptyDeck {
                // A deck with no cards: one action and a quiet way out, no
                // study buttons, tabs, filters or counts.
                Section { emptyDeck }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
            Section {
                studyButtons
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                if let why = studyUnavailableNote {
                    Text(why)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 4, trailing: 0))
                }
                GRASPSegmented(
                    selection: $tab, options: Tab.allCases.map { ($0, $0.rawValue) }, fillsWidth: true
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            switch tab {
            case .cards: cardSections
            case .overview: OverviewSection(deckIds: deckIds)
            }
            }
        }
        .environment(\.editMode, $editMode)
        .listSectionSpacing(6)
        .overlay(alignment: .bottom) { floatingApproveBar }
        .animation(Motion.glide, value: editMode == .active && !selectedDrafts.isEmpty)
        .sensoryFeedback(.success, trigger: generationFinished)
        .task(id: isGeneratingCards) { await watchGeneration() }
        .graspList()
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search cards")
        .task(id: store.revision) { load() }
        .onAppear {
            if let name = DebugLaunch.filter, let match = CardFilter.allCases.first(where: { $0.rawValue.lowercased() == name }) {
                filter = match
            }
            if DebugLaunch.confirmApproveAll { confirmingApproveAll = true }
            if DebugLaunch.select {
                editMode = .active
                selection = Set(cards.filter { $0.status == .draft }.prefix(3).map(\.id))
            }
            #if DEBUG
            if DebugLaunch.simulateGeneration { simulateGeneration() }
            #endif
            switch DebugLaunch.mode {
            case "study": studying = true
            case "learn": learning = true
            case "test": testPhase = .setup
            case "overview": tab = .overview
            default: break
            }
        }
        .animation(Motion.base, value: runningJob != nil && !isGeneratingCards)
        .fullScreenCover(isPresented: $studying, onDismiss: {
            load()
            guard let step = pendingNextStep else { return }
            pendingNextStep = nil
            switch step {
            case .learnMissed(let ids): learnFocus = ids; learning = true
            case .test: testPhase = .setup
            }
        }) {
            FlashcardStudyView(deckIds: deckIds, deckName: route.name) { pendingNextStep = $0 }
        }
        .fullScreenCover(isPresented: $learning, onDismiss: { learnFocus = []; load() }) {
            LearnRoundView(deckIds: deckIds, deckName: route.name, focusCardIds: learnFocus)
        }
        .testFlow($testPhase, onDismiss: load) {
            TestSetupSheet(deckIds: deckIds, deckName: route.name, onResume: { id in
                $testPhase.advance(to: TestPhase.resuming(id, store: store), store: store)
            }) { attemptId, questions, aiWarning in
                $testPhase.advance(to: .running(attemptId: attemptId, questions: questions, aiWarning: aiWarning), store: store)
            }
        } run: { phase in
            testView(phase)
        }
        .sheet(item: $editing) { card in
            CardEditor(card: card)
        }
        .sheet(isPresented: $creatingCard, onDismiss: load) {
            CardCreator(deckChoices: deckChoices, deckId: deckChoices.first?.id)
        }
        .toolbar {
            if tab == .cards, !cards.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode == .active ? "Done" : "Select") {
                        withAnimation(Motion.glideInOut) { editMode = editMode == .active ? .inactive : .active }
                        selection.removeAll()
                    }
                    .tint(GRASPColor.textPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { actionsMenu.tint(GRASPColor.textPrimary) }
        }
        .sheet(isPresented: $approveFirstNotice) {
            ResultSheet(
                icon: "checklist", title: "Approve some cards first",
                leadText: "A test asks about approved cards, and every card in this deck is still a draft. Approve the ones that look right, then come back."
            )
        }
        .sheet(isPresented: $confirmingApproveAll) {
            let aiDrafts = cards.filter { $0.status == .draft && $0.origin == .aiGenerated }.count
            ConfirmationSheet(
                icon: "checkmark.circle", title: "Approve \(draftCount) draft\(draftCount == 1 ? "" : "s")?",
                message: aiDrafts > 0
                    ? "\(aiDrafts == draftCount ? "All" : "\(aiDrafts) of them") written by the AI. They become cards you can study."
                    : "They become cards you can study.",
                confirmTitle: "Approve all", isDestructive: false, isCompact: true
            ) {
                try? store.approveAllDrafts(inDecks: deckIds)
                load()
            }
        }
        .sheet(isPresented: Binding(get: { aiMessage != nil }, set: { if !$0 { aiMessage = nil } })) {
            ResultSheet(icon: AIGlyph.symbol, title: "AI", leadText: aiMessage)
        }
        .task { await store.refreshGeneratorStatus() }
    }

    private var deckChoices: [Deck] {
        deckIds.compactMap { (try? store.deck($0)) ?? nil }
    }

    private var actionsMenu: some View {
        Menu {
            Button { creatingCard = true } label: { Label("New Card", systemImage: "plus") }
            Section("AI") {
                Button { refineDeck() } label: { Label("Refine Drafts with AI", systemImage: "checkmark.seal") }
                    .disabled(draftCount == 0)
                Button { addCards() } label: { Label("Generate Cards with AI", systemImage: "sparkles") }
                Button { writeOverviews() } label: { Label("Write Overviews", systemImage: "text.book.closed") }
            }
            .disabled(!store.isGeneratorAvailable || runningJob != nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - AI

    private func refineDeck() {
        let ids = deckIds
        let run = AIActivity(headline: "Refining \(route.name) with AI", purpose: "refine")
        store.runAIJob(store.cardJobKey(courseId: courseId), activity: run) { [store] run in
            let result = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await store.refineDeckWithAI(inDecks: ids)
            }
            if !(run.stopRequested && result.isEmpty) {
                aiMessage = result.isEmpty
                    ? "Every draft already looked right. Nothing to change."
                    : "Rewrote \(result.context.refined.count), removed \(result.context.removed.count) off-topic, cleaned up wording on \(result.wordingRefinedCount)."
            }
        }
    }

    private func addCards() {
        let ids = deckIds
        let run = AIActivity(headline: "Adding cards to \(route.name) with AI", purpose: "add")
        additionFailure = nil
        store.runAIJob(store.cardJobKey(courseId: courseId), activity: run) { [store] run in
            let outcome = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await store.addCards(inDecks: ids)
            }
            switch outcome {
            case .added(let count):
                aiMessage = "Added \(count) new card\(count == 1 ? "" : "s") as drafts for you to review."
            case .nothingToAdd:
                if !run.stopRequested { aiMessage = "No new cards to add. The notes are already well covered." }
            case .failed(let failure):
                additionFailure = AppStore.message(for: failure)
            }
        }
    }

    /// Writes an overview for each note behind the deck that lacks one.
    private func writeOverviews() {
        let targets = (try? store.deckOverview(inDecks: deckIds))?.writable ?? []
        guard !targets.isEmpty else {
            aiMessage = "Every note here already has an overview."
            return
        }
        let run = AIActivity(headline: "Writing overviews", units: targets.count)
        store.runAIJob(store.overviewJobKey(courseId: courseId), activity: run) { [store] run in
            var written = 0
            for (index, target) in targets.enumerated() {
                if Task.isCancelled { break }
                run.headline = "Writing overview \(index + 1) of \(targets.count) · \(target.title)"
                let outcome = await AIProgress.$current.withValue(run.reporter(forUnit: index)) {
                    await store.writeOverview(forMaterial: target.materialId, force: true)
                }
                run.completeUnit(index)
                if outcome == .written { written += 1 }
            }
            if !run.stopRequested {
                aiMessage = written == targets.count
                    ? "Wrote \(written) overview\(written == 1 ? "" : "s"). They're on the Overview tab."
                    : "Wrote \(written) of \(targets.count). The rest couldn't be written. Try again later."
            }
        }
    }

    /// One short line for why Study or Learn is dimmed, when it is.
    private var studyUnavailableNote: String? {
        let c = counts
        if c.all == 0 { return nil }
        if c.active == 0 {
            return c.drafts > 0
                ? "\(c.drafts) draft\(c.drafts == 1 ? "" : "s") to approve before you can study."
                : "Nothing active to study. Reactivate suspended cards."
        }
        if dueCount == 0 { return "Nothing due right now. Learn or Test any time." }
        return nil
    }

    /// The Mac's row: Study (yellow when cards are due), Learn, Test. Test is
    /// never dimmed while the deck has cards; with none approved yet it says
    /// what to do instead of looking broken.
    private var studyButtons: some View {
        HStack(spacing: 8) {
            StudyPill(title: "Study", icon: "rectangle.stack.fill", style: .primary,
                      detail: dueCount > 0 ? "\(dueCount)" : nil) { studying = true }
                .disabled(dueCount == 0)
            StudyPill(title: "Learn", icon: "graduationcap.fill", style: .quiet, detail: nil) { learning = true }
                .disabled(activeCount == 0)
            StudyPill(title: unfinishedTest == nil ? "Test" : "Continue test", icon: "checklist", style: .quiet,
                      detail: unfinishedTest.map { "\($0.answered)/\($0.total)" }) {
                if activeCount == 0 {
                    approveFirstNotice = true
                } else if let unfinishedTest {
                    testPhase = TestPhase.resuming(unfinishedTest.attemptId, store: store)
                } else {
                    testPhase = .setup
                }
            }
        }
    }

    @ViewBuilder
    private var cardSections: some View {
        if isGeneratingCards {
            Section { generatingStrip }.graspSection()
        } else if let additionFailure {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(GRASPColor.rejected)
                    Text(additionFailure).graspType(.body).foregroundStyle(GRASPColor.textSecondary)
                    Spacer(minLength: 6)
                    Button("Retry") { addCards() }
                        .font(.graspUI(size: 13, weight: .semibold))
                        .disabled(!store.isGeneratorAvailable || runningJob != nil)
                    Button { self.additionFailure = nil } label: { Image(systemName: "xmark") }
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
            .graspSection()
        }
        if !cards.isEmpty {
            Section {
                UnderstandingSummary(
                    cards: understanding, noteTitles: sourceTitles,
                    onOpenNote: { note in withAnimation(Motion.snappy) { noteFilter = .some(note); filter = .all } },
                    onPractice: { ids in learnFocus = Set(ids); learning = true }
                )
                if let note = noteFilter {
                    HStack(spacing: 8) {
                        Text("Cards from \(note.flatMap { sourceTitles[$0] } ?? "Other")")
                            .font(.graspSubheadline)
                            .foregroundStyle(GRASPColor.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Button("Show all") { withAnimation(Motion.snappy) { noteFilter = nil } }
                            .buttonStyle(.plain)
                            .font(.graspUI(size: 13, weight: .semibold))
                            .foregroundStyle(GRASPColor.textPrimary)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CardFilter.allCases) { option in
                            let on = filter == option
                            Button {
                                withAnimation(Motion.snappy) { filter = option }
                            } label: {
                                Text("\(option.rawValue) \(count(option))")
                                    .font(.graspUI(size: 13, weight: on ? .semibold : .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(on ? GRASPColor.textPrimary : GRASPColor.textTertiary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .background(on ? GRASPColor.surfaceRaised : GRASPColor.inset, in: Capsule())
                                    .overlay(Capsule().strokeBorder(on ? GRASPColor.hairlineStrong : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        if draftCount > 0, query.isEmpty, !isGeneratingCards {
            Section {
                HStack {
                    Label("\(draftCount) awaiting review", systemImage: "rectangle.on.rectangle")
                        .font(.graspSubheadline)
                        .foregroundStyle(GRASPColor.textSecondary)
                    Spacer(minLength: 6)
                    Button("Review drafts") { withAnimation(Motion.snappy) { filter = .drafts } }
                        .buttonStyle(.plain)
                        .font(.graspUI(size: 13, weight: .semibold))
                        .foregroundStyle(GRASPColor.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .overlay(Capsule().strokeBorder(GRASPColor.textPrimary.opacity(0.4), lineWidth: 1))
                    // With nothing to study yet, approving is the page's one
                    // yellow primary. Otherwise it is yellow text, and Study
                    // holds the fill.
                    if activeCount == 0 {
                        Button("Approve All") { confirmingApproveAll = true }
                            .buttonStyle(.plain)
                            .font(.graspUI(size: 13, weight: .semibold))
                            .foregroundStyle(GRASPColor.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Capsule().fill(GRASPColor.brand))
                    } else {
                        Button("Approve All") { confirmingApproveAll = true }
                            .buttonStyle(.plain)
                            .font(.graspUI(size: 13, weight: .semibold))
                            .foregroundStyle(GRASPColor.accent)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .graspSection()
        }
        Section("\(shownCards.count) cards") {
            ForEach(shownCards) { card in
                Button { editing = card } label: {
                    CardRowView(card: card, understanding: understandingById[card.id] ?? .of(level: nil),
                                sourceTitle: card.materialId.flatMap { sourceTitles[$0] },
                                reviewNote: reviewNotes[card.id])
                }
                    .buttonStyle(.plain)
                    .tag(card.id)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? store.deleteCard(card.id)
                            load()
                        } label: { Label("Delete", systemImage: "trash") }
                        Button {
                            try? store.setCardStatus(card.id, status: card.status == .suspended ? .active : .suspended)
                            load()
                        } label: {
                            Label(card.status == .suspended ? "Restore" : "Suspend", systemImage: "pause.circle")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        if card.status == .draft {
                            Button {
                                try? store.setCardStatus(card.id, status: .active)
                                load()
                            } label: { Label("Approve", systemImage: "checkmark") }
                            .tint(GRASPColor.success)
                        }
                    }
            }
        }
        .graspSection()
    }

    @ViewBuilder
    private func testView(_ phase: TestPhase) -> some View {
        switch phase {
        case .setup:
            EmptyView()   // presented as a sheet by `testFlow`
        case .running(let attemptId, let questions, let aiWarning, let answered):
            TestRunView(attemptId: attemptId, deckName: route.name, questions: questions, aiWarning: aiWarning,
                        answered: answered) { graded in
                _ = try? store.finishTest(attemptId: attemptId)
                $testPhase.advance(to: .results(attemptId: attemptId, graded: graded), store: store)
            }
        case .results(let attemptId, let graded):
            TestResultsView(deckName: route.name, attemptId: attemptId, graded: graded, deckIds: deckIds) { id, questions in
                $testPhase.advance(to: .running(attemptId: id, questions: questions, aiWarning: nil), store: store)
            }
        }
    }

    private func load() {
        let ids = deckIds
        cards = (try? store.cards(inDecks: ids)) ?? []
        reviewNotes = CardQuality.reviewNotes(for: cards)
        learnLevels = (try? store.learnLevels(forDecks: ids)) ?? [:]
        understanding = (try? store.understanding(forDecks: ids)) ?? []
        dueCount = (try? store.dueCards(inDecks: ids).count) ?? 0
        unfinishedTest = store.unfinishedTest(forDecks: ids)
        hasLoaded = true
        loadSourceTitles()
        if filter == .drafts, !cards.contains(where: { $0.status == .draft }) { filter = .all }
        if cards.isEmpty, let courseId { courseFileCount = (try? store.materialCount(inCourse: courseId)) ?? 0 }
    }

    #if DEBUG
    /// Stand-in for a model: a store-owned "add" job that writes an AI
    /// draft a second, so the live strip can be watched without one.
    private func simulateGeneration() {
        guard let deckId = deckIds.first else { return }
        let materialId = cards.compactMap(\.materialId).first
        let run = AIActivity(headline: "Simulated generation", purpose: "add")
        store.runAIJob(store.cardJobKey(courseId: courseId), activity: run) { [store] run in
            for index in 1...8 {
                try? await Task.sleep(for: .seconds(1))
                if run.stopRequested { break }
                let card = Card(materialId: materialId, front: "Simulated term \(index)",
                                back: "A pretend definition written by the simulated model, number \(index).",
                                origin: .aiGenerated, status: .draft)
                try? await store.database.queue.write { db in
                    try card.save(db)
                    try DeckCard(deckId: deckId, cardId: card.id, sortIndex: 1000 + index).save(db)
                }
            }
            store.reload()
        }
    }
    #endif

    private func loadSourceTitles() {
        for id in Set(cards.compactMap(\.materialId)) where sourceTitles[id] == nil {
            if let material = (try? store.material(id)) ?? nil { sourceTitles[id] = material.title }
        }
    }

    /// While a card-writing job runs, read the deck about twice a second:
    /// each note's cards are written as the note finishes, so they arrive
    /// in the list one batch at a time. A success haptic when it ends.
    private func watchGeneration() async {
        guard isGeneratingCards else {
            if !seenIds.isEmpty { generationFinished += 1; seenIds = [] }
            return
        }
        seenIds = Set(cards.map(\.id))
        recentAIIds = []
        liveSourceTitle = nil
        while !Task.isCancelled, isGeneratingCards {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let fresh = try? store.cards(inDecks: deckIds) else { continue }
            let arrivals = fresh.filter { !seenIds.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
            guard !arrivals.isEmpty else { continue }
            seenIds.formUnion(arrivals.map(\.id))
            if let source = arrivals.first(where: { $0.materialId != nil })?.materialId,
               let material = (try? store.material(source)) ?? nil {
                liveSourceTitle = material.title
            }
            recentAIIds = arrivals.map(\.id) + recentAIIds
            withAnimation(Motion.glide) {
                cards = fresh
                loadSourceTitles()
                reviewNotes = CardQuality.reviewNotes(for: fresh)
            }
            store.refreshDeckCounts()
        }
    }

    // MARK: - Generating and empty states

    private var generatingStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: AIGlyph.symbol)
                .font(.graspUI(size: 13, weight: .semibold))
                .foregroundStyle(GRASPColor.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text(liveSourceTitle.map { "Generating cards from \($0)…" } ?? "Generating cards from your notes…")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(recentAIIds.count) new card\(recentAIIds.count == 1 ? "" : "s")")
                .graspType(.meta)
                .monospacedDigit()
                .foregroundStyle(GRASPColor.textSecondary)
            if let job = runningJob {
                Button("Stop") { store.stopAIJob(job.key) }
                    .font(.graspUI(size: 13, weight: .semibold))
            }
        }
    }

    private var emptyDeck: some View {
        let hasFiles = courseFileCount > 0
        return VStack(spacing: 12) {
            if hasFiles {
                Button { generateFromCourse() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: AIGlyph.symbol).foregroundStyle(GRASPColor.accent)
                        Text("Generate cards from your notes").font(.graspUI(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                }
                .buttonStyle(GRASPQuietButton())
                .disabled(!store.isGeneratorAvailable)
                Text(store.isGeneratorAvailable ? "Uses the files in this course" : "Set up an AI model in Settings → AI")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            } else {
                Label("Add this course's files on your Mac first", systemImage: "doc.badge.plus")
                    .font(.graspUI(size: 15, weight: .semibold))
                    .foregroundStyle(GRASPColor.textPrimary)
                Text("Cards are written from a course's notes. Generate cards is waiting for them.")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    .multilineTextAlignment(.center)
            }
            if let notice {
                HStack(spacing: 8) {
                    Text(notice).graspType(.body).foregroundStyle(GRASPColor.textSecondary)
                    if hasFiles { Button("Retry") { generateFromCourse() } }
                }
            }
            Button("Add a card manually") { creatingCard = true }
                .font(.graspUI(size: 14, weight: .medium))
                .foregroundStyle(GRASPColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func generateFromCourse() {
        guard let courseId, let deckId = deckIds.first else { return }
        notice = nil
        let run = AIActivity(headline: "Writing cards for \(route.name) with AI", purpose: "add")
        store.runAIJob(store.cardJobKey(courseId: courseId), activity: run) { [store] run in
            do {
                let outcome = try await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                    try await store.generateCards(fromCourse: courseId, intoDeck: deckId)
                }
                switch outcome {
                case .noMaterials: courseFileCount = 0
                case .generated(let created, _, _):
                    if created == 0 && !run.stopRequested { notice = "Nothing came out of these notes." }
                }
            } catch let error as CardAI.CourseGenerationError {
                switch error {
                case .generatorUnavailable: notice = "No AI model is reachable. Check Settings → AI."
                case .noReadableNotes: notice = "No readable text in this course's files."
                case .deckMissing: notice = "This deck no longer exists."
                case .writeFailed(let created, _):
                    notice = (created > 0 ? "Stopped after \(created). " : "") + "Couldn't save the cards. Try again."
                }
            } catch {
                notice = PlainError.message(error, couldnt: "write cards")
            }
            load()
        }
    }

    @ViewBuilder private var floatingApproveBar: some View {
        let drafts = selectedDrafts
        if editMode == .active, !drafts.isEmpty {
            Button {
                try? store.bulkSetStatus(drafts, status: .active)
                selection.removeAll()
                load()
            } label: {
                Text("Approve \(drafts.count) selected")
                    .font(.graspUI(size: 15, weight: .semibold))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
            }
            .buttonStyle(GRASPQuietButton())
            .background(GRASPColor.surfaceRaised, in: Capsule())
            .padding(.bottom, 14)
            .transition(Motion.slide(from: .bottom))
        }
    }
}

/// A compact mode button for the deck page's row. `primary` is the
/// screen's one filled yellow button.
private struct StudyPill: View {
    enum Style { case primary, quiet }
    let title: String
    let icon: String
    let style: Style
    let detail: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.graspUI(size: 12, weight: .semibold))
                Text(title).font(.graspUI(size: 14, weight: .semibold)).lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.graspUI(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .opacity(0.75)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .foregroundStyle(style == .primary && isEnabled ? GRASPColor.ink : GRASPColor.textPrimary)
            .background {
                if style == .primary && isEnabled {
                    Capsule().fill(GRASPColor.brand)
                } else {
                    Capsule().fill(GRASPColor.surface)
                        .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong, lineWidth: 1))
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct CardRowView: View {
    let card: Card
    let understanding: UnderstandingState
    let sourceTitle: String?
    let reviewNote: String?

    /// Draft and suspended cards keep the 2 pt rail; it no longer says
    /// anything about mastery, the pips do.
    private var railTint: Color {
        card.status == .suspended ? GRASPColor.rejected : GRASPColor.hairlineStrong
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if card.status == .active {
                    PipMeter(state: understanding, size: .row)
                        .padding(.top, 5)
                } else {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(railTint)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 27, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if card.origin == .aiGenerated && card.status == .draft {
                        Image(systemName: AIGlyph.symbol)
                            .font(.graspUI(size: 11, weight: .semibold))
                            .foregroundStyle(GRASPColor.accent)
                    }
                    Text(card.front)
                        .graspType(.rowTitle)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text(CardRowStatus.text(for: card))
                        .font(.graspUI(size: 12))
                        .foregroundStyle(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
                Text(card.back)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .lineLimit(3)
                if card.origin == .aiGenerated, let sourceTitle {
                    Text("from \(sourceTitle)")
                        .font(.graspUI(size: 12))
                        .foregroundStyle(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
                if let reviewNote {
                    Text(reviewNote)
                        .font(.graspUI(size: 12))
                        .foregroundStyle(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// Edit a card's front and back.
struct CardEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var card: Card
    @State private var refining = false
    @State private var refineMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Front") { TextField("Front", text: $card.front, axis: .vertical) }
                    .graspSection()
                Section("Back") { TextField("Back", text: $card.back, axis: .vertical).lineLimit(3...12) }
                    .graspSection()
                if let materialId = card.materialId {
                    Section {
                        NavigationLink("View source note") { NoteScreen(materialId: materialId) }
                        if store.isGeneratorAvailable {
                            Button {
                                refining = true
                                Task {
                                    let outcome = await store.refineCard(card.id)
                                    refining = false
                                    refineMessage = switch outcome {
                                    case .removed: "It looked off-topic against its note, so it was removed."
                                    case .refined: "Checked against its note and cleaned up."
                                    case .unavailable: "Nothing to change."
                                    }
                                    if outcome != .unavailable, let fresh = try? store.card(card.id) { card = fresh }
                                }
                            } label: {
                                HStack {
                                    Label("Refine with AI", systemImage: "sparkles")
                                    if refining { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(refining)
                        }
                    } footer: {
                        if let refineMessage { Text(refineMessage) }
                    }
                    .graspSection()
                }
            }
            .graspList()
            .navigationTitle("Edit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        try? store.updateCard(card)
                        dismiss()
                    }
                    .disabled(card.front.trimmingCharacters(in: .whitespaces).isEmpty
                              || card.back.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// A source note's text.
struct NoteScreen: View {
    @Environment(AppStore.self) private var store
    let materialId: String

    /// The lecture/chapter and date, read the same way an overview's own
    /// header does -- so a note filed as
    /// "2026-08-27_Lecture-02_Row-Reduction-and-Echelon-Forms" reads as
    /// "LECTURE 2 · AUG 27" here too, not as its raw filename.
    private var heading: (kicker: String?, title: String)? {
        ((try? store.material(materialId)) ?? nil).map(DeckOverviewReader.lessonHeading(for:))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let kicker = heading?.kicker {
                    Text(kicker)
                        .graspType(.eyebrow)
                        .foregroundStyle(GRASPColor.accent)
                }
                Text((try? store.noteText(forMaterial: materialId))??.reflowed ?? "This note's text isn't available.")
                    .graspType(.prose)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GRASPColor.canvas.ignoresSafeArea())
        .navigationTitle(heading?.title ?? (try? store.material(materialId))??.title ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The deck's lesson overviews, read-only -- written on the Mac (or, later,
/// by the on-device model) and synced here.
private struct OverviewSection: View {
    @Environment(AppStore.self) private var store
    let deckIds: [String]

    var body: some View {
        let overview = try? store.deckOverview(inDecks: deckIds)
        if let overview, !overview.entries.isEmpty {
            ForEach(overview.entries) { entry in
                Section {
                    OverviewSectionsView(overview: entry)
                        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                }
                .graspSection()
            }
        } else {
            Section {
                ContentUnavailableView(
                    "No overviews yet",
                    systemImage: "text.book.closed",
                    description: Text("Write overviews for this deck's notes on your Mac and they'll sync here.")
                )
            }
        }
    }
}
