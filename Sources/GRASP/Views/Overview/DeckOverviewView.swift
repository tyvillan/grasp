import SwiftUI
import GRASPCore

/// The Overview half of the deck view: every note behind this deck,
/// summarised, in reading order.
struct DeckOverviewView: View {
    @Environment(AppStore.self) private var store
    let scope: AppStore.DeckScope
    /// Hands a card back to `DeckDetailView`, which switches to Cards and
    /// selects it.
    let onOpenCard: (String) -> Void

    @State private var overview: DeckOverview?
    @State private var isGeneratorAvailable = false
    /// The run in progress, owned by the store so it survives a switch to
    /// the Cards tab and back (which rebuilds this view) with its Stop
    /// button intact -- and so a second run can't start over the same
    /// notes while it goes.
    private var jobKey: String { store.overviewJobKey(courseId: courseId) }
    private var activity: AIActivity? { store.aiJob(jobKey)?.activity }
    private var isWriting: Bool { activity != nil }
    private var courseId: String? {
        switch scope {
        case .deck(let id): return (try? store.deck(id))??.courseId
        case .course(let id): return id
        }
    }
    @State private var showingConfirmation = false
    @State private var pendingTargets: [String] = []
    /// Set when a run ends with notes it couldn't write. Every AI action in
    /// this app fails soft by design, and a note that silently didn't
    /// appear looks exactly like one that was never attempted -- a run once
    /// skipped two lectures in the middle of a course with nothing on
    /// screen to say so.
    @State private var failure: Failure?
    @State private var hasMathInScope = false
    /// Which model is about to write these, so the sheet can say so. Apple's
    /// on-device model is a real fallback, not an equal one.
    @State private var generatorOrigin: OverviewOrigin?
    /// The same guard, for the same reason, as `DeckDetailView`'s: `scope`
    /// is a `let`, so a `Task` started from the write button holds whichever
    /// deck was open when it was pressed, while this counter read back after
    /// an await always sees the live one. Nothing in the app can cancel an
    /// AI call, so this is the only thing standing between a slow run and
    /// one deck's content appearing under another deck's name.
    @State private var scopeGeneration = 0

    private struct Failure: Equatable {
        var message: String
        /// The notes to try again, in their original order.
        var retry: [String]
    }

