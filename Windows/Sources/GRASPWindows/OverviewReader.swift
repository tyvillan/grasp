import Foundation
import GRASPCore
import SwiftCrossUI

/// The Overview tab of a deck: the notes behind it, each taught as a
/// lesson, in reading order. The Windows counterpart of the Mac's
/// `DeckOverviewView`, over GRASPCore's `DeckOverviewReader`. Lessons come
/// from the Mac through sync, or are written here with Ollama.
///
/// One lesson at a time, with a picker and Previous / Next, where the Mac
/// stacks every lesson on one page beside an "On this page" rail. A
/// course's All Cards can hold twenty lessons, and SwiftCrossUI lays out
/// every one of them up front; one at a time keeps the tab quick.
struct OverviewPane: View {
    let library: Library
    let scope: DeckScope
    @State var lessonIndex = 0
    /// Notes waiting on "Write Them" in the confirmation panel.
    @State var pending: [MissingNote]?
    /// Which local model would write, or nil when Ollama isn't up. Checked
    /// when the tab opens, since the server can come and go.
    @State var model: String?
    @State var checkedModel = false

    /// The reading measure, as on the Mac: near 75 characters a line.
    static let measure = 680.0

    var body: some View {
        let overview = library.deckOverview(inDecks: scope.deckIds)
        let job = library.overviewJob(forCourse: courseId)
        VStack(alignment: .leading, spacing: 0) {
            if let job {
                JobStrip(job: job) { library.dismissOverviewJob(forCourse: courseId) }
            } else if let pending {
                ConfirmWrite(count: pending.count, model: model ?? "the local model",
                             onCancel: { self.pending = nil },
                             onConfirm: {
                                 library.writeOverviews(pending.map { ($0.materialId, $0.title) }, courseId: courseId)
                                 self.pending = nil
                             })
            } else if let overview, !overview.staleEntries.isEmpty {
                staleNotice(overview.staleEntries)
            }
            if let overview, !overview.entries.isEmpty {
                let index = min(lessonIndex, overview.entries.count - 1)
                if overview.entries.count > 1 {
                    lessonBar(overview.entries, index: index)
                }
                // Alternating between two identical branches gives each
                // lesson a fresh scroll view, so it opens at its top rather
                // than wherever the last one was left.
                if index % 2 == 0 {
                    lessonPage(overview, index: index)
                } else {
                    lessonPage(overview, index: index)
                }
            } else {
                emptyState(overview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: scope.id) {
            lessonIndex = 0
            pending = nil
        }
        .task {
            model = await library.localModel()
            checkedModel = true
        }
    }

    /// The course this deck (or All Cards) belongs to: one overview run per
    /// course at a time.
    private var courseId: String? {
        if scope.id.hasPrefix("all:") { return String(scope.id.dropFirst(4)) }
        return library.decks.first { $0.id == scope.id }?.courseId
    }

    private var canWrite: Bool {
        model != nil && library.overviewJob(forCourse: courseId).map(\.isFinished) != false
    }

    private func lessonPage(_ overview: DeckOverview, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LessonView(overview: overview.entries[index])
                if index + 1 < overview.entries.count {
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Next lesson: \(overview.entries[index + 1].title)") { lessonIndex = index + 1 }
                            .fixedSize()
                    }
                } else {
                    footer(overview)
                }
            }
            .frame(maxWidth: Self.measure)
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
        }
    }

    /// Which lesson, as a drop-down of their titles, and a step either way.
    private func lessonBar(_ entries: [RenderedOverview], index: Int) -> some View {
        let choices = entries.enumerated().map { LessonChoice(index: $0.offset, title: $0.element.title) }
        return HStack(spacing: 8) {
            Text("Lesson \(index + 1) of \(entries.count)")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
                .fixedSize()
            Picker(of: choices, selection: Binding(
                get: { choices[index] },
                set: { lessonIndex = $0?.index ?? 0 }
            ))
            Spacer()
            Button("Previous") { lessonIndex = index - 1 }.disabled(index == 0).fixedSize()
            Button("Next") { lessonIndex = index + 1 }.disabled(index + 1 >= entries.count).fixedSize()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(GRASPColor.surface)
    }

    private func staleNotice(_ stale: [RenderedOverview]) -> some View {
        HStack(spacing: 10) {
            Text(stale.count == 1
                 ? "1 note changed since its overview was written."
                 : "\(stale.count) notes changed since their overviews were written.")
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textSecondary)
            Spacer()
            if canWrite {
                Button(stale.count == 1 ? "Rewrite It…" : "Rewrite Them…") {
                    pending = stale.map { MissingNote(materialId: $0.materialId, title: $0.title) }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.accentSoft)
    }

    private func footer(_ overview: DeckOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if overview.handTypedCardCount > 0 {
                Text("\(overview.handTypedCardCount) card"
                     + "\(overview.handTypedCardCount == 1 ? " in this deck was" : "s in this deck were") "
                     + "typed by hand and aren't covered here.")
            }
            if !overview.writable.isEmpty {
                Text("\(overview.writable.count) more note\(overview.writable.count == 1 ? " has" : "s have") "
                     + "no overview yet.")
                if canWrite {
                    Button("Write \(overview.writable.count) More…") { pending = missing(overview) }
                        .fixedSize()
                }
            }
        }
        .font(GRASPFont.meta)
        .foregroundColor(GRASPColor.textTertiary)
        .padding(.top, 32)
    }

    private func missing(_ overview: DeckOverview) -> [MissingNote] {
        overview.writable.map { MissingNote(materialId: $0.materialId, title: LessonText.noteTitle($0.title)) }
    }

    private func emptyState(_ overview: DeckOverview?) -> some View {
        let writable = overview?.writable ?? []
        return VStack(spacing: 10) {
            Text(overview?.writable.isEmpty == false || overview == nil ? "No overview yet" : "Nothing to summarise")
                .font(GRASPFont.title)
                .foregroundColor(GRASPColor.textPrimary)
            Text(emptyExplanation(overview))
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440.0)
            if !writable.isEmpty && canWrite, let overview {
                Button("Write Overview\(writable.count == 1 ? "" : "s")…") { pending = missing(overview) }
                    .fixedSize()
                    .padding(.top, 4)
            }
        }
        .padding(28)
    }

    private func emptyExplanation(_ overview: DeckOverview?) -> String {
        guard let overview, !overview.missing.isEmpty else {
            return "There are no source notes behind this deck."
        }
        let writable = overview.writable.count
        if writable > 0 {
            let what = "GRASP can read the \(writable) note\(writable == 1 ? "" : "s") behind this deck and write "
                + "a short lesson for each: the key ideas, terms, worked examples and a concept map."
            if !checkedModel { return what }
            return model == nil
                ? what + " That needs Ollama running on this PC (Settings shows its status), or write them on "
                    + "your Mac and they'll arrive with the next sync."
                : what
        }
        let tooShort = overview.missing.filter { if case .tooShort = $0.reason { return true } else { return false } }.count
        let tooLong = overview.missing.count - tooShort
        var parts: [String] = []
        if tooShort > 0 {
            parts.append("\(tooShort) note\(tooShort == 1 ? " is" : "s are") too short to be worth summarising")
        }
        if tooLong > 0 {
            parts.append("\(tooLong) note\(tooLong == 1 ? " is" : "s are") long enough to be reference material rather than a lecture")
        }
        return parts.joined(separator: ", and ") + "."
    }
}

