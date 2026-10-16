import SwiftUI
import GRASPCore

/// A deck's Questions tab: the deck's saved questions, each with where it
/// came from, what kind it is, and how it did lately. Questions are for
/// practicing like the exam; cards are for remembering. No Learn ladder or
/// meter here. AI-written questions arrive as drafts under "To review", and
/// stay on this device until approved. Shared by the Mac and the iPhone.
struct QuestionsTab: View {
    @Environment(AppStore.self) private var store
    let deckIds: [String]
    let courseId: String?
    var query = ""
    /// Opens the editor for a new question (the Add menu sets it).
    @Binding var isWriting: Bool
    /// Opens "Generate questions with AI" (the Add menu sets it).
    @Binding var isGenerating: Bool
    /// The decks a new question can go in.
    let decks: [Deck]
    var scopeName = ""

    private enum Filter: Hashable { case all, review }

    @State private var questions: [TestQuestion] = []
    @State private var history: [String: QuestionHistory] = [:]
    @State private var noteTitles: [String: String] = [:]
    @State private var hasLoaded = false
    @State private var filter: Filter = .all
    @State private var editing: TestQuestion?
    @State private var pendingDelete: TestQuestion?
    @State private var approveMessage: String?
    /// Why a draft stayed under To review after Approve all or Approve.
    @State private var notApproved: [String: String] = [:]
    @State private var showingDrops = false

    #if DEBUG
    private var debugShow: String? { ProcessInfo.processInfo.environment["GRASP_QUESTIONS_SHOW"] }
    #endif

    private var drafts: [TestQuestion] { questions.filter { $0.statusKind == .draft } }
    private var jobKey: String { store.questionDraftJobKey(courseId: courseId) }
    private var run: AppStore.QuestionDraftRunResult? {
        store.lastQuestionDraftRun.flatMap { Set($0.deckIds) == Set(deckIds) ? $0 : nil }
    }

