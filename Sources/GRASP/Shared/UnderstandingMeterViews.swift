import SwiftUI
import GRASPCore

/// Three pips for how close a card is to understood: recognition, recall,
/// mastered. A solid pip was reached, a dotted one was claimed ("I Know
/// This") and not yet shown, an outline is not reached. Shape carries the
/// meaning; the last pip turning green only reinforces it. No yellow.
struct PipMeter: View {
    enum Size {
        case row, card, large
        var diameter: CGFloat { switch self { case .row: 7; case .card: 9; case .large: 13 } }
        var spacing: CGFloat { switch self { case .row: 3; case .card: 4; case .large: 6 } }
    }

    let state: UnderstandingState
    var size: Size = .row
    /// The short word beside the pips ("Recall"), for the card and large sizes.
    var showsWord = false

    var body: some View {
        HStack(spacing: size == .large ? 10 : 6) {
            HStack(spacing: size.spacing) {
                ForEach(0..<3, id: \.self) { index in pip(index) }
            }
            if showsWord {
                Text(state.word)
                    .font(.graspUI(size: size == .large ? 13 : 12, weight: .medium))
                    .foregroundStyle(state.isMastered ? GRASPColor.success : GRASPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .animation(Motion.fade, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
    }

    @ViewBuilder private func pip(_ index: Int) -> some View {
        let fill = state.pips[index]
        let d = size.diameter
        let green = state.isMastered && index == 2
        switch fill {
        case .solid:
            Circle().fill(green ? GRASPColor.success : GRASPColor.textPrimary)
                .frame(width: d, height: d)
        case .dotted:
            Circle().strokeBorder(GRASPColor.textSecondary, style: StrokeStyle(lineWidth: 1.25, dash: [1.5, 1.8]))
                .frame(width: d, height: d)
        case .empty:
            // A card nobody has asked about gets the lighter hairline.
            Circle().strokeBorder(state.asked ? GRASPColor.hairlineStrong : GRASPColor.hairline, lineWidth: 1)
                .frame(width: d, height: d)
        }
    }
}

/// The deck's cards as one bar made of the same steps, left to right:
/// solid (green), recall, recognition, self-rated (dashed edge), and the
/// not-asked remainder as an outlined track.
struct UnderstandingBar: View {
    let distribution: DeckUnderstanding.Distribution
    var height: CGFloat = 10

    private func segment(_ count: Int, of width: CGFloat) -> CGFloat {
        width * CGFloat(count) / CGFloat(max(distribution.total, 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(GRASPColor.inset)
                Capsule().strokeBorder(GRASPColor.hairlineStrong, lineWidth: 1)
                HStack(spacing: 0) {
                    Rectangle().fill(GRASPColor.success).frame(width: segment(distribution.solid, of: geo.size.width))
                    Rectangle().fill(GRASPColor.textPrimary.opacity(0.7))
                        .frame(width: segment(distribution.recall, of: geo.size.width))
                    Rectangle().fill(GRASPColor.textPrimary.opacity(0.35))
                        .frame(width: segment(distribution.recognition, of: geo.size.width))
                    Rectangle().fill(GRASPColor.textSecondary.opacity(0.18))
                        .overlay(Rectangle().strokeBorder(GRASPColor.textSecondary,
                                                          style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                        .frame(width: segment(distribution.selfRated, of: geo.size.width))
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
                .animation(Motion.fill, value: distribution)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Understanding: " + distribution.line)
    }
}

/// The deck page's understanding block: the bar, its count line, the five
/// weakest notes and one outlined "Practice weakest" button.
struct UnderstandingSummary: View {
    let cards: [DeckUnderstanding.Card]
    let noteTitles: [String: String]
    var onOpenNote: (String?) -> Void
    var onPractice: ([String]) -> Void

    private var distribution: DeckUnderstanding.Distribution { DeckUnderstanding.distribution(of: cards) }
    private var weakest: [DeckUnderstanding.NoteGroup] { DeckUnderstanding.weakestNotes(of: cards) }
    private var practice: [String] { DeckUnderstanding.practiceCards(of: cards) }

    var body: some View {
        if distribution.total > 0 {
            VStack(alignment: .leading, spacing: 10) {
                UnderstandingBar(distribution: distribution)
                Text(distribution.line)
                    .font(.graspUI(size: 12.5))
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !weakest.isEmpty {
                    Text("Weakest notes")
                        .graspType(.eyebrow)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(weakest) { group in
                            Button { onOpenNote(group.materialId) } label: { row(group) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if !practice.isEmpty {
                    Button { onPractice(practice) } label: { Text("Practice weakest") }
                        .buttonStyle(GRASPQuietButton())
                        .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous).strokeBorder(GRASPColor.hairline))
        }
    }

    private func row(_ group: DeckUnderstanding.NoteGroup) -> some View {
        HStack(spacing: 10) {
            Text(group.materialId.flatMap { noteTitles[$0] } ?? "Other")
                .font(.graspUI(size: 13.5, weight: .medium))
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            UnderstandingBar(distribution: group.distribution, height: 6)
                .frame(width: 64)
            Text(group.summary)
                .font(.graspUI(size: 12))
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