struct MissingNote {
    let materialId: String
    let title: String
}

/// "Write overviews for 5 notes?" with what it costs, before a run that
/// can take a long while -- the one action long enough that the estimate
/// can change the decision.
private struct ConfirmWrite: View {
    let count: Int
    let model: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(count == 1 ? "Write an overview?" : "Write overviews for \(count) notes?")
                    .font(GRASPFont.rowTitle.weight(.semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                Text("\(model) on this PC writes each lesson: sections, key terms, worked examples and a concept "
                     + "map. Takes \(estimate). You can keep using GRASP while it runs, and stop it any time.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textSecondary)
            }
            Spacer()
            Button("Cancel") { onCancel() }.fixedSize()
            Button(count == 1 ? "Write It" : "Write Them") { onConfirm() }.fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.surface)
    }

    /// About two minutes a note with qwen3.5:9b on this PC's RTX 5060
    /// (the Mac's laptop estimate is four).
    private var estimate: String {
        let minutes = count * 2
        if minutes < 90 { return "roughly \(minutes) minutes" }
        return "roughly \(Int((Double(minutes) / 60).rounded())) hours"
    }
}

/// The run in progress: what it's doing, how far along, and Stop -- or,
/// once it's done, what went wrong.
private struct JobStrip: View {
    let job: OverviewJob
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(job.isFinished ? (job.failure ?? "Overviews written.") : job.headline)
                    .font(GRASPFont.body)
                    .foregroundColor(job.failure != nil ? GRASPColor.rejected : GRASPColor.textSecondary)
                Spacer()
                if job.isFinished {
                    Button("Dismiss") { dismiss() }.fixedSize()
                } else {
                    Text("\(Int(job.fraction * 100))%")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                        .fixedSize()
                    Button("Stop") { job.stop() }.fixedSize()
                }
            }
            if !job.isFinished {
                ProgressBar(fraction: job.fraction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.accentSoft)
    }
}

