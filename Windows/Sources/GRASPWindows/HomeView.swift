import Foundation
import GRASPCore
import SwiftCrossUI

/// Home, after the Mac's `HomeView` and `HomePieces`: one obvious thing to do.
///
/// The hero is the next exam as a giant yellow countdown; beside it, Today's
/// plan (two to four checkable steps with time estimates and the screen's one
/// yellow button) and "Today so far". Below, the next exams as plain cards,
/// one card that says what the big due number means, and the deck you were
/// last in. No course colours here: courses are named in muted text only.
struct HomeView: View {
    let library: Library
    @Binding var route: Route
    /// Opens a course at a deck (nil for All Cards).
    let onStudy: (String, String?) -> Void

    /// The Mac's column: 40 pt sides, filling the window up to `PageColumn.maxWidth`.
    private static let sidePadding = 40.0
    private static let maxWidth = PageColumn.maxWidth
    private static let gap = 16.0

    var body: some View {
        // Read so a review or a sync redraws the figures.
        let _ = library.revision
        let snapshot = library.homeSnapshot()
        let streak = library.studyStreak()
        let decks = library.dashboardDecks()
        GeometryReader { proxy in
            let available = proxy.size.width.isFinite ? Double(proxy.size.width) : 1000
            let width = min(Self.maxWidth, max(320, available - 2 * Self.sidePadding))
            ScrollView {
                VStack(alignment: .leading, spacing: Int(Self.gap)) {
                    header(streak: streak)
                        .padding(.bottom, 8)
                    topRow(snapshot: snapshot, streak: streak, width: width)
                    lowerCards(snapshot: snapshot, width: width)
                    if let deck = Dashboard.jumpBackIn(decks) {
                        ContinueCard(deck: deck, width: width, onContinue: {
                            library.requestStudy(deckId: deck.deckId)
                            onStudy(deck.courseId, deck.deckId)
                        }, onOpen: {
                            onStudy(deck.courseId, deck.deckId)
                        })
                        .padding(.top, 16)
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.leading, Int(Self.sidePadding))
                .padding(.top, 32)
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: - Header

    private func header(streak: StudyProgress.Streak) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Today")
                Text(Self.dateLine(Date()))
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            Spacer()
            if streak.days > 0 {
                // The Mac's StreakPill: outlined, never yellow.
                Text("\(streak.days)-day streak")
                    .font(Font.system(size: 13, weight: .semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .edged(fill: GRASPColor.surface, edge: GRASPColor.hairlineStrong, radius: 15)
                    .fixedSize()
            }
            GRASPButton("Open calendar \u{2192}") { route = .calendar }
        }
    }

    /// "Sunday, November 15", as the Mac formats it.
    static func dateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = CalendarFormat.locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter.string(from: date)
    }

    // MARK: - Hero, plan and today so far

    /// Below 820 pt the hero and the plan stack, as on the Mac.
    @ViewBuilder
    private func topRow(snapshot: HomeSnapshot, streak: StudyProgress.Streak, width: Double) -> some View {
        let checked = checkedSteps
        let plan = snapshot.plan
        // SwiftCrossUI can't stretch two columns to the taller one, so the
        // row's height is worked out: the plan's rows plus Today so far.
        let planHeight = plan.steps.isEmpty ? 190.0 : 132.0 + Double(plan.steps.count) * 74.0
        let height = max(520.0, planHeight + Self.gap + 200.0)
        if width >= 820 {
            let column = (width - Self.gap) / 2
            HStack(alignment: .top, spacing: Int(Self.gap)) {
                hero(snapshot: snapshot)
                    .card(padding: 28, width: column, height: height)
                VStack(alignment: .leading, spacing: Int(Self.gap)) {
                    planCard(plan, checked: checked, width: column)
                    todaySoFar(plan: plan, checked: checked, streak: streak, testsToday: snapshot.testsToday,
                               width: column, height: height - planHeight - Self.gap)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Int(Self.gap)) {
                hero(snapshot: snapshot).card(padding: 28, width: width, height: 460.0)
                planCard(plan, checked: checked, width: width)
                todaySoFar(plan: plan, checked: checked, streak: streak, testsToday: snapshot.testsToday,
                           width: width, height: nil)
            }
        }
    }

    @ViewBuilder
    private func hero(snapshot: HomeSnapshot) -> some View {
        if let exam = snapshot.exams.first {
            CountdownHero(event: exam, courseName: exam.courseId.flatMap { library.courseName($0) },
                          days: library.daysUntil(exam), standing: snapshot.standings[exam.id])
                .onTapGesture { open(exam) }
        } else {
            DueHero(totalDue: totalDue)
        }
    }

    private var totalDue: Int { library.decks.reduce(0) { $0 + $1.due } }

    private func planCard(_ plan: TodayPlan, checked: Set<String>, width: Double) -> some View {
        let minutesLeft = plan.steps.filter { !checked.contains($0.id) }.reduce(0) { $0 + $1.minutes }
        let allDone = !plan.steps.isEmpty && plan.steps.allSatisfy { checked.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Today's plan")
                    .font(Font.system(size: 24, weight: .heavy))
                    .foregroundColor(GRASPColor.textPrimary)
                Spacer()
                if !plan.steps.isEmpty {
                    Text(allDone ? "All done" : "about \(minutesLeft) min left")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                }
            }
            .padding(.bottom, 12)
            if plan.steps.isEmpty {
                Text("Nothing due and no exams coming up. Add an exam in the calendar and the plan will build itself around it.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textTertiary)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { HairlineRule() }
                    PlanStepRow(step: step, isDone: checked.contains(step.id),
                                onToggle: { toggle(step) }, onOpen: { run(step) })
                }
                GRASPButton(allDone ? "Plan done" : (checked.isEmpty ? "Start today's plan" : "Continue today's plan"),
                            kind: .primary) {
                    if let next = plan.steps.first(where: { !checked.contains($0.id) }) { run(next) }
                }
                .disabled(allDone)
                .padding(.top, 16)
            }
        }
        .card(padding: 28, width: width)
    }

    /// What has actually happened today: cards reviewed against the daily
    /// goal, tests finished, and how many of today's plan steps are ticked.
    private func todaySoFar(plan: TodayPlan, checked: Set<String>, streak: StudyProgress.Streak,
                            testsToday: Int, width: Double, height: Double?) -> some View {
        let doneSteps = plan.steps.filter { checked.contains($0.id) }.count
        let goal = library.settings.dailyGoal
        let reviewed = streak.reviewsToday
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Today so far")
            HStack(alignment: .top, spacing: 24) {
                Figure(value: "\(reviewed)", label: reviewed == 1 ? "card reviewed" : "cards reviewed")
                Figure(value: "\(testsToday)", label: testsToday == 1 ? "test finished" : "tests finished")
                if !plan.steps.isEmpty {
                    Figure(value: "\(doneSteps) of \(plan.steps.count)", label: "plan steps done")
                }
                Spacer()
            }
            if goal > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressBar(fraction: min(1, Double(reviewed) / Double(goal)),
                                tint: GRASPColor.textSecondary, height: 4.0)
                    Text(reviewed >= goal
                         ? "Daily goal of \(goal) cards reached"
                         : "\(goal - reviewed) more to reach today's goal of \(goal)")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                }
            }
            Spacer()
        }
        .card(padding: 24, width: width, height: height)
    }

