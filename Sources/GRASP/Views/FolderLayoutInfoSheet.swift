import SwiftUI
import GRASPCore

/// "How GRASP reads your folder": a drawn example of each layout, with a tag beside every row
/// saying what GRASP makes of it (a term, a course, a note, or nothing).
struct FolderLayoutInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var layout: Layout

    enum Layout: String, CaseIterable, Identifiable {
        case automatic = "Automatic", folders = "Any folder", vault = "Obsidian vault"
        var id: String { rawValue }
    }

    init(starting: AppStore.NotesLayout) {
        switch starting {
        case .automatic: _layout = State(initialValue: .automatic)
        case .vault: _layout = State(initialValue: .vault)
        case .folders: _layout = State(initialValue: .folders)
        }
    }

    /// What GRASP makes of a row.
    private enum Role {
        case chosen, term, course, note, skipped, unread, inside, passthrough

        var label: String? {
            switch self {
            case .chosen: return "The folder you choose"
            case .term: return "Term"
            case .course: return "Course"
            case .note: return "Note"
            case .skipped: return "Skipped"
            case .unread: return "Not read"
            case .inside, .passthrough: return nil
            }
        }
        var tint: Color {
            switch self {
            case .chosen: return GRASPColor.textSecondary
            case .term: return GRASPColor.textPrimary
            case .course: return GRASPColor.accent
            case .note: return GRASPColor.success
            case .skipped, .unread: return GRASPColor.textTertiary
            case .inside, .passthrough: return GRASPColor.textSecondary
            }
        }
    }

    private struct Row: Identifiable {
        let id = UUID()
        let depth: Int
        let name: String
        let isFolder: Bool
        let role: Role
        var detail: String? = nil
        /// A line of explanation between two drawings, not a file or folder.
        var isCaption = false
    }

    private var rows: [Row] {
        switch layout {
        case .automatic:
            return [
                Row(depth: 0, name: "If the folder has a College folder inside", isFolder: false, role: .chosen, isCaption: true),
                Row(depth: 0, name: "My Vault", isFolder: true, role: .chosen),
                Row(depth: 1, name: "College", isFolder: true, role: .passthrough),
                Row(depth: 2, name: "Fall Semester 2026", isFolder: true, role: .term),
                Row(depth: 3, name: "Biology", isFolder: true, role: .course, detail: "read as an Obsidian vault"),
                Row(depth: 0, name: "Otherwise", isFolder: false, role: .chosen, isCaption: true),
                Row(depth: 0, name: "Spring Classes", isFolder: true, role: .chosen),
                Row(depth: 1, name: "Biology", isFolder: true, role: .course, detail: "each folder inside is a course"),
                Row(depth: 2, name: "Week 1.md", isFolder: false, role: .note),
            ]
        case .folders:
            return [
                Row(depth: 0, name: "Spring Classes", isFolder: true, role: .chosen),
                Row(depth: 1, name: "Biology", isFolder: true, role: .course, detail: "one course, named after the folder"),
                Row(depth: 2, name: "Week 1.md", isFolder: false, role: .note),
                Row(depth: 2, name: "Week 2.pdf", isFolder: false, role: .note),
                Row(depth: 2, name: "Slides", isFolder: true, role: .inside, detail: "deeper folders are read too"),
                Row(depth: 3, name: "Cell Division.pptx", isFolder: false, role: .note),
                Row(depth: 1, name: "Chemistry", isFolder: true, role: .course),
                Row(depth: 2, name: "Lab Notes.docx", isFolder: false, role: .note),
                Row(depth: 2, name: "Reaction Chart.png", isFolder: false, role: .note),
                Row(depth: 1, name: ".git", isFolder: true, role: .skipped, detail: "tool folders are ignored"),
                Row(depth: 1, name: "syllabus.pdf", isFolder: false, role: .unread, detail: "loose files outside a course folder"),
            ]
        case .vault:
            return [
                Row(depth: 0, name: "My Vault", isFolder: true, role: .chosen),
                Row(depth: 1, name: "College", isFolder: true, role: .passthrough, detail: "must be here; GRASP starts inside it"),
                Row(depth: 2, name: "Fall Semester 2026", isFolder: true, role: .term, detail: "named Fall, Spring or Summer Semester + year"),
                Row(depth: 3, name: "Biology", isFolder: true, role: .course),
                Row(depth: 4, name: "Lecture 1.md", isFolder: false, role: .note),
                Row(depth: 4, name: "Lecture Notes", isFolder: true, role: .inside, detail: "deeper folders are read too"),
                Row(depth: 5, name: "Week 3.pdf", isFolder: false, role: .note),
                Row(depth: 3, name: "Chemistry", isFolder: true, role: .course),
                Row(depth: 2, name: "Side Lectures", isFolder: true, role: .course, detail: "any other folder is a course with no term"),
                Row(depth: 1, name: "Daily Notes", isFolder: true, role: .unread, detail: "outside College"),
                Row(depth: 1, name: ".obsidian", isFolder: true, role: .skipped),
            ]
        }
    }

    private var points: [String] {
        switch layout {
        case .automatic:
            return [
                "GRASP looks for a College folder inside the folder you choose, every time you import.",
                "Found: it is read as an Obsidian vault. Not found: each folder inside is a course.",
                "Pick Obsidian vault or Any folder instead if you want one reading every time.",
            ]
        case .folders:
            return [
                "Each folder directly inside the one you choose becomes a course.",
                "Everything below it (notes, PDFs, Word files, slides, notebooks, pictures) belongs to that course.",
                "Type a time frame, like Fall 2026, and the new courses are filed under it. Otherwise they sit under No timeline.",
                "Plain .txt and .rtf files are only taken when you pick them by name.",
            ]
        case .vault:
            return [
                "GRASP reads the College folder only.",
                "A folder named like Fall Semester 2026 is a term. The folders inside it are its courses.",
                "A note's own term tag, if it has one, wins over the folder name.",
                "Automatic mode uses this layout whenever it finds a College folder.",
            ]
        }
    }

    var body: some View {
        GRASPSheet(
            eyebrow: "Library", title: "How GRASP Reads Your Folder",
            message: "GRASP only reads your files. It never changes or moves them.",
            icon: "info.circle", width: 600
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $layout) {
                    ForEach(Layout.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if row.isCaption {
                            Text(row.name.uppercased())
                                .font(.graspUI(size: 10.5, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(GRASPColor.textTertiary)
                                .padding(.top, row.name == "Otherwise" ? 14 : 0).padding(.bottom, 4)
                        } else {
                        HStack(spacing: 8) {
                            Image(systemName: row.isFolder ? "folder" : iconName(for: row.name))
                                .font(.graspUI(size: 13))
                                .foregroundStyle(row.role == .skipped || row.role == .unread ? GRASPColor.textTertiary : GRASPColor.textSecondary)
                                .frame(width: 18)
                            Text(row.name)
                                .font(.graspMono(12.5))
                                .foregroundStyle(row.role == .skipped ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                                .strikethrough(row.role == .skipped, color: GRASPColor.textTertiary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let detail = row.detail {
                                Text(detail).graspType(.meta).foregroundStyle(GRASPColor.textTertiary).lineLimit(1)
                            }
                            if let label = row.role.label {
                                Text(label)
                                    .font(.graspUI(size: 11, weight: .semibold))
                                    .foregroundStyle(row.role.tint)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .overlay(Capsule().strokeBorder(row.role.tint.opacity(0.55)))
                                    .fixedSize()
                            }
                        }
                        .padding(.leading, CGFloat(row.depth) * 18)
                        .padding(.vertical, 5)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
                .animation(Motion.snappy, value: layout)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(GRASPColor.textTertiary).frame(width: 4, height: 4).offset(y: -2)
                            Text(point).graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func iconName(for file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg": return "photo"
        case "pdf": return "doc.richtext"
        case "pptx": return "rectangle.on.rectangle"
        default: return "doc.text"
        }
    }
}