/// A thin amber bar. GeometryReader rather than WinUI's ProgressBar, which
/// draws in Windows' accent colour.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width.isFinite ? Double(proxy.size.width) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(GRASPColor.hairlineStrong).frame(width: width, height: 4.0)
                Rectangle().fill(GRASPColor.accent).frame(width: max(0, min(1, fraction)) * width, height: 4.0)
            }
        }
        .frame(height: 4.0)
    }
}

// MARK: - A lesson

/// One note, taught as a lesson, laid out like the Mac's
/// `OverviewSectionsView`: where it sits in the course, a claim for a
/// title, the question it answers, what you'll be able to do, then
/// sections whose headings are the ideas, with key terms, figures, worked
/// examples and self-checks inside the section that introduces them.
///
/// Built from small named views on purpose: one body holding all of this
/// makes a view type so deeply nested that resolving its metadata
/// overflows the main thread's stack on Windows (see CLAUDE.md).
struct LessonView: View {
    let overview: RenderedOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LessonHeader(overview: overview)
            if !overview.objectives.isEmpty {
                ObjectivesCallout(objectives: overview.objectives)
            }
            ForEach(overview.sections, id: \.id) { section in
                LessonSectionView(section: section)
            }
            if !overview.formulas.isEmpty {
                FormulasCallout(formulas: overview.formulas)
            }
            if !overview.takeaways.isEmpty {
                TakeawaysView(takeaways: overview.takeaways)
            }
            if overview.diagram != nil || overview.mermaidSource != nil {
                DiagramSection(diagram: overview.diagram, source: overview.mermaidSource)
            }
        }
    }
}

private struct LessonHeader: View {
    let overview: RenderedOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let kicker = overview.kicker {
                    Text(kicker).font(GRASPFont.eyebrow).foregroundColor(GRASPColor.accent)
                }
                if overview.isStale {
                    Chip(text: "Out of date", tint: GRASPColor.accent, soft: GRASPColor.accentSoft)
                }
                Spacer()
            }
            Text(LessonText.clean(overview.title))
                .font(LessonFont.title)
                .foregroundColor(GRASPColor.textPrimary)
            if let hook = overview.hook {
                Text(LessonText.clean(hook))
                    .font(LessonFont.lede)
                    .foregroundColor(GRASPColor.textSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 22)
    }
}

private struct ObjectivesCallout: View {
    let objectives: [String]

    var body: some View {
        Callout(label: "Learning objectives", tint: GRASPColor.textSecondary) {
            Text("By the end you should be able to:")
                .font(LessonFont.prose)
                .foregroundColor(GRASPColor.textSecondary)
            ForEach(Array(objectives.enumerated()), id: \.offset) { _, objective in
                BulletRow(mark: "✓", text: LessonText.clean(objective))
            }
        }
        .padding(.bottom, 30)
    }
}

