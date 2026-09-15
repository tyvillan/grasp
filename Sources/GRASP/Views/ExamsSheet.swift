import SwiftUI
import GRASPCore

/// Dates for one course, reachable from that course's own toolbar -- the
/// quick "when is the midterm again?" view, as opposed to the full
/// `CalendarView` that shows every course at once. Setting an exam or quiz
/// here is what turns on FSRS's exam biasing (`AppStore.gradeCard`/
/// `dueCards`) for every deck in this course: capping intervals to land
/// before the date, and reordering the due queue by weakest retention
/// first in the final week. Deadlines and study blocks sit alongside them
/// without touching scheduling.
struct ExamsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let courseId: String

    @State private var events: [CalendarEvent] = []
    @State private var editing: CalendarEvent?
    @State private var creating: CalendarEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 24))
                    .foregroundStyle(GRASPColor.accent)
                Text("Dates for This Course")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
            }

            if events.isEmpty {
                Text("No exams, deadlines, or study blocks set for this course yet.")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(events) { event in
                            row(event)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            HStack {
                Button {
                    creating = CalendarEvent(
                        courseId: courseId, title: "",
                        startsAt: Calendar.current.startOfDay(for: Date().addingTimeInterval(14 * 86400))
                    )
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11))
                        Text("Add Date")
                    }
                }
                .buttonStyle(GRASPQuietButton())
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GRASPProminentButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(GRASPColor.canvas)
        .task { load() }
        .onChange(of: store.revision) { load() }
        .sheet(item: $editing) { event in
            CalendarEventEditSheet(event: event, isNew: false)
        }
        .sheet(item: $creating) { event in
            CalendarEventEditSheet(event: event, isNew: true)
        }
    }

    private func row(_ event: CalendarEvent) -> some View {
        Button { editing = event } label: {
            HStack(spacing: 10) {
                Image(systemName: event.kind.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(event.kind.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title.isEmpty ? event.kind.label : event.title)
                        .graspType(.rowTitle)
                        .foregroundStyle(GRASPColor.textPrimary)
                    Text(event.startsAt.formatted(date: .abbreviated, time: .omitted))
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textSecondary)
                }
                Spacer(minLength: 8)
                Text(event.countdownText())
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func load() {
        events = (try? store.calendarEvents(forCourse: courseId)) ?? []
    }
}
