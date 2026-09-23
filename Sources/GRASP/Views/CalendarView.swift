import SwiftUI
import GRASPCore

/// Each kind's mark on the calendar, drawn from the app's existing three
/// hues rather than inventing a fourth: terracotta for the exam you're
/// actually worried about, amber for a quiz, teal for time you set aside
/// yourself, and a plain neutral for a deadline someone else set -- which
/// is a date to hit, not a thing to revise for.
extension CalendarEventKind {
    var icon: String {
        switch self {
        case .exam: return "graduationcap.fill"
        case .quiz: return "checklist"
        case .deadline: return "flag.fill"
        case .study: return "book.fill"
        }
    }

    var tint: Color {
        switch self {
        case .exam: return GRASPColor.rejected
        case .quiz: return GRASPColor.accent
        case .deadline: return GRASPColor.textSecondary
        case .study: return GRASPColor.success
        }
    }

    var softTint: Color {
        switch self {
        case .exam: return GRASPColor.rejectedSoft
        case .quiz: return GRASPColor.accentSoft
        case .deadline: return GRASPColor.inset
        case .study: return GRASPColor.successSoft
        }
    }
}

extension CalendarEvent {
    /// The time range as shown on a chip or row -- nil for an all-day
    /// event, which is most exams. (`countdownText`/`daysAway` live in
    /// GRASPCore alongside the record itself, where the calendar-day math
    /// is unit-tested.)
    var timeText: String? {
        guard !isAllDay else { return nil }
        let start = startsAt.formatted(date: .omitted, time: .shortened)
        guard let endsAt else { return start }
        return "\(start) – \(endsAt.formatted(date: .omitted, time: .shortened))"
    }
}

