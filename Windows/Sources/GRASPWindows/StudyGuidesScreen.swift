import Foundation
import GRASPCore
import SwiftCrossUI

/// Where a row of the Study guides page leads, as the Mac's
/// `StudyGuideHubTarget`.
enum StudyGuideTarget: Hashable {
    case exam(courseId: String, examEventId: String)
    /// A guide with no exam.
    case practice(courseId: String, guideId: String)
}

/// The Study guides page, after the Mac's `StudyGuideHubView`: every
/// course's guides in one place, upcoming exams first (with or without a
/// guide), then practice sets, then past exams that have one. A row opens
/// the guide's page; an upcoming exam with no guide offers to add one.
///
/// The Mac's "New study guide" and "Make a study guide" write a practice
/// guide with AI. Here the page's one yellow button adds a guide file, and
/// an exam's row adds one straight to that exam.
struct StudyGuidesScreen: View {
    let library: Library
    let open: (StudyGuideTarget) -> Void
    @Environment(\.chooseFile) var chooseFile
    @State var expanded: Set<String> = []
    @State var choosingCourse = false
    @State var message: String?

    private static let sidePadding = 40.0
    private static let maxWidth = 1180.0

    var body: some View {
        let courses = visibleCourses
        GeometryReader { proxy in
            let available = PaneWidth.width(proxy.size.width)
            let width = min(Self.maxWidth, max(320, available - 2 * Self.sidePadding))
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    if let message {
                        HStack(spacing: 10) {
                            Text(message).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                            Spacer()
                            GRASPButton("Dismiss") { self.message = nil }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
                    }
                    if courses.isEmpty {
                        EmptyState(title: "No study guides yet",
                                   message: "Add a professor's or your own exam guide with Add a study guide. GRASP recognises guides by name, like \"Exam 1 Study Guide\" or \"Midterm Review\".")
                    }
                    ForEach(courses, id: \.id) { course in
                        courseBlock(course)
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.leading, Int(Self.sidePadding))
                .padding(.top, 32)
                .padding(.bottom, 48)
            }
        }
        .sheet(isPresented: Binding(get: { choosingCourse }, set: { if $0 != choosingCourse { choosingCourse = $0 } })) {
            GuideCourseSheet(groups: library.sidebarGroups.current, choose: { course in
                choosingCourse = false
                addGuide(to: course, exam: nil)
            }, close: { choosingCourse = false })
        }
    }

    /// The Mac's filter and order: a course shows when it has a guide or an
    /// exam still ahead, the one with the nearest exam first.
    private var visibleCourses: [StudyGuideActions.HubCourse] {
        let kept = library.studyGuideHub().filter { course in
            course.exams.contains { !$0.guides.isEmpty || !$0.isPast } || !course.practiceSets.isEmpty
        }
        func soonest(_ course: StudyGuideActions.HubCourse) -> Date {
            course.exams.filter { !$0.isPast }.map(\.exam.startsAt).min() ?? .distantFuture
        }
        return kept.enumerated().sorted { a, b in
            let (x, y) = (soonest(a.element), soonest(b.element))
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Study guides")
                .font(GRASPFont.display)
                .foregroundColor(GRASPColor.textPrimary)
            Spacer()
            if library.isImporting {
                Text("Reading guide\u{2026}").font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary).fixedSize()
            }
            GRASPButton("+ Add a study guide", kind: .primary) { choosingCourse = true }
                .disabled(library.isImporting)
        }
    }

    private func courseBlock(_ course: StudyGuideActions.HubCourse) -> some View {
        let upcoming = course.exams.filter { !$0.isPast }
        let past = course.exams.filter { $0.isPast && !$0.guides.isEmpty }
        let limit = 3
        let isExpanded = expanded.contains(course.id)
        let shown = isExpanded ? upcoming : Array(upcoming.prefix(limit))
        return VStack(alignment: .leading, spacing: 10) {
            Text(course.course.name)
                .font(Font.system(size: 22, weight: .heavy))
                .foregroundColor(GRASPColor.textPrimary)
            if !shown.isEmpty {
                group("Upcoming exams") {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { HairlineRule() }
                        examRow(entry, in: course.course)
                    }
                }
                if upcoming.count > limit {
                    Text(isExpanded ? "Show fewer" : "Show \(upcoming.count - limit) more")
                        .font(Font.system(size: 13, weight: .medium))
                        .foregroundColor(GRASPColor.textSecondary)
                        .padding(.top, 2)
                        .onTapGesture {
                            if isExpanded { expanded.remove(course.id) } else { expanded.insert(course.id) }
                        }
                }
            }
            if !course.practiceSets.isEmpty {
                group("Practice sets") {
                    ForEach(Array(course.practiceSets.enumerated()), id: \.element.id) { index, guide in
                        if index > 0 { HairlineRule() }
                        practiceRow(guide, in: course.course)
                    }
                }
            }
            if !past.isEmpty {
                group("Past exams") {
                    ForEach(Array(past.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { HairlineRule() }
                        examRow(entry, in: course.course)
                    }
                }
            }
        }
    }

    private func group<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 0) {
                rows()
            }
            .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.card)
        }
    }

    @ViewBuilder
    private func examRow(_ entry: StudyGuideActions.HubExam, in course: Course) -> some View {
        let date = CalendarFormat.string(entry.exam.startsAt, template: "EEEMMMd")
        let when = entry.isPast ? "\(date) \u{00B7} past" : "\(date) \u{00B7} \(entry.exam.countdownText())"
        if entry.guides.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                // The same mark column as the other rows, muted: nothing to open yet.
                Rectangle()
                    .fill(GRASPColor.hairlineStrong)
                    .frame(width: 8.0, height: 8.0)
                    .cornerRadius(2)
                    .frame(width: 14.0)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.exam.title).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary).lineLimit(1)
                    Text(when).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).lineLimit(1)
                    Text("No study guide yet").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).lineLimit(1)
                }
                Spacer()
                GRASPButton("Add a study guide") { addGuide(to: course, exam: entry.exam) }
                    .disabled(library.isImporting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        } else {
            let count = entry.guides.count
            row(title: entry.exam.title, subtitle: "\(when) \u{00B7} \(count) guide\(count == 1 ? "" : "s")",
                marked: !entry.isPast, dimmed: entry.isPast) {
                open(.exam(courseId: course.id, examEventId: entry.exam.id))
            }
        }
    }

    private func practiceRow(_ guide: StudyGuide, in course: Course) -> some View {
        let parts = guide.document()?.parts.count ?? 0
        let made = CalendarFormat.string(guide.createdAt, template: "MMMd")
        let written = guide.parser.hasPrefix("ai:")
        return row(title: guide.title,
                   subtitle: "\(parts) part\(parts == 1 ? "" : "s") \u{00B7} \(written ? "written" : "added") \(made)",
                   marked: true, dimmed: false) {
            open(.practice(courseId: course.id, guideId: guide.id))
        }
    }

    /// A row that opens a guide: a small mark (the yellow square for a guide
    /// ahead of you, muted once past, where the Mac has its cap icon), the
    /// title and a line, and a chevron.
    private func row(title: String, subtitle: String, marked: Bool, dimmed: Bool,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(marked ? GRASPColor.brand : GRASPColor.hairlineStrong)
                .frame(width: 8.0, height: 8.0)
                .cornerRadius(2)
                .frame(width: 14.0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GRASPFont.rowTitle)
                    .foregroundColor(dimmed ? GRASPColor.textSecondary : GRASPColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).lineLimit(1)
            }
            Spacer()
            Text("\u{203A}").font(Font.system(size: 18, weight: .semibold)).foregroundColor(GRASPColor.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .onTapGesture(perform: action)
    }

    /// The file dialog, then the import into the course. With an exam, every
    /// guide the import touched is linked to it; without one, the matcher
    /// links each guide to the exam its title and dates fit.
    private func addGuide(to course: Course, exam: CalendarEvent?) {
        Task {
            guard let url = await chooseFile(
                title: exam.map { "Choose a study guide for \($0.title)" } ?? "Choose a study guide for \(course.name)",
                defaultButtonLabel: "Add",
                allowSelectingFiles: true,
                allowSelectingDirectories: false
            ) else { return }
            let read = await library.importStudyGuides([url], intoCourse: course.id, examEventId: exam?.id)
            message = read == 0
                ? "That file didn't read as a study guide. Guides are recognised by name, like \"Exam 1 Study Guide\" or \"Midterm Review\"."
                : nil
            if read > 0, let exam {
                open(.exam(courseId: course.id, examEventId: exam.id))
            }
        }
    }
}