    private var deckIds: [String] {
        switch scope {
        case .deck(let id): return [id]
        case .course(let courseId): return (try? store.decks(inCourse: courseId))?.map(\.id) ?? []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let activity {
                AIProgressStrip(
                    activity: activity,
                    onStop: { store.stopAIJob(jobKey) },
                    stopHelp: "Stops now. Notes already written are kept; the one in progress is discarded."
                )
            } else if let failure {
                failureNotice(failure)
            } else if let overview, !overview.staleEntries.isEmpty {
                staleNotice(overview)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: scope) {
            scopeGeneration += 1
            load()
            isGeneratorAvailable = await isAnyGeneratorAvailable()
        }
        .onChange(of: store.revision) { _, _ in load() }
        .sheet(isPresented: $showingConfirmation) {
            WriteOverviewsSheet(
                noteCount: pendingTargets.count,
                mentionsMath: hasMathInScope,
                generator: generatorOrigin,
                onConfirm: {
                    showingConfirmation = false
                    write(pendingTargets)
                },
                onCancel: { showingConfirmation = false }
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let overview, !overview.entries.isEmpty {
            GeometryReader { proxy in
                // The contents rail only appears when there's room for it
                // beside a full-measure column. Below that the column simply
                // fills the pane -- a squeezed column plus a squeezed rail
                // is worse than either on its own.
                let unitWidth = OverviewMetrics.measure + OverviewMetrics.contentsGap
                    + OverviewMetrics.contentsWidth
                let showsContents = proxy.size.width >= unitWidth + 64
                // Column and rail are centred *together*, so on a wide
                // window the spare space splits evenly either side instead
                // of piling up on the right the way it used to.
                let leading = showsContents
                    ? max(32, (proxy.size.width - unitWidth) / 2)
                    : max(24, (proxy.size.width - OverviewMetrics.measure) / 2)
                ScrollViewReader { reader in
                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            lessonColumn(overview)
                                .frame(width: min(OverviewMetrics.measure, proxy.size.width - 48),
                                       alignment: .leading)
                                .padding(.leading, leading)
                                .padding(.vertical, 32)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Outside the scroll view, so it stays put while the
                        // lesson scrolls beside it -- a contents list that
                        // scrolls away is only useful at the top of the page.
                        if showsContents {
                            LessonContents(entries: overview.entries) { anchor in
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    reader.scrollTo(anchor, anchor: .top)
                                }
                            }
                            .frame(width: OverviewMetrics.contentsWidth, alignment: .leading)
                            .padding(.leading, leading + OverviewMetrics.measure + OverviewMetrics.contentsGap)
                            .padding(.top, 36)
                        }
                    }
                }
            }
        } else if overview == nil {
            Color.clear
        } else {
            emptyState
        }
    }

    /// Every note's lesson in reading order, with a rule between them so a
    /// multi-note deck reads as a sequence of lessons rather than one run of
    /// unrelated sections.
    private func lessonColumn(_ overview: DeckOverview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(overview.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Rectangle()
                        .fill(GRASPColor.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 40)
                }
                OverviewSectionsView(overview: entry) { cardIds in
                    if let first = cardIds.first { onOpenCard(first) }
                }
                .id(entry.id)
            }
            footer(overview)
                .padding(.top, 32)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let writable = overview?.writable ?? []
        if !isGeneratorAvailable {
            // A deliberate deviation from this app's usual "hide the AI
            // affordance" rule. The refine button can vanish silently
            // because there are cards around it; here the pane would just
            // be blank behind a tab the user only just clicked.
            ContentUnavailableView {
                Label("Overviews need a local model", systemImage: "sparkles")
            } description: {
                Text("Writing an overview takes a local AI model -- Ollama, or Apple's "
                     + "on-device model. Neither is available right now. Settings has the "
                     + "setup, and everything else in GRASP works without it.")
            }
        } else if writable.isEmpty, let overview, !overview.missing.isEmpty {
            ContentUnavailableView {
                Label("Nothing to summarise", systemImage: "text.book.closed")
            } description: {
                Text(missingExplanation(overview))
            }
        } else {
            ContentUnavailableView {
                Label("No overview yet", systemImage: "text.book.closed")
            } description: {
                Text("GRASP can read the \(writable.count) note\(writable.count == 1 ? "" : "s") "
                     + "behind this deck and write a study overview for each -- key takeaways, "
                     + "the definitions worth knowing, an outline, and a concept map.")
            } actions: {
                Button("Write Overview\(writable.count == 1 ? "" : "s")…") {
                    prepare(writable.map(\.materialId))
                }
                .buttonStyle(GRASPProminentButton())
                .disabled(isWriting || writable.isEmpty)
            }
        }
    }

    private func missingExplanation(_ overview: DeckOverview) -> String {
        let tooShort = overview.missing.filter { if case .tooShort = $0.reason { return true } else { return false } }
        let tooLong = overview.missing.filter { if case .tooLong = $0.reason { return true } else { return false } }
        var parts: [String] = []
        if !tooShort.isEmpty {
            parts.append("\(tooShort.count) note\(tooShort.count == 1 ? " is" : "s are") too short "
                         + "to be worth summarising")
        }
        if !tooLong.isEmpty {
            parts.append("\(tooLong.count) note\(tooLong.count == 1 ? " is" : "s are") long enough "
                         + "to be reference material rather than a lecture")
        }
        return parts.isEmpty
            ? "There are no source notes behind this deck."
            : parts.joined(separator: ", and ") + "."
    }

