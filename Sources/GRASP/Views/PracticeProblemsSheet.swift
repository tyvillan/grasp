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

    private var jobKey: String { store.codeQuestionJobKey(courseId: courseId) }
    private var job: AppStore.AIJob? { store.aiJob(jobKey) }
    private var requests: Int { AIQuotaEstimate.codeQuestionRequests(count: count) }
    private var showsCodeKinds: Bool { style == nil || style == .code }
    private var showsProblemKinds: Bool { style != .code }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Practice Problems: \(scopeName)").font(.headline)
                Text("Written from your notes and checked before they're kept: code is compiled and run, calculations are "
                     + "recomputed by a script, and multiple choice needs a second opinion on its answer. They're mixed "
                     + "into tests when \"Include AI-written questions\" is on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()

            if let job {
                AIProgressStrip(activity: job.activity, onStop: { store.stopAIJob(jobKey) },
                                stopHelp: "Stops now. Problems already checked are kept.")
            } else if let run = store.lastCodeQuestionRun {
                banner(run)
            }

            List {
                if questions.isEmpty {
                    Text("No saved problems yet.").foregroundStyle(.secondary)
                }
                ForEach(questions) { record in
                    row(record)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()
            writeControls
        }
        .macSheetFrame(width: 640)
        .task { load() }
        .onChange(of: store.revision) { load() }
    }

    private func load() { questions = store.codeQuestions(inDecks: deckIds) }

    @ViewBuilder
    private func row(_ record: TestQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GRASPColor.accent)
                if store.isCodeQuestionStale(record) {
                    Text("Note changed since")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(GRASPColor.accentSoft, in: Capsule())
                }
                Spacer()
                Button(expanded.contains(record.id) ? "Hide" : "Show") {
                    if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) { store.deleteCodeQuestion(record.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this problem")
            }
            if !expanded.contains(record.id) {
                // A problem's matrix is part of the question, so it is
                // shown whole; only the answer waits behind "Show".
                if let problem = record.problem {
                    GuideText(text: problem.prompt, style: .body, color: GRASPColor.textPrimary)
                } else {
                    Text(record.promptText).font(.callout).lineLimit(3)
                }
            } else if let question = record.question {
                Text(question.prompt).font(.callout)
                Text(question.code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 6))
                answerLine(question.answerText)
                footer(record)
            } else if let problem = record.problem {
                GuideText(text: problem.prompt, style: .body, color: GRASPColor.textPrimary)
                if let choices = problem.choices {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        Text("\(["A", "B", "C", "D"][min(index, 3)])) \(choice)")
                            .font(.callout)
                            .foregroundStyle(index == problem.correct ? GRASPColor.success : .primary)
                    }
                } else {
                    answerLine(problem.answerText)
                }
                if let explanation = problem.explanation {
                    Text(explanation).font(.callout).foregroundStyle(.secondary)
                }
                footer(record)
            }
        }
        .padding(.vertical, 3)
    }

    private func answerLine(_ text: String) -> some View {
        Text("Answer: \(text)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private func footer(_ record: TestQuestion) -> some View {
        Text(record.verifiedBy.prefix(1).uppercased() + record.verifiedBy.dropFirst()
             + (record.model.map { " · written by \($0)" } ?? ""))
            .font(.caption2).foregroundStyle(.tertiary)
    }

    private func banner(_ run: AppStore.CodeQuestionRunResult) -> some View {
        let failed = run.failure != nil
        return HStack(spacing: 8) {
            Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(failed ? GRASPColor.rejected : GRASPColor.success)
            Text(run.failure ?? "Saved \(run.saved) problem\(run.saved == 1 ? "" : "s")"
                 + (run.rejected > 0 ? " (\(run.rejected) didn't check out and were dropped" + (run.topReason.map { ", mostly because \($0)" } ?? "") + ")" : "")
                 + (run.wasStopped ? ", then stopped." : "."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { store.lastCodeQuestionRun = nil }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background((failed ? GRASPColor.rejectedSoft : GRASPColor.accentSoft).opacity(0.55))
    }

    private var writeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("How many", selection: $count) {
                    ForEach([5, 10, 20], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Style", selection: $style) {
                    Text("Automatic").tag(ProblemSubject?.none)
                    ForEach(ProblemSubject.allCases, id: \.self) { Text($0.label).tag(ProblemSubject?.some($0)) }
                }
                .fixedSize()
                .help("Automatic reads each note: code, matrices and equations, economics, or concepts.")
            }
            if showsCodeKinds {
                kindRow("Code", CodeQuestionKind.allCases, selection: $codeKinds, label: \.label)
            }
            if showsProblemKinds {
                kindRow("Problems", ProblemKind.allCases, selection: $problemKinds, label: \.label)
            }
            if !store.canWriteCodeQuestions {
                Label(store.isGeneratorAvailable
                      ? "Writing practice needs a Mac with Xcode's command line tools to check the answers."
                      : "No AI model is set up. Settings → AI has the setup.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(GRASPColor.rejected)
            } else {
                Text("Written by \(store.generatorStatus). About \(requests) request\(requests == 1 ? "" : "s"); "
                     + "with a cloud model several notes are written at once.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.aiMode.usesCloud, store.hasCloudKey {
                    Label("The notes' text is sent to Google Gemini. Its free tier may use what you send to improve Google's products.",
                          systemImage: "cloud")
                        .font(.caption).foregroundStyle(.secondary)
                    if let warning = AIQuotaEstimate.warning(needed: requests, mode: store.aiMode) {
                        Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                Button("Write Problems") {
                    store.writePractice(
                        PracticeBuilder.Request(
                            deckIds: deckIds, style: style,
                            codeKinds: CodeQuestionKind.allCases.filter(codeKinds.contains),
                            problemKinds: ProblemKind.allCases.filter(problemKinds.contains), count: count),
                        courseId: courseId)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(job != nil || !store.canWriteCodeQuestions
                          || (showsCodeKinds && codeKinds.isEmpty && !showsProblemKinds)
                          || (showsProblemKinds && problemKinds.isEmpty && !showsCodeKinds))
            }
        }
        .padding(20)
    }

    private func kindRow<Kind: Hashable>(_ title: String, _ kinds: [Kind], selection: Binding<Set<Kind>>,
                                         label: KeyPath<Kind, String>) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            ForEach(kinds, id: \.self) { kind in
                Toggle(kind[keyPath: label], isOn: Binding(
                    get: { selection.wrappedValue.contains(kind) },
                    set: { if $0 { selection.wrappedValue.insert(kind) } else { selection.wrappedValue.remove(kind) } }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)
            }
        }
    }
}