    // MARK: - Ticking steps off

    private var checkedSteps: Set<String> {
        let parts = library.settings.todayPlanChecked.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == Self.todayKey else { return [] }
        return Set(parts[1].split(separator: ",").map(String.init))
    }

    private static var todayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func toggle(_ step: TodayPlan.Step) {
        var set = checkedSteps
        if set.contains(step.id) { set.remove(step.id) } else { set.insert(step.id) }
        library.settings.todayPlanChecked = Self.todayKey + "|" + set.sorted().joined(separator: ",")
    }

    private func run(_ step: TodayPlan.Step) {
        switch step.action {
        case .review(let courseId, let deckId):
            guard !courseId.isEmpty else { return }
            if let deckId { library.requestStudy(deckId: deckId) }
            onStudy(courseId, deckId)
        case .continueDeck(let courseId, let deckId):
            library.requestStudy(deckId: deckId)
            onStudy(courseId, deckId)
        case .openExam(let eventId):
            if let event = library.homeSnapshot().exams.first(where: { $0.id == eventId }) { open(event) }
        }
    }

    /// The exam's study page when a guide says which lectures it covers,
    /// else its deck, else the course's All Cards.
    private func open(_ event: CalendarEvent) {
        guard let courseId = event.courseId else { return }
        onStudy(courseId, library.studyTarget(for: event))
    }

    // MARK: - Lower cards

