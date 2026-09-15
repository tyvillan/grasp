import SwiftUI
import GRASPCore

/// "Home" plus semesters-as-sections/courses-as-rows, newest semester
/// first (by `sortKey`, derived from the tag/slug -- never trust folder
/// name order, several vault folders are misleadingly named). Home shares
/// the same selection binding as courses via the `ContentView.homeRoute`
/// sentinel, so picking either is one selection, not two separate states.
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedCourseId: String?

    @State private var editingCourse: Course?
    @State private var deletingCourse: Course?

    var body: some View {
        List(selection: $selectedCourseId) {
            HStack(spacing: 7) {
                Image(systemName: "house.fill")
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text("Home").graspType(.rowTitle)
                Spacer(minLength: 0)
            }
            .tag(ContentView.homeRoute)
            .padding(.vertical, 3)

            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text("Calendar").graspType(.rowTitle)
                Spacer(minLength: 0)
            }
            .tag(ContentView.calendarRoute)
            .padding(.vertical, 3)

            ForEach(store.semesters.reversed()) { semester in
                let courses = store.courses(inSemester: semester.id)
                if !courses.isEmpty {
                    Section {
                        ForEach(courses) { course in
                            courseRow(course)
                        }
                    } header: {
                        SectionLabel(semester.name).padding(.top, 6)
                    }
                }
            }
            if !store.unfiledCourses.isEmpty {
                Section {
                    ForEach(store.unfiledCourses) { course in
                        courseRow(course)
                    }
                } header: {
                    SectionLabel("No Timeline").padding(.top, 6)
                }
            }
        }
        .listStyle(.sidebar)
        // The sidebar keeps real vibrancy -- it should sample what's
        // behind the window, as every Mac sidebar does -- but tinted
        // toward GRASP's own ground so it reads as part of this app
        // rather than a stock panel bolted to a black detail pane. The
        // material also resolves from the SwiftUI environment, which
        // keeps it in step with the detail pane's appearance instead of
        // drifting light while the content stays dark.
        .scrollContentBackground(.hidden)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(GRASPColor.canvas.opacity(0.45))
                .ignoresSafeArea()
        }
        // Row selection draws from the tint, so the selected course reads
        // in GRASP's amber instead of the stock grey pill.
        .tint(GRASPColor.accent)
        .navigationTitle("GRASP")
        .sheet(item: $editingCourse) { course in
            CourseEditSheet(course: course)
        }
        .courseDeleteConfirmation($deletingCourse) { deletedId in
            if selectedCourseId == deletedId { selectedCourseId = ContentView.homeRoute }
        }
    }

    @ViewBuilder
    private func courseRow(_ course: Course) -> some View {
        CourseRow(course: course)
            .tag(course.id)
            .contextMenu {
                CourseContextMenu(
                    course: course,
                    onEdit: { editingCourse = course },
                    onArchive: {
                        // Matches `courseDeleteConfirmation`'s own fallback
                        // below: archiving hides a course from both the
                        // sidebar and the dashboard, so leaving it selected
                        // would strand `ContentView` still showing an
                        // archived course's deck list with no matching row
                        // anywhere in the sidebar to show it as selected.
                        let isArchiving = !course.isArchived
                        try? store.setCourseArchived(course.id, archived: isArchiving)
                        if isArchiving, selectedCourseId == course.id {
                            selectedCourseId = ContentView.homeRoute
                        }
                    },
                    onDelete: { deletingCourse = course }
                )
            }
    }
}

/// The color dot sits in a fixed-width slot whether or not the course has
/// a color, so every course name starts on the same x -- a ragged left
/// edge is the fastest way to make a sidebar look unconsidered.
///
/// The course code is deliberately not shown here. Now that the Fall 2026
/// notes actually carry codes, a trailing "COP 3275C" costs enough width
/// to truncate the names beside it ("Systems Progr..."), and a sidebar
/// exists to be scanned by name. The code still appears on the dashboard
/// course tiles, which have room for it, and in the tooltip here.
private struct CourseRow: View {
    let course: Course

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(course.colorHex.map { Color(hex: $0) } ?? GRASPColor.hairlineStrong)
                .frame(width: 7, height: 7)
                .frame(width: 16)
            Text(course.name)
                .graspType(.rowTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(course.code.map { "\(course.name) (\($0))" } ?? course.name)
    }
}
