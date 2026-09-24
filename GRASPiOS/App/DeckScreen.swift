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
    @State private var editing: Card?
    @State private var query = ""
    @State private var creatingCard = false
    @State private var aiMessage: String?

    private var courseId: String? {
        switch route.scope {
        case .deck(let id): return (try? store.deck(id))??.courseId
        case .course(let id): return id
        }
    }

    /// The AI job running on this course, if any -- owned by the store, so
    /// it keeps going (with its Stop button) when this screen closes.
    private var runningJob: (key: String, activity: AIActivity)? {
        for key in [store.cardJobKey(courseId: courseId), store.overviewJobKey(courseId: courseId)] {
            if let job = store.aiJob(key) { return (key, job.activity) }
        }
        return nil
    }

    private var deckIds: [String] {
        switch route.scope {
        case .deck(let id): return [id]
        case .course(let id): return (try? store.decks(inCourse: id))?.map(\.id) ?? []
        }
    }

    private var activeCount: Int { cards.filter { $0.status == .active }.count }
    private var draftCount: Int { cards.filter { $0.status == .draft }.count }

    private var shownCards: [Card] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return cards }
        return cards.filter { $0.front.localizedCaseInsensitiveContains(q) || $0.back.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if let job = runningJob {
                Section {
                    AIProgressStrip(activity: job.activity, onStop: { store.stopAIJob(job.key) }, isInline: true)
                }
                .graspSection()
            }
            Section {
                studyButtons
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            switch tab {
            case .cards: cardSections
            case .overview: OverviewSection(deckIds: deckIds)
            }
        }
        .graspList()
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search cards")
        .task(id: store.revision) { load() }
        .onAppear {
            switch DebugLaunch.mode {
            case "study": studying = true
            case "learn": learning = true
            case "test": testPhase = .setup
            case "overview": tab = .overview
            default: break
            }
        }
        .fullScreenCover(isPresented: $studying, onDismiss: load) {
            FlashcardStudyView(deckIds: deckIds, deckName: route.name)
        }
        .fullScreenCover(isPresented: $learning, onDismiss: load) {
            LearnRoundView(deckIds: deckIds, deckName: route.name)
        }
        .fullScreenCover(item: $testPhase, onDismiss: load) { phase in
            testView(phase)
        }
        .sheet(item: $editing) { card in
            CardEditor(card: card)
        }
        .sheet(isPresented: $creatingCard, onDismiss: load) {
            CardCreator(deckChoices: deckChoices, deckId: deckChoices.first?.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actionsMenu }
        }
        .alert("AI", isPresented: Binding(get: { aiMessage != nil }, set: { if !$0 { aiMessage = nil } })) {
            Button("OK") { aiMessage = nil }
        } message: {
            Text(aiMessage ?? "")
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
                Button { addCards() } label: { Label("Add Cards with AI", systemImage: "sparkles") }
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
                    ? "Every draft already looked right -- nothing to change."
                    : "Rewrote \(result.context.refined.count), removed \(result.context.removed.count) off-topic, cleaned up wording on \(result.wordingRefinedCount)."
            }
        }
    }

    private func addCards() {
        let ids = deckIds
        let run = AIActivity(headline: "Adding cards to \(route.name) with AI", purpose: "add")
        store.runAIJob(store.cardJobKey(courseId: courseId), activity: run) { [store] run in
            let count = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await store.generateAdditionalCards(inDecks: ids)
            }
            if !(run.stopRequested && count == 0) {
                aiMessage = count == 0 ? "The notes are already well covered -- no new cards."
                    : "Added \(count) new card\(count == 1 ? "" : "s") as drafts for you to review."
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
                    ? "Wrote \(written) overview\(written == 1 ? "" : "s") -- they're on the Overview tab."
                    : "Wrote \(written) of \(targets.count). The rest couldn't be written -- try again later."
            }
        }
    }

    private var studyButtons: some View {
        HStack(spacing: 10) {
            StudyModeButton(title: "Study", subtitle: dueCount > 0 ? "\(dueCount) due" : "None due",
                            icon: "rectangle.stack.fill", prominent: dueCount > 0) { studying = true }
                .disabled(dueCount == 0)
            StudyModeButton(title: "Learn", subtitle: "\(activeCount) cards",
                            icon: "graduationcap.fill", prominent: dueCount == 0 && activeCount > 0) { learning = true }
                .disabled(activeCount == 0)
            StudyModeButton(title: "Test", subtitle: "Quiz", icon: "checklist", prominent: false) { testPhase = .setup }
                .disabled(activeCount == 0)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardSections: some View {
        if draftCount > 0, query.isEmpty {
            Section {
                HStack {
                    Label("\(draftCount) awaiting review", systemImage: "circle.dashed")
                        .foregroundStyle(GRASPColor.accent)
                    Spacer()
                    Button("Approve All") {
                        try? store.approveAllDrafts(inDecks: deckIds)
                        load()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .graspSection()
        }
        Section("\(shownCards.count) cards") {
            ForEach(shownCards) { card in
                Button { editing = card } label: { CardRowView(card: card) }
                    .buttonStyle(.plain)
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
            // The setup sheet has its own Cancel and Start buttons.
            ScrollView {
                TestSetupSheet(deckIds: deckIds, deckName: route.name) { attemptId, questions, aiWarning in
                    testPhase = .running(attemptId: attemptId, questions: questions, aiWarning: aiWarning)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            }
        case .running(let attemptId, let questions, let aiWarning):
            TestRunView(attemptId: attemptId, deckName: route.name, questions: questions, aiWarning: aiWarning) { graded in
                _ = try? store.finishTest(attemptId: attemptId)
                testPhase = .results(attemptId: attemptId, graded: graded)
            }
        case .results(let attemptId, let graded):
            TestResultsView(deckName: route.name, attemptId: attemptId, graded: graded)
        }
    }

    private func load() {
        let ids = deckIds
        cards = (try? store.cards(inDecks: ids)) ?? []
        dueCount = (try? store.dueCards(inDecks: ids).count) ?? 0
    }
}

private struct StudyModeButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let prominent: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).opacity(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            // The accent is dark gold in light mode and bright amber in
            // dark, so the text on it flips to stay readable on both.
            .foregroundStyle(prominent ? GRASPColor.dynamic(light: 0xFFFFFF, dark: 0x16130C) : GRASPColor.textPrimary)
            .background(prominent ? GRASPColor.accent : GRASPColor.inset,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

private struct CardRowView: View {
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.front)
                    .graspType(.rowTitle)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                switch card.status {
                case .draft:
                    PreviewChip(text: "Draft", tint: GRASPColor.accent, tintSoft: GRASPColor.accentSoft)
                case .suspended:
                    PreviewChip(text: "Suspended", tint: GRASPColor.rejected, tintSoft: GRASPColor.rejectedSoft)
                default:
                    EmptyView()
                }
            }
            Text(card.back)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textSecondary)
                .lineLimit(3)
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

    var body: some View {
        ScrollView {
            Text((try? store.noteText(forMaterial: materialId))??.reflowed ?? "This note's text isn't available.")
                .graspType(.prose)
                .foregroundStyle(GRASPColor.textPrimary)
                .textSelection(.enabled)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GRASPColor.canvas.ignoresSafeArea())
        .navigationTitle((try? store.material(materialId))??.title ?? "Note")
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
