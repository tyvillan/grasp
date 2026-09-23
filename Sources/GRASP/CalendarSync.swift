import Foundation
import EventKit
import GRASPCore

/// Reads exam dates out of the Mac's own Calendar (including any Google or
/// iCloud calendars subscribed there) and mirrors them into GRASP.
///
/// Strictly one-way: this never creates, edits or deletes anything in
/// Calendar.app. Events it imports keep the system event's identifier in
/// `CalendarEvent.sourceEventId`, so a later sync updates the same row --
/// a rescheduled midterm moves rather than appearing twice -- and anything
/// you typed into GRASP yourself (`sourceEventId == nil`) is never touched
/// by a sync at all.
///
/// The judgment calls -- is this title an exam, and whose course is it --
/// live in `ExamEventMatcher` in GRASPCore, where they're unit-tested
/// without needing a calendar or a permission prompt.
enum CalendarSync {

    struct Summary: Sendable {
        var imported: [String] = []
        var updated: [String] = []
        /// Titles that read as exams but matched no course. Surfaced
        /// rather than silently dropped: an unmatched exam is usually a
        /// missing course code, which is a two-second fix once you know.
        var unmatched: [String] = []
        var calendarsScanned = 0

        var changeCount: Int { imported.count + updated.count }
    }

    enum SyncError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "GRASP doesn't have permission to read your calendar. "
                    + "Grant it in System Settings › Privacy & Security › Calendars, then try again."
            }
        }
    }

    /// Asks for calendar access, reading whatever the user has already
    /// decided rather than re-prompting on every sync (macOS only shows
    /// the prompt once; after a denial the request returns false
    /// immediately, which is what surfaces as `accessDenied`).
    static func requestAccess(store: EKEventStore) async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await store.requestFullAccessToEvents()
        }
        return try await store.requestAccess(to: .event)
    }

    /// One scanned calendar entry, flattened out of EventKit into plain
    /// values. `EKEvent` is a non-Sendable reference type owned by the
    /// event store, so it must not cross into the database writer --
    /// copying the five fields that actually get persisted is what keeps
    /// the sync free of it.
    struct ScannedEvent: Sendable {
        let sourceEventId: String
        let title: String
        let startsAt: Date
        let endsAt: Date?
        let isAllDay: Bool
        let kind: CalendarEventKind
        let courseId: String?
    }

    /// Every exam-looking event in the window, already matched to courses.
    /// Returns what it would write, so the caller can persist it and report
    /// on it -- this half stays free of the database.
    static func scan(
        store: EKEventStore, courses: [(id: String, name: String, code: String?)],
        from start: Date, to end: Date
    ) -> [ScannedEvent] {
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            guard let title = event.title,
                  let sourceEventId = event.eventIdentifier,
                  let startDate = event.startDate,
                  let kind = ExamEventMatcher.examKind(forTitle: title)
            else { return nil }
            // Every occurrence of a repeating event shares one identifier, so
            // keyed on that alone a weekly quiz collapsed into a single row
            // that each occurrence overwrote in turn. Occurrences get the
            // date appended; one-off events keep the bare identifier, so
            // rows already synced still match.
            let key = event.hasRecurrenceRules
                ? "\(sourceEventId)@\(Int((event.occurrenceDate ?? startDate).timeIntervalSince1970))"
                : sourceEventId
            return ScannedEvent(
                sourceEventId: key, title: title, startsAt: startDate,
                endsAt: event.isAllDay ? nil : event.endDate, isAllDay: event.isAllDay,
                kind: kind, courseId: ExamEventMatcher.matchCourse(title: title, courses: courses)
            )
        }
    }

    static func calendarCount(store: EKEventStore) -> Int {
        store.calendars(for: .event).count
    }
}
