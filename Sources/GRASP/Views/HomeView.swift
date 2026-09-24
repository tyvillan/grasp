import SwiftUI
import GRASPCore

/// The dashboard shown before a course is picked.
///
/// Laid out asymmetrically on purpose: a wide left column carries the one
/// thing worth acting on (the deck to continue) and the course shelf,
/// while a narrow right rail holds reference material -- the day's figures
/// and recent activity. An even grid of same-sized cards would give equal
/// visual weight to "resume studying" and "you have 10 courses", which is
/// not how the screen is actually used.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedCourseId: String?
    @Binding var selectedDeckId: String?

    @State private var decks: [AppStore.DeckSummary] = []
    @State private var upcoming: [AppStore.UpcomingEvent] = []
    @State private var streak = AppStore.StudyStreak(days: 0, studiedToday: false, reviewsToday: 0)
    @AppStorage("dailyCardGoal") private var dailyGoal = 20
    @State private var studyingDeck: StudyTarget?
    @State private var editingCourse: Course?
    @State private var deletingCourse: Course?

    /// Below this the rail would squeeze both columns rather than help, so
    /// it folds under the main column instead.
    private let railBreakpoint: CGFloat = 860
    private let railWidth: CGFloat = 260

    struct StudyTarget: Identifiable {
        let id: String
        let name: String
    }

    private var totalDue: Int { decks.reduce(0) { $0 + $1.dueCount } }
    private var totalCards: Int { decks.reduce(0) { $0 + $1.cardCount } }
    private var courseCount: Int { Set(decks.map(\.courseId)).count }

    private var jumpBackIn: AppStore.DeckSummary? {
        if let mostRecent = decks.filter({ $0.lastReviewedAt != nil })
            .max(by: { $0.lastReviewedAt! < $1.lastReviewedAt! }) {
            return mostRecent
        }
        return decks.filter { $0.dueCount > 0 }.max { $0.dueCount < $1.dueCount }
    }

    /// Decks studied at least once, most recent first -- the "Recents"
    /// list. The deck already in "Jump back in" is dropped so the same
    /// deck doesn't headline the page twice.
    private var recents: [AppStore.DeckSummary] {
        decks
            .filter { $0.lastReviewedAt != nil && $0.deckId != jumpBackIn?.deckId }
            .sorted { $0.lastReviewedAt! > $1.lastReviewedAt! }
            .prefix(6)
            .map { $0 }
    }

    /// Built from the store's course list rather than from the deck rows,
    /// so a course with no decks yet -- one added by hand before its notes
    /// exist -- still shows up here instead of silently missing.
    private var courseRollups: [CourseRollup] {
        let statsByCourse = Dictionary(grouping: decks, by: \.courseId)
        return allCourses.map { course in
            let courseDecks = statsByCourse[course.id] ?? []
            return CourseRollup(
                id: course.id,
                name: course.name,
                // Falls back to the semester rather than a literal
                // "Course" label -- an eyebrow repeating the same word on
                // every tile carries no information and just adds noise
                // to the shelf.
                eyebrow: course.code ?? semesterName(course.semesterId),
                dueCount: courseDecks.reduce(0) { $0 + $1.dueCount },
                cardCount: courseDecks.reduce(0) { $0 + $1.cardCount },
                colorHex: course.colorHex
            )
        }
        .sorted { a, b in
            if a.dueCount != b.dueCount { return a.dueCount > b.dueCount }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var allCourses: [Course] {
        store.coursesBySemester.values.flatMap { $0 }.filter { !$0.isArchived }
    }

    private func semesterName(_ semesterId: String?) -> String? {
        guard let semesterId else { return nil }
        return store.semesters.first { $0.id == semesterId }?.name
    }

    struct CourseRollup: Identifiable {
        let id: String
        let name: String
        let eyebrow: String?
        let dueCount: Int
        let cardCount: Int
        let colorHex: String?
    }

    var body: some View {
        GeometryReader { geo in
            let showsRail = geo.size.width >= railBreakpoint
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    statStrip
                        .padding(.top, 26)
                    dailyGoalBar
                        .padding(.top, 14)
                    if showsRail {
                        HStack(alignment: .top, spacing: 32) {
                            mainColumn
                            rail.frame(width: railWidth)
                        }
                        .padding(.top, 32)
                    } else {
                        VStack(alignment: .leading, spacing: 36) {
                            mainColumn
                            rail
                        }
                        .padding(.top, 32)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(GRASPColor.canvas)
        .task { load() }
        .onChange(of: store.deckCounts.count) { load() }
        // Calendar edits change no deck count, so the line above never
        // fires for them -- without this, adding an exam leaves the alert
        // strip stale until the next launch.
        .onChange(of: store.revision) { load() }
        .sheet(item: $studyingDeck, onDismiss: load) { target in
            FlashcardStudyView(deckIds: [target.id], deckName: target.name)
        }
        .sheet(item: $editingCourse, onDismiss: load) { course in
            CourseEditSheet(course: course)
        }
        .courseDeleteConfirmation($deletingCourse) { _ in load() }
    }

    private func load() {
        decks = (try? store.dashboardDecks()) ?? []
        upcoming = (try? store.upcomingExams(within: 30, limit: 3)) ?? []
        streak = store.studyStreak()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            wordmark
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome back, \(firstName)")
                    .graspType(.display)
                    .foregroundStyle(GRASPColor.textPrimary)
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
        }
    }

    /// The name spelled out, with each source letter carried in the accent
    /// so the acronym explains itself rather than needing a legend.
    private var wordmark: some View {
        HStack(spacing: 10) {
            Text("G.R.A.S.P")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(GRASPColor.accent)
            Rectangle()
                .fill(GRASPColor.hairlineStrong)
                .frame(width: 14, height: 1)
            expansion
                .font(.system(size: 11, weight: .regular))
                .tracking(0.3)
        }
    }

    private var expansion: Text {
        let lead = { (letter: String) in
            Text(letter).foregroundStyle(GRASPColor.accentMuted).fontWeight(.bold)
        }
        let rest = { (text: String) in
            Text(text).foregroundStyle(GRASPColor.textTertiary)
        }
        return lead("G") + rest("ather ")
            + lead("R") + rest("esources, ")
            + lead("A") + rest("pply, ")
            + lead("S") + rest("tudy, ")
            + lead("P") + rest("erform")
    }

    private var firstName: String {
        store.profile.name.split(separator: " ").first.map(String.init) ?? store.profile.name
    }

    /// Three figures on one baseline, separated by hairlines -- the shape
    /// a Mac app uses for a status line. Three equally-sized bordered
    /// tiles would claim the same visual weight as the study card below,
    /// which is the thing actually worth clicking.
    private var statStrip: some View {
        HStack(spacing: 0) {
            StatFigure(value: totalDue, label: "Due today", tint: totalDue > 0 ? GRASPColor.accent : nil)
            statDivider
            StatFigure(value: totalCards, label: "Cards", tint: nil)
            statDivider
            StatFigure(value: courseCount, label: "Courses", tint: nil)
            statDivider
            // Tinted only while it's alive: a grey 0 next to three amber
            // figures reads as a scold, and a streak nobody has started
            // yet isn't news.
            StatFigure(
                value: streak.days, label: streak.days == 1 ? "Day streak" : "Day streak",
                tint: streak.days > 0 ? GRASPColor.success : nil
            )
            Spacer(minLength: 0)
        }
    }

    /// Today's progress toward the daily goal, sitting directly under the
    /// figures it qualifies. Hidden once the goal is met and nothing is
    /// left due -- a finished day should feel finished, not carry a full
    /// progress bar around all evening.
    @ViewBuilder
    private var dailyGoalBar: some View {
        if dailyGoal > 0 && !(streak.reviewsToday >= dailyGoal && totalDue == 0) {
            let progress = min(1, Double(streak.reviewsToday) / Double(dailyGoal))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(streak.reviewsToday >= dailyGoal
                         ? "Daily goal met -- \(streak.reviewsToday) cards reviewed"
                         : "\(streak.reviewsToday) of \(dailyGoal) cards today")
                        .graspType(.meta)
                        .monospacedDigit()
                        .foregroundStyle(streak.reviewsToday >= dailyGoal
                                         ? GRASPColor.success : GRASPColor.textSecondary)
                    Spacer(minLength: 8)
                    if !streak.studiedToday && streak.days > 0 {
                        Text("Study today to keep your \(streak.days)-day streak")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.accent)
                    }
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(streak.reviewsToday >= dailyGoal ? GRASPColor.success : GRASPColor.accent)
                    .frame(maxWidth: 420)
            }
        }
    }

    /// The stronger hairline: on the black canvas the default edge tone
    /// disappears entirely, and a divider nobody can see is just a gap.
    private var statDivider: some View {
        Rectangle()
            .fill(GRASPColor.hairlineStrong)
            .frame(width: 1, height: 26)
            .padding(.horizontal, 22)
    }

    // MARK: - Columns

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 34) {
            // Above "pick up where you left off" deliberately: a test in
            // three days outranks whatever deck happened to be open last,
            // and the strip disappears entirely when nothing is coming, so
            // it costs the ordinary dashboard nothing.
            if !upcoming.isEmpty {
                upcomingExams
            }
            if let jumpBackIn {
                continueCard(jumpBackIn)
            }
            coursesShelf
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Upcoming exams

    private var upcomingExams: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("Upcoming")
                Spacer(minLength: 8)
                Button("Open calendar") { selectedCourseId = ContentView.calendarRoute }
                    .buttonStyle(.plain)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.accent)
            }
            VStack(spacing: 8) {
                ForEach(upcoming) { item in
                    ExamAlertRow(item: item) { study(item) }
                }
            }
        }
    }

    /// Straight into the deck the exam is actually about -- its linked
    /// deck when one is set, otherwise the course's "All Cards", which is
    /// the honest answer when nobody has said which deck the test covers.
    private func study(_ item: AppStore.UpcomingEvent) {
        guard let courseId = item.event.courseId else { return }
        selectedCourseId = courseId
        selectedDeckId = item.event.deckId ?? DeckListView.allCardsId
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Recent")
            if recents.isEmpty {
                Text("Decks you study will collect here.")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.element.id) { index, deck in
                        if index > 0 {
                            Rectangle().fill(GRASPColor.hairlineStrong).frame(height: 1)
                        }
                        Button {
                            selectedCourseId = deck.courseId
                            selectedDeckId = deck.deckId
                        } label: {
                            RecentRow(deck: deck)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Continue card

    /// The one raised element on the dashboard. It gets the elevation, the
    /// larger radius and the only shadow, so "where was I?" is answered
    /// before anything else on the screen is read.
    private func continueCard(_ deck: AppStore.DeckSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(deck.dueCount > 0 ? "Pick up where you left off" : "Last studied")

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(deck.deckName)
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.5)
                        .foregroundStyle(GRASPColor.textPrimary)
                    Text(deck.courseName)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                }
                Spacer(minLength: 12)
                if deck.dueCount > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(deck.dueCount)")
                            .graspType(.numeral)
                            .foregroundStyle(GRASPColor.accent)
                        Text("due")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                    }
                }
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 7) {
                ProgressBar(value: deck.reviewedCount, total: deck.cardCount)
                Text("\(deck.reviewedCount) of \(deck.cardCount) cards reviewed")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .padding(.top, 20)

            HStack(spacing: 8) {
                Button("Continue") {
                    studyingDeck = StudyTarget(id: deck.deckId, name: deck.deckName)
                }
                .buttonStyle(GRASPProminentButton())
                .disabled(deck.dueCount == 0)

                Button("Open deck") {
                    selectedCourseId = deck.courseId
                    selectedDeckId = deck.deckId
                }
                .buttonStyle(GRASPQuietButton())
            }
            .padding(.top, 20)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(GRASPColor.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    // MARK: - Courses

    private var coursesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Your courses")
            if courseRollups.isEmpty {
                Text("Import the vault to populate your courses.")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textTertiary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 172, maximum: 230), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(courseRollups) { rollup in
                        CourseTile(rollup: rollup)
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onTapGesture(count: 2) {
                                if let course = course(for: rollup.id) { editingCourse = course }
                            }
                            .onTapGesture { selectedCourseId = rollup.id }
                            .contextMenu {
                                if let course = course(for: rollup.id) {
                                    CourseContextMenu(
                                        course: course,
                                        onEdit: { editingCourse = course },
                                        onArchive: {
                                            try? store.setCourseArchived(course.id, archived: !course.isArchived)
                                        },
                                        onDelete: { deletingCourse = course }
                                    )
                                }
                            }
                    }
                }
            }
        }
    }

    private func course(for id: String) -> Course? {
        store.coursesBySemester.values.flatMap { $0 }.first { $0.id == id }
    }

}

