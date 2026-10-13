import SwiftUI
import GRASPCore
import GRDB

/// Home: one obvious thing to do.
///
/// The hero is the next exam as a giant yellow countdown; beside it,
/// Today's plan -- two to four checkable steps with time estimates and the
/// screen's one yellow button. Below, the next exams as plain cards, one
/// card that says what the big due number means, and the deck you were
/// last in. No course colors here: courses are named in muted text only.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    private var reduceMotion: Bool { Motion.isReduced }
    @Binding var selectedCourseId: String?
    @Binding var selectedDeckId: String?

    @State private var decks: [AppStore.DeckSummary] = []
    @State private var upcoming: [AppStore.UpcomingEvent] = []
    @State private var standings: [String: ExamPlan.Standing] = [:]
    @State private var plan = TodayPlan(steps: [])
    @State private var streak = AppStore.StudyStreak(days: 0, studiedToday: false, reviewsToday: 0)
    @State private var studying: StudyTarget?
    /// Tests finished since midnight.
    @State private var testsToday = 0
    /// "yyyy-MM-dd|id,id": which plan steps were ticked off, today only.
    @AppStorage("todayPlanChecked") private var checkedStore = ""
    @AppStorage("dailyCardGoal") private var dailyGoal = 20

    /// Below this the hero and the plan stack instead of sitting side by side.
    private let twoColumnBreakpoint: CGFloat = 820

    struct StudyTarget: Identifiable {
        let id = UUID()
        let deckIds: [String]
        let name: String
    }

    private var totalDue: Int { decks.reduce(0) { $0 + $1.dueCount } }
    private var nextExam: AppStore.UpcomingEvent? { upcoming.first }
    private var laterExams: [AppStore.UpcomingEvent] { Array(upcoming.dropFirst().prefix(2)) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= twoColumnBreakpoint
            ScrollView {
                VStack(alignment: .leading, spacing: GRASPSpace.l) {
                    header
                        .padding(.bottom, GRASPSpace.s)
                    if wide {
                        HStack(alignment: .top, spacing: GRASPSpace.l) {
                            hero.frame(maxWidth: .infinity)
                            // The plan hugs its steps; what's freed below it
                            // is "Today so far".
                            VStack(spacing: GRASPSpace.l) {
                                planCard
                                todaySoFar
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        hero
                        planCard
                        todaySoFar
                    }
                    lowerCards
                    if let deck = Dashboard.jumpBackIn(decks) {
                        continueCard(deck)
                            .padding(.top, GRASPSpace.l)
                            .revealOnAppear(index: 6)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 32)
                .padding(.bottom, 48)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(GRASPColor.canvas)
        .task { load() }
        .onChange(of: store.deckCounts.count) { load() }
        // Calendar edits change no deck count; without this, adding an exam
        // leaves Home stale until the next launch.
        .onChange(of: store.revision) { load() }
        .sheet(item: $studying, onDismiss: load) { target in
            FlashcardStudyView(deckIds: target.deckIds, deckName: target.name)
        }
    }

    private func load() {
        decks = (try? store.dashboardDecks()) ?? []
        upcoming = (try? store.upcomingExams(within: 30, limit: 4)) ?? []
        var byId: [String: ExamPlan.Standing] = [:]
        for item in upcoming {
            let ids = store.planDeckIds(for: item.event)
            if !ids.isEmpty { byId[item.event.id] = store.examStanding(deckIds: ids) }
        }
        standings = byId
        plan = store.todayPlan(exams: upcoming, decks: decks)
        streak = store.studyStreak()
        let midnight = Calendar.current.startOfDay(for: Date())
        testsToday = (try? store.database.queue.read { db in
            try TestAttempt.filter(Column("finishedAt") >= midnight).fetchCount(db)
        }) ?? 0
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: GRASPSpace.m) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Today")
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer(minLength: GRASPSpace.m)
            if streak.days > 0 {
                StreakPill(days: streak.days, studiedToday: streak.studiedToday)
            }
            Button {
                selectedCourseId = ContentView.calendarRoute
            } label: {
                HStack(spacing: 6) {
                    Text("Open calendar")
                    Image(systemName: "arrow.right").font(.graspUI(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(GRASPQuietButton())
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        Group {
            if let exam = nextExam {
                CountdownHero(item: exam, days: store.daysUntil(exam.event),
                              standing: standings[exam.event.id])
            } else {
                DueHero(totalDue: totalDue)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 380, maxHeight: .infinity, alignment: .topLeading)
        .graspCard(padding: 28)
        .contentShape(RoundedRectangle(cornerRadius: GRASPRadius.card))
        .onTapGesture { if let exam = nextExam { study(exam) } }
        .revealOnAppear(index: 0)
    }

    // MARK: - Plan

    private var checked: Set<String> {
        let parts = checkedStore.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == Self.todayKey else { return [] }
        return Set(parts[1].split(separator: ",").map(String.init))
    }

    private static var todayKey: String {
        Date().formatted(.iso8601.year().month().day())
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
                    .font(.graspDisplay(24))
                    .tracking(-0.4)
                    .foregroundStyle(GRASPColor.textPrimary)
                Spacer(minLength: GRASPSpace.s)
                if !plan.steps.isEmpty {
                    Text(allDone ? "All done" : "about \(minutesLeft) min left")
                        .graspType(.meta)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(minutesLeft)))
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
            .padding(.bottom, GRASPSpace.m)

            if plan.steps.isEmpty {
                Text("Nothing due and no exams coming up. Add an exam in the calendar and the plan will build itself around it.")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, GRASPSpace.m)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                        PlanStepRow(step: step, isDone: checked.contains(step.id),
                                    onToggle: { toggle(step) }, onOpen: { run(step) })
                            .revealOnAppear(index: index + 1)
                    }
                }
            }

            if !plan.steps.isEmpty {
                // Right under the last step, not pinned to the card's foot.
                Button {
                    if let next = plan.steps.first(where: { !checked.contains($0.id) }) { run(next) }
                } label: {
                    Text(allDone ? "Plan done" : (checked.isEmpty ? "Start today's plan" : "Continue today's plan"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                }
                .buttonStyle(GRASPProminentButton())
                .disabled(allDone)
                .overlay { CelebrationBurst(trigger: allDone) }
                .padding(.top, GRASPSpace.l)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .graspCard(padding: 28)
    }

    // MARK: - Today so far

    /// What has actually happened today, from data the app keeps: cards
    /// reviewed (against the daily goal in Settings, when there is one), the
    /// streak, and how many of today's plan steps are ticked. Time spent is
    /// not shown: reviews don't record how long they took.
    @ViewBuilder
    private var todaySoFar: some View {
        let doneSteps = plan.steps.filter { checked.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Today so far")
            HStack(alignment: .top, spacing: GRASPSpace.xl) {
                soFarFigure("\(streak.reviewsToday)", streak.reviewsToday == 1 ? "card reviewed" : "cards reviewed")
                soFarFigure("\(testsToday)", testsToday == 1 ? "test finished" : "tests finished")
                if !plan.steps.isEmpty {
                    soFarFigure("\(doneSteps) of \(plan.steps.count)", "plan steps done")
                }
                Spacer(minLength: 0)
            }
            if dailyGoal > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressBar(value: min(streak.reviewsToday, dailyGoal), total: dailyGoal,
                                tint: GRASPColor.textPrimary.opacity(0.55))
                    Text(streak.reviewsToday >= dailyGoal
                         ? "Daily goal of \(dailyGoal) cards reached"
                         : "\(dailyGoal - streak.reviewsToday) more to reach today's goal of \(dailyGoal)")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .graspCard(padding: 24)
        .revealOnAppear(index: 2)
    }

    private func soFarFigure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.graspDisplay(28))
                .tracking(-0.4)
                .monospacedDigit()
                .foregroundStyle(GRASPColor.textPrimary)
                .contentTransition(.numericText())
            Text(label)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        }
    }

    private func run(_ step: TodayPlan.Step) {
        switch step.action {
        case .review(let deckIds, let name):
            studying = StudyTarget(deckIds: deckIds, name: name)
        case .continueDeck(_, let deckId, let name):
            studying = StudyTarget(deckIds: [deckId], name: name)
        case .openExam(let eventId):
            if let item = upcoming.first(where: { $0.event.id == eventId }) { study(item) }
        }
    }

    /// Straight into what the exam is actually about: its study page when
    /// a study guide says which lectures it covers, else its linked deck,
    /// else the course's "All Cards".
    private func study(_ item: AppStore.UpcomingEvent) {
        guard let courseId = item.event.courseId else { return }
        selectedCourseId = courseId
        selectedDeckId = store.hasStudyGuide(examEventId: item.event.id)
            ? DeckListView.examRowId(item.event.id)
            : item.event.deckId ?? DeckListView.allCardsId
    }

    // MARK: - Lower cards

    private var lowerCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: GRASPSpace.l, alignment: .top)],
                  alignment: .leading, spacing: GRASPSpace.l) {
            ForEach(Array(laterExams.enumerated()), id: \.element.id) { index, item in
                Button { study(item) } label: {
                    ExamCard(item: item, standing: standings[item.event.id])
                }
                .buttonStyle(.plain)
                .revealOnAppear(index: 3 + index)
            }
            DueExplainerCard(totalDue: totalDue)
                .revealOnAppear(index: 5)
        }
    }

    // MARK: - Continue

    private func continueCard(_ deck: AppStore.DeckSummary) -> some View {
        VStack(alignment: .leading, spacing: GRASPSpace.l) {
            SectionLabel(deck.dueCount > 0 ? "Pick up where you left off" : "Last studied")
            HStack(alignment: .firstTextBaseline, spacing: GRASPSpace.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deck.deckName)
                        .font(.graspDisplay(22))
                        .tracking(-0.3)
                        .foregroundStyle(GRASPColor.textPrimary)
                    Text(deck.courseName)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                Spacer(minLength: GRASPSpace.m)
                if deck.dueCount > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(deck.dueCount)")
                            .graspType(.numeral)
                            .foregroundStyle(GRASPColor.textPrimary)
                        Text("due")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ProgressBar(value: deck.reviewedCount, total: deck.cardCount)
                Text("\(deck.reviewedCount) of \(deck.cardCount) cards reviewed")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            HStack(spacing: GRASPSpace.s) {
                Button("Continue") {
                    studying = StudyTarget(deckIds: [deck.deckId], name: deck.deckName)
                }
                .buttonStyle(GRASPQuietButton())
                .disabled(deck.dueCount == 0)
                Button("Open deck") {
                    selectedCourseId = deck.courseId
                    selectedDeckId = deck.deckId
                }
                .buttonStyle(GRASPQuietButton())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .graspCard(padding: 24)
    }
}
