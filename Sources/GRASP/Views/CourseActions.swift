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

/// The "Delete Course" confirmation, identical wherever a course can be
/// deleted from (the sidebar, the dashboard's course tiles) -- previously
/// two copies of the same alert and impact-counting logic that would only
/// have drifted further apart the next time either needed a change, this
/// one included.
///
/// One button, not two: an earlier version offered a plain delete alongside
/// a "Delete & Exclude Folder" option, but a course silently coming back on
/// the next import is a surprise nobody wants, so permanence isn't
/// something to opt into separately -- every delete now excludes the vault
/// folder too (`AppStore.removeCourseAndExclude`). The escape hatch is
/// `VaultScanner.importPaths`'s own un-exclude step: manually adding files
/// back to that folder is the deliberate "undo" this leaves reachable,
/// rather than a second destructive button in this same dialog.
extension View {
    func courseDeleteConfirmation(_ course: Binding<Course?>, onDeleted: @escaping (String) -> Void) -> some View {
        modifier(CourseDeleteConfirmationModifier(course: course, onDeleted: onDeleted))
    }
}

private struct CourseDeleteConfirmationModifier: ViewModifier {
    @Environment(AppStore.self) private var store
    @Binding var course: Course?
    let onDeleted: (String) -> Void
    @State private var impact: (materials: Int, cards: Int, reviews: Int)?

    func body(content: Content) -> some View {
        content
            // Synchronous, unlike the `.task` below -- clearing `impact`
            // here happens in the same update as `course` changing, before
            // the alert's message can render. Without it, right-clicking a
            // second course's "Delete…" fast enough after canceling the
            // first could show the alert for the new course while
            // `impact` still holds the previous course's numbers, since
            // the async fetch that would replace it hasn't started yet.
            .onChange(of: course?.id) { impact = nil }
            .task(id: course?.id) {
                impact = course.flatMap { try? store.courseDeletionImpact($0.id) }
            }
            .sheet(isPresented: Binding(get: { course != nil }, set: { if !$0 { course = nil } })) {
                if let target = course {
                    ConfirmationSheet(
                        icon: "trash", title: "Delete \(target.name)?",
                        message: message(for: target), confirmTitle: "Delete"
                    ) {
                        try? store.removeCourseAndExclude(target.id)
                        onDeleted(target.id)
                    }
                }
            }
    }

    private func message(for course: Course) -> String {
        var message: String
        if let impact {
            message = "Removes \(impact.cards) card\(impact.cards == 1 ? "" : "s")"
            if impact.reviews > 0 {
                message += " and \(impact.reviews) review\(impact.reviews == 1 ? "" : "s") of study history"
            }
        } else {
            // The count hasn't loaded yet -- say nothing specific rather
            // than a wrong "0 cards" while it's still in flight.
            message = "Removes its cards and any study history for it"
        }
        message += ". Your notes in the vault are never touched"
        if course.folderPath != nil {
            message += ", and re-importing your vault won't bring this course back -- " +
                "add its files to a course by hand again if you ever want it back."
        } else {
            message += "."
        }
        return message
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
    @State private var timelineText = ""

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

            VStack(alignment: .leading, spacing: 6) {
                TimelineField(text: $timelineText, allowsNoTimeline: true)
                if course.folderPath != nil {
                    Text("Changing this here sticks -- re-importing the vault never overwrites a course's timeline once it's set.")
                        .font(.caption)
                        .foregroundStyle(GRASPColor.textSecondary)
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
                    let trimmedTimeline = timelineText.trimmingCharacters(in: .whitespacesAndNewlines)
                    course.semesterId = trimmedTimeline.isEmpty ? nil : (try? store.findOrCreateSemester(name: trimmedTimeline))
                    try? store.updateCourse(course)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(course.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        // Split from the `noteCount` fetch below: `store.semesters` is
        // already in memory (no I/O), so this must not wait behind that
        // fetch (which reads through GRDB, and this project's database
        // and vault both live under iCloud Drive, which can stall on an
        // evicted file). The field is interactive from the very first
        // frame -- a slow `noteCount` read must never leave it sitting
        // blank while the user starts typing, only to have that typed
        // text clobbered the moment the fetch finally resolves.
        .onAppear {
            timelineText = store.semesters.first { $0.id == course.semesterId }?.name ?? ""
        }
        .task {
            noteCount = try? store.materialCount(inCourse: course.id)
        }
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