// MARK: - Pieces

private struct StatFigure: View {
    let value: Int
    let label: String
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .graspType(.numeralSmall)
                .foregroundStyle(tint ?? GRASPColor.textPrimary)
            Text(label)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        }
        .fixedSize()
    }
}

/// One upcoming exam on the dashboard: what it is, which course, how long
/// you have, and a way to start studying for it in one click. The tint
/// escalates as the date closes in -- neutral a month out, amber inside a
/// week, terracotta in the last three days -- so the strip reads as
/// urgency at a glance rather than as four identical rows.
private struct ExamAlertRow: View {
    let item: AppStore.UpcomingEvent
    let onStudy: () -> Void

    private var daysAway: Int { item.daysAway(from: Date()) }

    private var urgencyTint: Color {
        if daysAway <= 3 { return GRASPColor.rejected }
        if daysAway <= 7 { return GRASPColor.accent }
        return GRASPColor.textSecondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.event.kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(urgencyTint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.event.title.isEmpty ? item.event.kind.label : item.event.title)
                    .graspType(.rowTitle)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let courseName = item.courseName {
                        Text(courseName)
                        Text("·").foregroundStyle(GRASPColor.textTertiary)
                    }
                    Text(item.event.startsAt.formatted(date: .abbreviated, time: .omitted))
                    if let timeText = item.event.timeText {
                        Text("·").foregroundStyle(GRASPColor.textTertiary)
                        Text(timeText)
                    }
                }
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(item.event.countdownText())
                .graspType(.meta)
                .fontWeight(.semibold)
                .foregroundStyle(urgencyTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(urgencyTint.opacity(0.12), in: Capsule())

            if item.event.courseId != nil {
                Button("Study", action: onStudy)
                    .buttonStyle(GRASPQuietButton())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(urgencyTint.opacity(daysAway <= 7 ? 0.35 : 0.12), lineWidth: 1)
        }
    }
}

