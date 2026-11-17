import Foundation
import GRASPCore
import SwiftCrossUI

/// A deck's Questions tab, after the Mac's `QuestionsTab`: the deck's saved
/// questions, each with where it came from, what kind it is, its meter and
/// how it did lately. AI drafts wait under "To review" and stay on this
/// device until approved. Rows are kept light (no menu or button on a row,
/// 15 to a page, as on the Cards tab): a click opens the question's window,
/// which edits, approves, suspends, moves, copies and deletes it.
struct QuestionsTab: View {
    let library: Library
    let scope: DeckScope
    /// Whether a model can write questions (Ollama up, or the stand-in).
    let canGenerate: Bool

    @State var filter: QuestionFilter = .all
    @State var shown = QuestionsTab.pageSize
    /// nil when not selecting; otherwise the questions ticked so far.
    @State var selection: Set<String>?
    @State var sheet: QuestionSheet?
    /// What the last approve, move or copy did.
    @State var notice: String?
    /// Why a draft stayed under To review, by question id.
    @State var notApproved: [String: String] = [:]
    @State var confirmingBulkDelete = false

    static let pageSize = 15

    enum QuestionFilter: Equatable { case all, review }

    var body: some View {
        let listing = library.questionListing(inDecks: scope.deckIds)
        let questions = listing.questions
        let draftCount = questions.filter { $0.statusKind == .draft }.count
        // A filter with nothing left in it falls back to All without a write.
        let current: QuestionFilter = draftCount == 0 ? .all : filter
        let ordered = Self.ordered(questions, filter: current)
        VStack(alignment: .leading, spacing: 16) {
            if let run = library.lastQuestionDraftRun, Set(run.deckIds) == Set(scope.deckIds) {
                runBanner(run)
            }
            if let notice {
                noticeBar(notice)
            }
            if let selection {
                selectionBar(selection, questions: questions, ordered: ordered)
            } else {
                listBar(total: questions.count, drafts: draftCount, filter: current, hasQuestions: !questions.isEmpty)
            }
            if questions.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ordered.prefix(shown)), id: \.id) { question in
                        QuestionRow(question: question, history: listing.history[question.id],
                                    state: listing.states[question.id] ?? UnderstandingState.of(level: nil),
                                    noteTitle: question.materialId.flatMap { listing.noteTitles[$0] },
                                    notApproved: notApproved[question.id],
                                    selected: selection.map { $0.contains(question.id) }) {
                            if var picked = selection {
                                if picked.contains(question.id) { picked.remove(question.id) } else { picked.insert(question.id) }
                                selection = picked
                            } else {
                                sheet = .edit(question)
                            }
                        }
                    }
                }
                if ordered.count > shown {
                    HStack(spacing: 10) {
                        Text("Showing \(shown) of \(ordered.count)")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textTertiary)
                        GRASPButton("Show \(min(Self.pageSize, ordered.count - shown)) more") { shown += Self.pageSize }
                    }
                }
            }
        }
        .watch(scope.id) {
            // Only what differs: each @State write redraws the whole list.
            if shown != Self.pageSize { shown = Self.pageSize }
            if selection != nil { selection = nil }
            if notice != nil { notice = nil }
            if !notApproved.isEmpty { notApproved = [:] }
            if filter != .all { filter = .all }
        }
        .watch(library.lastQuestionDraftRun?.id) {
            // A run that wrote drafts opens To review, as on the Mac.
            if let run = library.lastQuestionDraftRun, run.outcome.saved > 0,
               Set(run.deckIds) == Set(scope.deckIds), filter != .review {
                filter = .review
                shown = Self.pageSize
            }
        }
        .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })) {
            sheetContent
        }
    }

    /// Drafts first, then active questions, suspended ones last; otherwise
    /// the bank's order.
    private static func ordered(_ questions: [TestQuestion], filter: QuestionFilter) -> [TestQuestion] {
        let matching = filter == .review ? questions.filter { $0.statusKind == .draft } : questions
        let rank: (TestQuestion) -> Int = { $0.statusKind == .draft ? 0 : ($0.statusKind == .active ? 1 : 2) }
        return matching.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    // MARK: Bars

    /// The filter pills when there are drafts, Approve all under To review,
    /// Select, and the Add menu.
    private func listBar(total: Int, drafts: Int, filter current: QuestionFilter, hasQuestions: Bool) -> some View {
        HStack(spacing: 10) {
            if drafts > 0 {
                SegmentedChoice(options: [QuestionFilter.all, .review], selection: current,
                                label: { $0 == .all ? "All \(total)" : "To review \(drafts)" }) {
                    if filter != $0 { filter = $0 }
                    shown = Self.pageSize
                }
            }
            Spacer()
            if current == .review {
                GRASPButton("Approve all") { approveAll() }
            }
            if hasQuestions {
                GRASPButton("Select") {
                    selection = []
                    confirmingBulkDelete = false
                }
            }
            Menu("+ Add") {
                Button("Write a question\u{2026}") { sheet = .write }
                Button("\u{2726} Generate test questions with AI\u{2026}") { sheet = .generate }
            }
            .fixedSize()
        }
    }

    /// Select mode: Done, the count, All or None, and one Actions menu.
    private func selectionBar(_ picked: Set<String>, questions: [TestQuestion], ordered: [TestQuestion]) -> some View {
        let chosen = ordered.filter { picked.contains($0.id) }
        let allPicked = !ordered.isEmpty && picked.count == ordered.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                GRASPButton("Done") { endSelecting() }
                Text(picked.isEmpty ? "Tick questions" : "\(picked.count) selected")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                    .fixedSize()
                Spacer()
                QuietLink(title: allPicked ? "None" : "All") {
                    selection = allPicked ? [] : Set(ordered.map(\.id))
                }
                if !picked.isEmpty {
                    Menu("Actions") {
                        if chosen.contains(where: { $0.statusKind == .draft }) {
                            Button("Approve") { approveSelected(chosen) }
                        }
                        if courseDecks.count > 1 {
                            Button("Move to deck\u{2026}") { sheet = .pick(.move, chosen.map(\.id)) }
                            Button("Copy to deck\u{2026}") { sheet = .pick(.copy, chosen.map(\.id)) }
                        }
                        if chosen.contains(where: { $0.statusKind == .active }) {
                            Button("Suspend") {
                                library.setQuestionStatus(chosen.filter { $0.statusKind == .active }.map(\.id), to: .suspended)
                                endSelecting()
                            }
                        }
                        if chosen.contains(where: { $0.statusKind == .suspended }) {
                            Button("Reactivate") {
                                library.setQuestionStatus(chosen.filter { $0.statusKind == .suspended }.map(\.id), to: .active)
                                endSelecting()
                            }
                        }
                        Button("Delete\u{2026}") { confirmingBulkDelete = true }
                    }
                    .fixedSize()
                }
            }
            if confirmingBulkDelete && !picked.isEmpty {
                HStack(spacing: 8) {
                    Text("Delete \(picked.count) question\(picked.count == 1 ? "" : "s")? They will no longer appear in tests. Past test results are kept.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.rejected)
                    Spacer()
                    GRASPButton("Keep") { confirmingBulkDelete = false }
                    GRASPButton("Delete", kind: .destructive) {
                        library.deleteQuestions(chosen.map(\.id))
                        endSelecting()
                    }
                }
            }
        }
        .padding(12)
        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
    }

    private func endSelecting() {
        selection = nil
        confirmingBulkDelete = false
    }

    // MARK: Banners

    private func runBanner(_ run: QuestionDraftRun) -> some View {
        let failed = run.failure != nil
        let text = run.failure ?? ("Wrote \(run.outcome.saved) draft question\(run.outcome.saved == 1 ? "" : "s"). They're under To review."
                                   + (run.outcome.wasCancelled ? " Stopped early." : ""))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(failed ? "!" : "\u{2713}")
                    .font(GRASPFont.rowTitle.weight(.bold))
                    .foregroundColor(failed ? GRASPColor.rejected : GRASPColor.success)
                Text(text)
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textPrimary)
                Spacer()
                QuietLink(title: "Dismiss") { library.lastQuestionDraftRun = nil }
            }
            if let summary = run.outcome.droppedSummary {
                HStack(spacing: 10) {
                    Text(summary).font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary)
                    Text("See why")
                        .font(Font.system(size: 12.5, weight: .semibold))
                        .foregroundColor(GRASPColor.textPrimary)
                        .onTapGesture { sheet = .drops(run.outcome.drops) }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(failed ? GRASPColor.rejectedSoft : GRASPColor.successSoft)
        .cornerRadius(GRASPRadius.inner)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\u{2713}").font(GRASPFont.rowTitle.weight(.bold)).foregroundColor(GRASPColor.success)
            Text(text).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
            Spacer()
            QuietLink(title: "Dismiss") { notice = nil }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
    }

    /// The Mac's empty state: one line, one quiet button (Study keeps the
    /// page's yellow).
    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("Cards are for remembering. Questions are for practicing like the exam.")
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textSecondary)
            GRASPButton("Write a question") { sheet = .write }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    // MARK: Approving

    private func approveAll() {
        let result = library.approveAllQuestions(inDecks: scope.deckIds)
        notApproved = Dictionary(result.skipped.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
        notice = Self.approvedLine(result.approved, kept: result.skipped.count)
    }

    private func approveSelected(_ chosen: [TestQuestion]) {
        var reasons: [String: String] = [:]
        var approved = 0
        for question in chosen where question.statusKind == .draft {
            if QuestionBank.needsAnswerCheck(question) {
                reasons[question.id] = QuestionBank.checkReason(question)
            } else if let why = library.approveQuestion(question.id) {
                reasons[question.id] = why
            } else {
                approved += 1
            }
        }
        notApproved = reasons
        notice = Self.approvedLine(approved, kept: reasons.count)
        selection = Set(reasons.keys)
    }

    static func approvedLine(_ approved: Int, kept: Int) -> String {
        "Approved \(approved) question\(approved == 1 ? "" : "s")."
            + (kept == 0 ? "" : " \(kept) stayed under To review because \(kept == 1 ? "it" : "they") failed a check.")
    }

    // MARK: Sheets

    /// Where a new question can go, and where questions can move: this
    /// course's decks.
    private var courseDecks: [Choice] {
        let courseId = library.courseId(of: scope)
        return library.decks.filter { $0.courseId == courseId }.map { Choice(id: $0.id, description: $0.name) }
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch sheet {
        case .write:
            QuestionEditor(library: library, decks: courseDecks, editing: nil,
                           defaultDeckId: scope.deckIds.count == 1 ? scope.deckIds[0] : nil,
                           close: { sheet = nil }, then: { reopen($0) })
        case .edit(let question):
            QuestionEditor(library: library, decks: courseDecks, editing: question, defaultDeckId: nil,
                           close: { sheet = nil }, then: { reopen($0) }) { why in
                if let why { notApproved[question.id] = why } else { notApproved[question.id] = nil }
            }
        case .generate:
            GenerateQuestionsSheet(library: library, deckIds: scope.deckIds, courseId: library.courseId(of: scope),
                                   canGenerate: canGenerate) { sheet = nil }
        case .pick(let mode, let ids):
            QuestionDeckPicker(mode: mode, count: ids.count,
                               decks: courseDecks.filter { mode == .copy || !currentDecks(of: ids).contains($0.id ?? "") },
                               close: { sheet = nil }) { deck in finishPick(mode, ids: ids, deck: deck) }
        case .drops(let drops):
            DroppedQuestionsSheet(drops: drops) { sheet = nil }
        case nil:
            EmptyView()
        }
    }

    /// A sheet can't open another on Windows: close this one, then open the
    /// next once it has gone.
    private func reopen(_ next: QuestionSheet) {
        sheet = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            sheet = next
        }
    }

    private func currentDecks(of ids: [String]) -> Set<String> {
        Set(library.questionListing(inDecks: scope.deckIds).questions.filter { ids.contains($0.id) }.map(\.deckId))
    }

    private func finishPick(_ mode: DeckPickMode, ids: [String], deck: Choice) {
        guard let deckId = deck.id else { return }
        let noun = { (count: Int) in count == 1 ? "question" : "questions" }
        switch mode {
        case .move:
            notice = library.moveQuestions(ids, toDeck: deckId).map { "Moved \($0.changed) \(noun($0.changed)) to \(deck.description)." }
                ?? "That deck is gone."
        case .copy:
            notice = library.copyQuestions(ids, toDeck: deckId).map {
                "Copied \($0.changed) \(noun($0.changed)) to \(deck.description)."
                    + ($0.skippedRepeats > 0 ? " \($0.skippedRepeats) already there." : "")
            } ?? "That deck is gone."
        }
        sheet = nil
        endSelecting()
    }
}

