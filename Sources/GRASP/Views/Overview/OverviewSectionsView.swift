import SwiftUI
import AppKit
import GRASPCore

/// Reading-column metrics for the lesson.
enum OverviewMetrics {
    /// The reading measure. At the 16pt `.prose` size this lands near 75
    /// characters a line -- the upper end of comfortable. The page is
    /// wider than this on most windows, and that is deliberate: a line of
    /// text stretched across a whole wide window runs past 150 characters
    /// and the eye loses its place finding the next line. The column is
    /// centred instead, with the contents list using the space beside it.
    static let measure: CGFloat = 680
    /// Width of the "On this page" rail.
    static let contentsWidth: CGFloat = 200
    static let contentsGap: CGFloat = 48
}

/// Inline markdown for one generated string.
///
/// The prompt forbids markdown syntax outright, so this is defensive rather
/// than load-bearing: models don't always obey, and a stray `**` rendering
/// as literal asterisks looks like a bug. `.inlineOnlyPreservingWhitespace`
/// because block structure is carried by the lesson's own shape, and
/// `returnPartiallyParsedIfPossible` because this text came from a language
/// model -- an unclosed backtick must degrade to one odd character, never
/// to a thrown error and a blank line.
///
/// `Text("**bold**")` only renders markdown because the literal becomes a
/// `LocalizedStringKey`. Generated content is always a runtime `String`, so
/// it has to come through here or the asterisks reach the screen.
func overviewInline(_ source: String) -> AttributedString {
    var attributed = (try? AttributedString(
        markdown: source,
        options: AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
    )) ?? AttributedString(source)

    // Ranges are collected first: mutating `attributed` while iterating its
    // own `runs` view invalidates the iteration. SwiftUI renders emphasis
    // from `inlinePresentationIntent` on its own, but not `.code`.
    let codeRanges = attributed.runs.compactMap { run in
        run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
    }
    for range in codeRanges {
        attributed[range].font = .graspMono(14)
        attributed[range].foregroundColor = GRASPColor.accent
    }
    return attributed
}

/// One note, taught as a lesson.
///
/// Laid out the way the reference course page is: where the lecture sits
/// in the course, a claim for a title, the question it answers, what you'll
/// be able to do, and then sections whose headings are themselves the
/// ideas. Key terms, figures and self-checks sit inside the section that
/// introduces them rather than being collected into lists at the end --
/// meeting a term right where it's used is most of what makes it stick.
struct OverviewSectionsView: View {
    let overview: RenderedOverview
    var onOpenCards: (([String]) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)

            if !overview.objectives.isEmpty {
                ObjectivesCallout(objectives: overview.objectives)
                    .padding(.bottom, 30)
            }

            ForEach(overview.sections) { section in
                LessonSectionView(section: section, onOpenCards: onOpenCards)
                    .id(section.id)
                    .padding(.bottom, 36)
            }

