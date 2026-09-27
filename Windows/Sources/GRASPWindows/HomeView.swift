import Foundation
import GRASPCore
import SwiftCrossUI

/// The dashboard, after the Mac's `HomeView`: the wordmark, a greeting,
/// a strip of figures with today's goal, upcoming exams, and a shelf of
/// course tiles. The Mac's "pick up where you left off" card and recent
/// decks come later.
struct HomeView: View {
    let library: Library
    @Binding var route: Route
    /// Opens a course at a deck (nil for All Cards).
    let onStudy: (String, String?) -> Void

    private static let horizontalPadding = 32.0

    var body: some View {
        // Read so a review or a sync redraws the figures.
        let _ = library.revision
        let streak = library.studyStreak()
        let upcoming = library.upcomingExams()
        // Outside the ScrollView, where the width is known, as on the Mac.
        let decks = library.dashboardDecks()
        let headline = Dashboard.jumpBackIn(decks)
        let recents = Dashboard.recents(decks)
        GeometryReader { proxy in
            let content = proxy.size.width.isFinite ? proxy.size.width - 2 * Self.horizontalPadding : 800
            // The Mac's rule: the Recent rail sits beside the main column
            // from 860 points wide, and folds underneath below that.
            let showsRail = proxy.size.width >= 860
            let mainWidth = showsRail ? content - Self.railWidth - 32 : content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    statStrip(streak: streak).padding(.top, 26)
                    dailyGoalBar(streak: streak).padding(.top, 14)
                    if showsRail {
                        HStack(alignment: .top, spacing: 32) {
                            mainColumn(upcoming: upcoming, headline: headline, width: mainWidth)
                            RecentRail(decks: recents) { onStudy($0.courseId, $0.deckId) }
                                .frame(width: Self.railWidth)
                        }
                        .padding(.top, 32)
                    } else {
                        VStack(alignment: .leading, spacing: 36) {
                            mainColumn(upcoming: upcoming, headline: headline, width: mainWidth)
                            RecentRail(decks: recents) { onStudy($0.courseId, $0.deckId) }
                        }
                        .padding(.top, 32)
                    }
                }
                .padding(.horizontal, Int(Self.horizontalPadding))
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
        }
    }

    private static let railWidth = 260.0

    /// Upcoming exams first -- a test in three days outranks whatever deck
    /// was open last -- then "pick up where you left off", then the courses.
    private func mainColumn(upcoming: [CalendarEvent], headline: Dashboard.DeckSummary?, width: Double) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            if !upcoming.isEmpty {
                upcomingExams(upcoming)
            }
            if let headline {
                ContinueCard(deck: headline, onContinue: {
                    library.requestStudy(deckId: headline.deckId)
                    onStudy(headline.courseId, headline.deckId)
                }, onOpen: {
                    onStudy(headline.courseId, headline.deckId)
                })
                .frame(maxWidth: 720.0)
            }
            coursesShelf(width: width)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("G.R.A.S.P")
                    .font(Font.system(size: 11, weight: .bold))
                    .foregroundColor(GRASPColor.accent)
                Rectangle().fill(GRASPColor.hairlineStrong).frame(width: 14.0, height: 1.0)
                Text("Gather Resources, Apply, Study, Perform")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(GRASPFont.display)
                    .foregroundColor(GRASPColor.textPrimary)
                Text(Self.dateLine(Date()))
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textTertiary)
            }
        }
    }

    /// "Welcome back, Tyler", by the profile's first name. A fresh Windows
    /// profile is called "Me", which reads oddly, so that one gets no name
    /// until it's renamed in Settings.
    private var greeting: String {
        let first = library.profile.name.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty || first == "Me" ? "Welcome back" : "Welcome back, \(first)"
    }

    /// "Friday, September 25", as the Mac formats it.
    static func dateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter.string(from: date)
    }

    // MARK: - Figures

    private var totalDue: Int { library.decks.reduce(0) { $0 + $1.due } }

    private func statStrip(streak: StudyProgress.Streak) -> some View {
        let cards = library.decks.reduce(0) { $0 + $1.total }
        let courses = library.courseSections.reduce(0) { $0 + $1.courses.count }
        return HStack(spacing: 0) {
            StatFigure(value: totalDue, label: "Due today", tint: totalDue > 0 ? GRASPColor.accent : nil)
            statDivider
            StatFigure(value: cards, label: "Cards", tint: nil)
            statDivider
            StatFigure(value: courses, label: "Courses", tint: nil)
            statDivider
            // Teal only while it's alive: a grey 0 isn't news.
            StatFigure(value: streak.days, label: "Day streak",
                       tint: streak.days > 0 ? GRASPColor.success : nil)
            Spacer()
        }
    }

    /// Today's progress toward the daily goal (Settings), as on the Mac.
    /// Hidden once the goal is met and nothing is left due: a finished day
    /// should feel finished.
    @ViewBuilder
    private func dailyGoalBar(streak: StudyProgress.Streak) -> some View {
        let goal = library.settings.dailyGoal
        if goal > 0 && !(streak.reviewsToday >= goal && totalDue == 0) {
            let met = streak.reviewsToday >= goal
            let progress = min(1, Double(streak.reviewsToday) / Double(goal))
            let barWidth = 420.0
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(met ? "Daily goal met -- \(streak.reviewsToday) cards reviewed"
                             : "\(streak.reviewsToday) of \(goal) cards today")
                        .font(GRASPFont.meta)
                        .foregroundColor(met ? GRASPColor.success : GRASPColor.textSecondary)
                    if !streak.studiedToday && streak.days > 0 {
                        Text("Study today to keep your \(streak.days)-day streak")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.accent)
                    }
                }
                HStack(spacing: 0) {
                    Rectangle().fill(met ? GRASPColor.success : GRASPColor.accent)
                        .frame(width: (barWidth * progress).rounded(), height: 4.0)
                    // hairlineStrong, not inset: on the black canvas an inset
                    // track disappears and the bar reads as nothing.
                    Rectangle().fill(GRASPColor.hairlineStrong)
                        .frame(width: (barWidth * (1 - progress)).rounded(), height: 4.0)
                }
                .cornerRadius(2)
            }
        }
    }

    // MARK: - Upcoming exams

    private func upcomingExams(_ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("Upcoming")
                Spacer()
                Text("Open calendar")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.accent)
                    .onTapGesture { route = .calendar }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events, id: \.id) { event in
                    ExamAlertRow(
                        event: event,
                        courseName: event.courseId.flatMap { library.courseName($0) }
                    ) {
                        if let courseId = event.courseId { onStudy(courseId, event.deckId) }
                    }
                }
            }
        }
        .frame(maxWidth: 720.0)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(GRASPColor.hairlineStrong)
            .frame(width: 1.0, height: 26.0)
            .padding(.horizontal, 22)
    }

    // MARK: - Courses

    private func coursesShelf(width: Double) -> some View {
        let tiles = courseTiles
        let layout = Self.gridLayout(width: width)
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Your courses")
            if tiles.isEmpty {
                Text("Import your notes folder, or sign in to sync, to see your courses here.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textTertiary)
            } else {
                // SwiftCrossUI has no grid, so rows of fixed-width tiles.
                VStack(alignment: .leading, spacing: Int(Self.tileSpacing)) {
                    ForEach(Self.rows(of: tiles, size: layout.columns), id: \.first!.id) { row in
                        HStack(spacing: Int(Self.tileSpacing)) {
                            ForEach(row, id: \.id) { tile in
                                CourseTile(tile: tile) { route = .course(tile.id) }
                                    .frame(width: layout.tileWidth)
                            }
                        }
                    }
                }
            }
        }
    }

    private static let tileSpacing = 10.0

    /// The Mac's `GridItem(.adaptive(minimum: 172, maximum: 230))`: as many
    /// columns as fit at 172 wide or more, each at most 230.
    static func gridLayout(width proposed: Double) -> (columns: Int, tileWidth: Double) {
        // GeometryReader can be offered an infinite (or unset) width while
        // SwiftCrossUI measures the page; converting that to Int crashes.
        let width = proposed.isFinite && proposed > 0 ? proposed : 3 * 230 + 2 * tileSpacing
        let columns = max(1, Int((width + tileSpacing) / (172 + tileSpacing)))
        let tileWidth = min(230, (width - Double(columns - 1) * tileSpacing) / Double(columns))
        return (columns, max(172, tileWidth.rounded(.down)))
    }

    /// Every course that has cards, in sidebar order, with its totals.
    private var courseTiles: [CourseTileData] {
        let semesterNames = Dictionary(uniqueKeysWithValues: library.semesters.map { ($0.id, $0.name) })
        return library.courseSections.flatMap(\.courses).compactMap { course in
            let decks = library.decks(inCourse: course.id)
            guard !decks.isEmpty else { return nil }
            return CourseTileData(
                id: course.id,
                name: course.name,
                eyebrow: course.code ?? course.semesterId.flatMap { semesterNames[$0] },
                colorHex: course.colorHex,
                cards: decks.reduce(0) { $0 + $1.total },
                due: decks.reduce(0) { $0 + $1.due }
            )
        }
    }

    static func rows<T>(of items: [T], size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}