enum DeckPickMode { case move, copy }

enum QuestionSheet {
    case write
    case edit(TestQuestion)
    case generate
    case pick(DeckPickMode, [String])
    case drops([DraftDrop])
}

// MARK: - Row

/// One saved question: the prompt (two lines, a draft in full), the source
/// badge and its kind, then its meter and history (a draft names the note
/// it came from). A tap opens it, or ticks it in select mode.
private struct QuestionRow: View {
    let question: TestQuestion
    let history: QuestionHistory?
    let state: UnderstandingState
    let noteTitle: String?
    let notApproved: String?
    /// nil when not selecting.
    let selected: Bool?
    let open: () -> Void

    private var isDraft: Bool { question.statusKind == .draft }
    private var isSuspended: Bool { question.statusKind == .suspended }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                if let selected {
                    TickBox(isOn: selected, round: true).padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.promptText.isEmpty ? "(No text)" : MathNotation.prettify(question.promptText))
                        .font(Font.system(size: 14.5, weight: .medium))
                        .foregroundColor(isSuspended ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                        .lineLimit(isDraft ? nil : 2)
                    HStack(spacing: 8) {
                        SourceBadge(source: question.sourceKind)
                        Text(question.summaryLine)
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textTertiary)
                            .lineLimit(1)
                    }
                    if isDraft, let notApproved {
                        Text("Not approved. " + notApproved)
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.rejected)
                    }
                    if isDraft {
                        Text(noteTitle.map { "From \($0)" } ?? "Draft")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textTertiary)
                    } else {
                        HStack(spacing: 8) {
                            PipMeter(state: state, suspended: isSuspended)
                            Text(history?.line ?? "Not asked yet")
                                .font(GRASPFont.meta)
                                .foregroundColor(GRASPColor.textTertiary)
                            if isSuspended {
                                Text("Suspended")
                                    .font(Font.system(size: 12.5, weight: .medium))
                                    .foregroundColor(GRASPColor.rejected)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 12)
            HairlineRule()
        }
        .onTapGesture(perform: open)
    }
}