/// The calendar destination: exams, deadlines and study blocks in month,
/// week or agenda form. Reached from the sidebar via
/// `ContentView.calendarRoute`, the same sentinel-selection trick Home
/// already uses, so picking it is one selection rather than a second piece
/// of navigation state to keep in sync.
struct CalendarView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedCourseId: String?
    @Binding var selectedDeckId: String?

    @State private var mode: Mode = .month
    /// The month (or week) currently on screen -- always a real date
    /// inside it, never a range, so stepping forward is one
    /// `date(byAdding:)` rather than two bounds kept in step.
    @State private var anchor = Date()
    @State private var events: [CalendarEvent] = []
    @State private var dailyLoad: [Date: Int] = [:]
    @State private var editing: CalendarEvent?
    @State private var creating: CalendarEvent?
    @State private var isSyncing = false
    @State private var syncResult: SyncReport?

    private enum Mode: String, CaseIterable, Identifiable {
        case month = "Month", week = "Week", agenda = "Agenda"
        var id: String { rawValue }
    }

    private var calendar: Calendar { .current }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch mode {
            case .month: MonthGrid(days: gridDays, anchor: anchor, eventsByDay: eventsByDay,
                                   dailyLoad: dailyLoad,
                                   onOpen: { editing = $0 }, onAdd: { creating = newEvent(on: $0) })
            case .week: WeekColumns(days: weekDays, eventsByDay: eventsByDay,
                                    onOpen: { editing = $0 }, onAdd: { creating = newEvent(on: $0) })
            case .agenda: AgendaList(events: events, onOpen: { editing = $0 }, onStudy: study)
            }
        }
        .background(GRASPColor.canvas)
        .navigationTitle("Calendar")
        .task { load() }
        .onChange(of: anchor) { load() }
        .onChange(of: mode) { load() }
        .onChange(of: store.revision) { load() }
        .sheet(item: $editing) { event in
            CalendarEventEditSheet(event: event, isNew: false)
        }
        .sheet(item: $creating) { event in
            CalendarEventEditSheet(event: event, isNew: true)
        }
        .sheet(item: $syncResult) { report in
            ResultSheet(
                icon: report.isError ? "exclamationmark.triangle" : "calendar.badge.checkmark",
                title: report.title, leadText: report.lead, sections: report.sections
            )
        }
    }

    /// A finished sync, in the shape `ResultSheet` renders -- built here
    /// rather than in the store so the store stays free of anything about
    /// how a result gets displayed.
    struct SyncReport: Identifiable {
        let id = UUID()
        let title: String
        let lead: String
        var sections: [ResultSheet.Section] = []
        var isError = false
    }

    private func syncSystemCalendar() {
        isSyncing = true
        Task {
            let result = await store.syncSystemCalendar()
            isSyncing = false
            switch result {
            case .failure(let error):
                syncResult = SyncReport(
                    title: "Couldn't Read Your Calendar",
                    lead: error.localizedDescription, isError: true
                )
            case .success(let summary):
                var sections: [ResultSheet.Section] = []
                if !summary.imported.isEmpty {
                    sections.append(.init(icon: "plus.circle", tint: GRASPColor.success,
                                          title: "Imported", items: summary.imported))
                }
                if !summary.updated.isEmpty {
                    sections.append(.init(icon: "arrow.triangle.2.circlepath", tint: GRASPColor.accent,
                                          title: "Updated", items: summary.updated))
                }
                if !summary.unmatched.isEmpty {
                    sections.append(.init(icon: "questionmark.circle", tint: GRASPColor.textSecondary,
                                          title: "No matching course", items: summary.unmatched))
                }
                syncResult = SyncReport(
                    title: summary.changeCount > 0 ? "Calendar Synced" : "Already Up to Date",
                    lead: leadText(for: summary), sections: sections
                )
                load()
            }
        }
    }

    private func leadText(for summary: CalendarSync.Summary) -> String {
        let scanned = "Read \(summary.calendarsScanned) calendar\(summary.calendarsScanned == 1 ? "" : "s")"
        guard summary.changeCount > 0 else {
            return "\(scanned). No new exams or quizzes found in the next six months."
        }
        var text = "\(scanned) and found \(summary.changeCount) exam\(summary.changeCount == 1 ? "" : "s")."
        if !summary.unmatched.isEmpty {
            text += " Ones with no matching course were still added -- open them to pick a course, "
                + "or set that course's code so the next sync matches it automatically."
        }
        return text
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(periodTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(GRASPColor.textPrimary)
                Text(summaryLine)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            Spacer(minLength: 8)

            if mode != .agenda {
                HStack(spacing: 4) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(GRASPQuietButton())
                    Button("Today") { anchor = Date() }
                        .buttonStyle(GRASPQuietButton())
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(GRASPQuietButton())
                }
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            Button(action: syncSystemCalendar) {
                HStack(spacing: 5) {
                    if isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                    }
                    Text("Sync Calendar")
                }
            }
            .buttonStyle(GRASPQuietButton())
            .disabled(isSyncing)
            .help("Read exam and quiz dates from your Mac's Calendar and match them to courses. "
                  + "GRASP never changes anything in your calendar.")

            Button {
                creating = newEvent(on: calendar.startOfDay(for: Date()))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("New Event")
                }
            }
            .buttonStyle(GRASPProminentButton())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var periodTitle: String {
        switch mode {
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        case .week:
            guard let first = weekDays.first, let last = weekDays.last else { return "This Week" }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) – "
                + "\(last.formatted(.dateTime.month(.abbreviated).day()))"
        case .agenda:
            return "Agenda"
        }
    }

    private var summaryLine: String {
        let exams = events.filter { CalendarEventKind.examLike.contains($0.kind) }.count
        let others = events.count - exams
        if events.isEmpty {
            return mode == .agenda ? "Nothing scheduled in the next 90 days" : "Nothing scheduled"
        }
        var parts = ["\(exams) exam\(exams == 1 ? "" : "s")"]
        if others > 0 { parts.append("\(others) other event\(others == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func step(_ direction: Int) {
        let component: Calendar.Component = mode == .week ? .weekOfYear : .month
        anchor = calendar.date(byAdding: component, value: direction, to: anchor) ?? anchor
    }

    // MARK: - Date math

    /// Six full weeks, always -- a grid that changes height month to month
    /// makes the whole pane jump every time you step forward.
    private var gridDays: [Date] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)),
              let weekStart = calendar.dateInterval(of: .weekOfMonth, for: monthStart)?.start
        else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var weekDays: [Date] {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var visibleRange: (start: Date, end: Date) {
        switch mode {
        case .month:
            let start = gridDays.first ?? calendar.startOfDay(for: anchor)
            return (start, calendar.date(byAdding: .day, value: 42, to: start) ?? start)
        case .week:
            let start = weekDays.first ?? calendar.startOfDay(for: anchor)
            return (start, calendar.date(byAdding: .day, value: 7, to: start) ?? start)
        case .agenda:
            let start = calendar.startOfDay(for: Date())
            return (start, calendar.date(byAdding: .day, value: 90, to: start) ?? start)
        }
    }

    private var eventsByDay: [Date: [CalendarEvent]] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.startsAt) }
    }

    private func load() {
        let range = visibleRange
        events = (try? store.calendarEvents(from: range.start, to: range.end)) ?? []
        dailyLoad = store.dailyCardLoad(from: range.start, to: range.end)
    }

    private func newEvent(on day: Date) -> CalendarEvent {
        CalendarEvent(title: "", startsAt: calendar.startOfDay(for: day))
    }

    /// Jump straight into the deck an event is about -- the calendar's own
    /// version of Home's "Study" shortcut, so a glance at next week's exam
    /// can turn into actually studying for it without a detour through the
    /// sidebar.
    private func study(_ event: CalendarEvent) {
        guard let courseId = event.courseId else { return }
        selectedCourseId = courseId
        selectedDeckId = event.deckId ?? DeckListView.allCardsId
    }
}

