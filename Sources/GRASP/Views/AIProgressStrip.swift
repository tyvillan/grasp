import SwiftUI
import AppKit
import GRASPCore

/// One running AI job, as the screen sees it: what it is, which step it's
/// on, how far along, and roughly how long is left.
///
/// A job is made of one or more *units* -- a note, for overviews; the whole
/// run, for everything else -- and each unit reports its own steps through
/// a fresh `AIProgress`. Units are what the student counts ("overview 2 of
/// 5"); steps are what moves the bar in between, so a single note that
/// takes four minutes doesn't sit at the same spot for all four.
///
/// For as long as it exists it also keeps the Mac from idle-sleeping. A
/// sleeping Mac stops the local model mid-answer, and every request in
/// flight fails -- which is how two lectures in a run once came back
/// unwritten. Closing the lid still sleeps the Mac; `sleptDuringRun` is
/// how the failure message can say so instead of just "it failed".
@Observable
final class AIActivity {
    /// "Writing overview 2 of 5 · Vector Equations"
    var headline: String
    private(set) var snapshot = AIProgress.Snapshot.empty
    private(set) var fraction: Double = 0
    private(set) var sleptDuringRun = false
    var stopRequested = false
    let startedAt = Date()

    private let units: Int
    private var unit = 0
    @ObservationIgnored private var assertion: NSObjectProtocol?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    /// What the job is, for a button that needs to say "Adding Cards…"
    /// only while that particular job runs.
    let purpose: String

    init(headline: String, units: Int = 1, purpose: String = "") {
        self.headline = headline
        self.purpose = purpose
        self.units = max(1, units)
        assertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: headline
        )
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleptDuringRun = true }
        }
    }

    /// Releases the keep-awake assertion when the job ends, for any reason.
    /// Safe to call more than once.
    func finish() {
        if let assertion { ProcessInfo.processInfo.endActivity(assertion) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        assertion = nil
        sleepObserver = nil
    }

    /// A reporter for unit `index`, to install with
    /// `AIProgress.$current.withValue`. Snapshots from an earlier unit that
    /// arrive late are ignored.
    func reporter(forUnit index: Int) -> AIProgress {
        unit = index
        snapshot = AIProgress.Snapshot.empty
        fraction = max(fraction, Double(index) / Double(units))
        return AIProgress { [weak self] snapshot in
            Task { @MainActor in self?.receive(snapshot, unit: index) }
        }
    }

    func completeUnit(_ index: Int) {
        fraction = max(fraction, Double(index + 1) / Double(units))
    }

    private func receive(_ new: AIProgress.Snapshot, unit index: Int) {
        guard index == unit, new.sequence > snapshot.sequence else { return }
        snapshot = new
        // Never backwards: a plan that comes back with more sections than
        // assumed grows the denominator, and a bar that shrinks reads as
        // something having gone wrong.
        fraction = max(fraction, (Double(index) + new.fraction) / Double(units))
    }

    /// "Part 1 of 2 · Writing section 2 of 5 · about 4 min left"
    func detail(at now: Date) -> String {
        var parts = [snapshot.part, snapshot.step].compactMap { $0 }
        let remaining = AIProgressEstimate.remaining(
            fraction: fraction, elapsed: now.timeIntervalSince(startedAt)
        )
        parts.append(AIProgressEstimate.describe(remaining) ?? "estimating time left…")
        return parts.joined(separator: " · ")
    }
}

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