extension TestQuestion {
    /// "Multiple choice", "Fill in the blanks · C++": the kind, in words.
    /// A concepts question needs no subject beside its kind.
    var summaryLine: String {
        if let code = question { return "\(code.kind.label) \u{00B7} \(code.language.label)" }
        if let problem {
            return problem.subject == .concepts ? problem.kind.label : "\(problem.kind.label) \u{00B7} \(problem.subject.label)"
        }
        return kind
    }
}

/// Where a question came from. The sparkle means AI, and only AI.
struct SourceBadge: View {
    let source: QuestionSource

    var body: some View {
        HStack(spacing: 4) {
            if source == .ai { AIGlyph(size: 9) }
            Text(source.label)
                .font(Font.system(size: 11, weight: .semibold))
                .foregroundColor(GRASPColor.textSecondary)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .edged(fill: GRASPColor.inset, edge: GRASPColor.hairline, radius: 9)
    }
}

// MARK: - Editor

/// Write or edit a question, after the Mac's `QuestionEditorSheet`: multiple
/// choice (2 to 6 choices, one right), written (an answer and other wordings
/// that count), or true / false, with an optional card it helps. Editing
/// also approves, suspends, moves, copies or deletes it.
struct QuestionEditor: View {
    let library: Library
    let decks: [Choice]
    let editing: TestQuestion?
    let close: () -> Void
    /// Close this sheet and open another (the deck picker).
    let then: (QuestionSheet) -> Void
    /// After Approve: why it stayed a draft, or nil.
    var approved: (String?) -> Void = { _ in }

