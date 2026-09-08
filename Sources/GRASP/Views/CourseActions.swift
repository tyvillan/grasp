import SwiftUI
import GRASPCore

/// Right-click actions shared by the sidebar rows and the dashboard tiles,
/// so a course offers the same menu wherever it appears.
struct CourseContextMenu: View {
    let course: Course
    let onEdit: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("Edit Course…", action: onEdit)
        Button(course.isArchived ? "Unarchive" : "Archive", action: onArchive)
        Divider()
        Button("Delete Course…", role: .destructive, action: onDelete)
    }
}

/// Rename a course, give it a code and a color, and see where its
/// material actually comes from. The vault folder is shown read-only:
/// it's what the scanner matches on, so editing it here would silently
/// orphan the course from its notes on the next import.
struct CourseEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var course: Course
    @State private var noteCount: Int?

    init(course: Course) {
        _course = State(initialValue: course)
    }

    private static let palette: [(name: String, hex: String)] = [
        ("Amber", "F2B84B"), ("Teal", "5FC9B5"), ("Rose", "E2725B"),
        ("Violet", "9B8BF4"), ("Sky", "5AA9E6"), ("Lime", "A3C644"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Course").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(GRASPColor.textSecondary)
                TextField("Course name", text: $course.name)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Course code").font(.caption).foregroundStyle(GRASPColor.textSecondary)
                TextField("e.g. COP 3014", text: Binding(
                    get: { course.code ?? "" },
                    set: { course.code = $0.isEmpty ? nil : $0 }
                ))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.caption).foregroundStyle(GRASPColor.textSecondary)
                HStack(spacing: 8) {
                    ForEach(Self.palette, id: \.hex) { swatch in
                        Button {
                            course.colorHex = course.colorHex == swatch.hex ? nil : swatch.hex
                        } label: {
                            Circle()
                                .fill(Color(hex: swatch.hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(
                                        course.colorHex == swatch.hex ? GRASPColor.textPrimary : .clear,
                                        lineWidth: 2
                                    )
                                    .padding(-3)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                if let folderPath = course.folderPath {
                    Text("Source folder").font(.caption).foregroundStyle(GRASPColor.textSecondary)
                    Text(folderPath)
                        .font(.caption)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                } else {
                    Text("Added by hand -- no vault folder, so importing won't add notes to it.")
                        .font(.caption)
                        .foregroundStyle(GRASPColor.textSecondary)
                }
                if let noteCount {
                    Text("\(noteCount) imported file\(noteCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(GRASPColor.textSecondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    course.name = course.name.trimmingCharacters(in: .whitespaces)
                    try? store.updateCourse(course)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(course.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { noteCount = try? store.materialCount(inCourse: course.id) }
    }
}

extension Color {
    /// Six-digit RRGGBB, as stored in `course.colorHex`.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
