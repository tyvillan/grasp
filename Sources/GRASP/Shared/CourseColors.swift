import SwiftUI
import GRASPCore

/// Which term is "now", and each course's color. Course colors are
/// secondary to the brand: one hue per course in the current term, shown on
/// sidebar dots and Calendar events, never on Home.
extension AppStore {
    /// A real term ("fall-2026"), as opposed to a catch-all like "Other".
    static func isTerm(_ semester: Semester) -> Bool {
        semester.slug.range(of: #"^(spring|summer|fall|winter)-\d{4}$"#, options: .regularExpression) != nil
    }

    /// The term whose dates contain today, else the newest term that has
    /// courses.
    var currentTerm: Semester? {
        let now = Date()
        let terms = semesters.filter { Self.isTerm($0) && !courses(inSemester: $0.id).isEmpty }
        if let dated = terms.first(where: { term in
            guard let start = term.startsOn, let end = term.endsOn else { return false }
            return start <= now && now <= end
        }) { return dated }
        return terms.max { $0.sortKey < $1.sortKey }
    }

    /// Terms other than the current one, newest first.
    var pastTerms: [Semester] {
        let current = currentTerm?.id
        return semesters.filter { Self.isTerm($0) && $0.id != current && !courses(inSemester: $0.id).isEmpty }
            .sorted { $0.sortKey > $1.sortKey }
    }

    /// Catch-all groups ("Other", side lectures) that aren't terms.
    var nonTermSemesters: [Semester] {
        semesters.filter { !Self.isTerm($0) && !courses(inSemester: $0.id).isEmpty }
            .sorted { $0.sortKey > $1.sortKey }
    }

    /// A course's color: the one chosen for it, else the palette slot for
    /// its position in its term, so a past term reads consistently too.
    func courseColor(_ course: Course) -> Color {
        if let hex = course.colorHex { return CoursePalette.color(hex: hex) }
        let siblings = courses(inSemester: course.semesterId)
        let index = siblings.firstIndex { $0.id == course.id } ?? 0
        return CoursePalette.slots[index % CoursePalette.slots.count].color
    }

    func courseColor(id courseId: String?) -> Color? {
        guard let courseId,
              let course = coursesBySemester.values.joined().first(where: { $0.id == courseId })
        else { return nil }
        return courseColor(course)
    }

    /// Gives every current-term course without a color the next unused
    /// palette slot, in order, and saves it -- so a course keeps its color
    /// when another is added. Never reuses a color within the term.
    func assignCourseColorsIfNeeded() {
        guard let term = currentTerm else { return }
        let courses = courses(inSemester: term.id).filter { !$0.isArchived }
        var used = Set(courses.compactMap { $0.colorHex?.uppercased() })
        for var course in courses where course.colorHex == nil {
            guard let slot = CoursePalette.slots.first(where: { !used.contains($0.hex) }) else { return }
            used.insert(slot.hex)
            course.colorHex = slot.hex
            try? updateCourse(course)
        }
    }
}