    @State var input: UserQuestionInput
    @State var deckId: String?
    @State var saveError: String?
    @State var confirmingDelete = false
    @State var approveProblem: String?

    init(library: Library, decks: [Choice], editing: TestQuestion?, defaultDeckId: String?,
         close: @escaping () -> Void, then: @escaping (QuestionSheet) -> Void,
         approved: @escaping (String?) -> Void = { _ in }) {
        self.library = library
        self.decks = decks
        self.editing = editing
        self.close = close
        self.then = then
        self.approved = approved
        _input = State(wrappedValue: editing.flatMap { UserQuestionInput($0) } ?? UserQuestionInput())
        _deckId = State(wrappedValue: editing?.deckId ?? defaultDeckId ?? decks.first?.id)
    }

    private var isEditing: Bool { editing != nil }
    /// Code and math questions can't be written by hand; they open read-only.
    private var canEdit: Bool { editing.map { UserQuestionInput($0) != nil } ?? true }

    var body: some View {
        GRASPSheet(eyebrow: "Question", title: isEditing ? "Edit question" : "Write a question", width: 540,
                   confirm: { if !canEdit { close() } else if input.problem == nil && (isEditing || deckId != nil) { save() } },
                   multiline: true) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if canEdit { fields } else { readOnly }
                }
                .frame(width: 480.0, alignment: .leading)
                .padding(.trailing, 12)
            }
            .frame(height: 440.0)
            if let editing { actions(editing) }
        } footer: {
            if canEdit, let problem = input.problem, !input.prompt.isEmpty || input.kind != .multipleChoice {
                Text(problem).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            } else if let saveError {
                Text(saveError).font(GRASPFont.meta).foregroundColor(GRASPColor.rejected)
            }
            Spacer()
            if canEdit {
                GRASPButton("Cancel") { close() }
                GRASPButton(isEditing ? "Save" : "Add question", kind: .primary) { save() }
                    .disabled(input.problem != nil || (!isEditing && deckId == nil))
            } else {
                GRASPButton("Done", kind: .primary) { close() }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        if !isEditing {
            SegmentedChoice(options: UserQuestionInput.writableKinds, selection: input.kind, label: \.label) {
                if input.kind != $0 { input.kind = $0 }
            }
        } else {
            Text(input.kind.label).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
        }
        if !isEditing && decks.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Deck")
                Picker(of: decks, selection: Binding(
                    get: { decks.first { $0.id == deckId } },
                    set: { choice in if choice?.id != deckId { deckId = choice?.id } }
                ))
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(input.kind == .trueFalse ? "Statement" : "Question")
            TextEditor(text: Binding(get: { input.prompt }, set: { input.prompt = $0 }).changesOnly())
                .frame(height: 72.0)
                .padding(1)
                .edged(fill: GRASPColor.inset, edge: GRASPColor.hairlineStrong, radius: 6)
        }
        switch input.kind {
        case .multipleChoice: choiceFields
        case .written: writtenFields
        default: trueFalseFields
        }
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Why (optional)")
            TextEditor(text: Binding(get: { input.explanation }, set: { input.explanation = $0 }).changesOnly())
                .frame(height: 52.0)
                .padding(1)
                .edged(fill: GRASPColor.inset, edge: GRASPColor.hairlineStrong, radius: 6)
        }
        cardLink
    }

    private var readOnly: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editing?.summaryLine ?? "").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            Text(MathNotation.prettify(editing?.promptText ?? ""))
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textPrimary)
            if let code = editing?.question {
                CodeBlockView(code: code.code)
            }
            Text("This kind of question is checked by running it, so it is edited on the Mac.")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
        }
    }

    // MARK: Fields by kind

    private var choiceFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Choices (click the circle beside the right one)")
            ForEach(Array(input.choices.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    Text(input.correct == index ? "\u{2713}" : " ")
                        .font(Font.system(size: 12, weight: .bold))
                        .foregroundColor(GRASPColor.ink)
                        .frame(width: 20.0, height: 20.0)
                        .background(input.correct == index ? GRASPColor.success : GRASPColor.hairlineStrong)
                        .cornerRadius(10)
                        .onTapGesture { if input.correct != index { input.correct = index } }
                    TextField("Choice \(index + 1)", text: Binding(
                        get: { index < input.choices.count ? input.choices[index] : "" },
                        set: { if index < input.choices.count { input.choices[index] = $0 } }
                    ).changesOnly())
                    .frame(width: 400.0)
                    if input.choices.count > UserQuestionInput.choiceRange.lowerBound {
                        Text("\u{2212}")
                            .font(GRASPFont.title)
                            .foregroundColor(GRASPColor.textTertiary)
                            .frame(width: 24.0)
                            .onTapGesture { removeChoice(index) }
                    }
                }
            }
            if input.choices.count < UserQuestionInput.choiceRange.upperBound {
                GRASPButton("+ Add a choice") { input.choices.append("") }
            }
        }
    }

    private func removeChoice(_ index: Int) {
        guard index < input.choices.count else { return }
        input.choices.remove(at: index)
        if input.correct == index { input.correct = 0 } else if input.correct > index { input.correct -= 1 }
    }

    private var writtenFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Answer")
                TextField("The answer", text: Binding(get: { input.answer }, set: { input.answer = $0 }).changesOnly())
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Other wordings that count (optional, one per line)")
                TextEditor(text: Binding(
                    get: { input.accepted.joined(separator: "\n") },
                    set: { input.accepted = $0.components(separatedBy: "\n") }
                ).changesOnly())
                .frame(height: 52.0)
                .padding(1)
                .edged(fill: GRASPColor.inset, edge: GRASPColor.hairlineStrong, radius: 6)
                Text("Typed answers are checked by meaning too, so small differences in wording are fine.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
        }
    }

    private var trueFalseFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("The statement is")
            SegmentedChoice(options: [true, false], selection: input.isTrue, label: { $0 ? "True" : "False" }) {
                if input.isTrue != $0 { input.isTrue = $0 }
            }
        }
    }

    /// "Helps this card": answering the question moves that card's meter,
    /// never its flashcard schedule. The drop-down gets a fresh node when the
    /// deck changes, since a WinUI drop-down mustn't lose options in place.
    @ViewBuilder
    private var cardLink: some View {
        let cards = deckId.map { library.linkableCards(inDecks: [$0]) } ?? []
        if !cards.isEmpty {
            let options = [Choice(id: nil, description: "No card")]
                + cards.map { Choice(id: $0.id, description: Self.short($0.front)) }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Helps this card (optional)")
                ForEach([deckId ?? ""], id: \.self) { _ in
                    Picker(of: options, selection: Binding(
                        get: { options.first { $0.id == input.cardId } ?? options[0] },
                        set: { choice in if choice?.id != input.cardId { input.cardId = choice?.id } }
                    ))
                }
                Text("Answering it moves that card's understanding meter. It never changes when the card comes back in flashcards.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
        }
    }

    private static func short(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 70 ? String(line.prefix(69)) + "\u{2026}" : line
    }

    // MARK: Actions on a saved question

    private func actions(_ question: TestQuestion) -> some View {
        let isDraft = question.statusKind == .draft
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isDraft {
                    GRASPButton("Approve") {
                        let why = QuestionBank.needsAnswerCheck(question) ? QuestionBank.checkReason(question)
                            : library.approveQuestion(question.id)
                        approved(why)
                        if let why { approveProblem = why } else { close() }
                    }
                } else {
                    GRASPButton(question.statusKind == .suspended ? "Reactivate" : "Suspend") {
                        library.setQuestionStatus([question.id], to: question.statusKind == .suspended ? .active : .suspended)
                        close()
                    }
                }
                if decks.count > 1 {
                    GRASPButton("Move to deck\u{2026}") { then(.pick(.move, [question.id])) }
                    GRASPButton("Copy to deck\u{2026}") { then(.pick(.copy, [question.id])) }
                }
                Spacer()
                GRASPButton(isDraft ? "Delete" : "Delete\u{2026}", kind: .destructive) {
                    // A draft was never approved: deleting it needs no second question.
                    if isDraft {
                        library.deleteQuestions([question.id])
                        close()
                    } else {
                        confirmingDelete = true
                    }
                }
            }
            if let approveProblem {
                Text("Not approved. " + approveProblem).font(GRASPFont.meta).foregroundColor(GRASPColor.rejected)
            }
            if confirmingDelete {
                HStack(spacing: 8) {
                    Text("Delete this question? It will no longer appear in tests. Past test results are kept.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.rejected)
                    Spacer()
                    GRASPButton("Keep") { confirmingDelete = false }
                    GRASPButton("Delete", kind: .destructive) {
                        library.deleteQuestions([question.id])
                        close()
                    }
                }
            }
        }
    }

    private func save() {
        saveError = nil
        do {
            if let editing {
                try library.updateQuestion(editing.id, with: input)
            } else if let deckId {
                try library.saveQuestion(input, deckId: deckId)
            }
            close()
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? "Couldn't save the question."
        }
    }
}

