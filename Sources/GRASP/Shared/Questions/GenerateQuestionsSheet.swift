import SwiftUI
import GRASPCore

/// "Generate questions with AI": pick the notes, how many, and what kinds.
/// What comes back lands as drafts on the Questions tab, to review.
struct GenerateQuestionsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let deckIds: [String]
    let courseId: String?
    let scopeName: String

    @State private var notes: [DraftNote] = []
    @State private var selected: Set<String> = []
    @State private var count = 10
    @State private var multipleChoice = true
    @State private var written = true
    @State private var codeKinds: Set<CodeQuestionKind> = Set(CodeQuestionKind.allCases)
    @State private var mathKinds: Set<ProblemKind> = [.number, .matrix]
    @State private var hasLoaded = false

    private var chosen: [DraftNote] { notes.filter { selected.contains($0.id) } }
    private var hasCodeNotes: Bool { chosen.contains { $0.subject == .code } }
    private var hasMathNotes: Bool { chosen.contains { $0.subject == .math || $0.subject == .economics } }
    private var showsCodeKinds: Bool { hasCodeNotes && store.canCheckCodeAndMath }
    private var showsMathKinds: Bool { hasMathNotes && store.canCheckCodeAndMath }
    private var needsMac: Bool { (hasCodeNotes || hasMathNotes) && !store.canCheckCodeAndMath }
    private var requests: Int { AIQuotaEstimate.codeQuestionRequests(count: count) }
    private var running: Bool { store.aiJob(store.questionDraftJobKey(courseId: courseId)) != nil }

    private var canStart: Bool {
        guard store.isGeneratorAvailable, !running, !selected.isEmpty else { return false }
        return multipleChoice || written || (showsCodeKinds && !codeKinds.isEmpty) || (showsMathKinds && !mathKinds.isEmpty)
    }

    var body: some View {
        GRASPSheet(
            eyebrow: "Generate with AI", title: "Generate questions with AI",
            message: "The AI writes draft questions from your notes. They wait under To review on the Questions tab until you approve them.",
            icon: AIGlyph.symbol, width: 500
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Which model, the cost, and where the text goes come first,
                // so they are seen before the button, not below the fold.
                notices
                notesGroup
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("How many").graspType(.body)
                        Spacer()
                        Text("\(count)").font(.graspUI(size: 15, weight: .semibold)).monospacedDigit()
                        Stepper("", value: $count, in: 5...30, step: 5).labelsHidden()
                    }
                    Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                    FieldLabel("Question types")
                    Toggle("Multiple choice", isOn: $multipleChoice)
                    Toggle("Written", isOn: $written)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("True / False", isOn: .constant(false)).disabled(true)
                        Text("Not written by AI yet. Write these yourself.")
                            .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    }
                    if showsCodeKinds {
                        Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                        FieldLabel("Code")
                        ForEach(CodeQuestionKind.allCases, id: \.self) { kind in
                            Toggle(kind.label, isOn: binding(kind, in: $codeKinds))
                        }
                    }
                    if showsMathKinds {
                        Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                        FieldLabel("Math")
                        Toggle("Type a number", isOn: binding(.number, in: $mathKinds))
                        Toggle("Type a matrix", isOn: binding(.matrix, in: $mathKinds))
                    }
                    if needsMac {
                        Text("Code and math questions are written on the Mac, which checks them by running them.")
                            .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .popupGroup()
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button {
                start()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: AIGlyph.symbol).font(.graspUI(size: 11, weight: .semibold))
                    Text("Write questions")
                }
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
        .task {
            load()
            #if DEBUG
            // Screenshots only: with the canned writer on, start at once.
            if StubHooks.enabled("GRASP_STUB_QUESTIONS"), ProcessInfo.processInfo.environment["GRASP_AUTO_GENERATE"] == "1" {
                try? await Task.sleep(for: .milliseconds(900))
                start()
            }
            #endif
        }
    }

    // MARK: Notes

    private var notesGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FieldLabel("Notes to use")
                Spacer()
                if notes.count > 1 {
                    Button(selected.count == notes.count ? "Select none" : "Select all") {
                        selected = selected.count == notes.count ? [] : Set(notes.map(\.id))
                    }
                    .buttonStyle(.plain)
                    .font(.graspUI(size: 12, weight: .semibold))
                    .foregroundStyle(GRASPColor.textSecondary)
                }
            }
            if hasLoaded && notes.isEmpty {
                Text("This deck has no source notes to write questions from.")
                    .graspType(.body).foregroundStyle(GRASPColor.textSecondary)
            } else {
                ForEach(notes) { note in
                    Toggle(isOn: binding(note.id, in: $selected)) {
                        Text(note.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .popupGroup()
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.isGeneratorAvailable {
                Label("No AI model is set up. Settings has the setup.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(GRASPColor.rejected)
            } else {
                Text("Written by \(store.generatorStatus). About \(requests) request\(requests == 1 ? "" : "s"). "
                     + "Nothing runs until you press Write questions.")
                if store.aiMode.usesCloud, store.hasCloudKey {
                    Label("The text of the notes you pick is sent to Google Gemini. Its free tier may use what you send "
                          + "to improve Google's products.", systemImage: "cloud")
                    if let warning = AIQuotaEstimate.warning(needed: requests, mode: store.aiMode) {
                        Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
            }
        }
        .graspType(.meta)
        .foregroundStyle(GRASPColor.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func load() {
        notes = store.draftNotes(inDecks: deckIds)
        selected = Set(notes.map(\.id))
        hasLoaded = true
    }

    private func start() {
        let request = QuestionDrafter.Request(
            deckIds: deckIds, materialIds: selected, count: count, multipleChoice: multipleChoice, written: written,
            codeKinds: showsCodeKinds ? CodeQuestionKind.allCases.filter(codeKinds.contains) : [],
            mathKinds: showsMathKinds ? [.number, .matrix].filter(mathKinds.contains) : [])
        store.draftQuestions(request, courseId: courseId)
        dismiss()
    }

    private func binding<Value: Hashable>(_ value: Value, in set: Binding<Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { if $0 { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } }
        )
    }
}