// MARK: - Month

/// How heavy a day's reviewing is, as a traffic light on the month grid.
/// The bands are about what a day of studying actually feels like rather
/// than about even thirds: twenty cards is a coffee-length session, fifty
/// is a real sitting, and past that the day is one to move work off.
enum WorkloadLevel {
    case none, light, moderate, heavy

    init(cardCount: Int) {
        switch cardCount {
        case 0: self = .none
        case 1...20: self = .light
        case 21...50: self = .moderate
        default: self = .heavy
        }
    }

    var color: Color? {
        switch self {
        case .none: return nil
        case .light: return GRASPColor.success
        case .moderate: return GRASPColor.accent
        case .heavy: return GRASPColor.rejected
        }
    }

    var label: String {
        switch self {
        case .none: return "Nothing due"
        case .light: return "Light day"
        case .moderate: return "Moderate day"
        case .heavy: return "Heavy day"
        }
    }
}

private struct MonthGrid: View {
    let days: [Date]
    let anchor: Date
    let eventsByDay: [Date: [CalendarEvent]]
    let dailyLoad: [Date: Int]
    let onOpen: (CalendarEvent) -> Void
    let onAdd: (Date) -> Void

    private var calendar: Calendar { .current }

    /// `shortWeekdaySymbols` is always Sunday-first; rotating it by
    /// `firstWeekday` is what makes the header match the grid for anyone
    /// whose week starts on Monday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased())
                        .graspType(.eyebrow)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
            .background(GRASPColor.surface)

            GeometryReader { geometry in
                let rowHeight = max(74, geometry.size.height / 6)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                        ForEach(days, id: \.self) { day in
                            DayCell(
                                day: day,
                                isInMonth: calendar.isDate(day, equalTo: anchor, toGranularity: .month),
                                events: eventsByDay[calendar.startOfDay(for: day)] ?? [],
                                dueCount: dailyLoad[calendar.startOfDay(for: day)] ?? 0,
                                onOpen: onOpen,
                                onAdd: { onAdd(day) }
                            )
                            .frame(height: rowHeight)
                        }
                    }
                    .background(GRASPColor.hairline)
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let isInMonth: Bool
    let events: [CalendarEvent]
    let dueCount: Int
    let onOpen: (CalendarEvent) -> Void
    let onAdd: () -> Void

