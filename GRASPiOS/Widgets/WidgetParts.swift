import SwiftUI
import WidgetKit

/// Pieces every GRASP widget is built from, in the app's own type scale and
/// palette (Theme.swift is compiled into the extension).

extension View {
    /// The app's panel surface as the widget's background.
    func graspWidgetBackground() -> some View {
        containerBackground(for: .widget) { GRASPColor.surface }
    }
}

/// The small uppercase label that heads each widget.
struct WidgetEyebrow: View {
    let text: String
    var body: some View {
        Text(text)
            .graspType(.eyebrow)
            .textCase(.uppercase)
            .foregroundStyle(GRASPColor.textTertiary)
            .lineLimit(1)
    }
}

/// The streak, as the Today tab shows it: amber once today counts.
struct StreakBadge: View {
    let days: Int
    let studiedToday: Bool
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .foregroundStyle(studiedToday ? GRASPColor.accent : GRASPColor.textTertiary)
                .widgetAccentable()
            Text("\(days)")
                .font(.graspNumber(13))
                .foregroundStyle(GRASPColor.textPrimary)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(days) day streak")
    }
}

/// Today's reviews against the daily goal.
struct GoalBar: View {
    let done: Int
    let goal: Int
    var body: some View {
        let met = done >= goal
        VStack(alignment: .leading, spacing: 5) {
            ProgressBar(value: min(done, goal), total: max(goal, 1),
                        tint: met ? GRASPColor.success : GRASPColor.accent, height: 6)
                .widgetAccentable()
            Text(met ? "Goal met · \(done) today" : "\(done) of \(goal) today")
                .graspType(.meta)
                .foregroundStyle(met ? GRASPColor.success : GRASPColor.textSecondary)
                .lineLimit(1)
        }
    }
}

/// Shown until the app has published anything.
struct OpenAppPrompt: View {
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(GRASPColor.accent)
            Spacer(minLength: 0)
            Text("Open GRASP to see your cards here.")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

enum EventStyle {
    static func icon(for kind: String) -> String {
        switch kind {
        case "quiz": return "questionmark.circle.fill"
        case "deadline": return "flag.fill"
        case "study": return "book.fill"
        default: return "graduationcap.fill"
        }
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "quiz": return "Quiz"
        case "deadline": return "Deadline"
        case "study": return "Study"
        default: return "Exam"
        }
    }

    /// "Today", "Tomorrow", "in 5 days".
    static func whenText(_ days: Int) -> String {
        switch days {
        case ..<1: return "Today"
        case 1: return "Tomorrow"
        default: return "in \(days) days"
        }
    }
}
