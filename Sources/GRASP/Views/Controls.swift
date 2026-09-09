import SwiftUI

/// Buttons drawn to Mac metrics rather than left to `.borderedProminent`,
/// which tints its fill from the window's accent and ends up a different
/// amber from the rest of the app. These keep GRASP's own accent exactly,
/// carry a real pressed state, and sit at the 28pt height a Mac control
/// of this weight actually uses.
struct GRASPProminentButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(isEnabled ? Color.black.opacity(0.88) : GRASPColor.textTertiary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isEnabled ? GRASPColor.accent : GRASPColor.surface)
            )
            .overlay(
                // A one-pixel light edge along the top only: the way a
                // physical control catches light, and what separates a
                // filled button from a flat colored rectangle.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isEnabled ? Color.white.opacity(0.22) : GRASPColor.hairline,
                        lineWidth: 1
                    )
                    .blendMode(isEnabled ? .plusLighter : .normal)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct GRASPQuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .tracking(-0.1)
            .foregroundStyle(isEnabled ? GRASPColor.textPrimary : GRASPColor.textTertiary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering && isEnabled ? GRASPColor.surfaceRaised : GRASPColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(GRASPColor.hairlineStrong, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Used for the two mastery verdicts in a study session, where the choice
/// itself is the screen's main interaction and deserves more presence than
/// a standard push button.
struct GRASPVerdictButton: ButtonStyle {
    let tint: Color
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovering ? tint.opacity(0.16) : tint.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(tint.opacity(isHovering ? 0.55 : 0.3), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}