    @State private var isHovering = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var workload: WorkloadLevel { WorkloadLevel(cardCount: dueCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                    .graspType(.meta)
                    .monospacedDigit()
                    .foregroundStyle(dayNumberColor)
                    .padding(.horizontal, isToday ? 5 : 0)
                    .padding(.vertical, isToday ? 1 : 0)
                    .background {
                        if isToday { Capsule().fill(GRASPColor.accent) }
                    }
                // The workload dot yields to the hover "+" rather than
                // sitting beside it: two 9pt marks in one corner of a
                // small cell read as noise, and while you're reaching to
                // add something the dot isn't what you're looking at.
                if let color = workload.color, !isHovering {
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .help("\(workload.label) -- \(dueCount) card\(dueCount == 1 ? "" : "s") due")
                }
                Spacer(minLength: 0)
                if isHovering {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(GRASPColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Add an event on this day")
                }
            }

            // Three chips, then a count: a cell that lists everything
            // grows the row and pushes the rest of the month off screen,
            // and the agenda already exists for reading a day in full.
            ForEach(events.prefix(3)) { event in
                EventChip(event: event) { onOpen(event) }
            }
            if events.count > 3 {
                Text("+\(events.count - 3) more")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isInMonth ? GRASPColor.canvas : GRASPColor.inset)
        .onHover { isHovering = $0 }
    }

    private var dayNumberColor: Color {
        if isToday { return GRASPColor.canvas }
        return isInMonth ? GRASPColor.textPrimary : GRASPColor.textTertiary
    }
}

private struct EventChip: View {
    let event: CalendarEvent
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 4) {
                Image(systemName: event.kind.icon)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(event.kind.tint)
                Text(event.title.isEmpty ? event.kind.label : event.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(event.kind.softTint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(event.title)
    }
}

// MARK: - Week

private struct WeekColumns: View {
    let days: [Date]
    let eventsByDay: [Date: [CalendarEvent]]
    let onOpen: (CalendarEvent) -> Void
    let onAdd: (Date) -> Void

    private var calendar: Calendar { .current }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(days, id: \.self) { day in
                WeekColumn(
                    day: day,
                    events: eventsByDay[calendar.startOfDay(for: day)] ?? [],
                    onOpen: onOpen,
                    onAdd: { onAdd(day) }
                )
            }
        }
        .background(GRASPColor.hairline)
    }
}

private struct WeekColumn: View {
    let day: Date
    let events: [CalendarEvent]
    let onOpen: (CalendarEvent) -> Void
    let onAdd: () -> Void

    @State private var isHovering = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .graspType(.eyebrow)
                        .foregroundStyle(GRASPColor.textTertiary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? GRASPColor.accent : GRASPColor.textPrimary)
                }
                Spacer(minLength: 0)
                if isHovering {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(GRASPColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Add an event on this day")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(events) { event in
                        WeekEventCard(event: event) { onOpen(event) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GRASPColor.canvas)
        .onHover { isHovering = $0 }
    }
}

private struct WeekEventCard: View {
    let event: CalendarEvent
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: event.kind.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(event.kind.tint)
                    Text(event.kind.label)
                        .graspType(.eyebrow)
                        .foregroundStyle(event.kind.tint)
                }
                Text(event.title.isEmpty ? event.kind.label : event.title)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let timeText = event.timeText {
                    Text(timeText)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textSecondary)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(event.kind.softTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Agenda

private struct AgendaList: View {
    let events: [CalendarEvent]
    let onOpen: (CalendarEvent) -> Void
    let onStudy: (CalendarEvent) -> Void

    private var calendar: Calendar { .current }

    private var grouped: [(day: Date, events: [CalendarEvent])] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.startsAt) }
            .map { (day: $0.key, events: $0.value.sorted { $0.startsAt < $1.startsAt }) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView(
                "Nothing scheduled", systemImage: "calendar",
                description: Text("Add an exam, a deadline, or a study block to see it here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GRASPColor.canvas)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(group.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                    .graspType(.rowTitle)
                                    .foregroundStyle(GRASPColor.textPrimary)
                                Text(group.events[0].countdownText())
                                    .graspType(.meta)
                                    .foregroundStyle(GRASPColor.textTertiary)
                            }
                            ForEach(group.events) { event in
                                AgendaRow(event: event, onOpen: { onOpen(event) }, onStudy: { onStudy(event) })
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgendaRow: View {
    @Environment(AppStore.self) private var store
    let event: CalendarEvent
    let onOpen: () -> Void
    let onStudy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.kind.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? event.kind.label : event.title)
                    .graspType(.rowTitle)
                    .foregroundStyle(GRASPColor.textPrimary)
                HStack(spacing: 5) {
                    Text(event.kind.label).foregroundStyle(event.kind.tint)
                    if let courseName {
                        Text("·").foregroundStyle(GRASPColor.textTertiary)
                        Text(courseName).foregroundStyle(GRASPColor.textSecondary)
                    }
                    if let timeText = event.timeText {
                        Text("·").foregroundStyle(GRASPColor.textTertiary)
                        Text(timeText).foregroundStyle(GRASPColor.textSecondary)
                    }
                }
                .graspType(.meta)
            }
            Spacer(minLength: 8)
            if event.courseId != nil {
                Button("Study", action: onStudy)
                    .buttonStyle(GRASPQuietButton())
            }
            Button("Edit", action: onOpen)
                .buttonStyle(GRASPQuietButton())
        }
        .padding(10)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var courseName: String? {
        guard let courseId = event.courseId else { return nil }
        return store.courseName(courseId)
    }
}

