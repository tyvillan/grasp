import SwiftUI
import GRASPCore

/// Read-only view of the source note behind a card -- the reflowed text,
/// since that's what the parser actually saw, with the original preserved
/// underneath for when the reflow looks suspicious.
struct NoteViewerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let materialId: String
    @State private var material: GRASPCore.Material?
    @State private var noteText: NoteText?
    @State private var showRaw = false

    /// The lecture/chapter and date, read the same way an overview's own
    /// header does -- so a note filed as
    /// "2026-08-27_Lecture-02_Row-Reduction-and-Echelon-Forms" reads as
    /// "LECTURE 2 · AUG 27" here too, not as its raw filename.
    private var heading: (kicker: String?, title: String)? {
        material.map(DeckOverviewReader.lessonHeading(for:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: GRASPSpace.m) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(heading?.kicker ?? "Note")
                    Text(heading?.title ?? material?.title ?? "Note")
                        .font(.graspDisplay(22))
                        .tracking(-0.4)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                GRASPSegmented(selection: $showRaw, options: [(false, "Reflowed"), (true, "Raw")])
                PopupCloseButton { dismiss() }
            }
            .padding(.horizontal, GRASPSpace.xl)
            .padding(.top, 22)
            .padding(.bottom, GRASPSpace.l)
            ScrollView {
                Text((showRaw ? noteText?.raw : noteText?.reflowed) ?? "")
                    .font(showRaw ? .graspMono(12.5) : .graspBody)
                    .lineSpacing(3)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(GRASPSpace.l)
            }
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous)
                    .strokeBorder(GRASPColor.hairline, lineWidth: 1)
            )
            .padding(.horizontal, GRASPSpace.xl)
            if let path = material?.relativePath {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.graspUI(size: 10))
                    Text(path)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .padding(.horizontal, GRASPSpace.xl)
                .padding(.vertical, 14)
            } else {
                Spacer().frame(height: GRASPSpace.xl)
            }
        }
        .macSheetFrame(width: 640, height: 560)
        .graspPopupBackground()
        .task(id: materialId) {
            material = try? store.material(materialId)
            noteText = try? store.noteText(forMaterial: materialId)
        }
    }
}
