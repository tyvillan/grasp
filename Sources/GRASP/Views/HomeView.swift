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
    @State private var studyingDeck: StudyTarget?
    @State private var editingCourse: Course?
    @State private var deletingCourse: Course?
    @State private var deletionImpact: (materials: Int, cards: Int, reviews: Int)?

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
        .sheet(item: $studyingDeck, onDismiss: load) { target in
            FlashcardStudyView(deckId: target.id, deckName: target.name)
        }
        .sheet(item: $editingCourse, onDismiss: load) { course in
            CourseEditSheet(course: course)
        }
        .alert(
            "Delete \(deletingCourse?.name ?? "course")?",
            isPresented: Binding(
                get: { deletingCourse != nil },
                set: { if !$0 { deletingCourse = nil } }
            ),
            presenting: deletingCourse
        ) { course in
            Button("Delete", role: .destructive) {
                try? store.deleteCourse(course.id)
                load()
            }
            Button("Cancel", role: .cancel) {}
        } message: { course in
            Text(deletionMessage(for: course))
        }
    }

    private func load() {
        decks = (try? store.dashboardDecks()) ?? []
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
            Spacer(minLength: 0)
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
            if let jumpBackIn {
                continueCard(jumpBackIn)
            }
            coursesShelf
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                                        onDelete: { beginDelete(course) }
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

    private func beginDelete(_ course: Course) {
        deletionImpact = try? store.courseDeletionImpact(course.id)
        deletingCourse = course
    }

    private func deletionMessage(for course: Course) -> String {
        let cards = deletionImpact?.cards ?? 0
        let reviews = deletionImpact?.reviews ?? 0
        var message = "Removes \(cards) card\(cards == 1 ? "" : "s")"
        if reviews > 0 { message += " and \(reviews) review\(reviews == 1 ? "" : "s") of study history" }
        message += ". Your notes in the vault are never touched"
        message += course.folderPath != nil ? " -- importing again will bring this course back." : "."
        return message
    }
}

// MARK: - Pieces

/// Small uppercase label that opens a section. Tracked positive, because
/// capitals at 11pt jam together at default spacing.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .graspType(.eyebrow)
            .textCase(.uppercase)
            .foregroundStyle(GRASPColor.textTertiary)
    }
}

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