private struct RecentRow: View {
    let deck: AppStore.DeckSummary
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.deckName)
                    .graspType(.rowTitle)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(1)
                Text(deck.courseName)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let last = deck.lastReviewedAt {
                Text(last.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? GRASPColor.surface : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// A course tile carries no border at rest -- it separates from the ground
/// by value alone -- and gains one on hover. That keeps a shelf of ten
/// courses from reading as ten outlined boxes while still giving each one
/// a real pointer state, the way a Mac collection view behaves.
private struct CourseTile: View {
    let rollup: HomeView.CourseRollup
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(rollup.colorHex.map { Color(hex: $0) } ?? GRASPColor.accentMuted)
                    .frame(width: 6, height: 6)
                if let eyebrow = rollup.eyebrow {
                    Text(eyebrow)
                        .graspType(.eyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 13)

            Text(rollup.name)
                .graspType(.title)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Spacer(minLength: 10)

            HStack(spacing: 5) {
                Text("\(rollup.cardCount) cards")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                if rollup.dueCount > 0 {
                    Text("·").graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    Text("\(rollup.dueCount) due")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.accent)
                }
            }
        }
        .padding(13)
        .frame(height: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? GRASPColor.surfaceRaised : GRASPColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isHovering ? GRASPColor.hairlineStrong : .clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }
}