    /// The next two exams after the hero's, then "Everything else". The
    /// tiles share the column evenly, one, two or three across (the Mac's
    /// row), and drop to fewer per row only when a tile would be narrower
    /// than 260 pt. Sized for four across they left a gap on the right and
    /// cut their titles short.
    private func lowerCards(snapshot: HomeSnapshot, width: Double) -> some View {
        var tiles: [LowerTile] = snapshot.exams.dropFirst().prefix(2).map { .exam($0) }
        tiles.append(.due)
        let fit = max(1, Int((width + Self.gap) / (260 + Self.gap)))
        let columns = min(tiles.count, fit)
        let tileWidth = ((width - Double(columns - 1) * Self.gap) / Double(columns)).rounded(.down)
        // A fresh node per width: the row otherwise kept the width of the
        // GeometryReader's first pass (920 pt, its 1000 pt guess) even once
        // the real width arrived (see gotchas, "A layout guess sticks").
        return ForEach([Int(width)], id: \.self) { _ in
            VStack(alignment: .leading, spacing: Int(Self.gap)) {
                ForEach(Self.rows(of: tiles, size: columns), id: \.first!.id) { row in
                    HStack(alignment: .top, spacing: Int(Self.gap)) {
                        ForEach(row, id: \.id) { tile in
                            lowerTile(tile, standings: snapshot.standings)
                                .card(padding: 24, width: tileWidth, height: 160.0)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lowerTile(_ tile: LowerTile, standings: [String: ExamPlan.Standing]) -> some View {
        switch tile {
        case .exam(let event):
            ExamCard(event: event, standing: standings[event.id])
                .onTapGesture { open(event) }
        case .due:
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Everything else")
                Text("\(totalDue) card\(totalDue == 1 ? "" : "s") due")
                    .font(Font.system(size: 19, weight: .heavy))
                    .foregroundColor(GRASPColor.textPrimary)
                Text(totalDue == 0
                     ? "You're clear. New cards come due as you learn them."
                     : "You don't need to clear them all. The plan covers what matters before your exams.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
        }
    }

    private enum LowerTile {
        case exam(CalendarEvent), due
        var id: String {
            switch self {
            case .exam(let event): return event.id
            case .due: return "due"
            }
        }
    }

    static func rows<T>(of items: [T], size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}

extension View {
    /// The Mac's `graspCard`: a `surface` panel with a hairline edge and the
    /// card radius. `width` and `height` are the card's outer size; the
    /// content is framed inside them, less the padding and the edge.
    func card(padding: Double, width: Double? = nil, height: Double? = nil) -> some View {
        let inset = 2 * padding + 2
        return self
            .frame(width: width.map { max(0, $0 - inset) }, height: height.map { max(0, $0 - inset) },
                   alignment: .topLeading)
            .padding(Int(padding))
            .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.card)
    }
}

// MARK: - Pieces

/// A figure and its label ("260" over "due").
private struct Figure: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Font.system(size: 28, weight: .heavy))
                .foregroundColor(GRASPColor.textPrimary)
            Text(label)
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
        }
        .fixedSize()
    }
}

/// The next exam as a giant yellow numeral, what it is, and where you stand.
private struct CountdownHero: View {
    let event: CalendarEvent
    let courseName: String?
    let days: Int
    let standing: ExamPlan.Standing?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Next exam")
            Text(days == 0 ? "Today" : "\(days)")
                .font(Font.system(size: days == 0 ? 120 : 190, weight: .heavy))
                .foregroundColor(GRASPColor.accent)
                .lineLimit(1)
            Text(days == 0 ? event.displayTitle : "day\(days == 1 ? "" : "s") to your\n\(event.displayTitle)")
                .font(Font.system(size: 26, weight: .heavy))
                .foregroundColor(GRASPColor.textPrimary)
            Spacer()
            if let standing, standing.activeCards > 0 {
                VStack(alignment: .leading, spacing: 14) {
                    HairlineRule()
                    HStack(alignment: .top, spacing: 24) {
                        Figure(value: "\(standing.dueCards)", label: "due")
                        Figure(value: "\(standing.weakCards)",
                               label: standing.weakCards == 1 ? "weak spot" : "weak spots")
                        Figure(value: "\(standing.activeCards)", label: "cards in play")
                        Spacer()
                    }
                    Text(readinessNote(standing))
                        .font(GRASPFont.body)
                        .foregroundColor(GRASPColor.textSecondary)
                }
                .padding(.bottom, 16)
            }
            Text(detail)
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
                .lineLimit(2)
        }
    }

    private func readinessNote(_ standing: ExamPlan.Standing) -> String {
        let tested: String
        switch standing.daysSinceTest {
        case nil: tested = "You haven't taken a practice test on this yet."
        case 0?: tested = "You took a practice test today."
        case 1?: tested = "Your last practice test was yesterday."
        case let n?: tested = "Your last practice test was \(n) days ago."
        }
        if standing.weakCards > 0 {
            return "Drill the \(standing.weakCards) weak spot\(standing.weakCards == 1 ? "" : "s") first. " + tested
        }
        return standing.dueCards > 0 ? "Clear what's due, then test yourself. " + tested : tested
    }

    private var detail: String {
        var parts: [String] = []
        if let courseName { parts.append(courseName) }
        parts.append(CalendarFormat.string(event.startsAt, template: "EEEMMMd"))
        if let time = event.timeText { parts.append(time) }
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
                .font(Font.system(size: 190, weight: .heavy))
                .foregroundColor(GRASPColor.accent)
                .lineLimit(1)
            Text(totalDue == 1 ? "card waiting" : "cards waiting")
                .font(Font.system(size: 26, weight: .heavy))
                .foregroundColor(GRASPColor.textPrimary)
            Spacer()
            Text("No exams in the next month.")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
        }
    }
}