private struct BulletRow: View {
    let mark: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(mark).font(GRASPFont.meta.weight(.bold)).foregroundColor(GRASPColor.textTertiary)
            Text(text).font(LessonFont.prose).foregroundColor(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FormulasCallout: View {
    let formulas: [IdentifiedFormula]

    var body: some View {
        Callout(label: "Formulas", tint: GRASPColor.accent) {
            ForEach(formulas, id: \.id) { formula in
                FormulaRow(formula: formula)
            }
        }
        .padding(.bottom, 30)
    }
}

private struct FormulaRow: View {
    let formula: IdentifiedFormula

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formula.name).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            Text(formula.plain).font(LessonFont.formula).foregroundColor(GRASPColor.textPrimary)
            if let meaning = formula.meaning {
                Text(LessonText.clean(meaning)).font(LessonFont.prose).foregroundColor(GRASPColor.textSecondary)
            }
        }
    }
}

private struct TakeawaysView: View {
    let takeaways: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Key takeaways").font(LessonFont.h2).foregroundColor(GRASPColor.textPrimary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(takeaways.enumerated()), id: \.offset) { index, takeaway in
                    TakeawayRow(number: index + 1, text: takeaway)
                }
            }
            .padding(18)
            .background(GRASPColor.surface)
            .cornerRadius(10)
        }
        .padding(.bottom, 30)
    }
}

private struct TakeawayRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(Font.system(size: 13, weight: .semibold))
                .foregroundColor(GRASPColor.accent)
                .frame(width: 16.0, alignment: .trailing)
            Text(LessonText.clean(text)).font(LessonFont.prose).foregroundColor(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

private struct DiagramSection: View {
    let diagram: LaidOutDiagram?
    let source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it all fits together").font(LessonFont.h2).foregroundColor(GRASPColor.textPrimary)
            if let diagram {
                ConceptMapView(diagram: diagram)
            } else if let source {
                // Couldn't be parsed: the source is more use than nothing.
                Text(source)
                    .font(LessonFont.code)
                    .foregroundColor(GRASPColor.textSecondary)
                    .padding(14)
                    .background(GRASPColor.surface)
                    .cornerRadius(8)
            }
        }
    }
}

private struct LessonSectionView: View {
    let section: RenderedSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LessonText.clean(section.heading, math: section.isMath))
                .font(LessonFont.h2)
                .foregroundColor(GRASPColor.textPrimary)

            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(LessonText.clean(paragraph, math: section.isMath))
                    .font(LessonFont.prose)
                    .foregroundColor(GRASPColor.textPrimary)
            }

            if let code = section.code {
                CodeSnippetView(snippet: code)
            }

            if !section.terms.isEmpty {
                KeyTermsCallout(terms: section.terms, isMath: section.isMath)
                    .padding(.top, 4)
            }

            if let figure = section.figure {
                FigureCard(figure: figure)
                    .padding(.top, 6)
            }

            if let example = section.example {
                WorkedExampleView(example: example, isMath: section.isMath)
                    .padding(.top, 4)
            }

            if let check = section.check {
                CheckCallout(check: check, isMath: section.isMath)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 36)
    }
}

// MARK: - Callouts

/// The shared shape of every aside in a lesson: an accent rule down the
/// left edge, a faint wash of the same hue, and a small uppercase label.
/// The label and hue are what tell a key term from a self-check at a glance.
struct Callout<Content: View>: View {
    let label: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(tint).frame(width: 3.0)
            VStack(alignment: .leading, spacing: 8) {
                Text(label.uppercased()).font(GRASPFont.eyebrow).foregroundColor(tint)
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Spacer()
        }
        .background(tint.opacity(0.08))
        .cornerRadius(6)
    }
}

private struct KeyTermsCallout: View {
    let terms: [LinkedDefinition]
    let isMath: Bool

