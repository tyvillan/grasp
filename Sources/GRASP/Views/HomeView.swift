import SwiftUI
import GRASPCore

/// Home: one obvious thing to do.
///
/// The hero is the next exam as a giant yellow countdown; beside it,
/// Today's plan -- two to four checkable steps with time estimates and the
/// screen's one yellow button. Below, the next exams as plain cards, one
/// card that says what the big due number means, and the deck you were
/// last in. No course colors here: courses are named in muted text only.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedCourseId: String?
    @Binding var selectedDeckId: String?

    @State private var decks: [AppStore.DeckSummary] = []
    @State private var upcoming: [AppStore.UpcomingEvent] = []
    @State private var standings: [String: ExamPlan.Standing] = [:]
    @State private var plan = TodayPlan(steps: [])
    @State private var streak = AppStore.StudyStreak(days: 0, studiedToday: false, reviewsToday: 0)
    @State private var studying: StudyTarget?
    /// "yyyy-MM-dd|id,id": which plan steps were ticked off, today only.
    @AppStorage("todayPlanChecked") private var checkedStore = ""

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
                            planCard.frame(maxWidth: .infinity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        hero
                        planCard
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
                CountdownHero(item: exam, days: store.daysUntil(exam.event))
            } else {
                DueHero(totalDue: totalDue)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 380, maxHeight: .infinity, alignment: .topLeading)
        .graspCard(padding: 28)
        .contentShape(RoundedRectangle(cornerRadius: GRASPRadius.card))
        .onTapGesture { if let exam = nextExam { study(exam) } }
        .revealOnAppear(index: 0, distance: 14)
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

            Spacer(minLength: GRASPSpace.xl)

            if !plan.steps.isEmpty {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .graspCard(padding: 28)
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

// MARK: - Pieces

/// The next exam as a giant yellow numeral that rolls up to its value.
private struct CountdownHero: View {
    let item: AppStore.UpcomingEvent
    let days: Int
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String { item.event.title.isEmpty ? item.event.kind.label : item.event.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Next exam")
            Group {
                if days == 0 {
                    Text("Today")
                } else {
                    Text("\(shown)")
                        .contentTransition(.numericText(value: Double(shown)))
                }
            }
            .font(.graspDisplay(190))
            .tracking(-3.8)
            .foregroundStyle(GRASPColor.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.top, 8)
            .accessibilityLabel(days == 0 ? "Today" : "\(days) days")

            Text(days == 0 ? title : "day\(days == 1 ? "" : "s") to your\n\(title)")
                .font(.graspDisplay(26))
                .tracking(-0.4)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)

            Spacer(minLength: GRASPSpace.xl)

            Text(detail)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(2)
        }
        .onAppear {
            guard shown != days else { return }
            if reduceMotion { shown = days; return }
            withAnimation(Motion.settle.delay(0.12)) { shown = days }
        }
        .onChange(of: days) { withAnimation(Motion.settle) { shown = days } }
    }

    private var detail: String {
        var parts: [String] = []
        if let course = item.courseName { parts.append(course) }
        parts.append(item.event.startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
        if let time = item.event.timeText { parts.append(time) }
        return parts.joined(separator: " · ")
    }
}

/// When no exam is coming: the due count is the number that matters.
private struct DueHero: View {
    let totalDue: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Due today")
            Text("\(totalDue)")
                .font(.graspDisplay(190))
                .tracking(-3.8)
                .foregroundStyle(GRASPColor.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .contentTransition(.numericText(value: Double(totalDue)))
                .padding(.top, 8)
            Text(totalDue == 1 ? "card waiting" : "cards waiting")
                .font(.graspDisplay(26))
                .foregroundStyle(GRASPColor.textPrimary)
            Spacer(minLength: GRASPSpace.xl)
            Text("No exams in the next month.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        }
    }
}

/// One plan step: a ring that fills and draws a check, the step, and its
/// time. The ring ticks the step off; the rest of the row starts it.
private struct PlanStepRow: View {
    let step: TodayPlan.Step
    let isDone: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggle) {
                CheckRing(isOn: isDone)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
            .sensoryFeedback(.success, trigger: isDone) { _, new in new }

            Button(action: onOpen) {
                HStack(alignment: .center, spacing: GRASPSpace.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.graspUI(size: 14.5, weight: .semibold))
                            .foregroundStyle(GRASPColor.textPrimary)
                            .strikethrough(isDone, color: GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(step.subtitle)
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: GRASPSpace.s)
                    Text("\(step.minutes) min")
                        .graspType(.meta)
                        .monospacedDigit()
                        .foregroundStyle(GRASPColor.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(.graspUI(size: 11, weight: .semibold))
                        .foregroundStyle(GRASPColor.textSecondary)
                        .opacity(hovering ? 1 : 0)
                        .offset(x: hovering ? 0 : -3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.snappy, value: hovering)
        }
        .padding(.vertical, 14)
        .opacity(isDone ? 0.5 : 1)
    }
}

/// A cream ring at 40% that fills yellow and draws a check when on.
struct CheckRing: View {
    let isOn: Bool
    var size: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(GRASPColor.textPrimary.opacity(0.4), lineWidth: 1.5)
            Circle()
                .fill(GRASPColor.brand)
                .scaleEffect(isOn ? 1 : 0.2)
                .opacity(isOn ? 1 : 0)
            CheckMark()
                .trim(from: 0, to: isOn ? 1 : 0)
                .stroke(GRASPColor.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.42, height: size * 0.32)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .animation(Motion.choose(Motion.bouncy, reduceMotion: reduceMotion), value: isOn)
    }
}

