import SwiftUI
import WidgetKit

/// A countdown to the next exam or quiz, and what comes after it.
struct NextExamWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GRASPNextExam", provider: SnapshotProvider()) { entry in
            NextExamView(entry: entry)
                .widgetURL(WidgetLink.calendar.url)
                .graspWidgetBackground()
        }
        .configurationDisplayName("Next Exam")
        .description("Days until your next exam or quiz.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NextExamView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state {
            if let next = state.upcomingEvents.first {
                switch family {
                case .systemMedium:
                    HStack(alignment: .top, spacing: 16) {
                        countdown(next)
                        let later = state.upcomingEvents.dropFirst().prefix(3)
                        if !later.isEmpty {
                            Rectangle().fill(GRASPColor.hairline).frame(width: 1)
                            upNext(Array(later))
                        }
                    }
                default:
                    countdown(next)
                }
            } else {
                nothingScheduled
            }
        } else {
            OpenAppPrompt(icon: "graduationcap.fill")
        }
    }

    private func days(to event: WidgetSnapshot.Event) -> Int {
        WidgetSnapshot.daysAway(event, from: entry.date)
    }

    private func countdown(_ event: WidgetSnapshot.Event) -> some View {
        let days = days(to: event)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: EventStyle.icon(for: event.kind))
                    .foregroundStyle(GRASPColor.accent)
                    .widgetAccentable()
                WidgetEyebrow(text: "Next \(EventStyle.kindLabel(event.kind))")
            }
            .font(.system(size: 12))
            Spacer(minLength: 4)
            if days <= 1 {
                Text(days <= 0 ? "Today" : "Tomorrow")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(GRASPColor.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(days)")
                        .font(.system(size: 40, weight: .semibold).monospacedDigit())
                        .tracking(-1)
                        .foregroundStyle(GRASPColor.textPrimary)
                    Text("days")
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 6)
            Text(event.title)
                .graspType(.rowTitle)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(2)
            Text(subtitle(event))
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Course, and the time when it's today or tomorrow -- that's when the
    /// hour matters; further out, the date does.
    private func subtitle(_ event: WidgetSnapshot.Event) -> String {
        let when: String
        if days(to: event) <= 1 && !event.isAllDay {
            when = event.startsAt.formatted(date: .omitted, time: .shortened)
        } else {
            when = event.startsAt.formatted(.dateTime.month(.abbreviated).day())
        }
        return [event.courseName, when].compactMap { $0 }.joined(separator: " · ")
    }

    private func upNext(_ events: [WidgetSnapshot.Event]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetEyebrow(text: "After that")
            ForEach(events) { event in
                HStack(spacing: 7) {
                    Image(systemName: EventStyle.icon(for: event.kind))
                        .font(.system(size: 11))
                        .foregroundStyle(GRASPColor.accent)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .graspType(.rowTitle)
                            .foregroundStyle(GRASPColor.textPrimary)
                            .lineLimit(1)
                        if let course = event.courseName {
                            Text(course)
                                .graspType(.meta)
                                .foregroundStyle(GRASPColor.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(EventStyle.whenText(days(to: event)))
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.accent)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var nothingScheduled: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "calendar")
                .font(.system(size: 22))
                .foregroundStyle(GRASPColor.accent)
                .widgetAccentable()
            Spacer(minLength: 6)
            WidgetEyebrow(text: "Next exam")
                .padding(.bottom, 3)
            Text("Nothing scheduled")
                .graspType(.title)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(2)
            Text("No exams in the next 60 days.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
