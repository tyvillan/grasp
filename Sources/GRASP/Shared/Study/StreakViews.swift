import SwiftUI
import GRASPCore

/// The flame that pops in when a Learn streak reaches three right answers and
/// again with each one after it. One short entrance (`Motion.glide`, 0.32 s)
/// with a few embers drifting up once; no repeating animation. Under Reduce
/// Motion the embers are dropped and the flame just fades in.
struct StreakBanner: View {
    let streak: LearnStreak
    @State private var shown = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if !Motion.isReduced { Embers(active: shown) }
                Image(systemName: "flame.fill")
                    .font(.graspUI(size: 22, weight: .semibold))
                    .foregroundStyle(GRASPColor.accent)
                    .scaleEffect(Motion.isReduced ? 1 : (shown ? 1 : 0.5))
                    .opacity(shown ? 1 : 0)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(streak.headline)
                    .font(.graspUI(size: 14, weight: .semibold))
                    .foregroundStyle(GRASPColor.textPrimary)
                    .monospacedDigit()
                Text(streak.count == LearnStreak.threshold ? "You're on a streak. Keep it going." : "Streak continues")
                    .font(.graspUI(size: 12))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(GRASPColor.accentSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streak. \(streak.headline)")
        .onAppear { withAnimation(Motion.glide) { shown = true } }
        .transition(.opacity)
    }
}

/// Six embers that rise a short way and fade once.
private struct Embers: View {
    let active: Bool
    private let spots: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (-10, -16, 3), (-4, -22, 2.5), (3, -18, 3), (10, -24, 2.5), (-14, -10, 2), (14, -12, 2),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                Circle()
                    .fill(GRASPColor.brand)
                    .frame(width: spot.size, height: spot.size)
                    .offset(x: spot.x, y: active ? spot.y : 2)
                    .opacity(active ? 0 : 0.9)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The running streak in the header, once it is on.
struct StreakChip: View {
    let streak: LearnStreak

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").font(.graspUI(size: 11, weight: .semibold))
            Text("\(streak.count)").font(.graspUI(size: 12.5, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(GRASPColor.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(GRASPColor.accent.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streak of \(streak.count)")
    }
}