private struct CheckMark: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A short yellow burst around the primary button when the whole plan is
/// done. Under 1s; nothing under Reduce Motion.
private struct CelebrationBurst: View {
    let trigger: Bool
    @State private var fired = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                let angle = Double(i) / 10 * 2 * .pi
                BrandDot(size: i.isMultiple(of: 2) ? 7 : 5)
                    .rotationEffect(.degrees(fired ? 120 : 0))
                    .offset(x: fired ? cos(angle) * 90 : 0, y: fired ? sin(angle) * 40 : 0)
                    .opacity(fired ? 0 : 1)
            }
        }
        .opacity(trigger && !reduceMotion ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, now in
            guard now, !reduceMotion else { fired = false; return }
            fired = false
            withAnimation(.easeOut(duration: 0.8)) { fired = true }
        }
    }
}

/// The streak: a yellow pill that pulses once when it appears and rolls
/// its number when it grows.
private struct StreakPill: View {
    let days: Int
    let studiedToday: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Text("\(days)")
                .contentTransition(.numericText(value: Double(days)))
            Text("-day streak")
        }
        .font(.graspUI(size: 13, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(GRASPColor.ink)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Capsule().fill(GRASPColor.brand))
        .scaleEffect(pulse ? 1.08 : 1)
        .help(studiedToday ? "You've studied today" : "Study today to keep your streak")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Motion.bouncy.delay(0.35)) { pulse = true }
            withAnimation(Motion.snappy.delay(0.6)) { pulse = false }
        }
        .animation(Motion.snappy, value: days)
    }
}

/// One later exam: when, what, and where you stand. Plain -- no course
/// color, a hairline edge that brightens on hover.
private struct ExamCard: View {
    let item: AppStore.UpcomingEvent
    let standing: ExamPlan.Standing?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(when)
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.textTertiary)
            Text(item.event.title.isEmpty ? item.event.kind.label : item.event.title)
                .font(.graspDisplay(19))
                .tracking(-0.2)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(GRASPSpace.xl)
        .background(hovering ? GRASPColor.surfaceRaised : GRASPColor.surface,
                    in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous)
                .strokeBorder(hovering ? GRASPColor.hairlineStrong : GRASPColor.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: GRASPRadius.card))
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
    }

    private var when: String {
        var text = item.event.startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if let time = item.event.timeText { text += " · " + time }
        return text
    }

    private var summary: String {
        var parts: [String] = []
        if let standing {
            parts.append("\(standing.dueCards) due")
            if standing.weakCards > 0 {
                parts.append("\(standing.weakCards) weak spot\(standing.weakCards == 1 ? "" : "s")")
            }
        }
        parts.append(item.event.countdownText())
        return parts.joined(separator: " · ")
    }
}

/// Says what the big due count means, so 722 doesn't read as a debt.
private struct DueExplainerCard: View {
    let totalDue: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Everything else")
            Text("\(totalDue) card\(totalDue == 1 ? "" : "s") due")
                .font(.graspDisplay(19))
                .tracking(-0.2)
                .foregroundStyle(GRASPColor.textPrimary)
                .contentTransition(.numericText(value: Double(totalDue)))
            Text(totalDue == 0
                 ? "You're clear. New cards come due as you learn them."
                 : "You don't need to clear them all. The plan covers what matters before your exams.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .graspCard(padding: GRASPSpace.xl)
    }
}
