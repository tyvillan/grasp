import SwiftUI
import GRASPCore

/// A deck's saved practice problems -- code questions, matrix and
/// calculation problems, scenario questions -- and the way to write more.
/// Each was checked before it was kept (code is compiled and run, numbers
/// are recomputed by a script, multiple choice gets a second opinion), and
/// they're mixed into tests when "Include AI-written questions" is on.
struct PracticeProblemsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckIds: [String]
    let scopeName: String
    let courseId: String?

    @State private var questions: [TestQuestion] = []
    @State private var count = 10
    /// nil: read each deck's notes.
    @State private var style: ProblemSubject?
    @State private var codeKinds: Set<CodeQuestionKind> = Set(CodeQuestionKind.allCases)
    @State private var problemKinds: Set<ProblemKind> = Set(ProblemKind.allCases)
    @State private var expanded: Set<String> = []
    private enum Tab { case saved, write }
    @State private var tab: Tab = .saved

    private var jobKey: String { store.codeQuestionJobKey(courseId: courseId) }
    private var job: AppStore.AIJob? { store.aiJob(jobKey) }
    private var requests: Int { AIQuotaEstimate.codeQuestionRequests(count: count) }
    private var showsCodeKinds: Bool { style == nil || style == .code }
    private var showsProblemKinds: Bool { style != .code }

    var body: some View {
        GRASPSheet(
            eyebrow: "Practice problems", title: scopeName,
            message: "Worked problems written from your notes: code to complete, calculations, matrices. Each is checked "
                + "before it's kept, and tests mix some in when \u{201C}Include AI-written questions\u{201D} is on.",
            icon: "function", width: 660, height: 620
        ) {
            VStack(alignment: .leading, spacing: GRASPSpace.m) {
                GRASPSegmented(selection: $tab, options: [(.saved, "Saved (\(questions.count))"), (.write, "Write new")])

                if let job {
                    AIProgressStrip(activity: job.activity, onStop: { store.stopAIJob(jobKey) },
                                    stopHelp: "Stops now. Problems already checked are kept.", isInline: true)
                        .popupGroup(padding: 12)
                } else if let run = store.lastCodeQuestionRun {
                    banner(run)
                }

                if tab == .saved {
                    if questions.isEmpty {
                        VStack(spacing: 10) {
                            Text("No saved problems yet.")
                                .graspType(.body)
                                .foregroundStyle(GRASPColor.textSecondary)
                            Button("Write some") { tab = .write }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .popupGroup()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(questions) { record in
                                    row(record)
                                        .popupGroup(padding: 14)
                                }
                            }
                        }
                    }
                } else {
                    ScrollView { writeControls }
                }
            }
        } footer: {
            Button("Done") { dismiss() }
                .keyboardShortcut(tab == .saved ? .defaultAction : .cancelAction)
            if tab == .write {
                Button {
                    tab = .saved
                    store.writePractice(
                        PracticeBuilder.Request(
                            deckIds: deckIds, style: style,
                            codeKinds: CodeQuestionKind.allCases.filter(codeKinds.contains),
                            problemKinds: ProblemKind.allCases.filter(problemKinds.contains), count: count),
                        courseId: courseId)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: AIGlyph.symbol).font(.graspUI(size: 11, weight: .semibold))
                        Text("Write problems")
                    }
                }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
                .disabled(job != nil || !store.canWriteCodeQuestions
                          || (showsCodeKinds && codeKinds.isEmpty && !showsProblemKinds)
                          || (showsProblemKinds && problemKinds.isEmpty && !showsCodeKinds))
            }
        }
        .task {
            store.addMissingChoicesInBackground()
            load()
            if questions.isEmpty { tab = .write }
        }
        .onChange(of: store.revision) { load() }
    }

    private func load() { questions = store.codeQuestions(inDecks: deckIds) }

    @ViewBuilder
    private func row(_ record: TestQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.summary)
                    .font(.graspUI(size: 12, weight: .semibold))
                    .foregroundStyle(GRASPColor.accent)
                if store.isCodeQuestionStale(record) {
                    PreviewChip(text: "Note changed since", tint: GRASPColor.accent, tintSoft: GRASPColor.accentSoft)
                }
                Spacer()
                Button(expanded.contains(record.id) ? "Hide answer" : "Show answer") {
                    withAnimation(Motion.snappy) {
                        if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
                    }
                }
                .buttonStyle(.plain)
                .font(.graspUI(size: 12, weight: .semibold))
                .foregroundStyle(GRASPColor.textSecondary)
                Button { store.deleteCodeQuestion(record.id) } label: {
                    Image(systemName: "trash").font(.graspUI(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(GRASPColor.rejected)
                .help("Delete this problem")
            }
            // The whole problem is always on show -- the prompt, the code to
            // fill in or trace, a problem's matrix and its choices. Only the
            // answer (and the explanation) waits behind "Show answer".
            let revealed = expanded.contains(record.id)
            if let question = record.question {
                Text(question.prompt).graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                Text(question.code)
                    .font(.graspMono(12))
                    .foregroundStyle(GRASPColor.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if revealed {
                    answerLine(question.answerText)
                    footer(record)
                }
            } else if let problem = record.problem {
                GuideText(text: problem.prompt, style: .body, color: GRASPColor.textPrimary)
                if let choices = problem.choices {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        Text("\(["A", "B", "C", "D"][min(index, 3)])) \(choice)")
                            .graspType(.body)
                            .foregroundStyle(revealed && index == problem.correct ? GRASPColor.success : GRASPColor.textPrimary)
                    }
                } else if revealed {
                    answerLine(problem.answerText)
                }
                if revealed {
                    if let explanation = problem.explanation {
                        Text(explanation).graspType(.body).foregroundStyle(GRASPColor.textSecondary)
                    }
                    footer(record)
                }
            } else {
                Text(record.promptText).graspType(.body).foregroundStyle(GRASPColor.textPrimary)
            }
        }
    }

    private func answerLine(_ text: String) -> some View {
        Text("Answer: \(text)")
            .font(.graspMono(12))
            .foregroundStyle(GRASPColor.success)
            .textSelection(.enabled)
    }

    private func footer(_ record: TestQuestion) -> some View {
        Text(record.verifiedBy.prefix(1).uppercased() + record.verifiedBy.dropFirst()
             + (record.model.map { " · written by \($0)" } ?? ""))
            .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
    }

    private func banner(_ run: AppStore.CodeQuestionRunResult) -> some View {
        let failed = run.failure != nil
        return HStack(spacing: 8) {
            Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(failed ? GRASPColor.rejected : GRASPColor.success)
            Text(run.failure ?? "Saved \(run.saved) problem\(run.saved == 1 ? "" : "s")"
                 + (run.rejected > 0 ? " (\(run.rejected) didn't check out and were dropped" + (run.topReason.map { ", mostly because \($0)" } ?? "") + ")" : "")
                 + (run.wasStopped ? ", then stopped." : "."))
                .graspType(.body)
                .foregroundStyle(GRASPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.lastCodeQuestionRun = nil } label: {
                Image(systemName: "xmark").font(.graspUI(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(GRASPColor.textTertiary)
            .help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(failed ? GRASPColor.rejectedSoft : GRASPColor.successSoft,
                    in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
    }

    private var writeControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: GRASPSpace.xl) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("How many")
                        GRASPSegmented(selection: $count, options: [5, 10, 20].map { ($0, "\($0)") })
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Style")
                        GRASPDropdown(
                            selection: $style,
                            options: [(nil, "Automatic")] + ProblemSubject.allCases.map { (ProblemSubject?.some($0), $0.label) }
                        )
                        .frame(width: 200)
                        .help("Automatic reads each note: code, matrices and equations, economics, or concepts.")
                    }
                }
                if showsCodeKinds {
                    kindRow("Code", CodeQuestionKind.allCases, selection: $codeKinds, label: \.label)
                }
                if showsProblemKinds {
                    kindRow("Problems", ProblemKind.allCases, selection: $problemKinds, label: \.label)
                }
            }
            .popupGroup()

            if !store.canWriteCodeQuestions {
                Label(store.isGeneratorAvailable
                      ? "Writing practice needs a Mac with Xcode's command line tools to check the answers."
                      : "No AI model is set up. Settings → AI has the setup.",
                      systemImage: "exclamationmark.triangle")
                    .graspType(.meta).foregroundStyle(GRASPColor.rejected)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Written by \(store.generatorStatus). About \(requests) request\(requests == 1 ? "" : "s"); "
                         + "with a cloud model several notes are written at once.")
                    if store.aiMode.usesCloud, store.hasCloudKey {
                        Label("The notes' text is sent to Google Gemini. Its free tier may use what you send to improve Google's products.",
                              systemImage: "cloud")
                        if let warning = AIQuotaEstimate.warning(needed: requests, mode: store.aiMode) {
                            Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                        }
                    }
                }
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func kindRow<Kind: Hashable>(_ title: String, _ kinds: [Kind], selection: Binding<Set<Kind>>,
                                         label: KeyPath<Kind, String>) -> some View {
        HStack(spacing: 14) {
            FieldLabel(title).frame(width: 64, alignment: .leading)
            ForEach(kinds, id: \.self) { kind in
                Toggle(kind[keyPath: label], isOn: Binding(
                    get: { selection.wrappedValue.contains(kind) },
                    set: { if $0 { selection.wrappedValue.insert(kind) } else { selection.wrappedValue.remove(kind) } }
                ))
                .font(.graspCallout)
            }
        }
    }
}
