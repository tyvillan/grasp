import SwiftUI
import GRASPCore

/// Exam dates for one course. Setting one here is what turns on FSRS's
/// exam biasing (`AppStore.gradeCard`/`dueCards`) for every deck in this
/// course -- capping intervals to land before the date, and reordering
/// the due queue by weakest retention first in the final week.
struct ExamsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let courseId: String

    @State private var exams: [Exam] = []
    @State private var newName = "Exam"
    @State private var newDate = Date().addingTimeInterval(14 * 86400)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exams").font(.headline)

            if exams.isEmpty {
                Text("No exam dates set for this course yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(exams) { exam in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(exam.name)
                                Text(exam.examDate.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                try? store.deleteExam(exam.id)
                                load()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: min(CGFloat(exams.count) * 44, 180))
            }

            Divider()

            HStack {
                TextField("Name", text: $newName)
                DatePicker("", selection: $newDate, displayedComponents: .date)
                    .labelsHidden()
                Button("Add") {
                    try? store.addExam(courseId: courseId, name: newName, date: newDate)
                    load()
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { load() }
    }

    private func load() {
        exams = (try? store.exams(forCourse: courseId)) ?? []
    }
}