    var body: some View {
        Callout(label: terms.count == 1 ? "Key term" : "Key terms", tint: GRASPColor.success) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(terms, id: \.id) { term in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(LessonText.clean(term.term, math: isMath))
                                .font(LessonFont.prose.weight(.semibold))
                                .foregroundColor(GRASPColor.textPrimary)
                            if !term.cardIds.isEmpty {
                                Chip(text: term.cardIds.count == 1 ? "1 card" : "\(term.cardIds.count) cards",
                                     tint: GRASPColor.success, soft: GRASPColor.successSoft)
                            }
                        }
                        Text(LessonText.clean(term.text, math: isMath))
                            .font(LessonFont.prose)
                            .foregroundColor(GRASPColor.textSecondary)
                        if let example = term.example {
                            boundary(label: "Is", text: example, tint: GRASPColor.success)
                        }
                        if let nonExample = term.nonExample {
                            boundary(label: "Isn't", text: nonExample, tint: GRASPColor.rejected)
                        }
                        if let contrast = term.matrixContrast {
                            MatrixContrastView(contrast: contrast)
                                .padding(.top, 6)
                        }
                    }
                }
            }
        }
    }

    private func boundary(label: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label.uppercased())
                .font(GRASPFont.badge)
                .foregroundColor(tint)
                .frame(width: 40.0, alignment: .leading)
                .padding(.top, 3)
            Text(LessonText.clean(text, math: isMath))
                .font(LessonFont.prose)
                .foregroundColor(GRASPColor.textSecondary)
        }
        .padding(.top, 2)
    }
}

/// "Pause and check": the answer stays hidden until asked for. Trying to
/// answer before looking is the whole mechanism.
private struct CheckCallout: View {
    let check: OverviewCheck
    let isMath: Bool
    @State var isRevealed = false

    var body: some View {
        Callout(label: "Pause and check", tint: GRASPColor.accent) {
            Text(LessonText.clean(check.question, math: isMath))
                .font(LessonFont.prose)
                .foregroundColor(GRASPColor.textPrimary)
            if isRevealed {
                Text(LessonText.clean(check.answer, math: isMath))
                    .font(LessonFont.prose)
                    .foregroundColor(GRASPColor.textSecondary)
                    .padding(.top, 2)
            }
            Text(isRevealed ? "Hide answer ▴" : "Show answer ▾")
                .font(Font.system(size: 12, weight: .semibold))
                .foregroundColor(GRASPColor.accent)
                .padding(.top, 2)
                .onTapGesture { isRevealed.toggle() }
        }
    }
}

/// A worked example, a step at a time: what was done, what it produced,
/// and why. Revealed one step at a time, as on the Mac, so the reader can
/// guess the next move before seeing it.
struct WorkedExampleView: View {
    let example: OverviewWorkedExample
    let isMath: Bool
    @State var revealed = 1

    private let tint = GRASPColor.figureBlue

    var body: some View {
        Callout(label: "Worked example", tint: tint) {
            if let title = example.title {
                Text(LessonText.clean(title, math: isMath))
                    .font(LessonFont.prose.weight(.semibold))
                    .foregroundColor(GRASPColor.textPrimary)
            }
            if let setup = example.setup {
                Text(LessonText.clean(setup, math: isMath))
                    .font(LessonFont.prose)
                    .foregroundColor(GRASPColor.textSecondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(example.steps.prefix(revealed).enumerated()), id: \.offset) { index, step in
                    stepRow(index: index, step: step)
                }
            }
            .padding(.top, 4)

            if revealed >= example.steps.count, let outcome = example.outcome {
                HStack(alignment: .top, spacing: 8) {
                    Text("✓").font(LessonFont.prose.weight(.bold)).foregroundColor(GRASPColor.success)
                    Text(LessonText.clean(outcome, math: isMath))
                        .font(LessonFont.prose)
                        .foregroundColor(GRASPColor.textPrimary)
                }
                .padding(.top, 2)
            }

            if revealed < example.steps.count {
                HStack(spacing: 16) {
                    Text("Next step ▾")
                        .foregroundColor(tint)
                        .onTapGesture { revealed += 1 }
                    Text("Show all")
                        .foregroundColor(GRASPColor.textTertiary)
                        .onTapGesture { revealed = example.steps.count }
                }
                .font(Font.system(size: 12, weight: .semibold))
                .padding(.top, 2)
            }
        }
    }

