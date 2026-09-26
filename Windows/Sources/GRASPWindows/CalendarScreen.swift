import Foundation
import GRASPCore
import SwiftCrossUI

/// Each kind's colours, as on the Mac: terracotta for an exam, amber for a
/// quiz, teal for a study block you set aside, neutral for a deadline.
extension CalendarEventKind {
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
    var displayTitle: String { title.isEmpty ? kind.label : title }

    /// "9:00 AM – 10:30 AM", or nil for an all-day event.
    var timeText: String? {
        guard !isAllDay else { return nil }
        let start = CalendarFormat.time(startsAt)
        guard let endsAt else { return start }
        return "\(start) – \(CalendarFormat.time(endsAt))"
    }
}

nonisolated enum CalendarFormat {
    static func string(_ date: Date, template: String, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// How heavy a day's reviewing is, as the Mac's month grid shows it:
/// twenty cards is a coffee-length session, fifty a real sitting.
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
}

/// The calendar: exams, quizzes, deadlines and study blocks in month, week
/// or agenda form, after the Mac's `CalendarView`. Events sync, so the
/// Mac's and iPhone's show up here. (The Mac's "Sync Calendar" reads the
/// Mac's own Calendar app, which Windows doesn't have.)
struct CalendarScreen: View {
    let library: Library
    /// Opens a course at a deck (nil for All Cards).
    let onStudy: (String, String?) -> Void

    @State var anchor = Date()
    @State var editor: EventEditorTarget?

    private var calendar: Calendar { library.settings.calendar }
    private var mode: AppSettings.CalendarMode { library.settings.calendarMode }

    var body: some View {
        // Read so edits and syncs redraw the calendar.
        let _ = library.revision
        let range = visibleRange
        let events = library.calendarEvents(from: range.start, to: range.end)
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.startsAt) }

        VStack(spacing: 0) {
            header(events: events)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
            switch mode {
            case .month:
                MonthGrid(
                    days: gridDays, anchor: anchor, calendar: calendar, eventsByDay: byDay,
                    dailyLoad: library.dailyCardLoad(from: range.start, to: range.end, calendar: calendar),
                    onOpen: open, onAdd: add
                )
            case .week:
                WeekColumns(days: weekDays, calendar: calendar, eventsByDay: byDay, onOpen: open, onAdd: add)
            case .agenda:
                AgendaList(library: library, events: events, calendar: calendar, onOpen: open, onStudy: study)
            }
        }
        .sheet(isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
            if let editor {
                EventEditor(library: library, target: editor) { self.editor = nil }
            }
        }
    }

    private func open(_ event: CalendarEvent) {
        editor = EventEditorTarget(event: event, isNew: false)
    }

    private func add(on day: Date) {
        editor = EventEditorTarget(event: CalendarEvent(title: "", startsAt: calendar.startOfDay(for: day)), isNew: true)
    }

    private func study(_ event: CalendarEvent) {
        guard let courseId = event.courseId else { return }
        onStudy(courseId, event.deckId)
    }

    // MARK: - Header

    private func header(events: [CalendarEvent]) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(periodTitle)
                    .font(Font.system(size: 20, weight: .semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                Text(summaryLine(events))
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textSecondary)
            }
            Spacer()
            if mode != .agenda {
                HStack(spacing: 4) {
                    Button("‹") { step(-1) }.fixedSize()
                    Button("Today") { anchor = Date() }.fixedSize()
                    Button("›") { step(1) }.fixedSize()
                }
            }
            SegmentedChoice(
                options: AppSettings.CalendarMode.allCases, selection: mode, label: \.rawValue
            ) { library.settings.calendarMode = $0 }
            Button("+ New Event") { add(on: Date()) }.fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var periodTitle: String {
        switch mode {
        case .month:
            return CalendarFormat.string(anchor, template: "MMMMy", calendar: calendar)
        case .week:
            guard let first = weekDays.first, let last = weekDays.last else { return "This Week" }
            return "\(CalendarFormat.string(first, template: "MMMd")) – \(CalendarFormat.string(last, template: "MMMd"))"
        case .agenda:
            return "Agenda"
        }
    }

    private func summaryLine(_ events: [CalendarEvent]) -> String {
        guard !events.isEmpty else {
            return mode == .agenda ? "Nothing scheduled in the next 90 days" : "Nothing scheduled"
        }
        let exams = events.filter { CalendarEventKind.examLike.contains($0.kind) }.count
        let others = events.count - exams
        var parts = ["\(exams) exam\(exams == 1 ? "" : "s")"]
        if others > 0 { parts.append("\(others) other event\(others == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func step(_ direction: Int) {
        let component: Calendar.Component = mode == .week ? .weekOfYear : .month
        anchor = calendar.date(byAdding: component, value: direction, to: anchor) ?? anchor
    }

    // MARK: - Date math (as on the Mac)

    /// Six full weeks, always, so the grid doesn't change height month to month.
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
}

/// A row of pill buttons standing in for a segmented control.
struct SegmentedChoice<Option: Equatable>: View {
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    let choose: (Option) -> Void

    init(options: [Option], selection: Option, label: @escaping (Option) -> String, choose: @escaping (Option) -> Void) {
        self.options = options
        self.selection = selection
        self.label = label
        self.choose = choose
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(label(option))
                    .font(GRASPFont.rowTitle)
                    .foregroundColor(option == selection ? GRASPColor.accent : GRASPColor.textSecondary)
                    // Otherwise the row squeezes labels to "Mon…".
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(option == selection ? GRASPColor.accentSoft : Color.clear)
                    .cornerRadius(6)
                    .onTapGesture { choose(option) }
            }
        }
        .padding(2)
        .background(GRASPColor.inset)
        .cornerRadius(8)
        .fixedSize()
    }
}