// MARK: - Moving and copying

/// Which deck of the same course to move or copy questions to.
struct QuestionDeckPicker: View {
    let mode: DeckPickMode
    let count: Int
    let decks: [Choice]
    let close: () -> Void
    let pick: (Choice) -> Void

    var body: some View {
        let noun = "\(count) question\(count == 1 ? "" : "s")"
        GRASPSheet(eyebrow: "Questions", title: mode == .move ? "Move to deck" : "Copy to deck",
                   message: mode == .move ? "\(noun) will move, keeping their history."
                                          : "\(noun) will be copied. The copies start with no history.",
                   width: 460) {
            if decks.isEmpty {
                Text("There is no other deck in this course.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(decks, id: \.description) { deck in
                            HStack {
                                Text(deck.description).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                                Spacer()
                                Text("\u{203A}").font(GRASPFont.title).foregroundColor(GRASPColor.textTertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(GRASPColor.inset)
                            .cornerRadius(GRASPRadius.inner)
                            .onTapGesture { pick(deck) }
                        }
                    }
                    .frame(width: 400.0)
                    .padding(.trailing, 12)
                }
                .frame(height: min(360.0, Double(decks.count) * 46 + 4))
            }
        } footer: {
            Spacer()
            GRASPButton("Cancel") { close() }
        }
    }
}

