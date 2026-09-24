import SwiftUI

/// A progress bar drawn as a recessed well with a filled indicator, rather
/// than a flat tinted capsule on a grey one: the track is the darkest
/// surface in the palette and carries a hairline, so the fill reads as
/// sitting *in* something. `checkpoints` draws division marks along the
/// track -- used by Learn mode, where a round genuinely is divided into
/// segments, so the marks encode structure rather than decorate.
struct ProgressBar: View {
    let value: Int
    let total: Int
    var checkpoints: Int = 0
    var tint: Color = GRASPColor.accent
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(GRASPColor.inset)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(GRASPColor.hairline, lineWidth: 1)
                    )

                if checkpoints > 1 {
                    checkpointMarks(width: geo.size.width)
                }

                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(fraction > 0 ? height : 0, fraction * geo.size.width))
                    .animation(.easeOut(duration: 0.28), value: value)
            }
        }
        .frame(height: height)
    }

    /// Marks sit *under* the fill, so a completed segment simply covers
    /// its own divider instead of leaving ticks scratched across the bar.
    private func checkpointMarks(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(1..<checkpoints, id: \.self) { _ in
                Spacer(minLength: 0)
                Rectangle()
                    .fill(GRASPColor.hairlineStrong)
                    .frame(width: 1)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width)
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, Double(value) / Double(total)))
    }
}