// MARK: - Month

private struct MonthGrid: View {
    let days: [Date]
    let anchor: Date
    let calendar: Calendar
    let eventsByDay: [Date: [CalendarEvent]]
    let dailyLoad: [Date: Int]
    let onOpen: (CalendarEvent) -> Void
    let onAdd: (Date) -> Void

    /// Weekday names starting on the calendar's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width.isFinite && proxy.size.width > 0 ? proxy.size.width : 840
            let height = proxy.size.height.isFinite && proxy.size.height > 0 ? proxy.size.height : 600
            let cellWidth = ((width - 6) / 7).rounded(.down)
            let rowHeight = max(84, ((height - 30 - 5) / 6).rounded(.down))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 1) {
                    ForEach(weekdaySymbols, id: \.self) { symbol in
                        Text(symbol.uppercased())
                            .font(GRASPFont.eyebrow)
                            .foregroundColor(GRASPColor.textTertiary)
                            .frame(width: cellWidth, height: 30.0)
                    }
                }
                .background(GRASPColor.surface)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(HomeView.rows(of: days, size: 7), id: \.first!) { week in
                            HStack(spacing: 1) {
                                ForEach(week, id: \.self) { day in
                                    DayCell(
                                        day: day,
                                        isInMonth: calendar.isDate(day, equalTo: anchor, toGranularity: .month),
                                        isToday: calendar.isDateInToday(day),
                                        dayNumber: calendar.component(.day, from: day),
                                        events: eventsByDay[calendar.startOfDay(for: day)] ?? [],
                                        dueCount: dailyLoad[calendar.startOfDay(for: day)] ?? 0,
                                        width: cellWidth,
                                        onOpen: onOpen,
                                        onAdd: { onAdd(day) }
                                    )
                                    .frame(width: cellWidth, height: rowHeight)
                                }
                            }
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
    let isToday: Bool
    let dayNumber: Int
    let events: [CalendarEvent]
    let dueCount: Int
    let width: Double
    let onOpen: (CalendarEvent) -> Void
    let onAdd: () -> Void
    @State var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(dayNumber)")
                    .font(GRASPFont.meta)
                    .foregroundColor(isToday ? GRASPColor.canvas : (isInMonth ? GRASPColor.textPrimary : GRASPColor.textTertiary))
                    .padding(.horizontal, isToday ? 5 : 0)
                    .padding(.vertical, isToday ? 1 : 0)
                    .background(isToday ? GRASPColor.accent : Color.clear)
                    .cornerRadius(8)
                // The workload dot gives way to the "+" while you hover.
                if let color = WorkloadLevel(cardCount: dueCount).color, !isHovering {
                    Circle().fill(color).frame(width: 5.0, height: 5.0)
                        .help("\(dueCount) card\(dueCount == 1 ? "" : "s") due")
                }
                Spacer()
                if isHovering {
                    Text("+")
                        .font(Font.system(size: 13, weight: .semibold))
                        .foregroundColor(GRASPColor.textTertiary)
                        .padding(.horizontal, 4)
                        .onTapGesture(perform: onAdd)
                        .help("Add an event on this day")
                }
            }
            // Three chips, then a count; the agenda is for reading a day in full.
            ForEach(Array(events.prefix(3)), id: \.id) { event in
                EventChip(event: event, width: width - 10) { onOpen(event) }
            }
            if events.count > 3 {
                Text("+\(events.count - 3) more")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            Spacer()
        }
        .padding(5)
        .background(isInMonth ? GRASPColor.canvas : GRASPColor.inset)
        .onHover { isHovering = $0 }
    }
}

private struct EventChip: View {
    let event: CalendarEvent
    let width: Double
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(event.kind.tint).frame(width: 6.0, height: 6.0)
            Text(event.displayTitle)
                .font(Font.system(size: 10, weight: .medium))
                .foregroundColor(GRASPColor.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(width: max(20, width))
        .background(event.kind.softTint)
        .cornerRadius(4)
        .onTapGesture(perform: onOpen)
        .help(event.displayTitle)
    }
}

