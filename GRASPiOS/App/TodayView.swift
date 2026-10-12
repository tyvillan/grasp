import SwiftUI
import GRASPCore

/// The home tab -- the Mac's Home at phone width: the next exam as a big
/// yellow countdown, Today's plan with the one yellow button, the next
/// exams, what the due count means, and the deck you were last in.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var decks: [AppStore.DeckSummary] = []
    @State private var exams: [AppStore.UpcomingEvent] = []
    @State private var standings: [String: ExamPlan.Standing] = [:]
    @State private var plan = TodayPlan(steps: [])
    @State private var streak = AppStore.StudyStreak(days: 0, studiedToday: false, reviewsToday: 0)
    @State private var studying: StudyTarget?
    @State private var route: TodayRoute?
    @State private var showsAcronym = false
    /// The acronym is shown once, on the first launch; after that a long
    /// press on the wordmark brings it back.
    @AppStorage("seenAcronym", store: .standard) private var seenAcronym = false
    @AppStorage("todayPlanChecked") private var checkedStore = ""

    struct StudyTarget: Identifiable {
        let id = UUID()
        let deckIds: [String]
        let name: String
    }

    enum TodayRoute: Hashable {
        case deck(DeckRoute)
        case exam(courseId: String, examEventId: String)
    }

    private var totalDue: Int { decks.reduce(0) { $0 + $1.dueCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GRASPSpace.l) {
                header
                hero
                planCard
                ForEach(Array(exams.dropFirst().prefix(2).enumerated()), id: \.element.id) { index, item in
                    Button { open(item) } label: {
                        ExamCard(item: item, standing: standings[item.event.id])
                    }
                    .buttonStyle(.plain)
                    .revealOnAppear(index: 3 + index)
                }
                DueExplainerCard(totalDue: totalDue)
                if let deck = Dashboard.jumpBackIn(decks) { jumpBackCard(deck) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(GRASPColor.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { store.sync.syncNow() }
        .task(id: store.revision) { load() }
        .fullScreenCover(item: $studying, onDismiss: load) { target in
            FlashcardStudyView(deckIds: target.deckIds, deckName: target.name)
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .deck(let deck): DeckScreen(route: deck)
            case .exam(let courseId, let examEventId): ExamScreen(courseId: courseId, examEventId: examEventId)
            }
        }
        .onAppear {
            if !seenAcronym {
                showsAcronym = true
                seenAcronym = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: GRASPSpace.m) {
            HStack(spacing: GRASPSpace.s) {
                HStack(spacing: 8) {
                    BrandDot(size: 14)
                    Text("GRASP").font(.graspDisplay(20)).foregroundStyle(GRASPColor.textPrimary)
                }
                .onLongPressGesture {
                    withAnimation(Motion.choose(Motion.snappy, reduceMotion: reduceMotion)) { showsAcronym.toggle() }
                }
                .sensoryFeedback(.selection, trigger: showsAcronym)
                .accessibilityLabel("GRASP: Gather Resources, Apply, Study, Perform")
                Spacer()
                SyncIndicator()
                if streak.days > 0 {
                    StreakPill(days: streak.days, studiedToday: streak.studiedToday)
                }
            }
            if showsAcronym {
                acronym.transition(.opacity.combined(with: .move(edge: .top)))
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Today")
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
        }
    }

    private var acronym: some View {
        let words = ["Gather", "Resources", "Apply", "Study", "Perform"]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(words, id: \.self, content: acronymWord) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) { ForEach(words.prefix(3), id: \.self, content: acronymWord) }
                HStack(spacing: 12) { ForEach(words.suffix(2), id: \.self, content: acronymWord) }
            }
        }
        .onTapGesture { withAnimation(Motion.snappy) { showsAcronym = false } }
    }

    private func acronymWord(_ word: String) -> some View {
        HStack(spacing: 4) {
            Text(String(word.prefix(1))).font(.graspDisplay(16)).foregroundStyle(GRASPColor.accent)
            Text(word).font(.graspUI(size: 13, weight: .medium)).foregroundStyle(GRASPColor.textPrimary)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        Group {
            if let exam = exams.first {
                CountdownHero(item: exam, days: store.daysUntil(exam.event), numeralSize: 132)
            } else {
                DueHero(totalDue: totalDue, numeralSize: 132)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .graspCard(padding: 22)
        .contentShape(RoundedRectangle(cornerRadius: GRASPRadius.card))
        .onTapGesture { if let exam = exams.first { open(exam) } }
        .revealOnAppear(index: 0, distance: 14)
    }

    // MARK: - Plan

    private static var todayKey: String { Date().formatted(.iso8601.year().month().day()) }

    private var checked: Set<String> {
        let parts = checkedStore.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == Self.todayKey else { return [] }
        return Set(parts[1].split(separator: ",").map(String.init))
    }

    private func toggle(_ step: TodayPlan.Step) {
        var set = checked
        if set.contains(step.id) { set.remove(step.id) } else { set.insert(step.id) }
        withAnimation(Motion.choose(Motion.snappy, reduceMotion: reduceMotion)) {
            checkedStore = Self.todayKey + "|" + set.sorted().joined(separator: ",")
        }
    }

    private var minutesLeft: Int {
        plan.steps.filter { !checked.contains($0.id) }.reduce(0) { $0 + $1.minutes }
    }

    private var allDone: Bool { !plan.steps.isEmpty && plan.steps.allSatisfy { checked.contains($0.id) } }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today's plan")
                    .font(.graspDisplay(22))
                    .foregroundStyle(GRASPColor.textPrimary)
                Spacer()
                if !plan.steps.isEmpty {
                    Text(allDone ? "All done" : "about \(minutesLeft) min")
                        .graspType(.meta)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(minutesLeft)))
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
            .padding(.bottom, GRASPSpace.s)

            if plan.steps.isEmpty {
                Text("Nothing due and no exams coming up.")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .padding(.vertical, GRASPSpace.s)
            } else {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                    PlanStepRow(step: step, isDone: checked.contains(step.id),
                                onToggle: { toggle(step) }, onOpen: { run(step) })
                        .revealOnAppear(index: index + 1)
                }
                Button {
                    if let next = plan.steps.first(where: { !checked.contains($0.id) }) { run(next) }
                } label: {
                    Text(allDone ? "Plan done" : (checked.isEmpty ? "Start today's plan" : "Continue today's plan"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(GRASPProminentButton())
                .disabled(allDone)
                .overlay { CelebrationBurst(trigger: allDone) }
                .padding(.top, GRASPSpace.m)
            }
        }
        .graspCard(padding: 20)
    }

    private func run(_ step: TodayPlan.Step) {
        switch step.action {
        case .review(let deckIds, let name):
            studying = StudyTarget(deckIds: deckIds, name: name)
        case .continueDeck(_, let deckId, let name):
            studying = StudyTarget(deckIds: [deckId], name: name)
        case .openExam(let eventId):
            if let item = exams.first(where: { $0.event.id == eventId }) { open(item) }
        }
    }

    /// An exam with a study guide opens its page; otherwise its deck, else
    /// the course's cards.
    private func open(_ item: AppStore.UpcomingEvent) {
        guard let courseId = item.event.courseId else { return }
        if store.hasStudyGuide(examEventId: item.event.id) {
            route = .exam(courseId: courseId, examEventId: item.event.id)
        } else if let deckId = item.event.deckId, let deck = try? store.deck(deckId) {
            route = .deck(DeckRoute(scope: .deck(deckId), name: deck.name))
        } else {
            route = .deck(DeckRoute(scope: .course(courseId), name: item.courseName ?? "All Cards"))
        }
    }

    // MARK: - Jump back in

    private func jumpBackCard(_ deck: AppStore.DeckSummary) -> some View {
        Button {
            route = .deck(DeckRoute(scope: .deck(deck.deckId), name: deck.deckName))
        } label: {
            VStack(alignment: .leading, spacing: GRASPSpace.m) {
                SectionLabel(deck.dueCount > 0 ? "Pick up where you left off" : "Last studied")
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(deck.deckName).font(.graspDisplay(19)).foregroundStyle(GRASPColor.textPrimary)
                        Text(deck.courseName).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    }
                    Spacer()
                    if deck.dueCount > 0 {
                        Text("\(deck.dueCount) due").graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                    }
                    Image(systemName: "chevron.right").foregroundStyle(GRASPColor.textTertiary)
                }
                ProgressBar(value: deck.reviewedCount, total: deck.cardCount)
            }
            .graspCard(padding: 20)
        }
        .buttonStyle(.plain)
    }

    private func load() {
        decks = (try? store.dashboardDecks()) ?? []
        exams = (try? store.upcomingExams(within: 30, limit: 4)) ?? []
        var byId: [String: ExamPlan.Standing] = [:]
        for item in exams {
            let ids = store.planDeckIds(for: item.event)
            if !ids.isEmpty { byId[item.event.id] = store.examStanding(deckIds: ids) }
        }
        standings = byId
        plan = store.todayPlan(exams: exams, decks: decks)
        streak = store.studyStreak()
    }
}

/// A GRASP panel: the surface step up from the canvas, with a hairline.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .graspCard(padding: 16)
    }
}