// MARK: - Generate with AI

/// "Generate test questions with AI", after the Mac's `GenerateQuestionsSheet`:
/// pick the notes, how many and the kinds. What comes back lands as drafts
/// under To review. Code and math kinds need the Mac, which checks them by
/// running them, so Windows writes multiple choice and written ones only.
struct GenerateQuestionsSheet: View {
    let library: Library
    let deckIds: [String]
    let courseId: String?
    let canGenerate: Bool
    let close: () -> Void

    @State var notes: [DraftNote]
    @State var selected: Set<String>
    @State var count = 10
    @State var multipleChoice = true
    @State var written = true

    init(library: Library, deckIds: [String], courseId: String?, canGenerate: Bool, close: @escaping () -> Void) {
        self.library = library
        self.deckIds = deckIds
        self.courseId = courseId
        self.canGenerate = canGenerate
        self.close = close
        let notes = library.draftNotes(inDecks: deckIds)
        _notes = State(wrappedValue: notes)
        _selected = State(wrappedValue: Set(notes.map(\.id)))
    }

    private var chosen: [DraftNote] { notes.filter { selected.contains($0.id) } }
    private var needsMac: Bool { chosen.contains { $0.subject != .concepts } }
    private var running: Bool { !(library.cardJob(forCourse: courseId)?.isFinished ?? true) }
    private var canStart: Bool { canGenerate && !running && !selected.isEmpty && (multipleChoice || written) }