// MARK: - Week

private struct WeekColumns: View {
    let days: [Date]
    let calendar: Calendar
    let eventsByDay: [Date: [CalendarEvent]]
    let onOpen: (CalendarEvent) -> Void
    let onAdd: (Date) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width.isFinite && proxy.size.width > 0 ? proxy.size.width : 840
            let columnWidth = ((width - 6) / 7).rounded(.down)
            HStack(spacing: 1) {
                ForEach(days, id: \.self) { day in
                    WeekColumn(
                        day: day,
                        weekday: CalendarFormat.string(day, template: "EEE").uppercased(),
                        dayNumber: calendar.component(.day, from: day),
                        isToday: calendar.isDateInToday(day),
                        events: eventsByDay[calendar.startOfDay(for: day)] ?? [],
                        width: columnWidth,
                        onOpen: onOpen,
                        onAdd: { onAdd(day) }
                    )
                    .frame(width: columnWidth)
                    .frame(maxHeight: .infinity)
                }
            }
            .background(GRASPColor.hairline)
        }
    }
}

private struct WeekColumn: View {
    let day: Date
    let weekday: String
    let dayNumber: Int
    let isToday: Bool
    let events: [CalendarEvent]
    let width: Double
    let onOpen: (CalendarEvent) -> Void
    let onAdd: () -> Void
    @State var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(weekday).font(GRASPFont.eyebrow).foregroundColor(GRASPColor.textTertiary)
                    Text("\(dayNumber)")
                        .font(Font.system(size: 16, weight: .semibold))
                        .foregroundColor(isToday ? GRASPColor.accent : GRASPColor.textPrimary)
                }
                Spacer()
                if isHovering {
                    Text("+")
                        .font(Font.system(size: 14, weight: .semibold))
                        .foregroundColor(GRASPColor.textTertiary)
                        .padding(.horizontal, 4)
                        .onTapGesture(perform: onAdd)
                        .help("Add an event on this day")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(events, id: \.id) { event in
                        WeekEventCard(event: event, width: width - 16) { onOpen(event) }
                    }
                }
            }
            Spacer()
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(GRASPColor.canvas)
        .onHover { isHovering = $0 }
    }
}

private struct WeekEventCard: View {
    let event: CalendarEvent
    let width: Double
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.kind.label.uppercased())
                .font(GRASPFont.eyebrow)
                .foregroundColor(event.kind.tint)
            Text(event.displayTitle)
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textPrimary)
                .lineLimit(2)
            if let timeText = event.timeText {
                Text(timeText).font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary)
            }
        }
        .padding(7)
        .frame(width: max(40, width), alignment: .leading)
        .background(event.kind.softTint)
        .cornerRadius(6)
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - Agenda

private struct AgendaList: View {
    let library: Library
    let events: [CalendarEvent]
    let calendar: Calendar
    let onOpen: (CalendarEvent) -> Void
    let onStudy: (CalendarEvent) -> Void

    private var grouped: [(day: Date, events: [CalendarEvent])] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.startsAt) }
            .map { (day: $0.key, events: $0.value.sorted { $0.startsAt < $1.startsAt }) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        if events.isEmpty {
            VStack(spacing: 8) {
                Text("Nothing scheduled").font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
                Text("Add an exam, a deadline, or a study block to see it here.")
                    .foregroundColor(GRASPColor.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(CalendarFormat.string(group.day, template: "EEEEMMMd"))
                                    .font(GRASPFont.rowTitle)
                                    .foregroundColor(GRASPColor.textPrimary)
                                Text(group.events[0].countdownText())
                                    .font(GRASPFont.meta)
                                    .foregroundColor(GRASPColor.textTertiary)
                            }
                            ForEach(group.events, id: \.id) { event in
                                AgendaRow(
                                    event: event,
                                    courseName: event.courseId.flatMap { library.courseName($0) },
                                    onOpen: { onOpen(event) },
                                    onStudy: { onStudy(event) }
                                )
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: 720.0)
            }
        }
    }
}

private struct AgendaRow: View {
    let event: CalendarEvent
    let courseName: String?
    let onOpen: () -> Void
    let onStudy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(event.kind.tint).frame(width: 3.0, height: 34.0).cornerRadius(2)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayTitle)
                    .font(GRASPFont.rowTitle)
                    .foregroundColor(GRASPColor.textPrimary)
                Text(detail)
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textSecondary)
            }
            Spacer()
            if event.courseId != nil {
                Button("Study") { onStudy() }.fixedSize()
            }
            Button("Edit") { onOpen() }.fixedSize()
        }
        .padding(10)
        .background(GRASPColor.surface)
        .cornerRadius(8)
    }

    private var detail: String {
        var parts = [event.kind.label]
        if let courseName { parts.append(courseName) }
        if let timeText = event.timeText { parts.append(timeText) }
        return parts.joined(separator: " · ")
    }
}
