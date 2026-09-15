import SwiftUI

/// A Pomodoro-style work/break timer for a study session.
///
/// Deliberately advisory, never coercive: it does not pause the session,
/// hide cards, or block input when an interval ends. Studying that was
/// going well shouldn't be interrupted by a modal, and a timer that fights
/// the user gets switched off and never used again -- so a finished
/// interval changes the bar's colour and label and waits to be
/// acknowledged. Nothing here writes to the database; card counts come
/// from the session view that owns it.
@MainActor
@Observable
final class FocusTimerModel {
    enum Phase {
        case idle, working, breaking

        var label: String {
            switch self {
            case .idle: return "Focus"
            case .working: return "Focus"
            case .breaking: return "Break"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var secondsRemaining = 0
    /// True once an interval has run out and nobody has acknowledged it
    /// yet -- what turns the bar amber and swaps the label for a prompt.
    private(set) var isElapsed = false
    private(set) var completedIntervals = 0
    /// Cards marked since the timer started, against `cardTarget`.
    private(set) var cardsThisSession = 0

    var workMinutes: Int
    var breakMinutes: Int
    var cardTarget: Int

    private var ticker: Task<Void, Never>?

    init(workMinutes: Int, breakMinutes: Int, cardTarget: Int) {
        self.workMinutes = workMinutes
        self.breakMinutes = breakMinutes
        self.cardTarget = cardTarget
    }

    // No `deinit` cancelling `ticker`: a nonisolated deinit can't touch
    // main-actor state, and it isn't needed -- the tick loop holds `self`
    // weakly, so it falls out on its next tick once the model is gone.
    var isRunning: Bool { ticker != nil && !isElapsed }

    var timeText: String {
        let minutes = secondsRemaining / 60
        let seconds = secondsRemaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// 0...1 through the current interval, for the bar's fill.
    var intervalProgress: Double {
        let total = Double((phase == .breaking ? breakMinutes : workMinutes) * 60)
        guard total > 0 else { return 0 }
        return max(0, min(1, 1 - Double(secondsRemaining) / total))
    }

    var cardProgress: Double {
        guard cardTarget > 0 else { return 0 }
        return max(0, min(1, Double(cardsThisSession) / Double(cardTarget)))
    }

    var hasHitCardTarget: Bool { cardTarget > 0 && cardsThisSession >= cardTarget }

    func start() {
        phase = .working
        begin(seconds: workMinutes * 60)
    }

    func startBreak() {
        phase = .breaking
        begin(seconds: breakMinutes * 60)
    }

    func pause() {
        ticker?.cancel()
        ticker = nil
    }

    func resume() {
        guard phase != .idle, secondsRemaining > 0 else { return }
        begin(seconds: secondsRemaining)
    }

    func reset() {
        pause()
        phase = .idle
        secondsRemaining = 0
        isElapsed = false
    }

    /// Acknowledges a finished interval: work rolls into a break, a break
    /// rolls into the next work interval. Guarded on `isElapsed` so a
    /// second call landing before SwiftUI swaps the button away (a fast
    /// double-click, say) can't advance twice and skip a whole interval --
    /// the first call already flips `isElapsed` back to false, so the
    /// second sees nothing to acknowledge.
    func advance() {
        guard isElapsed else { return }
        isElapsed = false
        if phase == .breaking {
            start()
        } else {
            completedIntervals += 1
            cardsThisSession = 0
            startBreak()
        }
    }

    func countCard() {
        guard phase == .working else { return }
        cardsThisSession += 1
    }

    private func begin(seconds: Int) {
        ticker?.cancel()
        isElapsed = false
        secondsRemaining = seconds
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.secondsRemaining > 0 else {
                    self.isElapsed = true
                    self.ticker = nil
                    return
                }
                self.secondsRemaining -= 1
                if self.secondsRemaining == 0 {
                    self.isElapsed = true
                    self.ticker = nil
                    NSSound.beep()
                    return
                }
            }
        }
    }
}

/// The timer as it appears above a study session: one slim bar carrying
/// the countdown, the interval's own progress as its fill, and how far the
/// session is toward its card target. Collapsed to a single "Start focus
/// timer" affordance until someone actually wants it, so a plain study
/// session isn't made busier by a feature it isn't using.
struct FocusTimerBar: View {
    @Bindable var model: FocusTimerModel
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 10) {
            if model.phase == .idle {
                Button {
                    model.start()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "timer").font(.system(size: 11))
                        Text("Start Focus Timer")
                    }
                }
                .buttonStyle(GRASPQuietButton())
                .help("A Pomodoro-style work/break timer for this session")
            } else {
                Image(systemName: model.phase == .breaking ? "cup.and.saucer.fill" : "timer")
                    .font(.system(size: 11))
                    .foregroundStyle(tint)

                Text(model.isElapsed ? elapsedPrompt : model.timeText)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(model.isElapsed ? tint : GRASPColor.textPrimary)

                ProgressView(value: model.intervalProgress)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(width: 90)

                if model.cardTarget > 0, model.phase == .working {
                    Text("\(model.cardsThisSession)/\(model.cardTarget) cards")
                        .graspType(.meta)
                        .monospacedDigit()
                        .foregroundStyle(model.hasHitCardTarget ? GRASPColor.success : GRASPColor.textSecondary)
                }

                if model.isElapsed {
                    Button(model.phase == .breaking ? "Back to Work" : "Take a Break") { model.advance() }
                        .buttonStyle(GRASPProminentButton(tint: tint))
                } else {
                    Button(model.isRunning ? "Pause" : "Resume") {
                        model.isRunning ? model.pause() : model.resume()
                    }
                    .buttonStyle(GRASPQuietButton())
                }

                Button {
                    model.reset()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(GRASPColor.textTertiary)
                .help("Stop the focus timer")
            }

            Spacer(minLength: 0)

            if model.completedIntervals > 0 {
                Text("\(model.completedIntervals) interval\(model.completedIntervals == 1 ? "" : "s") done")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Work and break lengths, and this session's card target")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(GRASPColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
        }
        .sheet(isPresented: $showingSettings) {
            FocusTimerSettingsSheet(model: model)
        }
    }

