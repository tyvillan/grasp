import SwiftUI

/// A slim capsule progress bar in the app's accent color -- shared by the
/// dashboard's "Jump back in" card and Learn mode's mastery indicator.
struct ProgressBar: View {
    let value: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(GRASPColor.stroke)
                Capsule()
                    .fill(GRASPColor.accent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total)
    }
}