// MARK: - Create / edit

/// One sheet for both creating and editing, since the fields are
/// identical and the only real difference is whether Delete is offered --
/// two near-identical sheets would only drift apart the next time either
/// gained a field.
struct CalendarEventEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let original: CalendarEvent
    let isNew: Bool

    @State private var title: String
    @State private var kind: CalendarEventKind
    @State private var day: Date
    @State private var isAllDay: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var courseId: String?
    @State private var deckId: String?
    @State private var decks: [Deck] = []
    @State private var showingDeleteConfirmation = false

    init(event: CalendarEvent, isNew: Bool) {
        self.original = event
        self.isNew = isNew
        _title = State(initialValue: event.title)
        _kind = State(initialValue: event.kind)
        _day = State(initialValue: event.startsAt)
        _isAllDay = State(initialValue: event.isAllDay)
        _startTime = State(initialValue: event.startsAt)
        _endTime = State(initialValue: event.endsAt ?? event.startsAt.addingTimeInterval(3600))
        _courseId = State(initialValue: event.courseId)
        _deckId = State(initialValue: event.deckId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: kind.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(kind.tint)
                Text(isNew ? "New Event" : "Edit Event")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
            }

            VStack(alignment: .leading, spacing: 12) {
                field("Title") {
                    TextField("e.g. ECON 201 Midterm", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                field("Type") {
                    Picker("", selection: $kind) {
                        ForEach(CalendarEventKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                field("Date") {
                    HStack(spacing: 10) {
                        DatePicker("", selection: $day, displayedComponents: .date)
                            .labelsHidden()
                        Toggle("All day", isOn: $isAllDay)
                        Spacer(minLength: 0)
                    }
                }
                if !isAllDay {
                    field("Time") {
                        HStack(spacing: 8) {
                            DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text("to").graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                            DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Spacer(minLength: 0)
                        }
                    }
                }
                field("Course") {
                    Picker("", selection: $courseId) {
                        Text("None").tag(String?.none)
                        ForEach(store.coursePickerGroups(), id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.courses) { course in
                                    Text(course.name).tag(String?.some(course.id))
                                }
                            }
                        }
                    }
                    .labelsHidden()
                }
                // Only meaningful once a course is picked: the deck list
                // is that course's decks, and a deck from some other
                // course would be a link to study the wrong material.
                if courseId != nil {
                    field("Deck to study") {
                        Picker("", selection: $deckId) {
                            Text("All cards in the course").tag(String?.none)
                            ForEach(decks) { deck in
                                Text(deck.name).tag(String?.some(deck.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            if canPlan {
                studyPlanSection
            }

            HStack {
                if !isNew {
                    Button("Delete") { showingDeleteConfirmation = true }
                        .buttonStyle(GRASPQuietButton())
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Add Event" : "Save") { save() }
                    .buttonStyle(GRASPProminentButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(GRASPColor.canvas)
        .task(id: courseId) { loadDecks() }
        .onChange(of: courseId) { _, _ in deckId = nil }
        .sheet(isPresented: $showingDeleteConfirmation) {
            ConfirmationSheet(
                icon: "trash",
                title: "Delete \"\(original.title)\"?",
                message: "This removes the event from your GRASP calendar. "
                    + "If it was an exam, its cards go back to ordinary spaced-repetition scheduling.",
                confirmTitle: "Delete"
            ) {
                try? store.deleteCalendarEvent(original.id)
                dismiss()
            }
        }
    }

    /// Only an exam or quiz that belongs to a course and is still in the
    /// future can be planned for -- there's nothing to schedule toward
    /// otherwise, and offering the button anyway would just produce an
    /// empty plan and a confused user.
    private var canPlan: Bool {
        !isNew && CalendarEventKind.examLike.contains(kind) && courseId != nil
            && edited.daysAway(from: Date()) >= 1
    }

    /// Generating writes to the calendar immediately, so the sheet closes
    /// and the plan appears behind it -- that's the confirmation, rather
    /// than a second sheet stacked on this one saying what you can already
    /// see.
    private var studyPlanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Study plan")
                        .graspType(.eyebrow)
                        .foregroundStyle(GRASPColor.textTertiary)
                    Text(planDescription)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(hasPlan ? "Regenerate" : "Generate") {
                    let event = edited
                    save()
                    try? store.generateStudyPlan(for: event)
                }
                .buttonStyle(GRASPQuietButton())
                .disabled(plannableCards == 0)
            }
        }
    }

    private var hasPlan: Bool { store.hasStudyPlan(for: original.id) }

    private var plannableCards: Int { store.plannableCardCount(for: edited) }

    private var planDescription: String {
        guard plannableCards > 0 else {
            return "No active cards in this deck yet -- add or approve some first."
        }
        let days = edited.daysAway(from: Date())
        let plan = StudyPlanner.plan(cardCount: plannableCards, from: Date(), examDate: original.startsAt)
        let existing = hasPlan ? "Replaces the current plan. " : ""
        let ending = plan.last?.isFinalReview == true
            ? ", ending with a full review the day before"
            : " -- the exam is too soon for a separate review day, so it's all one push"
        return "\(existing)\(plannableCards) cards across \(days) day\(days == 1 ? "" : "s") "
            + "-- \(plan.count) study block\(plan.count == 1 ? "" : "s")\(ending)."
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .graspType(.eyebrow)
                .foregroundStyle(GRASPColor.textTertiary)
            content()
        }
    }

    private func loadDecks() {
        decks = courseId.flatMap { try? store.decks(inCourse: $0) } ?? []
    }

    private func save() {
        let event = edited
        if isNew {
            try? store.addCalendarEvent(event)
        } else {
            try? store.updateCalendarEvent(event)
        }
        dismiss()
    }

    /// The event as it stands with the sheet's edits applied. The study plan
    /// reads this rather than `original`: planning from the pre-edit event
    /// laid out blocks for the old date and deck right after the new ones
    /// were saved.
    private var edited: CalendarEvent {
        let calendar = Calendar.current
        var event = original
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.kind = kind
        event.courseId = courseId
        event.deckId = courseId == nil ? nil : deckId
        event.isAllDay = isAllDay
        if isAllDay {
            event.startsAt = calendar.startOfDay(for: day)
            event.endsAt = nil
        } else {
            event.startsAt = combine(day: day, time: startTime, calendar: calendar)
            let end = combine(day: day, time: endTime, calendar: calendar)
            // An end before the start is a typo, not an overnight block --
            // drop it rather than storing a negative-length event the
            // week view would render as an empty sliver.
            event.endsAt = end > event.startsAt ? end : nil
        }
        return event
    }

    private func combine(day: Date, time: Date, calendar: Calendar) -> Date {
        let dayParts = calendar.dateComponents([.year, .month, .day], from: day)
        let timeParts = calendar.dateComponents([.hour, .minute], from: time)
        var parts = DateComponents()
        parts.year = dayParts.year; parts.month = dayParts.month; parts.day = dayParts.day
        parts.hour = timeParts.hour; parts.minute = timeParts.minute
        return calendar.date(from: parts) ?? day
    }
}