struct CourseTileData: Identifiable {
    let id: String
    let name: String
    let eyebrow: String?
    let colorHex: String?
    let cards: Int
    let due: Int
}

private struct StatFigure: View {
    let value: Int
    let label: String
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(Font.system(size: 15, weight: .semibold))
                .foregroundColor(tint ?? GRASPColor.textPrimary)
            Text(label)
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
        }
        .fixedSize()
    }
}

/// One upcoming exam: what, which course, when, how long you have, and a
/// way to start studying for it. The tint escalates as the date closes in:
/// neutral a month out, amber inside a week, terracotta in the last three
/// days, as on the Mac.
private struct ExamAlertRow: View {
    let event: CalendarEvent
    let courseName: String?
    let onStudy: () -> Void

    private var tint: Color {
        let days = event.daysAway(from: Date())
        if days <= 3 { return GRASPColor.rejected }
        if days <= 7 { return GRASPColor.accent }
        return GRASPColor.textSecondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(tint).frame(width: 3.0, height: 34.0).cornerRadius(2)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayTitle)
                    .font(GRASPFont.rowTitle)
                    .foregroundColor(GRASPColor.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(event.countdownText())
                .font(GRASPFont.meta.weight(.semibold))
                .foregroundColor(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(GRASPColor.inset)
                .cornerRadius(10)
            if event.courseId != nil {
                Button("Study") { onStudy() }.fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(GRASPColor.surface)
        .cornerRadius(10)
    }

    private var detail: String {
        var parts: [String] = []
        if let courseName { parts.append(courseName) }
        parts.append(CalendarFormat.string(event.startsAt, template: "MMMd"))
        if let timeText = event.timeText { parts.append(timeText) }
        return parts.joined(separator: " · ")
    }
}

/// A course on the dashboard: dot and code, the name, then its card and
/// due counts. No border at rest; lighter on hover, as on the Mac.
private struct CourseTile: View {
    let tile: CourseTileData
    let open: () -> Void
    @State var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tile.colorHex.map { Color(hex: $0) } ?? GRASPColor.hairlineStrong)
                    .frame(width: 6.0, height: 6.0)
                if let eyebrow = tile.eyebrow {
                    Text(eyebrow.uppercased())
                        .font(GRASPFont.eyebrow)
                        .foregroundColor(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Text(tile.name)
                .font(GRASPFont.title)
                .foregroundColor(GRASPColor.textPrimary)
                .lineLimit(2)
                .padding(.top, 8)
            Spacer()
            HStack(spacing: 5) {
                Text("\(tile.cards) cards")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
                if tile.due > 0 {
                    Text("·").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                    Text("\(tile.due) due")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.accent)
                }
            }
        }
        .padding(13)
        .frame(height: 112.0)
        .background(isHovering ? GRASPColor.surfaceRaised : GRASPColor.surface)
        .cornerRadius(10)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
    }
}