    private func stepRow(index: Int, step: OverviewExampleStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)")
                .font(Font.system(size: 12, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 22.0, height: 22.0)
                .background(tint.opacity(0.15))
                .cornerRadius(11)
            VStack(alignment: .leading, spacing: 6) {
                Text(LessonText.clean(step.action, math: isMath))
                    .font(LessonFont.prose.weight(.medium))
                    .foregroundColor(GRASPColor.textPrimary)
                if let visual = step.visual {
                    StepVisualView(visual: visual)
                }
                if let result = step.result {
                    Text(LessonText.clean(result, math: isMath))
                        .font(LessonFont.formula)
                        .foregroundColor(GRASPColor.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(GRASPColor.surface)
                        .cornerRadius(6)
                }
                if let why = step.why {
                    Text(LessonText.clean(why, math: isMath))
                        .font(LessonFont.prose)
                        .foregroundColor(GRASPColor.textSecondary)
                }
            }
        }
    }
}

/// Code from the note that a section talks about, with line numbers.
private struct CodeSnippetView: View {
    let snippet: NoteCode.Snippet

    var body: some View {
        let lines = snippet.code.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text((snippet.language ?? "code").uppercased())
                    .font(GRASPFont.badge)
                    .foregroundColor(GRASPColor.accent)
                Text("From your notes").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(LessonFont.code)
                            .foregroundColor(GRASPColor.textTertiary)
                            .frame(width: 22.0, alignment: .trailing)
                        Text(line.isEmpty ? " " : line)
                            .font(LessonFont.code)
                            .foregroundColor(GRASPColor.textPrimary)
                    }
                }
            }
        }
        .padding(14)
        .background(GRASPColor.surface)
        .cornerRadius(8)
    }
}

/// A small tinted label, like the Mac's `PreviewChip`.
struct Chip: View {
    let text: String
    let tint: Color
    let soft: Color

    var body: some View {
        Text(text)
            .font(GRASPFont.badge)
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(soft)
            .cornerRadius(8)
            .fixedSize()
    }
}

// MARK: - Type and text

/// The lesson's type scale, after the Mac's `.lessonTitle`, `.proseH2`,
/// `.prose` and friends: bigger than the rest of the app, because this is
/// the one screen meant for sustained reading.
enum LessonFont {
    static let title = Font.system(size: 28, weight: .bold)
    static let lede = Font.system(size: 17)
    static let h2 = Font.system(size: 20, weight: .semibold)
    static let prose = Font.system(size: 15)
    static let formula = Font.system(size: 14).monospaced()
    static let code = Font.system(size: 12).monospaced()
}

/// Generated text, readied for plain `Text`. The prompt forbids markdown
/// but models don't always obey, and a stray `**` showing as literal
/// asterisks looks like a bug; SwiftCrossUI's `Text` has no inline
/// markdown, so the markers are removed. Math notes get the same
/// `MathNotation.prettify` the Mac applies (x_1 → x₁ and so on).
enum LessonText {
    static func clean(_ text: String, math: Bool = false) -> String {
        var result = text
        for marker in ["**", "__", "`"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return math ? MathNotation.prettify(result) : result
    }
}

/// A lesson in the picker: "3. Classes own their parts".
struct LessonChoice: Equatable, CustomStringConvertible {
    let index: Int
    let title: String
    var description: String { "\(index + 1). \(LessonText.clean(title))" }
}

extension LessonText {
    /// "Row Reduction" from `2026-08-27_Lecture-02_Row-Reduction`, the way a
    /// lesson's fallback title reads.
    static func noteTitle(_ fileName: String) -> String {
        let topic = FilenameParsing.parse(fileNameWithoutExtension: fileName).topic?
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (topic?.isEmpty == false ? topic : nil) ?? fileName
    }
}