    var body: some View {
        GRASPSheet(eyebrow: "Generate with AI", title: "Generate test questions",
                   message: "The AI writes draft questions from your notes. They wait under To review on the Questions tab until you approve them.",
                   ai: true, width: 540, confirm: { if canStart { start() } }) {
            notices
            notesGroup
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("How many").font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                    Spacer()
                    GRASPButton("\u{2212}") { count = max(5, count - 5) }
                    Text("\(count)").font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary).frame(width: 36.0)
                    GRASPButton("+") { count = min(30, count + 5) }
                }
                HairlineRule()
                FieldLabel("Question types")
                HStack(spacing: 6) {
                    Pill(title: "Multiple choice", isOn: multipleChoice) { multipleChoice.toggle() }
                    Pill(title: "Written", isOn: written) { written.toggle() }
                }
                note("True / False is not written by AI yet. Write these yourself.", width: 460)
                if needsMac {
                    note("Code and math questions are written on the Mac, which checks them by running them. Here these notes get multiple choice and written questions.", width: 460)
                }
            }
            .padding(14)
            .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
        } footer: {
            Spacer()
            GRASPButton("Cancel") { close() }
            GRASPButton("Generate test questions", kind: .primary) { start() }
                .disabled(!canStart)
        }
    }

    /// Which model and the cost come first, so they are seen before the button.
    @ViewBuilder
    private var notices: some View {
        if !canGenerate {
            note("No AI model is set up. Settings has the setup.", color: GRASPColor.rejected)
        } else {
            let model = StubHooks.enabled("GRASP_STUB_QUESTIONS") ? "the stand-in writer"
                : ((Library.lastLocalModel ?? nil) ?? "the local model")
            let requests = AIQuotaEstimate.codeQuestionRequests(count: count)
            note("Written by \(model) on this PC. About \(requests) request\(requests == 1 ? "" : "s"). Nothing runs until you press Generate test questions.")
        }
        if running {
            note("An AI job is already running for this course. Wait for it to finish, or stop it.")
        }
    }

    /// A muted line at a fixed width, so it wraps instead of being cut to "...".
    private func note(_ text: String, color: Color = GRASPColor.textTertiary, width: Double = 490) -> some View {
        Text(text)
            .font(GRASPFont.meta)
            .foregroundColor(color)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var notesGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FieldLabel("Notes to use")
                Spacer()
                if notes.count > 1 {
                    QuietLink(title: selected.count == notes.count ? "Select none" : "Select all") {
                        selected = selected.count == notes.count ? [] : Set(notes.map(\.id))
                    }
                }
            }
            if notes.isEmpty {
                Text("This deck has no source notes to write questions from.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(notes, id: \.id) { note in
                            let isOn = selected.contains(note.id)
                            HStack(spacing: 10) {
                                TickBox(isOn: isOn)
                                Text(note.title)
                                    .font(GRASPFont.body)
                                    .foregroundColor(GRASPColor.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .onTapGesture {
                                if isOn { selected.remove(note.id) } else { selected.insert(note.id) }
                            }
                        }
                    }
                    .frame(width: 440.0)
                    .padding(.trailing, 12)
                }
                .frame(height: min(200.0, Double(notes.count) * 32 + 4))
            }
        }
        .padding(14)
        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
    }

    private func start() {
        let request = QuestionDrafter.Request(deckIds: deckIds, materialIds: selected, count: count,
                                              multipleChoice: multipleChoice, written: written,
                                              codeKinds: [], mathKinds: [])
        library.draftQuestions(request, courseId: courseId)
        close()
    }
}

// MARK: - Dropped items

/// Every question the last run threw away, and why.
struct DroppedQuestionsSheet: View {
    let drops: [DraftDrop]
    let close: () -> Void

    var body: some View {
        GRASPSheet(eyebrow: "Questions", title: "What was dropped",
                   message: "These were not kept. Each failed a check, repeated a question you already have, or needs something from you.",
                   confirm: { close() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(drops, id: \.id) { drop in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(drop.text).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                            Text(Self.reasonLine(drop)).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                        }
                        .padding(12)
                        .frame(width: 446.0, alignment: .leading)
                        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
                    }
                }
                .padding(.trailing, 12)
            }
            .frame(height: min(400.0, Double(drops.count) * 84 + 4))
        } footer: {
            Spacer()
            GRASPButton("Done", kind: .primary) { close() }
        }
    }

    private static func reasonLine(_ drop: DraftDrop) -> String {
        let label = drop.reason.label(1)
        return label.prefix(1).uppercased() + label.dropFirst() + ". " + drop.detail
    }
}
