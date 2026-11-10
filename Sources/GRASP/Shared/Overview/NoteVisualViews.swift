import SwiftUI
import GRASPCore

/// A picture the note already contains, drawn in the overview: a pipeline,
/// a table, a commented listing, or the variables a listing declares. Found
/// in the note's text by `NoteVisuals`, so each is exactly what the note says.
struct NoteVisualView: View {
    let visual: NoteVisual

    var body: some View {
        switch visual.kind {
        case .pipeline(let stages):
            VisualCard(icon: "arrow.right.circle", label: "Pipeline", title: visual.title) {
                FlowDiagramView(nodes: stages, highlight: nil)
            }
        case .table(let header, let rows):
            VisualCard(icon: "tablecells", label: "Table", title: visual.title) {
                NoteTableBody(header: header, rows: rows)
            }
        case .annotatedCode(let lines):
            VisualCard(icon: "chevron.left.forwardslash.chevron.right", label: "Code", title: visual.title) {
                AnnotatedCodeBody(lines: lines)
            }
        case .memory(let boxes):
            VisualCard(icon: "square.grid.3x1.below.line.grid.1x2", label: "Memory", title: visual.title) {
                MemoryBoxesBody(boxes: boxes)
            }
        }
    }
}

/// The frame every note picture shares: a label, the note's own heading,
/// and where it came from.
private struct VisualCard<Content: View>: View {
    let icon: String
    let label: String
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.graspUI(size: 10, weight: .semibold))
                Text(label.uppercased())
                    .graspType(.eyebrow)
                if let title, title.caseInsensitiveCompare(label) != .orderedSame {
                    Text(title)
                        .graspType(.meta)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("From your notes")
                    .graspType(.meta)
            }
            .foregroundStyle(GRASPColor.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(GRASPColor.hairline).frame(height: 1)

            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GRASPColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

private struct NoteTableBody: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    Text(header[column])
                        .graspType(.eyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
            Divider()
            ForEach(rows.indices, id: \.self) { row in
                GridRow(alignment: .firstTextBaseline) {
                    ForEach(rows[row].indices, id: \.self) { column in
                        Text(rows[row][column])
                            .graspType(.body)
                            .fontWeight(column == 0 ? .semibold : .regular)
                            .foregroundStyle(column == 0 ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridColumnAlignment(.leading)
                    }
                }
            }
        }
    }
}

/// Each line of the listing with its comment beside it, or under it when
/// the two don't fit side by side. Code is never wrapped: a listing that is
/// too wide scrolls.
private struct AnnotatedCodeBody: View {
    let lines: [NoteVisual.CodeLine]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            rows(sideBySide: true)
            ScrollView(.horizontal, showsIndicators: false) { rows(sideBySide: false) }
        }
        .textSelection(.enabled)
    }

    private func rows(sideBySide: Bool) -> some View {
        VStack(alignment: .leading, spacing: sideBySide ? 5 : 7) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                if line.code.trimmingCharacters(in: .whitespaces).isEmpty {
                    Color.clear.frame(height: 4)
                } else if let note = line.note, sideBySide {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        code(line.code)
                        Spacer(minLength: 12)
                        noteText(note)
                    }
                } else if let note = line.note {
                    VStack(alignment: .leading, spacing: 1) {
                        code(line.code)
                        noteText(note)
                    }
                } else {
                    code(line.code)
                }
            }
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(GRASPColor.textPrimary)
            .fixedSize()
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .graspType(.meta)
            .foregroundStyle(GRASPColor.accent)
            .fixedSize()
    }
}

/// The listing's variables as labelled boxes, a question mark where the
/// note stores nothing yet.
private struct MemoryBoxesBody: View {
    let boxes: [NoteVisual.Box]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 12) {
                ForEach(boxes.indices, id: \.self) { index in
                    let box = boxes[index]
                    VStack(spacing: 4) {
                        Text(box.type)
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                        Text(box.value ?? "?")
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(box.value == nil ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                            .frame(minWidth: 52)
                            .padding(.vertical, 8)
                            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(GRASPColor.hairlineStrong, lineWidth: 1))
                        Text(box.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(GRASPColor.textSecondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(box.type) \(box.name), \(box.value ?? "no value yet")")
                }
            }
            Text("Each variable is a box with a type. A question mark means nothing is stored yet.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        }
    }
}