    private var shown: [TestQuestion] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var matching = needle.isEmpty ? questions : questions.filter { $0.promptText.lowercased().contains(needle) }
        if filter == .review { matching = matching.filter { $0.statusKind == .draft } }
        // Drafts first, then the rest; suspended questions sink to the bottom.
        let order: (TestQuestion) -> Int = { $0.statusKind == .draft ? 0 : ($0.statusKind == .active ? 1 : 2) }
        return matching.enumerated().sorted { (order($0.element), $0.offset) < (order($1.element), $1.offset) }.map(\.element)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let job = store.aiJob(jobKey) {
                AIProgressStrip(activity: job.activity, onStop: { store.stopAIJob(jobKey) },
                                stopHelp: "Stops now. Questions already written are kept as drafts.")
                    .padding(.horizontal, 18).padding(.top, 12)
            }
            if let run { runBanner(run).padding(.horizontal, 18).padding(.top, 12) }
            if let approveMessage {
                notice(approveMessage, icon: "checkmark.circle", tint: GRASPColor.success) { self.approveMessage = nil }
                    .padding(.horizontal, 18).padding(.top, 12)
            }
            if !drafts.isEmpty { filterBar.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4) }

            if hasLoaded && questions.isEmpty {
                QuestionsEmptyState { isWriting = true }
            } else if hasLoaded {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { question in
                        QuestionRow(
                            question: question, history: history[question.id],
                            noteTitle: question.materialId.flatMap { noteTitles[$0] },
                            notApprovedReason: notApproved[question.id],
                            onEdit: { editing = question },
                            onApprove: { approve(question) },
                            onSetStatus: { store.setQuestionStatus(question.id, to: $0) },
                            onDelete: {
                                // A draft was never approved: deleting it needs no second question.
                                if question.statusKind == .draft { store.deleteCodeQuestion(question.id) } else { pendingDelete = question }
                            }
                        )
                        Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                    }
                }
            }
        }
        .task(id: "\(store.revision)-\(deckIds.joined())") { load() }
        .task { store.addMissingChoicesInBackground() }
        .onChange(of: store.lastQuestionDraftRun) { _, new in
            if let new, new.outcome.saved > 0 { filter = .review }
            #if DEBUG
            if new != nil, debugShow == "drops" { showingDrops = true }
            #endif
        }
        #if DEBUG
        .task {
            // Screenshots only, with the canned writer on.
            guard StubHooks.enabled("GRASP_STUB_QUESTIONS"), debugShow == "approveall" || debugShow == "editdraft" else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if debugShow == "editdraft" {
                filter = .review
                editing = questions.first { $0.statusKind == .draft }
                return
            }
            filter = .review
            approveAll()
        }
        #endif
        .sheet(isPresented: $isWriting) { QuestionEditorSheet(decks: decks) }
        .sheet(isPresented: $isGenerating) {
            GenerateQuestionsSheet(deckIds: deckIds, courseId: courseId, scopeName: scopeName)
        }
        .sheet(isPresented: $showingDrops) {
            if let run { DroppedQuestionsSheet(drops: run.outcome.drops) }
        }
        .sheet(item: $editing, onDismiss: { notApproved = [:] }) { question in
            QuestionEditorSheet(decks: decks, editing: question)
        }
        .sheet(item: $pendingDelete) { question in
            ConfirmationSheet(
                icon: "trash", title: "Delete This Question?",
                message: "It will no longer appear in tests. Past test results are kept.",
                confirmTitle: "Delete"
            ) {
                CodeQuestionBankDeleter.delete(question.id, store: store)
            }
        }
    }

    // MARK: Filter and approving

    private var filterBar: some View {
        HStack(spacing: 8) {
            pill("All \(questions.count)", selected: filter == .all) { filter = .all }
            pill("To review \(drafts.count)", selected: filter == .review) { filter = .review }
            Spacer(minLength: 8)
            if filter == .review {
                Button("Approve all") { approveAll() }
                    .buttonStyle(GRASPQuietButton())
                    .help("Approves every draft that passes its checks. A draft that fails one stays here.")
            }
        }
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.graspUI(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(selected ? GRASPColor.surfaceRaised : GRASPColor.inset, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? GRASPColor.hairlineStrong : GRASPColor.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func approve(_ question: TestQuestion) {
        if let why = store.approveQuestion(question.id) {
            // The reason sits on the row itself, the same as after Approve all.
            notApproved[question.id] = why
        } else {
            notApproved[question.id] = nil
        }
    }

    private func approveAll() {
        let result = store.approveAllQuestions(inDecks: deckIds)
        notApproved = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.id, $0.reason) })
        var text = "Approved \(result.approved) question\(result.approved == 1 ? "" : "s")."
        if !result.skipped.isEmpty {
            text += " \(result.skipped.count) stayed under To review because \(result.skipped.count == 1 ? "it" : "they") failed a check."
        }
        approveMessage = text
    }

    // MARK: Banners

    private func runBanner(_ run: AppStore.QuestionDraftRunResult) -> some View {
        let failed = run.failure != nil
        let outcome = run.outcome
        let text: String = run.failure ?? ("Wrote \(outcome.saved) draft question\(outcome.saved == 1 ? "" : "s"). They're under To review."
                                          + (outcome.wasCancelled ? " Stopped early." : ""))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(failed ? GRASPColor.rejected : GRASPColor.success)
                Text(text)
                    .graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { store.lastQuestionDraftRun = nil } label: {
                    Image(systemName: "xmark").font(.graspUI(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(GRASPColor.textTertiary).help("Dismiss")
            }
            if let summary = outcome.droppedSummary {
                HStack(spacing: 8) {
                    Text(summary).graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                    Button("See why") { showingDrops = true }
                        .buttonStyle(.plain)
                        .font(.graspUI(size: 12, weight: .semibold))
                        .foregroundStyle(GRASPColor.textPrimary)
                        .underline()
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(failed ? GRASPColor.rejectedSoft : GRASPColor.successSoft,
                    in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
    }

    private func notice(_ text: String, icon: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark").font(.graspUI(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(GRASPColor.textTertiary).help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
    }

    private func load() {
        questions = store.savedQuestions(inDecks: deckIds)
        history = store.questionHistory(of: questions.map(\.id))
        noteTitles = store.noteTitles(forMaterials: Array(Set(questions.compactMap(\.materialId))))
        if drafts.isEmpty, filter == .review { filter = .all }
        hasLoaded = true
    }
}

/// Soft delete through the bank; the questions' test history stays.
enum CodeQuestionBankDeleter {
    @MainActor static func delete(_ id: String, store: AppStore) { store.deleteCodeQuestion(id) }
}

// MARK: - Dropped items

/// Every question the last run threw away, and why.
struct DroppedQuestionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let drops: [DraftDrop]

    /// A long list scrolls inside the sheet instead of growing past the
    /// window it opened over.
    private var sheetHeight: CGFloat? {
        #if os(macOS)
        let parent = NSApp.mainWindow?.contentLayoutRect.height ?? 820
        return min(640, max(360, parent - 40))
        #else
        return nil
        #endif
    }

    var body: some View {
        GRASPSheet(eyebrow: "Generate with AI", title: "What was dropped",
                   message: "These were written but not kept. Each failed a check or repeated a question you already have.",
                   icon: "tray", width: 520, height: sheetHeight) {
            #if os(macOS)
            ScrollView { dropList }
            #else
            dropList
            #endif
        } footer: {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private var dropList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(drops) { drop in
                VStack(alignment: .leading, spacing: 4) {
                    Text(drop.text).graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(reasonLine(drop))
                        .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .popupGroup(padding: 12)
            }
        }
    }

    private func reasonLine(_ drop: DraftDrop) -> String {
        let label = drop.reason.label(1)
        return label.prefix(1).uppercased() + label.dropFirst() + ". " + drop.detail
    }
}

// MARK: - Empty state

private struct QuestionsEmptyState: View {
    let onWrite: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.clipboard")
                .font(.graspUI(size: 26))
                .foregroundStyle(GRASPColor.textTertiary)
            Text("Cards are for remembering. Questions are for practicing like the exam.")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Button("Write a question", action: onWrite)
                .buttonStyle(GRASPQuietButton())
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
    }
}

// MARK: - Row

private struct QuestionRow: View {
    let question: TestQuestion
    let history: QuestionHistory?
    let noteTitle: String?
    var notApprovedReason: String? = nil
    let onEdit: () -> Void
    let onApprove: () -> Void
    let onSetStatus: (QuestionStatus) -> Void
    let onDelete: () -> Void

    private var canEdit: Bool { UserQuestionInput(question) != nil }
    private var isSuspended: Bool { question.statusKind == .suspended }
    private var isDraft: Bool { question.statusKind == .draft }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text(question.promptText.isEmpty ? "(No text)" : question.promptText)
                    .font(.graspUI(size: 14, weight: .medium))
                    .foregroundStyle(isSuspended ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                    // A draft is read in full before it is approved.
                    .lineLimit(isDraft ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // The same two lines for every row, at any width: where it
                // came from and what kind it is, then how it did lately (a
                // draft shows the note it was written from instead).
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        SourceBadge(source: question.sourceKind)
                        Text(question.summaryLine)
                            .font(.graspUI(size: 12))
                            .foregroundStyle(GRASPColor.textTertiary)
                            .lineLimit(1)
                    }
                    if isDraft, let notApprovedReason {
                        Label("Not approved. " + notApprovedReason, systemImage: "exclamationmark.circle")
                            .font(.graspUI(size: 12, weight: .medium))
                            .foregroundStyle(GRASPColor.rejected)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if isDraft {
                            Text(noteTitle.map { "From \($0)" } ?? "Draft")
                                .font(.graspUI(size: 12))
                                .foregroundStyle(GRASPColor.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(history?.line ?? "Not asked yet")
                                .font(.graspUI(size: 12))
                                .foregroundStyle(GRASPColor.textTertiary)
                                .monospacedDigit()
                        }
                        if isSuspended {
                            Label("Suspended", systemImage: "pause.circle")
                                .font(.graspUI(size: 12, weight: .medium))
                                .foregroundStyle(GRASPColor.rejected)
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            if isDraft {
                Button("Approve", action: onApprove)
                    .buttonStyle(GRASPQuietButton())
                    .help("Approve this question so tests can ask it")
            }
            QuestionRowMenu(
                canEdit: canEdit, isSuspended: isSuspended, isDraft: isDraft, onEdit: onEdit, onApprove: onApprove,
                onSuspend: { onSetStatus(.suspended) }, onReactivate: { onSetStatus(.active) }, onDelete: onDelete
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

private extension TestQuestion {
    /// "Multiple choice", "Fill in the blanks · C++": the kind, in words.
    /// A concepts question needs no subject beside its kind.
    var summaryLine: String {
        if let code = question { return "\(code.kind.label) · \(code.language.label)" }
        if let problem {
            return problem.subject == .concepts ? problem.kind.label : "\(problem.kind.label) · \(problem.subject.label)"
        }
        return kind
    }
}

/// Where a question came from. The sparkle means AI, and only AI.
struct SourceBadge: View {
    let source: QuestionSource

    var body: some View {
        HStack(spacing: 4) {
            if source == .ai {
                Image(systemName: AIGlyph.symbol)
                    .font(.graspUI(size: 9, weight: .semibold))
                    .foregroundStyle(GRASPColor.accent)
            }
            Text(source.label)
                .font(.graspUI(size: 11, weight: .semibold))
                .foregroundStyle(GRASPColor.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(GRASPColor.inset, in: Capsule())
        .overlay(Capsule().strokeBorder(GRASPColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source: \(source.label)")
    }
}

private struct QuestionRowMenu: View {
    let canEdit: Bool
    let isSuspended: Bool
    let isDraft: Bool
    let onEdit: () -> Void
    let onApprove: () -> Void
    let onSuspend: () -> Void
    let onReactivate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        #if os(macOS)
        IconMenu(help: "Question actions") {
            var items: [PillMenuItem] = []
            if isDraft { items.append(.action("Approve", systemImage: "checkmark.circle") { onApprove() }) }
            if canEdit { items.append(.action("Edit…", systemImage: "pencil") { onEdit() }) }
            if !isDraft {
                items.append(isSuspended
                    ? .action("Reactivate", systemImage: "play.circle") { onReactivate() }
                    : .action("Suspend", systemImage: "pause.circle",
                              help: "Keeps it, but it won't come up in tests") { onSuspend() })
            }
            items.append(.divider)
            items.append(.action(isDraft ? "Delete" : "Delete…", systemImage: "trash", destructive: true) { onDelete() })
            return items
        }
        #else
        Menu {
            if isDraft { Button { onApprove() } label: { Label("Approve", systemImage: "checkmark.circle") } }
            if canEdit { Button { onEdit() } label: { Label("Edit", systemImage: "pencil") } }
            if !isDraft {
                if isSuspended {
                    Button { onReactivate() } label: { Label("Reactivate", systemImage: "play.circle") }
                } else {
                    Button { onSuspend() } label: { Label("Suspend", systemImage: "pause.circle") }
                }
            }
            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.graspUI(size: 13, weight: .bold))
                .foregroundStyle(GRASPColor.textSecondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Question actions")
        #endif
    }
}