/// Which course a new guide goes into: this term's courses and the
/// catch-all groups, as the sidebar lists them.
private struct GuideCourseSheet: View {
    let groups: [(title: String, courses: [Course])]
    let choose: (Course) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Study guides")
            Text("Add a study guide")
                .font(Font.system(size: 22, weight: .heavy))
                .foregroundColor(GRASPColor.textPrimary)
            Text("Pick the course, then the guide's file. GRASP links it to the exam its title and dates fit, and each part to its lecture decks.")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.title) { group in
                    SectionLabel(group.title).padding(.top, 12).padding(.bottom, 4)
                    ForEach(group.courses, id: \.id) { course in
                        HStack(spacing: 10) {
                            Circle().fill(course.colorHex.map { Color(hex: $0) } ?? GRASPColor.textTertiary)
                                .frame(width: 8.0, height: 8.0)
                            Text(course.name.replacingOccurrences(of: "++", with: "+\u{2060}+"))
                                .font(GRASPFont.rowTitle)
                                .foregroundColor(GRASPColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text("\u{203A}").font(Font.system(size: 16, weight: .semibold)).foregroundColor(GRASPColor.textTertiary)
                        }
                        .padding(.vertical, 8)
                        .onTapGesture { choose(course) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(width: 452.0, alignment: .leading)
            .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
            HStack(spacing: 8) {
                Spacer()
                GRASPButton("Cancel") { close() }
            }
        }
        .padding(24)
        .frame(width: 500.0)
        .background(GRASPColor.canvas)
    }
}

/// A guide opened from the Study guides page: a way back, then the exam
/// page (or a practice set's page) the course's deck column also opens.
struct StudyGuidePage: View {
    let library: Library
    let target: StudyGuideTarget
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\u{2190} Study guides")
                    .font(Font.system(size: 13, weight: .medium))
                    .foregroundColor(GRASPColor.textSecondary)
                    .onTapGesture(perform: back)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 2)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch target {
        case .exam(let courseId, let examEventId):
            if let course = library.course(courseId), let page = library.examPage(examEventId: examEventId) {
                ExamStudyView(library: library, course: course, exam: page.exam, organize: { _ in })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                missing
            }
        case .practice(let courseId, let guideId):
            if let course = library.course(courseId), let page = library.practicePage(guideId: guideId) {
                ExamStudyView(library: library, course: course, exam: page.exam, organize: { _ in },
                              practiceGuideId: guideId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                missing
            }
        }
    }

    private var missing: some View {
        Text("This guide isn't in the library any more.")
            .foregroundColor(GRASPColor.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