/// One plan step: a ring that ticks it off, the step, and its time. The rest
/// of the row starts it.
private struct PlanStepRow: View {
    let step: TodayPlan.Step
    let isDone: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ring.onTapGesture(perform: onToggle)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(Font.system(size: 14.5, weight: .semibold))
                        .foregroundColor(isDone ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                    Text(step.subtitle)
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(step.minutes) min")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            .onTapGesture(perform: onOpen)
        }
        .padding(.vertical, 14)
    }

    /// The Mac's CheckRing: a cream ring at 40%, filled yellow with an ink
    /// check when done.
    @ViewBuilder
    private var ring: some View {
        if isDone {
            Text("\u{2713}")
                .font(Font.system(size: 14, weight: .bold))
                .foregroundColor(GRASPColor.ink)
                .frame(width: 26.0, height: 26.0)
                .background(GRASPColor.brand)
                .cornerRadius(13)
        } else {
            Circle()
                .stroke(GRASPColor.textSecondary, style: StrokeStyle(width: 1.5))
                .frame(width: 26.0, height: 26.0)
        }
    }
}

/// One later exam: when, what, and where you stand. Plain, no course colour.
private struct ExamCard: View {
    let event: CalendarEvent
    let standing: ExamPlan.Standing?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(when.uppercased())
                .font(GRASPFont.eyebrow)
                .foregroundColor(GRASPColor.textTertiary)
                .lineLimit(1)
            Text(event.displayTitle)
                .font(Font.system(size: 19, weight: .heavy))
                .foregroundColor(GRASPColor.textPrimary)
                .lineLimit(2)
            Text(summary)
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
                .lineLimit(2)
        }
    }

    private var when: String {
        var text = CalendarFormat.string(event.startsAt, template: "EEEMMMd")
        if let time = event.timeText { text += " · " + time }
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
        parts.append(event.countdownText())
        return parts.joined(separator: " · ")
    }
}

/// "Pick up where you left off": the deck you were last in.
private struct ContinueCard: View {
    let deck: Dashboard.DeckSummary
    let width: Double
    let onContinue: GRASPAction
    let onOpen: GRASPAction

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(deck.dueCount > 0 ? "Pick up where you left off" : "Last studied")
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deck.deckName)
                        .font(Font.system(size: 22, weight: .heavy))
                        .foregroundColor(GRASPColor.textPrimary)
                    Text(deck.courseName).font(GRASPFont.body).foregroundColor(GRASPColor.textTertiary)
                }
                Spacer()
                if deck.dueCount > 0 {
                    HStack(alignment: .bottom, spacing: 5) {
                        Text("\(deck.dueCount)").font(GRASPFont.numeral).foregroundColor(GRASPColor.textPrimary)
                        Text("due").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ProgressBar(fraction: deck.cardCount == 0 ? 0 : Double(deck.reviewedCount) / Double(deck.cardCount),
                            tint: GRASPColor.brand)
                Text("\(deck.reviewedCount) of \(deck.cardCount) cards reviewed")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            HStack(spacing: 8) {
                GRASPButton("Continue", action: onContinue).disabled(deck.dueCount == 0)
                GRASPButton("Open deck", action: onOpen)
            }
        }
        .card(padding: 24, width: width)
    }
}
