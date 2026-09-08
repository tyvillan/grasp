import SwiftUI
import GRASPCore

/// The dashboard shown before a course is picked: a "Jump back in" card
/// for whatever deck was most recently studied (or most due, if nothing
/// has been studied yet), a due-today/total-cards/course-count stat row,
/// and every course as a tappable tile grouped by semester -- the same
/// shape as Quizlet's home screen, in GRASP's own palette.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedCourseId: String?
    @Binding var selectedDeckId: String?

    @State private var decks: [AppStore.DeckSummary] = []

    private var totalDue: Int { decks.reduce(0) { $0 + $1.dueCount } }
    private var totalCards: Int { decks.reduce(0) { $0 + $1.cardCount } }
    private var courseCount: Int { Set(decks.map(\.courseId)).count }

    private var jumpBackIn: AppStore.DeckSummary? {
        if let mostRecent = decks.filter({ $0.lastReviewedAt != nil }).max(by: { $0.lastReviewedAt! < $1.lastReviewedAt! }) {
            return mostRecent
        }
        return decks.filter { $0.dueCount > 0 }.max { $0.dueCount < $1.dueCount }
    }

    private var decksByCourse: [(course: (id: String, name: String), due: Int, cards: Int)] {
        let grouped = Dictionary(grouping: decks, by: \.courseId)
        return grouped.map { courseId, decks in
            ((courseId, decks.first?.courseName ?? ""), decks.reduce(0) { $0 + $1.dueCount }, decks.reduce(0) { $0 + $1.cardCount })
        }
        .sorted { $0.due > $1.due || ($0.due == $1.due && $0.course.name < $1.course.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                statsRow
                if let jumpBackIn {
                    jumpBackInCard(jumpBackIn)
                }
                coursesGrid
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GRASPColor.background)
        .task { load() }
        .onChange(of: store.deckCounts.count) { load() }
    }

    private func load() {
        decks = (try? store.dashboardDecks()) ?? []
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome back, \(firstName)")
                .font(.graspHeading(28))
                .foregroundStyle(GRASPColor.textPrimary)
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(.callout)
                .foregroundStyle(GRASPColor.textSecondary)
        }
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
        Button {
            selectedCourseId = deck.courseId
            selectedDeckId = deck.deckId
        } label: {
            HStack(spacing: 20) {
                ZStack {
                    Circle().fill(GRASPColor.accentSoft).frame(width: 56, height: 56)
                    Image(systemName: "arrow.forward.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(GRASPColor.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jump back in").font(.caption.weight(.semibold)).foregroundStyle(GRASPColor.textSecondary)
                    Text(deck.deckName).font(.graspHeading(20)).foregroundStyle(GRASPColor.textPrimary)
                    Text(deck.courseName).font(.callout).foregroundStyle(GRASPColor.textSecondary)
                }
                Spacer()
                if deck.dueCount > 0 {
                    VStack {
                        Text("\(deck.dueCount)").font(.graspNumber(22)).foregroundStyle(GRASPColor.accent)
                        Text("due").font(.caption).foregroundStyle(GRASPColor.textSecondary)
                    }
                }
            }
            .padding(20)
            .background(GRASPColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(GRASPColor.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var coursesGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Courses").font(.graspHeading(18)).foregroundStyle(GRASPColor.textPrimary)
            if decksByCourse.isEmpty {
                Text("Import the vault to populate your courses.")
                    .font(.callout)
                    .foregroundStyle(GRASPColor.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)], spacing: 16) {
                    ForEach(decksByCourse, id: \.course.id) { entry in
                        Button {
                            selectedCourseId = entry.course.id
                        } label: {
                            CourseTile(name: entry.course.name, cardCount: entry.cards, dueCount: entry.due)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "book.closed.fill").foregroundStyle(GRASPColor.accent)
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
