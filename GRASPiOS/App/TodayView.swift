import SwiftUI
import GRASPCore

/// The home tab: how today's going, what to study next, and what's coming.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("dailyCardGoal") private var dailyGoal = 20

    @State private var decks: [AppStore.DeckSummary] = []
    @State private var exams: [AppStore.UpcomingEvent] = []
    @State private var streak = AppStore.StudyStreak(days: 0, studiedToday: false, reviewsToday: 0)

    private var totalDue: Int { decks.reduce(0) { $0 + $1.dueCount } }

    /// The deck studied most recently that still has something due -- or,
    /// failing that, the one with the most due.
    private var jumpBackIn: AppStore.DeckSummary? {
        let due = decks.filter { $0.dueCount > 0 }
        return due.filter { $0.lastReviewedAt != nil }.max { ($0.lastReviewedAt ?? .distantPast) < ($1.lastReviewedAt ?? .distantPast) }
            ?? due.max { $0.dueCount < $1.dueCount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                greeting
                statsRow
                if dailyGoal > 0 { goalCard }
                if let deck = jumpBackIn { jumpBackCard(deck) }
                if !exams.isEmpty { examsCard }
                dueByCourse
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(GRASPColor.canvas.ignoresSafeArea())
        .navigationTitle("Today")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SyncIndicator() } }
        .refreshable { store.sync.syncNow() }
        .task(id: store.revision) { load() }
    }

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = store.profile.name.split(separator: " ").first.map(String.init) ?? store.profile.name
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(part), \(first)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(GRASPColor.textPrimary)
            Text(totalDue == 0 ? "Nothing due right now -- a good moment to learn something new."
                               : "\(totalDue) card\(totalDue == 1 ? "" : "s") due across your courses.")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatTile(value: "\(streak.days)", label: streak.days == 1 ? "day streak" : "day streak",
                     icon: "flame.fill", tint: streak.studiedToday ? GRASPColor.accent : GRASPColor.textTertiary)
            StatTile(value: "\(streak.reviewsToday)", label: "reviewed today", icon: "checkmark.circle.fill",
                     tint: GRASPColor.success)
            StatTile(value: "\(totalDue)", label: "due now", icon: "clock.fill", tint: GRASPColor.accent)
        }
    }

    private var goalCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Daily goal")
                    Spacer()
                    Text(streak.reviewsToday >= dailyGoal ? "Done for today"
                         : "\(streak.reviewsToday) of \(dailyGoal)")
                        .graspType(.meta)
                        .foregroundStyle(streak.reviewsToday >= dailyGoal ? GRASPColor.success : GRASPColor.textSecondary)
                }
                ProgressBar(value: min(streak.reviewsToday, dailyGoal), total: dailyGoal,
                            tint: streak.reviewsToday >= dailyGoal ? GRASPColor.success : GRASPColor.accent)
            }
        }
    }

    private func jumpBackCard(_ deck: AppStore.DeckSummary) -> some View {
        NavigationLink {
            DeckScreen(route: DeckRoute(scope: .deck(deck.deckId), name: deck.deckName))
        } label: {
            Panel {
                HStack(spacing: 14) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(GRASPColor.dynamic(light: 0xFFFFFF, dark: 0x16130C))
                        .frame(width: 42, height: 42)
                        .background(GRASPColor.accent, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        SectionLabel("Jump back in")
                        Text(deck.deckName).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary)
                        Text("\(deck.courseName) · \(deck.dueCount) due")
                            .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(GRASPColor.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var examsCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Coming up")
                ForEach(exams) { upcoming in
                    HStack(spacing: 12) {
                        Image(systemName: upcoming.event.kind == .quiz ? "questionmark.circle" : "graduationcap")
                            .foregroundStyle(GRASPColor.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(upcoming.event.title).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary)
                                .lineLimit(1)
                            Text(upcoming.courseName ?? "No course")
                                .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                        }
                        Spacer()
                        Text(daysAway(upcoming.event.startsAt))
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.accent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dueByCourse: some View {
        let byCourse = Dictionary(grouping: decks.filter { $0.dueCount > 0 }, by: \.courseName)
            .map { (name: $0.key, due: $0.value.reduce(0) { $0 + $1.dueCount }) }
            .sorted { $0.due > $1.due }
        if !byCourse.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Due by course")
                    ForEach(byCourse, id: \.name) { course in
                        HStack {
                            Text(course.name).graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                            Spacer()
                            DueBadge(count: course.due)
                        }
                    }
                }
            }
        }
    }

    private func daysAway(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Tomorrow"
        default: return "in \(days) days"
        }
    }

    private func load() {
        decks = (try? store.dashboardDecks()) ?? []
        exams = (try? store.upcomingExams(within: 30, limit: 5)) ?? []
        streak = store.studyStreak()
    }
}

/// A GRASP panel: the surface step up from the canvas.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundStyle(GRASPColor.textPrimary)
            Text(label).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