/// "Pick up where you left off": the one raised element on the dashboard,
/// so "where was I?" is answered before anything else is read.
private struct ContinueCard: View {
    let deck: Dashboard.DeckSummary
    let onContinue: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(deck.dueCount > 0 ? "Pick up where you left off" : "Last studied")
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(deck.deckName)
                        .font(Font.system(size: 24, weight: .semibold))
                        .foregroundColor(GRASPColor.textPrimary)
                    Text(deck.courseName).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                }
                Spacer()
                if deck.dueCount > 0 {
                    HStack(alignment: .bottom, spacing: 5) {
                        Text("\(deck.dueCount)").font(GRASPFont.numeral).foregroundColor(GRASPColor.accent)
                        Text("due").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                    }
                }
            }
            .padding(.top, 14)
            VStack(alignment: .leading, spacing: 7) {
                ProgressBar(fraction: deck.cardCount == 0 ? 0 : Double(deck.reviewedCount) / Double(deck.cardCount))
                Text("\(deck.reviewedCount) of \(deck.cardCount) cards reviewed")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            .padding(.top, 20)
            HStack(spacing: 8) {
                Button("Continue") { onContinue() }.disabled(deck.dueCount == 0).fixedSize()
                Button("Open Deck") { onOpen() }.fixedSize()
            }
            .padding(.top, 20)
        }
        .padding(22)
        .background(GRASPColor.surfaceRaised)
        .cornerRadius(14)
    }
}

/// Decks studied recently, newest first.
private struct RecentRail: View {
    let decks: [Dashboard.DeckSummary]
    let open: (Dashboard.DeckSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Recent")
            if decks.isEmpty {
                Text("Decks you study will collect here.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(decks, id: \.deckId) { deck in
                        RecentRow(deck: deck).onTapGesture { open(deck) }
                    }
                }
            }
        }
    }
}

private struct RecentRow: View {
    let deck: Dashboard.DeckSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.deckName).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary).lineLimit(1)
                    Text(deck.courseName).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).lineLimit(1)
                }
                Spacer()
                if let last = deck.lastReviewedAt {
                    Text(RecentRow.ago(last)).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).fixedSize()
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            Rectangle().fill(GRASPColor.hairlineStrong).frame(height: 1.0)
        }
    }

    /// "5m ago", "3h ago", "2d ago" -- the Mac's narrow relative style.
    nonisolated static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d ago"
        default: return "\(Int(seconds / (86_400 * 30)))mo ago"
        }
    }
}