            if !overview.formulas.isEmpty {
                Callout(label: "Formulas", tint: GRASPColor.accent) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(overview.formulas) { FormulaRow(formula: $0) }
                    }
                }
                .padding(.bottom, 30)
            }

            if !overview.takeaways.isEmpty {
                TakeawaysView(takeaways: overview.takeaways)
                    .id("\(overview.materialId)#takeaways")
                    .padding(.bottom, 30)
            }

            if overview.diagram != nil || overview.mermaidSource != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How it all fits together")
                        .graspType(.proseH2)
                        .foregroundStyle(GRASPColor.textPrimary)
                    DiagramSection(overview: overview, onOpenCards: onOpenCards)
                }
                .id("\(overview.materialId)#map")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if let kicker = overview.kicker {
                    Text(kicker)
                        .graspType(.eyebrow)
                        .foregroundStyle(GRASPColor.accent)
                }
                if overview.isStale {
                    PreviewChip(
                        text: "Out of date", tint: GRASPColor.accent,
                        tintSoft: GRASPColor.accentSoft, icon: "clock"
                    )
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Copy Lesson") { copyToPasteboard() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                // A borderless menu otherwise tints itself with the window
                // accent, which put a bright amber dot in the corner that
                // read as an alert rather than a menu.
                .tint(GRASPColor.textTertiary)
                .foregroundStyle(GRASPColor.textTertiary)
                .fixedSize()
                .help("More")
            }

            Text(overviewInline(overview.title))
                .graspType(.lessonTitle)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let hook = overview.hook {
                Text(overviewInline(hook))
                    .graspType(.lede)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    /// Each `Text` is its own selection island in SwiftUI, so dragging
    /// across a heading and the paragraph under it doesn't work. Copying the
    /// whole lesson as Markdown covers the real use case -- pasting it
    /// somewhere else -- better than drag-selection would.
    private func copyToPasteboard() {
        var lines: [String] = []
        if let kicker = overview.kicker { lines.append("*\(kicker)*") }
        lines.append("# \(overview.title)")
        lines.append("")
        if let hook = overview.hook {
            lines.append(hook)
            lines.append("")
        }
        if !overview.objectives.isEmpty {
            lines.append("**By the end you should be able to:**")
            lines += overview.objectives.map { "- \($0)" }
            lines.append("")
        }
        for section in overview.sections {
            lines.append("## \(section.heading)")
            lines.append("")
            for paragraph in section.paragraphs {
                lines.append(paragraph)
                lines.append("")
            }
            for term in section.terms {
                lines.append("> **\(term.term)** — \(term.text)")
            }
            if !section.terms.isEmpty { lines.append("") }
            if let check = section.check {
                lines.append("> **Pause and check:** \(check.question)")
                lines.append(">")
                lines.append("> *Answer:* \(check.answer)")
                lines.append("")
            }
        }
        if !overview.formulas.isEmpty {
            lines.append("## Formulas")
            lines += overview.formulas.map { "- \($0.name): \($0.latex ?? $0.plain)" }
            lines.append("")
        }
        if !overview.takeaways.isEmpty {
            lines.append("## Key takeaways")
            lines += overview.takeaways.map { "- \($0)" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Section

private struct LessonSectionView: View {
    let section: RenderedSection
    var onOpenCards: (([String]) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(overviewInline(section.heading))
                .graspType(.proseH2)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(overviewInline(paragraph))
                    .graspType(.prose)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !section.terms.isEmpty {
                KeyTermsCallout(terms: section.terms, onOpenCards: onOpenCards)
                    .padding(.top, 4)
            }

            if let figure = section.figure {
                FigureCard(figure: figure)
                    .padding(.top, 6)
            }

            if let check = section.check {
                CheckCallout(check: check)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Callouts

/// The shared shape of every aside in the lesson: an accent rule down the
/// left edge, a faint wash of the same hue, and a small uppercase label.
/// One component for all of them so they read as a family -- the label and
/// the hue are what tell a key term from a self-check at a glance.
struct Callout<Content: View>: View {
    let label: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(tint)
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct ObjectivesCallout: View {
    let objectives: [String]

    var body: some View {
        Callout(label: "Learning objectives", tint: GRASPColor.textSecondary) {
            Text("By the end you should be able to:")
                .graspType(.prose)
                .foregroundStyle(GRASPColor.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(objectives.enumerated()), id: \.offset) { _, objective in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(GRASPColor.textTertiary)
                        Text(overviewInline(objective))
                            .graspType(.prose)
                            .foregroundStyle(GRASPColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct KeyTermsCallout: View {
    let terms: [LinkedDefinition]
    var onOpenCards: (([String]) -> Void)?

    var body: some View {
        Callout(label: terms.count == 1 ? "Key term" : "Key terms", tint: GRASPColor.success) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(terms) { term in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(overviewInline(term.term))
                                .graspType(.prose)
                                .fontWeight(.semibold)
                                .foregroundStyle(GRASPColor.textPrimary)
                            if !term.cardIds.isEmpty {
                                Button {
                                    onOpenCards?(term.cardIds)
                                } label: {
                                    PreviewChip(
                                        text: term.cardIds.count == 1
                                            ? "1 card" : "\(term.cardIds.count) cards",
                                        tint: GRASPColor.success, tintSoft: GRASPColor.successSoft,
                                        icon: "rectangle.stack"
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("Show the flashcard for this term")
                            }
                        }
                        Text(overviewInline(term.text))
                            .graspType(.prose)
                            .foregroundStyle(GRASPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// "Pause and check": a question placed right after the idea it tests,
/// with the answer held back until asked for. Trying to answer before
/// looking is the whole mechanism -- it's retrieval, not re-reading.
private struct CheckCallout: View {
    let check: OverviewCheck
    @State private var isRevealed = false

    var body: some View {
        Callout(label: "Pause and check", tint: GRASPColor.accent) {
            Text(overviewInline(check.question))
                .graspType(.prose)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if isRevealed {
                Text(overviewInline(check.answer))
                    .graspType(.prose)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                withAnimation(.easeOut(duration: 0.18)) { isRevealed.toggle() }
            } label: {
                Label(isRevealed ? "Hide answer" : "Show answer",
                      systemImage: isRevealed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(GRASPColor.accent)
            .padding(.top, 2)
        }
    }
}

private struct TakeawaysView: View {
    let takeaways: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Key takeaways")
                .graspType(.proseH2)
                .foregroundStyle(GRASPColor.textPrimary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(takeaways.enumerated()), id: \.offset) { index, takeaway in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(GRASPColor.accent)
                            .frame(width: 16, alignment: .trailing)
                        Text(overviewInline(takeaway))
                            .graspType(.prose)
                            .foregroundStyle(GRASPColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Figures

/// A figure with its caption, on a raised panel so it reads as the thing to
/// look at in its section.
private struct FigureCard: View {
    let figure: RenderedFigure

    private var caption: String? {
        switch figure {
        case .lines(let lines): return lines.caption
        case .transform(let transform): return transform.caption
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch figure {
            case .lines(let lines): SystemOfLinesView(figure: lines)
            case .transform(let transform): LinearTransformView(figure: transform)
            }
            if let caption {
                Text(overviewInline(caption))
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Selection inside an interactive figure would fight the drag.
        .textSelection(.disabled)
    }
}

private struct FormulaRow: View {
    let formula: IdentifiedFormula

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formula.name)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
            Text(formula.plain)
                .graspType(.formula)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let meaning = formula.meaning {
                Text(overviewInline(meaning))
                    .graspType(.prose)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The original notation, for anyone who wants to copy it into
        // something that does typeset.
        .help(formula.latex ?? formula.plain)
    }
}