    @ViewBuilder
    private func footer(_ overview: DeckOverview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if overview.handTypedCardCount > 0 {
                Text("\(overview.handTypedCardCount) card"
                     + "\(overview.handTypedCardCount == 1 ? " in this deck was" : "s in this deck were") "
                     + "typed by hand and aren't covered here.")
            }
            let writable = overview.writable
            if !writable.isEmpty, isGeneratorAvailable {
                Button("Write \(writable.count) more overview\(writable.count == 1 ? "" : "s")…") {
                    prepare(writable.map(\.materialId))
                }
                .buttonStyle(GRASPQuietButton())
                .disabled(isWriting)
                .padding(.top, 6)
            }
        }
        .graspType(.meta)
        .foregroundStyle(GRASPColor.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Notices

    private func failureNotice(_ failure: Failure) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(GRASPColor.rejected)
            Text(failure.message)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !failure.retry.isEmpty, isGeneratorAvailable {
                Button("Try Again") { write(failure.retry) }
                    .buttonStyle(GRASPQuietButton())
                    .disabled(isWriting)
            }
            Button("Dismiss") { self.failure = nil }
                .buttonStyle(GRASPQuietButton())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.rejectedSoft.opacity(0.55))
        .background(alignment: .bottom) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
        }
    }

    private func staleNotice(_ overview: DeckOverview) -> some View {
        let stale = overview.staleEntries
        return HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(GRASPColor.accent)
            Text(stale.count == 1
                 ? "1 note changed since its overview was written"
                 : "\(stale.count) notes changed since their overviews were written")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
            Spacer(minLength: 8)
            if isGeneratorAvailable {
                Button(stale.count == 1 ? "Rewrite It" : "Rewrite Them") {
                    prepare(stale.map(\.materialId))
                }
                .buttonStyle(GRASPQuietButton())
                .disabled(isWriting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.accentSoft.opacity(0.55))
        .background(alignment: .bottom) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
        }
    }

    // MARK: - Loading and writing

    private func load() {
        overview = try? store.deckOverview(inDecks: deckIds)
    }

    private func isAnyGeneratorAvailable() async -> Bool {
        await CardGenerators.select().isAvailable
    }

    private func prepare(_ materialIds: [String]) {
        pendingTargets = materialIds
        hasMathInScope = (try? store.overviewMaterials(inDecks: deckIds))?
            .contains { (try? store.noteText(forMaterial: $0.id))??.hasMath == true } ?? false
        Task {
            let generator = await CardGenerators.select()
            generatorOrigin = generator is OllamaGenerator ? .ollama
                : (generator is NoGenerator ? nil : .appleOnDevice)
            showingConfirmation = true
        }
    }

    /// The loop lives here rather than in the store so each note's section
    /// lands in the reader as it finishes. That incremental arrival is the
    /// real progress indicator; the bar just says how much is left.
    private func write(_ materialIds: [String]) {
        guard !materialIds.isEmpty else { return }
        failure = nil
        let generation = scopeGeneration
        let run = AIActivity(headline: "Writing overviews", units: materialIds.count)
        let titles = Dictionary(uniqueKeysWithValues: materialIds.map { ($0, title(of: $0)) })

        store.runAIJob(jobKey, activity: run) { [store] run in
            var failed: [(materialId: String, title: String, outcome: AppStore.OverviewOutcome)] = []
            var wroteAny = false
            for (index, materialId) in materialIds.enumerated() {
                if Task.isCancelled { break }
                let title = titles[materialId] ?? "note"
                run.headline = materialIds.count == 1
                    ? "Writing overview · \(title)"
                    : "Writing overview \(index + 1) of \(materialIds.count) · \(title)"

                let reporter = run.reporter(forUnit: index)
                let outcome = await AIProgress.$current.withValue(reporter) {
                    await store.writeOverview(forMaterial: materialId, force: true)
                }
                run.completeUnit(index)
                switch outcome {
                case .written: wroteAny = true
                case .empty, .unavailable: failed.append((materialId, title, outcome))
                case .unchanged, .tooShort, .tooLong, .cancelled: break
                }

                // Carries on through a deck switch -- the store persists each
                // note as it lands -- but only refreshes this view while it's
                // still showing the deck the run started on.
                if generation == scopeGeneration { load() }
            }
            guard generation == scopeGeneration else { return }
            load()
            // A stop is the student's own choice, not a failure to explain.
            if !run.stopRequested, !failed.isEmpty {
                failure = Failure(
                    message: explanation(failed: failed, wroteAny: wroteAny, slept: run.sleptDuringRun),
                    retry: failed.map(\.materialId)
                )
            }
        }
    }

    private func title(of materialId: String) -> String {
        overview?.missing.first { $0.materialId == materialId }?.title
            ?? overview?.entries.first { $0.materialId == materialId }?.title
            ?? "note"
    }

    /// Names the notes, because "2 notes failed" in a deck of eight leaves
    /// the student hunting for which two.
    private func explanation(
        failed: [(materialId: String, title: String, outcome: AppStore.OverviewOutcome)],
        wroteAny: Bool,
        slept: Bool
    ) -> String {
        let names = failed.map(\.title)
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        case 3...4: list = names.dropLast().joined(separator: ", ") + ", and " + names.last!
        default: list = "\(names.count) notes"
        }
        let what = "\(list) couldn't be written" + (wroteAny ? "; the rest were." : ".")

        if slept {
            return what + " Your Mac went to sleep during the run, which stops the model "
                 + "mid-answer -- keep the lid open until it finishes."
        }
        if failed.allSatisfy({ $0.outcome == .empty }) {
            return what + " The model ran but came back with nothing usable."
        }
        return what + " The model stopped responding partway -- check that Ollama is "
             + "running (Settings shows its status)."
    }
}