    private var tint: Color {
        if model.phase == .breaking { return GRASPColor.success }
        return model.isElapsed ? GRASPColor.accent : GRASPColor.accentMuted
    }

    private var elapsedPrompt: String {
        model.phase == .breaking ? "Break's up" : "Time's up"
    }
}

private struct FocusTimerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: FocusTimerModel

    // Persisted per profile, like every other study preference, so the
    // intervals someone settles on survive the app closing.
    @AppStorage("focusWorkMinutes") private var workMinutes = 25
    @AppStorage("focusBreakMinutes") private var breakMinutes = 5
    @AppStorage("focusCardTarget") private var cardTarget = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "timer")
                    .font(.system(size: 24))
                    .foregroundStyle(GRASPColor.accent)
                Text("Focus Timer")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
            }

            stepper("Work interval", value: $workMinutes, range: 5...90, unit: "min")
            stepper("Break", value: $breakMinutes, range: 1...30, unit: "min")
            stepper("Card target per interval", value: $cardTarget, range: 0...200, unit: "cards")

            Text("Set the card target to 0 to hide it. The timer never interrupts a session -- "
                 + "it changes colour when an interval is up and waits for you.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") {
                    model.workMinutes = workMinutes
                    model.breakMinutes = breakMinutes
                    model.cardTarget = cardTarget
                    dismiss()
                }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(GRASPColor.canvas)
    }

    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack {
            Text(label)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textPrimary)
            Spacer()
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue) \(unit)")
                    .graspType(.body)
                    .monospacedDigit()
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            .fixedSize()
        }
    }
}
