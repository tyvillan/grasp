import SwiftUI
import GRASPCore

// The pieces of Home, shared by the Mac's Home and the iPhone's Today tab:
// the countdown hero, plan rows with their check rings, the streak pill
// and the plain exam and due-count cards.

extension CalendarEvent {
    /// The time range as shown on a chip or row -- nil for an all-day
    /// event, which is most exams. (`countdownText`/`daysAway` live in
    /// GRASPCore alongside the record itself, where the calendar-day math
    /// is unit-tested.)
    var timeText: String? {
        guard !isAllDay else { return nil }
        let start = startsAt.formatted(date: .omitted, time: .shortened)
        guard let endsAt else { return start }
        return "\(start) – \(endsAt.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Pieces

/// The next exam as a giant yellow numeral that rolls up to its value.
struct CountdownHero: View {
    let item: AppStore.UpcomingEvent
    let days: Int
    var numeralSize: CGFloat = 190
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String { item.event.title.isEmpty ? item.event.kind.label : item.event.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Next exam")
            Group {
                if days == 0 {
                    Text("Today")
                } else {
                    Text("\(shown)")
                        .contentTransition(.numericText(value: Double(shown)))
                }
            }
            .font(.graspDisplay(numeralSize))
            .tracking(-numeralSize * 0.02)
            .foregroundStyle(GRASPColor.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.top, 8)
            .accessibilityLabel(days == 0 ? "Today" : "\(days) days")

            Text(days == 0 ? title : "day\(days == 1 ? "" : "s") to your\n\(title)")
                .font(.graspDisplay(26))
                .tracking(-0.4)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1)

            Spacer(minLength: GRASPSpace.xl)

            Text(detail)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(2)
        }
        .onAppear {
            guard shown != days else { return }
            if reduceMotion { shown = days; return }
            withAnimation(Motion.settle.delay(0.12)) { shown = days }
        }
        .onChange(of: days) { withAnimation(Motion.settle) { shown = days } }
    }

    private var detail: String {
        var parts: [String] = []
        if let course = item.courseName { parts.append(course) }
        parts.append(item.event.startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
        if let time = item.event.timeText { parts.append(time) }
        return parts.joined(separator: " · ")
    }
}

/// When no exam is coming: the due count is the number that matters.
struct DueHero: View {
    let totalDue: Int
    var numeralSize: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Due today")
            Text("\(totalDue)")
                .font(.graspDisplay(numeralSize))
                .tracking(-numeralSize * 0.02)
                .foregroundStyle(GRASPColor.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .contentTransition(.numericText(value: Double(totalDue)))
                .padding(.top, 8)
            Text(totalDue == 1 ? "card waiting" : "cards waiting")
                .font(.graspDisplay(26))
                .foregroundStyle(GRASPColor.textPrimary)
            Spacer(minLength: GRASPSpace.xl)
            Text("No exams in the next month.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        }
    }
}

/// One plan step: a ring that fills and draws a check, the step, and its
/// time. The ring ticks the step off; the rest of the row starts it.
struct PlanStepRow: View {
    let step: TodayPlan.Step
    let isDone: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggle) {
                CheckRing(isOn: isDone)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
            .sensoryFeedback(.success, trigger: isDone) { _, new in new }

            Button(action: onOpen) {
                HStack(alignment: .center, spacing: GRASPSpace.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.graspUI(size: 14.5, weight: .semibold))
                            .foregroundStyle(GRASPColor.textPrimary)
                            .strikethrough(isDone, color: GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(step.subtitle)
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: GRASPSpace.s)
                    Text("\(step.minutes) min")
                        .graspType(.meta)
                        .monospacedDigit()
                        .foregroundStyle(GRASPColor.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(.graspUI(size: 11, weight: .semibold))
                        .foregroundStyle(GRASPColor.textSecondary)
                        .opacity(hovering ? 1 : 0)
                        .offset(x: hovering ? 0 : -3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.snappy, value: hovering)
        }
        .padding(.vertical, 14)
        .opacity(isDone ? 0.5 : 1)
    }
}

/// A cream ring at 40% that fills yellow and draws a check when on.
struct CheckRing: View {
    let isOn: Bool
    var size: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(GRASPColor.textPrimary.opacity(0.4), lineWidth: 1.5)
            Circle()
                .fill(GRASPColor.brand)
                .scaleEffect(isOn ? 1 : 0.2)
                .opacity(isOn ? 1 : 0)
            CheckMark()
                .trim(from: 0, to: isOn ? 1 : 0)
                .stroke(GRASPColor.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.42, height: size * 0.32)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .animation(Motion.choose(Motion.bouncy, reduceMotion: reduceMotion), value: isOn)
    }
}

struct CheckMark: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A short yellow burst around the primary button when the whole plan is
/// done. Under 1s; nothing under Reduce Motion.
struct CelebrationBurst: View {
    let trigger: Bool
    @State private var fired = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                let angle = Double(i) / 10 * 2 * .pi
                BrandDot(size: i.isMultiple(of: 2) ? 7 : 5)
                    .rotationEffect(.degrees(fired ? 120 : 0))
                    .offset(x: fired ? cos(angle) * 90 : 0, y: fired ? sin(angle) * 40 : 0)
                    .opacity(fired ? 0 : 1)
            }
        }
        .opacity(trigger && !reduceMotion ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, now in
            guard now, !reduceMotion else { fired = false; return }
            fired = false
            withAnimation(.easeOut(duration: 0.8)) { fired = true }
        }
    }
}

