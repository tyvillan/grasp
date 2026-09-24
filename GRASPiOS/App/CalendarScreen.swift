import SwiftUI
import GRASPCore

/// The next two months as an agenda: exams, quizzes, deadlines, and study
/// blocks, grouped by day. The same calendar as the Mac -- it syncs.
struct CalendarScreen: View {
    @Environment(AppStore.self) private var store
    @State private var events: [CalendarEvent] = []
    @State private var editing: CalendarEvent?
    @State private var creating = false
    @State private var importMessage: String?
    @State private var isImporting = false

    private var days: [(day: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        return Dictionary(grouping: events) { calendar.startOfDay(for: $0.startsAt) }
            .map { ($0.key, $0.value.sorted { $0.startsAt < $1.startsAt }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        List {
            if events.isEmpty {
                ContentUnavailableView(
                    "Nothing scheduled",
                    systemImage: "calendar",
                    description: Text("Add an exam, or import exam dates from your iPhone's Calendar.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(days, id: \.day) { group in
                Section(dayTitle(group.day)) {
                    ForEach(group.events) { event in
                        Button { editing = event } label: { EventRow(event: event) }
                            .buttonStyle(.plain)
                    }
                }
                .graspSection()
            }
        }
        .graspList()
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    importFromCalendar()
                } label: {
                    if isImporting { ProgressView() } else { Label("Import from Calendar", systemImage: "calendar.badge.plus") }
                }
                .disabled(isImporting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Label("Add Event", systemImage: "plus") }
            }
        }
        .task(id: store.revision) { load() }
        .sheet(item: $editing) { event in EventEditor(event: event, isNew: false) }
        .sheet(isPresented: $creating) {
            EventEditor(event: CalendarEvent(kind: .exam, title: "", startsAt: Calendar.current.startOfDay(
                for: Date().addingTimeInterval(7 * 86400))), isNew: true)
        }
        .alert("Calendar import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    private func load() {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 60, to: start) ?? start
        events = (try? store.calendarEvents(from: start, to: end)) ?? []
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func importFromCalendar() {
        isImporting = true
        Task {
            defer { isImporting = false }
            switch await store.syncSystemCalendar() {
            case .success(let summary):
                var parts: [String] = []
                if !summary.imported.isEmpty { parts.append("Added \(summary.imported.count).") }
                if !summary.updated.isEmpty { parts.append("Updated \(summary.updated.count).") }
                if !summary.unmatched.isEmpty {
                    parts.append("\(summary.unmatched.count) couldn't be matched to a course -- open them to pick one.")
                }
                importMessage = parts.isEmpty ? "No new exam or quiz dates found." : parts.joined(separator: " ")
                load()
            case .failure(let error):
                importMessage = error.localizedDescription
            }
        }
    }
}

private struct EventRow: View {
    @Environment(AppStore.self) private var store
    let event: CalendarEvent

    private var icon: String {
        switch event.kind {
        case .exam: return "graduationcap.fill"
        case .quiz: return "questionmark.circle.fill"
        case .deadline: return "flag.fill"
        case .study: return "book.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(event.kind == .study ? GRASPColor.success : GRASPColor.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary).lineLimit(2)
                Text([event.courseId.flatMap { store.courseName($0) }, event.kind.label].compactMap { $0 }
                        .joined(separator: " · "))
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer()
            if !event.isAllDay {
                Text(event.startsAt.formatted(date: .omitted, time: .shortened))
                    .graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Add or edit an event, and plan study toward an exam.
struct EventEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var event: CalendarEvent
    let isNew: Bool
    @State private var planMessage: String?

    private var courseGroups: [(title: String, courses: [Course])] { store.coursePickerGroups() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $event.title)
                    Picker("Kind", selection: $event.kind) {
                        ForEach(CalendarEventKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Course", selection: $event.courseId) {
                        Text("None").tag(String?.none)
                        ForEach(courseGroups, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.courses) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }
                }
                .graspSection()
                Section {
                    Toggle("All day", isOn: $event.isAllDay)
                    DatePicker("Date", selection: $event.startsAt,
                               displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                }
                .graspSection()

                if !isNew, CalendarEventKind.examLike.contains(event.kind), event.courseId != nil {
                    Section {
                        Button(store.hasStudyPlan(for: event.id) ? "Regenerate Study Plan" : "Generate Study Plan") {
                            save()
                            if let summary = try? store.generateStudyPlan(for: event) {
                                planMessage = "Added \(summary.blocksCreated) study block\(summary.blocksCreated == 1 ? "" : "s") covering \(summary.cardsCovered) cards."
                            }
                        }
                        .disabled(store.plannableCardCount(for: event) == 0)
                    } footer: {
                        Text(planMessage ?? "Spreads this course's cards over the days before the exam.")
                    }
                    .graspSection()
                }

                if !isNew {
                    Section {
                        Button("Delete Event", role: .destructive) {
                            try? store.deleteCalendarEvent(event.id)
                            dismiss()
                        }
                    }
                    .graspSection()
                }
            }
            .graspList()
            .navigationTitle(isNew ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }
                        .disabled(event.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        var saved = event
        if saved.isAllDay {
            saved.startsAt = Calendar.current.startOfDay(for: saved.startsAt)
            saved.endsAt = nil
        }
        if isNew { try? store.addCalendarEvent(saved) } else { try? store.updateCalendarEvent(saved) }
    }
}
