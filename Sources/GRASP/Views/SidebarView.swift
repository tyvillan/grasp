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

    var body: some View {
        List(selection: $selectedCourseId) {
            Label("Home", systemImage: "house.fill")
                .tag(ContentView.homeRoute)
                .padding(.vertical, 2)

            ForEach(store.semesters.reversed()) { semester in
                let courses = store.courses(inSemester: semester.id)
                if !courses.isEmpty {
                    Section(semester.name) {
                        ForEach(courses) { course in
                            CourseRow(course: course).tag(course.id)
                        }
                    }
                }
            }
            if !store.unfiledCourses.isEmpty {
                Section("This Semester") {
                    ForEach(store.unfiledCourses) { course in
                        CourseRow(course: course).tag(course.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("GRASP")
    }
}

private struct CourseRow: View {
    let course: Course

    var body: some View {
        HStack {
            Text(course.name)
            Spacer()
            if let code = course.code {
                Text(code)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
