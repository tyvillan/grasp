import SwiftUI
import GRASPCore

/// A deck's saved code questions, and the way to write more. Questions are
/// written by the AI and then compiled and run here; only the ones that
/// work are kept, so every answer in a test is what the program really does.
struct CodeQuestionBankSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckIds: [String]
    let scopeName: String
    let courseId: String?

    @State private var questions: [TestQuestion] = []
    @State private var count = 10
    @State private var kinds: Set<CodeQuestionKind> = Set(CodeQuestionKind.allCases)
    @State private var expanded: Set<String> = []

    private var jobKey: String { store.codeQuestionJobKey(courseId: courseId) }
    private var job: AppStore.AIJob? { store.aiJob(jobKey) }
    private var requests: Int { AIQuotaEstimate.codeQuestionRequests(count: count) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Code Questions: \(scopeName)").font(.headline)
                Text("Written from the code in your notes. Each one is compiled and run on this Mac before it is kept, "
                     + "so its answer is what the program really does. They're mixed into tests when \"Include AI-written questions\" is on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()

            if let job {
                AIProgressStrip(activity: job.activity, onStop: { store.stopAIJob(jobKey) },
                                stopHelp: "Stops now. Questions already checked are kept.")
            } else if let run = store.lastCodeQuestionRun {
                banner(run)
            }

            List {
                if questions.isEmpty {
                    Text("No saved questions yet.").foregroundStyle(.secondary)
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
        .macSheetFrame(width: 600)
        .task { load() }
        .onChange(of: store.revision) { load() }
    }

    private func load() { questions = store.codeQuestions(inDecks: deckIds) }

    @ViewBuilder
    private func row(_ record: TestQuestion) -> some View {
        if let question = record.question {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(question.kind.label) · \(question.language.label)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GRASPColor.accent)
                    if store.isCodeQuestionStale(record) {
                        Text("Note changed since")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(GRASPColor.accentSoft, in: Capsule())
                    }
                    Spacer()
                    Button {
                        if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
                    } label: { Text(expanded.contains(record.id) ? "Hide" : "Show") }
                        .buttonStyle(.borderless)
                    Button(role: .destructive) { store.deleteCodeQuestion(record.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this question")
                }
                Text(question.prompt).font(.callout)
                if expanded.contains(record.id) {
                    Text(question.code)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 6))
                    Text("Answer: \(question.answerText)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(record.verifiedBy.capitalized + (record.model.map { " · written by \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func banner(_ run: AppStore.CodeQuestionRunResult) -> some View {
        let failed = run.failure != nil
        return HStack(spacing: 8) {
            Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(failed ? GRASPColor.rejected : GRASPColor.success)
            Text(run.failure ?? "Saved \(run.saved) question\(run.saved == 1 ? "" : "s")"
                 + (run.rejected > 0 ? " (\(run.rejected) didn't run correctly and were dropped" + (run.topReason.map { ", mostly because \($0)" } ?? "") + ")" : "")
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
                ForEach(CodeQuestionKind.allCases, id: \.self) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { kinds.contains(kind) },
                        set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                }
            }
            if !store.canWriteCodeQuestions {
                Label(store.isGeneratorAvailable
                      ? "This Mac has no compiler for running the questions. Install Xcode's command line tools (xcode-select --install)."
                      : "No AI model is set up. Settings → AI has the setup.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(GRASPColor.rejected)
            } else {
                Text("Written by \(store.generatorStatus). About \(requests) request\(requests == 1 ? "" : "s"), a few minutes on a local model.")
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
                Button("Write Questions") {
                    store.writeCodeQuestions(deckIds: deckIds, courseId: courseId,
                                             kinds: CodeQuestionKind.allCases.filter(kinds.contains), count: count)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(job != nil || kinds.isEmpty || !store.canWriteCodeQuestions)
            }
        }
        .padding(20)
    }
}
