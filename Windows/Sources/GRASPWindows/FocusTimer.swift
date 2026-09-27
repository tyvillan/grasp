import Foundation
import Observation
import SwiftCrossUI
#if os(Windows)
import WinSDK
#endif

/// A Pomodoro-style work / break timer for a flashcard session, after the
/// Mac's `FocusTimerModel`: work for an interval, then a break, with a card
/// target per work interval. It never interrupts -- when an interval is up
/// it chimes, changes colour and waits.
@Observable
final class FocusTimerModel {
    enum Phase { case idle, working, breaking }

    private(set) var phase: Phase = .idle
    private(set) var secondsRemaining = 0
    private(set) var isElapsed = false
    private(set) var completedIntervals = 0
    private(set) var cardsThisInterval = 0
    var workMinutes: Int
    var breakMinutes: Int
    var cardTarget: Int
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(workMinutes: Int, breakMinutes: Int, cardTarget: Int) {
        self.workMinutes = workMinutes
        self.breakMinutes = breakMinutes
        self.cardTarget = cardTarget
    }

    var isRunning: Bool { ticker != nil && !isElapsed }

    var timeText: String { String(format: "%d:%02d", secondsRemaining / 60, secondsRemaining % 60) }

    var intervalProgress: Double {
        let total = Double((phase == .breaking ? breakMinutes : workMinutes) * 60)
        guard total > 0 else { return 0 }
        return max(0, min(1, 1 - Double(secondsRemaining) / total))
    }

    var hasHitCardTarget: Bool { cardTarget > 0 && cardsThisInterval >= cardTarget }

    func start() {
        phase = .working
        begin(seconds: workMinutes * 60)
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

    /// After an interval is up: on to the break, or back to work.
    func advance() {
        guard isElapsed else { return }
        isElapsed = false
        if phase == .breaking {
            start()
        } else {
            completedIntervals += 1
            cardsThisInterval = 0
            phase = .breaking
            begin(seconds: breakMinutes * 60)
        }
    }

    /// A card was answered: counts toward the interval's target.
    func countCard() {
        guard phase == .working else { return }
        cardsThisInterval += 1
    }

    private func begin(seconds: Int) {
        ticker?.cancel()
        isElapsed = false
        secondsRemaining = seconds
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.secondsRemaining > 0 { self.secondsRemaining -= 1 }
                if self.secondsRemaining == 0 {
                    self.isElapsed = true
                    self.ticker = nil
                    Self.chime()
                    return
                }
            }
        }
    }

    /// The system's short notification sound: audible without being an alarm.
    private static func chime() {
        #if os(Windows)
        _ = MessageBeep(UINT(MB_ICONASTERISK))
        #endif
    }
}

/// The timer's strip under a flashcard session's header.
struct FocusTimerBar: View {
    let model: FocusTimerModel
    let settings: AppSettings
    @State var showingSettings = false

    var body: some View {
        HStack(spacing: 10) {
            if model.phase == .idle {
                QuietLink(title: "⏱ Start Focus Timer") { model.start() }
            } else {
                Text(model.isElapsed ? (model.phase == .breaking ? "Break's up" : "Time's up") : model.timeText)
                    .font(Font.system(size: 13, weight: .semibold))
                    .foregroundColor(model.isElapsed ? tint : GRASPColor.textPrimary)
                    .fixedSize()
                Text(model.phase == .breaking ? "BREAK" : "FOCUS")
                    .font(GRASPFont.badge)
                    .foregroundColor(tint)
                    .fixedSize()
                ProgressBar(fraction: model.intervalProgress, tint: tint, height: 3.0)
                    .frame(width: 90.0)
                if model.cardTarget > 0, model.phase == .working {
                    Text("\(model.cardsThisInterval)/\(model.cardTarget) cards")
                        .font(GRASPFont.meta)
                        .foregroundColor(model.hasHitCardTarget ? GRASPColor.success : GRASPColor.textSecondary)
                        .fixedSize()
                }
                if model.isElapsed {
                    Button(model.phase == .breaking ? "Back to Work" : "Take a Break") { model.advance() }.fixedSize()
                } else {
                    Button(model.isRunning ? "Pause" : "Resume") {
                        if model.isRunning { model.pause() } else { model.resume() }
                    }
                    .fixedSize()
                }
                QuietLink(title: "Stop") { model.reset() }
            }
            Spacer()
            if model.completedIntervals > 0 {
                Text("\(model.completedIntervals) interval\(model.completedIntervals == 1 ? "" : "s") done")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
                    .fixedSize()
            }
            QuietLink(title: "Timer Settings") { showingSettings = true }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(GRASPColor.surface)
        .sheet(isPresented: $showingSettings) {
            FocusTimerSettings(model: model, settings: settings) { showingSettings = false }
        }
    }

    private var tint: Color {
        if model.phase == .breaking { return GRASPColor.success }
        return model.isElapsed ? GRASPColor.accent : GRASPColor.accentMuted
    }
}

/// Work and break lengths, and the card target, kept per profile.
private struct FocusTimerSettings: View {
    let model: FocusTimerModel
    let settings: AppSettings
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Focus Timer")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            stepper("Work interval", value: settings.focusWorkMinutes, unit: "min", range: 5...90, step: 5) {
                settings.focusWorkMinutes = $0
            }
            stepper("Break", value: settings.focusBreakMinutes, unit: "min", range: 1...30, step: 1) {
                settings.focusBreakMinutes = $0
            }
            stepper("Card target per interval", value: settings.focusCardTarget, unit: "cards", range: 0...200, step: 5) {
                settings.focusCardTarget = $0
            }
            Text("Set the card target to 0 to hide it. The timer never interrupts a session -- it changes colour when an interval is up and waits for you.")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") {
                    model.workMinutes = settings.focusWorkMinutes
                    model.breakMinutes = settings.focusBreakMinutes
                    model.cardTarget = settings.focusCardTarget
                    close()
                }
                .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 400.0)
        .background(GRASPColor.canvas)
    }

    private func stepper(_ label: String, value: Int, unit: String, range: ClosedRange<Int>, step: Int,
                         set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
            Spacer()
            Button("−") { set(max(range.lowerBound, value - step)) }.fixedSize()
            Text("\(value) \(unit)").font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary).frame(width: 76.0)
            Button("+") { set(min(range.upperBound, value + step)) }.fixedSize()
        }
    }
}