/// Explains what a run will produce and roughly how long it will take.
/// This is the one action in the app long enough that the estimate can
/// change the decision, which is why it states one.
struct WriteOverviewsSheet: View {
    let noteCount: Int
    let mentionsMath: Bool
    let generator: OverviewOrigin?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var estimate: String {
        // Measured, not hoped: qwen3.5 on an M-series laptop takes three to
        // five minutes a note -- a plan, a call per section, figures, and a
        // diagram. The old "30 seconds a note" promised a two-minute run
        // that took forty.
        let seconds = noteCount * 240
        let minutes = seconds / 60
        if minutes < 90 { return "roughly \(minutes) minutes" }
        let hours = (Double(minutes) / 60 * 2).rounded() / 2
        return "roughly \(hours.formatted(.number.precision(.fractionLength(0...1)))) hours"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 26))
                    .foregroundStyle(GRASPColor.accent)
                Text(noteCount == 1 ? "Write an overview?" : "Write overviews for \(noteCount) notes?")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
            }

            VStack(alignment: .leading, spacing: 10) {
                effect("list.bullet", "Key takeaways, the definitions worth knowing, and the "
                                     + "note's own outline.")
                effect("point.topleft.down.curvedto.point.bottomright.up",
                       "A concept map, where the note has relationships worth drawing.")
                effect("clock", "Takes \(estimate). You can keep using the rest of GRASP while "
                                + "it runs, and stop it at any time.")
                effect("laptopcomputer", "Keep the lid open. GRASP stops your Mac from dozing off "
                                         + "while it works, but closing the lid still puts it to "
                                         + "sleep and interrupts the model.")
                if mentionsMath {
                    effect("function", "Some of these notes contain formulas. They'll be shown as "
                                       + "written rather than typeset.")
                }
                if generator == .appleOnDevice {
                    // Said before the run, not after. The on-device model is
                    // a genuine fallback rather than an equal one, and
                    // finding that out from a thin result is worse than
                    // being told while the choice is still open.
                    effect("exclamationmark.triangle",
                           "Using Apple's on-device model, which writes noticeably thinner "
                           + "overviews and splits long notes into more pieces. Starting Ollama "
                           + "gives markedly better results.")
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(noteCount == 1 ? "Write It" : "Write Them", action: onConfirm)
                    .buttonStyle(GRASPProminentButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(GRASPColor.canvas)
    }

    private func effect(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(GRASPColor.accent)
                .frame(width: 16)
            Text(text)
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// "On this page": every lesson's section headings, as jump links.
///
/// Because the headings are claims, this list doubles as a one-glance
/// summary of the whole deck -- reading down it is reading the argument of
/// the lecture. That's the other reason the headings are written as
/// sentences rather than topics.
private struct LessonContents: View {
    let entries: [RenderedOverview]
    let onJump: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("On this page")
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(GRASPColor.textTertiary)

                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        // With several notes, each lesson's title leads its
                        // own group; with one, the page title already says it.
                        if entries.count > 1 {
                            link(entry.title, anchor: entry.id, isTitle: true)
                        }
                        ForEach(entry.sections) { section in
                            link(section.heading, anchor: section.id, isTitle: false)
                        }
                        if !entry.takeaways.isEmpty {
                            link("Key takeaways", anchor: "\(entry.materialId)#takeaways", isTitle: false)
                        }
                        if entry.diagram != nil || entry.mermaidSource != nil {
                            link("How it all fits together", anchor: "\(entry.materialId)#map", isTitle: false)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private func link(_ text: String, anchor: String, isTitle: Bool) -> some View {
        Button {
            onJump(anchor)
        } label: {
            Text(text)
                .font(.system(size: 12, weight: isTitle ? .semibold : .regular))
                .foregroundStyle(isTitle ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
    }
}