/// The streak: a yellow pill that pulses once when it appears and rolls
/// its number when it grows.
struct StreakPill: View {
    let days: Int
    let studiedToday: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Text("\(days)")
                .contentTransition(.numericText(value: Double(days)))
            Text("-day streak")
        }
        .font(.graspUI(size: 13, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(GRASPColor.ink)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Capsule().fill(GRASPColor.brand))
        .scaleEffect(pulse ? 1.08 : 1)
        .help(studiedToday ? "You've studied today" : "Study today to keep your streak")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Motion.bouncy.delay(0.35)) { pulse = true }
            withAnimation(Motion.snappy.delay(0.6)) { pulse = false }
        }
        .animation(Motion.snappy, value: days)
    }
}

/// One later exam: when, what, and where you stand. Plain -- no course
/// color, a hairline edge that brightens on hover.
struct ExamCard: View {
    let item: AppStore.UpcomingEvent
    let standing: ExamPlan.Standing?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(when)
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.textTertiary)
            Text(item.event.title.isEmpty ? item.event.kind.label : item.event.title)
                .font(.graspDisplay(19))
                .tracking(-0.2)
                .foregroundStyle(GRASPColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(GRASPSpace.xl)
        .background(hovering ? GRASPColor.surfaceRaised : GRASPColor.surface,
                    in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous)
                .strokeBorder(hovering ? GRASPColor.hairlineStrong : GRASPColor.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: GRASPRadius.card))
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
    }

    private var when: String {
        var text = item.event.startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if let time = item.event.timeText { text += " · " + time }
        return text
    }

    private var summary: String {
        var parts: [String] = []
        if let standing {
            parts.append("\(standing.dueCards) due")
            if standing.weakCards > 0 {
                parts.append("\(standing.weakCards) weak spot\(standing.weakCards == 1 ? "" : "s")")
            }
        }
        parts.append(item.event.countdownText())
        return parts.joined(separator: " · ")
    }
}

/// Says what the big due count means, so 722 doesn't read as a debt.
struct DueExplainerCard: View {
    let totalDue: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Everything else")
            Text("\(totalDue) card\(totalDue == 1 ? "" : "s") due")
                .font(.graspDisplay(19))
                .tracking(-0.2)
                .foregroundStyle(GRASPColor.textPrimary)
                .contentTransition(.numericText(value: Double(totalDue)))
            Text(totalDue == 0
                 ? "You're clear. New cards come due as you learn them."
                 : "You don't need to clear them all. The plan covers what matters before your exams.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .graspCard(padding: GRASPSpace.xl)
    }
}
