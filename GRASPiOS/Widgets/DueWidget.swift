import SwiftUI
import WidgetKit

/// Cards due now, the streak, and progress toward today's goal.
struct DueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GRASPDue", provider: SnapshotProvider()) { entry in
            DueWidgetView(entry: entry)
                .widgetURL(WidgetLink.today.url)
                .graspWidgetBackground()
        }
        .configurationDisplayName("Cards Due")
        .description("How many cards are due, your streak, and today's goal.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DueWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state {
            switch family {
            case .systemMedium:
                HStack(alignment: .top, spacing: 16) {
                    summary(state)
                    Rectangle().fill(GRASPColor.hairline).frame(width: 1)
                    byCourse(state)
                }
            default:
                summary(state)
            }
        } else {
            OpenAppPrompt(icon: "rectangle.stack.fill")
        }
    }

    private func summary(_ state: WidgetSnapshot.State) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WidgetEyebrow(text: "Due now")
                Spacer(minLength: 4)
                StreakBadge(days: state.streakDays, studiedToday: state.studiedToday)
            }
            Spacer(minLength: 4)
            Text("\(state.dueNow)")
                .font(.system(size: 40, weight: .semibold).monospacedDigit())
                .tracking(-1)
                .foregroundStyle(state.dueNow > 0 ? GRASPColor.textPrimary : GRASPColor.success)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(state.dueNow == 0 ? "All caught up" : state.dueNow == 1 ? "card due" : "cards due")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textSecondary)
            Spacer(minLength: 8)
            if state.dailyGoal > 0 {
                GoalBar(done: state.reviewsToday, goal: state.dailyGoal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func byCourse(_ state: WidgetSnapshot.State) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetEyebrow(text: "By course")
            if state.dueByCourse.isEmpty {
                Spacer(minLength: 0)
                Label("Nothing due", systemImage: "checkmark.circle.fill")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.success)
                Spacer(minLength: 0)
            } else {
                ForEach(state.dueByCourse.prefix(4), id: \.name) { course in
                    HStack(spacing: 6) {
                        Text(course.name)
                            .graspType(.rowTitle)
                            .foregroundStyle(GRASPColor.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(course.dueCount)")
                            .font(.graspNumber(12))
                            .foregroundStyle(GRASPColor.accent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
