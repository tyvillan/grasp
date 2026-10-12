import SwiftUI

/// GRASP's own line icons for the four top-level places (house, calendar,
/// graduation cap, books), drawn on a 24×24 grid from `GRASP_sidebar_icons.svg`
/// and stroked at 1.7 with round caps. Shared so the iPhone tab bar could
/// use the same drawings.
enum SidebarGlyph: CaseIterable {
    case home, calendar, studyGuides, library

    /// The drawing, as a shape stroked by `SidebarIcon`.
    var shape: GlyphShape { GlyphShape(glyph: self) }
}

struct GlyphShape: Shape {
    let glyph: SidebarGlyph

    nonisolated func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2
        let oy = rect.minY + (rect.height - 24 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s),
                 cornerRadius: r * s, style: .continuous)
        }
        var path = Path()
        switch glyph {
        case .home:
            path.move(to: p(4, 10.5))
            path.addLine(to: p(12, 3.5))
            path.addLine(to: p(20, 10.5))
            path.addLine(to: p(20, 19.5))
            path.addQuadCurve(to: p(19, 20.5), control: p(20, 20.5))
            path.addLine(to: p(15, 20.5))
            path.addLine(to: p(15, 14.5))
            path.addLine(to: p(9, 14.5))
            path.addLine(to: p(9, 20.5))
            path.addLine(to: p(5, 20.5))
            path.addQuadCurve(to: p(4, 19.5), control: p(4, 20.5))
            path.closeSubpath()
        case .calendar:
            path.addPath(roundRect(3.5, 5, 17, 15.5, 3))
            path.move(to: p(3.5, 10)); path.addLine(to: p(20.5, 10))
            path.move(to: p(8, 3)); path.addLine(to: p(8, 6.5))
            path.move(to: p(16, 3)); path.addLine(to: p(16, 6.5))
            for x in [8.0, 12.0, 16.0] {
                path.move(to: p(x, 14)); path.addLine(to: p(x + 0.01, 14))
            }
        case .studyGuides:
            path.move(to: p(2.5, 9))
            path.addLine(to: p(12, 4.5))
            path.addLine(to: p(21.5, 9))
            path.addLine(to: p(12, 13.5))
            path.closeSubpath()
            path.move(to: p(6.5, 11.3))
            path.addLine(to: p(6.5, 15.5))
            path.addCurve(to: p(12, 18), control1: p(6.5, 16.6), control2: p(9, 18))
            path.addCurve(to: p(17.5, 15.5), control1: p(15, 18), control2: p(17.5, 16.6))
            path.addLine(to: p(17.5, 11.3))
            path.move(to: p(21.5, 9)); path.addLine(to: p(21.5, 14))
        case .library:
            path.addPath(roundRect(3.5, 4, 4.5, 16.5, 1.2))
            path.addPath(roundRect(9.5, 4, 4.5, 16.5, 1.2))
            path.move(to: p(16.2, 5.6))
            path.addLine(to: p(19.6, 4.7))
            path.addLine(to: p(22.6, 18.8))
            path.addLine(to: p(19.2, 19.7))
            path.closeSubpath()
        }
        return path
    }
}

/// A 20pt sidebar icon: cream at rest; on hover it turns yellow, grows to
/// 1.15 and tilts -5° with a spring (no movement under Reduce Motion).
struct SidebarIcon: View {
    let glyph: SidebarGlyph
    var isHovering: Bool
    var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        glyph.shape
            .stroke(isHovering ? GRASPColor.accent : GRASPColor.textPrimary,
                    style: StrokeStyle(lineWidth: 1.7 * size / 24 * 1.2, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .scaleEffect(isHovering && !reduceMotion ? 1.15 : 1)
            .rotationEffect(.degrees(isHovering && !reduceMotion ? -5 : 0))
            .animation(Motion.bouncy, value: isHovering)
            .accessibilityHidden(true)
    }
}
