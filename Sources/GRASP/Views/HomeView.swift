import SwiftUI
import GRASPCore

/// The dashboard shown before a course is picked: a "Jump back in" card
/// for whatever deck was most recently studied (or most due, if nothing
/// has been studied yet), a due-today/total-cards/course-count stat row,
/// recent study activity, and every course as a tile -- the same shape as
/// Quizlet's home screen, in GRASP's own palette.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedCourseId: String?
    @Binding var selectedDeckId: String?

    @State private var decks: [AppStore.DeckSummary] = []
    @State private var studyingDeck: StudyTarget?
    @State private var editingCourse: Course?
    @State private var deletingCourse: Course?
    @State private var deletionImpact: (materials: Int, cards: Int, reviews: Int)?

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
            .prefix(5)
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

    struct CourseRollup: Identifiable {
        let id: String
        let name: String
        let dueCount: Int
        let cardCount: Int
        let colorHex: String?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                statsRow
                if let jumpBackIn {
                    jumpBackInCard(jumpBackIn)
                }
                if !recents.isEmpty {
                    recentsSection
                }
                coursesGrid
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GRASPColor.background)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            wordmark
                .padding(.bottom, 6)
            Text("Welcome back, \(firstName)")
                .font(.graspHeading(28))
                .foregroundStyle(GRASPColor.textPrimary)
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(.callout)
                .foregroundStyle(GRASPColor.textSecondary)
        }
    }

    /// The name spelled out, with each source letter carried in the accent
    /// so the acronym explains itself rather than needing a legend.
    private var wordmark: some View {
        HStack(spacing: 8) {
            Text("G.R.A.S.P")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(GRASPColor.accent)
            Text("—")
                .font(.caption)
                .foregroundStyle(GRASPColor.stroke)
            expansion
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var expansion: Text {
        let lead = { (letter: String) in
            Text(letter).foregroundStyle(GRASPColor.accent).fontWeight(.heavy)
        }
        let rest = { (text: String) in
            Text(text).foregroundStyle(GRASPColor.textSecondary)
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

    private var statsRow: some View {
        HStack(spacing: 16) {
            StatTile(title: "Due Today", value: totalDue, icon: "clock.fill", tint: GRASPColor.accent)
            StatTile(title: "Total Cards", value: totalCards, icon: "rectangle.stack.fill", tint: GRASPColor.success)
            StatTile(title: "Courses", value: courseCount, icon: "books.vertical.fill", tint: GRASPColor.accent)
        }
    }

    private func jumpBackInCard(_ deck: AppStore.DeckSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jump back in")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GRASPColor.textSecondary)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(deck.deckName).font(.graspHeading(22)).foregroundStyle(GRASPColor.textPrimary)
                    Text(deck.courseName).font(.callout).foregroundStyle(GRASPColor.textSecondary)
                }
                Spacer()
                if deck.dueCount > 0 {
                    VStack(spacing: 0) {
                        Text("\(deck.dueCount)").font(.graspNumber(22)).foregroundStyle(GRASPColor.accent)
                        Text("due").font(.caption).foregroundStyle(GRASPColor.textSecondary)
                    }
                }
            }

            ProgressBar(value: deck.reviewedCount, total: deck.cardCount)
            Text("\(deck.reviewedCount)/\(deck.cardCount) cards reviewed")
                .font(.caption)
                .foregroundStyle(GRASPColor.textSecondary)

            HStack(spacing: 10) {
                Button("Continue") {
                    studyingDeck = StudyTarget(id: deck.deckId, name: deck.deckName)
                }
                .buttonStyle(.borderedProminent)
                .tint(GRASPColor.accent)
                .disabled(deck.dueCount == 0)

                Button("Open deck") {
                    selectedCourseId = deck.courseId
                    selectedDeckId = deck.deckId
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(GRASPColor.stroke, lineWidth: 1))
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recents").font(.graspHeading(18)).foregroundStyle(GRASPColor.textPrimary)
            VStack(spacing: 8) {
                ForEach(recents) { deck in
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

    private var coursesGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Courses").font(.graspHeading(18)).foregroundStyle(GRASPColor.textPrimary)
            if courseRollups.isEmpty {
                Text("Import the vault to populate your courses.")
                    .font(.callout)
                    .foregroundStyle(GRASPColor.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)], spacing: 16) {
                    ForEach(courseRollups) { rollup in
                        CourseTile(
                            name: rollup.name,
                            cardCount: rollup.cardCount,
                            dueCount: rollup.dueCount,
                            colorHex: rollup.colorHex
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if let course = course(for: rollup.id) { editingCourse = course } }
                        .onTapGesture { selectedCourseId = rollup.id }
                        .contextMenu {
                            if let course = course(for: rollup.id) {
                                CourseContextMenu(
                                    course: course,
                                    onEdit: { editingCourse = course },
                                    onArchive: { try? store.setCourseArchived(course.id, archived: !course.isArchived) },
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

private struct ProgressBar: View {
    let value: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(GRASPColor.stroke)
                Capsule()
                    .fill(GRASPColor.accent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total)
    }
}

private struct RecentRow: View {
    let deck: AppStore.DeckSummary

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(GRASPColor.accentSoft)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 15))
                        .foregroundStyle(GRASPColor.accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.deckName).font(.body.weight(.medium)).foregroundStyle(GRASPColor.textPrimary)
                Text("\(deck.cardCount) cards · \(deck.courseName)")
                    .font(.caption)
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            Spacer()
            if let last = deck.lastReviewedAt {
                Text(last.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(GRASPColor.textSecondary)
            }
        }
        .padding(12)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GRASPColor.stroke, lineWidth: 1))
    }
}

private struct StatTile: View {
    let title: String
    let value: Int
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.graspNumber(20)).foregroundStyle(GRASPColor.textPrimary)
                Text(title).font(.caption).foregroundStyle(GRASPColor.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(GRASPColor.stroke, lineWidth: 1))
    }
}

private struct CourseTile: View {
    let name: String
    let cardCount: Int
    let dueCount: Int
    let colorHex: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(colorHex.map { Color(hex: $0) } ?? GRASPColor.accent)
                Spacer()
                if dueCount > 0 {
                    Text("\(dueCount)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(GRASPColor.accent, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            Text(name)
                .font(.body.weight(.semibold))
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(2)
                .frame(minHeight: 36, alignment: .top)
            Text("\(cardCount) cards")
                .font(.caption)
                .foregroundStyle(GRASPColor.textSecondary)
        }
        .padding(16)
        .frame(height: 130, alignment: .top)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(GRASPColor.stroke, lineWidth: 1))
    }
}
