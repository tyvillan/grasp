import Foundation
import GRASPCore
import SwiftCrossUI

/// What the event editor opens on: an existing event, or a new one.
struct EventEditorTarget {
    let event: CalendarEvent
    let isNew: Bool
}

/// A picker option: a label and the id it stands for (nil for "None").
struct Choice: Equatable, CustomStringConvertible {
    let id: String?
    let description: String
}

/// One sheet for creating and editing an event, after the Mac's
/// `CalendarEventEditSheet`: title, type, date and time, course, the deck
/// to study, a study plan for an upcoming exam, and delete.
struct EventEditor: View {
    let library: Library
    let original: CalendarEvent
    let isNew: Bool
    let close: () -> Void

    @State var title: String
    @State var kind: CalendarEventKind
    @State var day: Date
    @State var isAllDay: Bool
    @State var startTime: Date
    @State var endTime: Date
    @State var courseId: String?
    @State var deckId: String?
    @State var confirmingDelete = false

    init(library: Library, target: EventEditorTarget, close: @escaping () -> Void) {
        let event = target.event
        self.library = library
        self.original = event
        self.isNew = target.isNew
        self.close = close
        _title = State(wrappedValue: event.title)
        _kind = State(wrappedValue: event.kind)
        _day = State(wrappedValue: event.startsAt)
        _isAllDay = State(wrappedValue: event.isAllDay)
        _startTime = State(wrappedValue: event.startsAt)
        _endTime = State(wrappedValue: event.endsAt ?? event.startsAt.addingTimeInterval(3600))
        _courseId = State(wrappedValue: event.courseId)
        _deckId = State(wrappedValue: event.deckId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Event" : "Edit Event")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)

            field("Title") {
                TextField("e.g. ECON 201 Midterm", text: $title)
            }
            field("Type") {
                SegmentedChoice(options: CalendarEventKind.allCases, selection: kind, label: \.label) { kind = $0 }
            }
            field("Date") {
                HStack(spacing: 12) {
                    DatePicker("", selection: $day, displayedComponents: .date)
                    // A pill rather than WinUI's toggle, which draws in
                    // Windows' accent colour instead of GRASP's amber.
                    SegmentedChoice(options: [true], selection: isAllDay, label: { _ in "All day" }) { _ in
                        isAllDay.toggle()
                    }
                    Spacer()
                }
            }
            if !isAllDay {
                field("Time") {
                    HStack(spacing: 8) {
                        DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                        Text("to").font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary)
                        DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                        Spacer()
                    }
                }
            }
            field("Course") {
                Picker(of: courseChoices, selection: Binding(
                    get: { courseChoices.first { $0.id == courseId } },
                    set: { choice in
                        // A deck from another course would be the wrong material.
                        if choice?.id != courseId { deckId = nil }
                        courseId = choice?.id
                    }
                ))
            }
            // Only meaningful once a course is picked: the list is its decks.
            if courseId != nil {
                field("Deck to study") {
                    Picker(of: deckChoices, selection: Binding(
                        get: { deckChoices.first { $0.id == deckId } },
                        set: { deckId = $0?.id }
                    ))
                }
            }

            if canPlan {
                studyPlanSection
            }

            if confirmingDelete {
                HStack(spacing: 8) {
                    Text("Delete \"\(original.displayTitle)\"? Its study plan goes too, and an exam's cards go back to ordinary scheduling.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.rejected)
                    Spacer()
                    Button("Delete") {
                        library.deleteEvent(original.id)
                        close()
                    }
                    .fixedSize()
                    Button("Keep") { confirmingDelete = false }.fixedSize()
                }
            } else {
                HStack(spacing: 8) {
                    if !isNew {
                        Button("Delete…") { confirmingDelete = true }.fixedSize()
                    }
                    Spacer()
                    Button("Cancel") { close() }.fixedSize()
                    Button(isNew ? "Add Event" : "Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fixedSize()
                }
            }
        }
        .padding(24)
        .frame(width: 480.0)
        .background(GRASPColor.canvas)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(label)
            content()
        }
    }

    private var courseChoices: [Choice] {
        [Choice(id: nil, description: "None")]
            + library.courseSections.flatMap(\.courses).map { Choice(id: $0.id, description: $0.name) }
    }

    private var deckChoices: [Choice] {
        [Choice(id: nil, description: "All cards in the course")]
            + (courseId.map { library.decks(inCourse: $0) } ?? []).map { Choice(id: $0.id, description: $0.name) }
    }

    // MARK: - Study plan

    /// Only an existing exam or quiz for a course, still in the future,
    /// can be planned for; anything else would just make an empty plan.
    private var canPlan: Bool {
        !isNew && CalendarEventKind.examLike.contains(kind) && courseId != nil
            && edited.daysAway(from: Date()) >= 1
    }

    private var studyPlanSection: some View {
        let cards = library.plannableCardCount(for: edited)
        let hasPlan = library.hasStudyPlan(for: original.id)
        return VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Study plan")
                    Text(planDescription(cards: cards, hasPlan: hasPlan))
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textSecondary)
                }
                Spacer()
                // Saving first, so the plan is laid out for the edited date and deck.
                Button(hasPlan ? "Regenerate" : "Generate") {
                    let event = edited
                    persist(event)
                    library.generateStudyPlan(for: event)
                    close()
                }
                .disabled(cards == 0)
                .fixedSize()
            }
        }
    }

    private func planDescription(cards: Int, hasPlan: Bool) -> String {
        guard cards > 0 else { return "No active cards in this deck yet -- add or approve some first." }
        let event = edited
        let days = event.daysAway(from: Date())
        let plan = StudyPlanner.plan(cardCount: cards, from: Date(), examDate: event.startsAt)
        let existing = hasPlan ? "Replaces the current plan. " : ""
        let ending = plan.last?.isFinalReview == true
            ? ", ending with a full review the day before"
            : " -- the exam is too soon for a separate review day, so it's all one push"
        return "\(existing)\(cards) cards across \(days) day\(days == 1 ? "" : "s") "
            + "-- \(plan.count) study block\(plan.count == 1 ? "" : "s")\(ending)."
    }

    // MARK: - Saving

    private func save() {
        persist(edited)
        close()
    }

    private func persist(_ event: CalendarEvent) {
        if isNew { library.addEvent(event) } else { library.updateEvent(event) }
    }

    /// The event with the sheet's edits applied.
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
            // An end before the start is a typo, not an overnight block.
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
