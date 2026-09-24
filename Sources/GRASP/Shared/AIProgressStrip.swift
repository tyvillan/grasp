import SwiftUI
import GRASPCore

/// The strip every AI job shows while it runs: the same place, the same
/// shape, whichever feature started it. Sits under the header like the
/// app's other notices.
struct AIProgressStrip: View {
    let activity: AIActivity
    /// Nil hides the Stop button.
    var onStop: (() -> Void)?
    var stopTitle = "Stop"
    var stoppingTitle = "Stopping…"
    var stopHelp = "Stops now. Work already finished is kept; the step in progress is discarded."
    /// Drawn bare, for a form row or a sheet, instead of as a full-width
    /// notice under a pane's header.
    var isInline = false

    var body: some View {
        if isInline {
            content
        } else {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(GRASPColor.accentSoft.opacity(0.55))
                .background(alignment: .bottom) {
                    Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(activity.headline)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let onStop {
                    Button(activity.stopRequested ? stoppingTitle : stopTitle) {
                        activity.stopRequested = true
                        onStop()
                    }
                    .buttonStyle(GRASPQuietButton())
                    .disabled(activity.stopRequested)
                    .help(stopHelp)
                }
            }
            ProgressBar(value: Int((activity.fraction * 1000).rounded()), total: 1000)
            // Re-evaluated on a clock as well as on each step, so the time
            // left keeps counting down during a long call rather than
            // freezing between steps.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(activity.detail(at: context.date))
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
    }
}
