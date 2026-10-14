import SwiftUI
import GRASPCore

/// Three short capsules for how close a card is to understood:
/// recognition, recall, understood. Capsules, not dots, so they don't read
/// as page dots or the sidebar's coloured dots. A solid capsule was reached
/// and shown, a dashed one was claimed ("I Know This") and not yet shown,
/// an outline is not reached. Shape carries the meaning; the last one
/// turning green only reinforces it. No yellow.
struct PipMeter: View {
    enum Size {
        case row, card, large
        var width: CGFloat { switch self { case .row: 10; case .card: 12; case .large: 16 } }
        var height: CGFloat { switch self { case .row: 4; case .card: 5; case .large: 6 } }
        var gap: CGFloat { switch self { case .row: 2; case .card: 2.5; case .large: 3 } }
    }

    let state: UnderstandingState
    var size: Size = .row
    /// The short word beside the pips ("Recall"), for the card and large sizes.
    var showsWord = false

    var body: some View {
        HStack(spacing: size == .large ? 10 : 8) {
            HStack(spacing: size.gap) {
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
        let green = state.isMastered && index == 2
        switch state.pips[index] {
        case .solid:
            Capsule().fill(green ? GRASPColor.success : GRASPColor.textPrimary)
                .frame(width: size.width, height: size.height)
        case .dotted:
            Capsule().strokeBorder(GRASPColor.textSecondary, style: StrokeStyle(lineWidth: 1, dash: [2.2, 1.6]))
                .frame(width: size.width, height: size.height)
        case .empty:
            // Never asked: a hairline outline, stronger than before and
            // still quieter than text. A card asked and missed is a touch firmer.
            Capsule().strokeBorder(state.asked ? GRASPColor.textTertiary.opacity(0.7) : GRASPColor.hairlineStrong,
                                   lineWidth: 1.25)
                .frame(width: size.width, height: size.height)
        }
    }
}

/// Where a card stands after an answer. When the level changed: the pips
/// before, a small arrow, the pips after, and one line saying so. When it
/// did not: just the current state.
struct PipChange: View {
    let before: UnderstandingState
    let after: UnderstandingState
    @State private var shown = false

    private var caption: String? { UnderstandingState.changeCaption(from: before, to: after) }

    var body: some View {
        if let caption {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    PipMeter(state: before, size: .card)
                    Image(systemName: "arrow.right")
                        .font(.graspUI(size: 10, weight: .semibold))
                        .foregroundStyle(GRASPColor.textTertiary)
                    PipMeter(state: after, size: .card)
                        .opacity(shown ? 1 : 0)
                }
                Text(caption)
                    .font(.graspUI(size: 12.5, weight: .medium))
                    .foregroundStyle(after.isMastered ? GRASPColor.success : GRASPColor.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(caption + ". " + after.accessibilityLabel)
            .onAppear {
                // 0.20 s, no overshoot; under Reduce Motion the token is instant.
                withAnimation(Motion.base) { shown = true }
            }
            .transition(.opacity)
        } else {
            PipMeter(state: after, size: .card, showsWord: true)
                .transition(.opacity)
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
/// weakest notes and one outlined "Practice weakest" button. On the phone
/// the notes sit behind a disclosure, closed by default.
struct UnderstandingSummary: View {
    let cards: [DeckUnderstanding.Card]
    let noteTitles: [String: String]
    var collapsesNotes = false
    var onOpenNote: (String?) -> Void
    var onPractice: ([String]) -> Void

    @State private var notesOpen = false

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
                    notesHeader
                    if !collapsesNotes || notesOpen {
                        VStack(spacing: 0) {
                            ForEach(weakest) { group in
                                Button { onOpenNote(group.materialId) } label: { row(group) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .transition(.opacity)
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
            .animation(Motion.base, value: notesOpen)
        }
    }

    @ViewBuilder private var notesHeader: some View {
        if collapsesNotes {
            Button { notesOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Weakest notes")
                        .graspType(.eyebrow)
                    Text("\(weakest.count)")
                        .font(.graspUI(size: 12, weight: .medium))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.graspUI(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(notesOpen ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(GRASPColor.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityLabel("Weakest notes, \(weakest.count)")
            .accessibilityValue(notesOpen ? "Expanded" : "Collapsed")
        } else {
            Text("Weakest notes")
                .graspType(.eyebrow)
                .foregroundStyle(GRASPColor.textTertiary)
                .padding(.top, 4)
        }
    }

    private func row(_ group: DeckUnderstanding.NoteGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(group.materialId.flatMap { noteTitles[$0] } ?? "Other")
                    .font(.graspUI(size: 13.5, weight: .medium))
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(group.summary)
                    .font(.graspUI(size: 12))
                    .foregroundStyle(GRASPColor.textTertiary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            UnderstandingBar(distribution: group.distribution, height: 6)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
