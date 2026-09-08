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
    @State private var deletionImpact: (materials: Int, cards: Int, reviews: Int)?

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
                            courseRow(course)
                        }
                    }
                }
            }
            if !store.unfiledCourses.isEmpty {
                Section("This Semester") {
                    ForEach(store.unfiledCourses) { course in
                        courseRow(course)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("GRASP")
        .sheet(item: $editingCourse) { course in
            CourseEditSheet(course: course)
        }
        .alert(
            "Delete \(deletingCourse?.name ?? "course")?",
            isPresented: Binding(
                get: { deletingCourse != nil },
                set: { if !$0 { deletingCourse = nil } }
            ),
            presenting: deletingCourse
        ) { course in
            Button("Delete", role: .destructive) {
                if selectedCourseId == course.id { selectedCourseId = ContentView.homeRoute }
                try? store.deleteCourse(course.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { course in
            Text(deletionMessage(for: course))
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
                    onArchive: { try? store.setCourseArchived(course.id, archived: !course.isArchived) },
                    onDelete: { beginDelete(course) }
                )
            }
    }

    private func beginDelete(_ course: Course) {
        deletionImpact = try? store.courseDeletionImpact(course.id)
        deletingCourse = course
    }

    private func deletionMessage(for course: Course) -> String {
        let impact = deletionImpact
        let cards = impact?.cards ?? 0
        let reviews = impact?.reviews ?? 0
        var message = "Removes \(cards) card\(cards == 1 ? "" : "s")"
        if reviews > 0 { message += " and \(reviews) review\(reviews == 1 ? "" : "s") of study history" }
        message += ". Your notes in the vault are never touched"
        if course.folderPath != nil {
            message += " -- importing again will bring this course back."
        } else {
            message += "."
        }
        return message
    }
}

private struct CourseRow: View {
    let course: Course

    var body: some View {
        HStack(spacing: 8) {
            if let hex = course.colorHex {
                Circle().fill(Color(hex: hex)).frame(width: 8, height: 8)
            }
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
