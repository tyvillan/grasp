import SwiftUI
import GRASPCore

/// Drives the three-screen test flow (setup -> running -> results) as one
/// continuous `.sheet(item:)` presentation in the caller: changing this
/// value to a new case swaps the sheet's content in place rather than
/// dismissing and re-presenting, so the flow reads as one flow, not three.
enum TestPhase: Identifiable {
    case setup
    case running(attemptId: String, questions: [LearnEngine.RoundQuestion], aiWarning: String?,
                 answered: [GradedQuestion] = [])
    case results(attemptId: String, graded: [GradedQuestion])

    var id: String {
        switch self {
        case .setup: return "setup"
        case .running(let attemptId, _, _, _): return "running-\(attemptId)"
        case .results(let attemptId, _): return "results-\(attemptId)"
        }
    }
}

extension TestPhase {
    /// An unfinished test, ready to run from its next unanswered question.
    @MainActor
    static func resuming(_ attemptId: String, store: AppStore) -> TestPhase? {
        guard let saved = store.resumeTest(attemptId: attemptId), !saved.questions.isEmpty else { return nil }
        let answered = saved.answers.enumerated().map { index, answer in
            GradedQuestion(question: saved.questions[index], ordinal: index,
                           givenAnswer: answer.given, isCorrect: answer.isCorrect)
        }
        return .running(attemptId: attemptId, questions: saved.questions, aiWarning: nil, answered: answered)
    }
}

/// One answered question, carrying enough state for the results screen to
/// render it and, for a written question, let the user override a wrong
/// fuzzy-match verdict -- `LearnEngine.RoundQuestion` alone doesn't carry
/// what was actually typed or whether it was judged correct, since that
/// lives in `TestItem`, not the in-memory question.
struct GradedQuestion: Identifiable {
    var id: String { question.id }
    let question: LearnEngine.RoundQuestion
    /// This question's position in the attempt -- `AppStore.submitTestAnswer`/
    /// `overrideTestItemCorrect` key off this, not `cardId`, since an
    /// AI-generated question has no `cardId` at all.
    let ordinal: Int
    var givenAnswer: String
    var isCorrect: Bool
}

/// The custom-test flow: a config sheet, then a running test over its own
/// fixed question set (no requeue-on-miss here, unlike Learn -- a test
/// measures where you stand), then a results screen showing every miss
/// beside the correct answer. Every card you got right also gets fed back
/// into FSRS as a Good grade (`AppStore.finishTest`), so a clean test
/// session pushes those cards' schedules out; a miss isn't graded at all,
/// so getting one wrong never tightens a card's schedule.
struct TestSetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckIds: [String]
    let deckName: String
    /// Picks an unfinished test up again, by attempt id.
    var onResume: ((String) -> Void)? = nil
    /// Set for a test on a study guide rather than on decks alone.
    var guide: (page: StudyGuideActions.ExamPage, scopeKey: String)? = nil
    let onStart: (String, [LearnEngine.RoundQuestion], String?) -> Void
    @State private var unfinished: Study.UnfinishedTest?

    @State private var questionCount = 20
    @State private var allowMultipleChoice = true
    @State private var allowWritten = true
    @State private var allowTrueFalse = true
    // Fixed defaults: tests shuffle, and ask about every card.
    private let shuffle = true
    private let excludeMastered = false
    private let weakSpotsOnly = false
    @State private var history: [Study.TestHistoryEntry] = []
    @State private var mostMissed: [(front: String, misses: Int)] = []
    /// True while `startTest` is in flight -- worth surfacing explicitly
    /// since, with AI test questions on, this can take a few seconds
    /// (a real network round trip to a local model) rather than the
    /// near-instant card-only path, and a silent multi-second pause with
    /// no feedback reads as a hang.
    @State private var isStarting = false
    /// Set only while AI questions are being written -- the one slow part
    /// of starting a test.
    @State private var aiActivity: AIActivity?
    /// Set when Start found nothing to ask, so the sheet says why instead
    /// of just not starting.
    @State private var noQuestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 26))
                    .foregroundStyle(GRASPColor.accent)
                Text("Test: \(deckName)")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(GRASPColor.textPrimary)
                Text(guide != nil
                     ? "Built from what the exam will ask: this guide's worked examples (code answers become "
                       + "fill-in-the-blank, output questions become predict-the-output) and the checked practice "
                       + "problems saved for the lectures it covers."
                     : "A graded quiz on this deck's cards: multiple choice, written, and true / false. "
                       + "Worked problems with code or calculations live under Problems instead.")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let unfinished, let onResume {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Unfinished test")
                        .graspType(.eyebrow).textCase(.uppercase).foregroundStyle(GRASPColor.textTertiary)
                    Text("\(unfinished.answered) of \(unfinished.total) answered, started "
                         + unfinished.startedAt.formatted(.relative(presentation: .named)) + ".")
                        .graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                    HStack(spacing: 8) {
                        Button("Continue Test") { onResume(unfinished.attemptId) }
                            .buttonStyle(GRASPProminentButton())
                        Button("Discard") {
                            store.discardTest(attemptId: unfinished.attemptId)
                            self.unfinished = nil
                        }
                        .buttonStyle(GRASPQuietButton())
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GRASPColor.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Stepper("Questions: \(questionCount)", value: $questionCount, in: 5...100, step: 5)

            VStack(alignment: .leading, spacing: 8) {
                Text("Question types")
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(GRASPColor.textTertiary)
                Toggle("Multiple choice", isOn: $allowMultipleChoice)
                Toggle("Written", isOn: $allowWritten)
                if guide == nil {
                    // A guide's questions come from its worked examples,
                    // which have no true/false form.
                    Toggle("True / False", isOn: $allowTrueFalse)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            historyBlock
            if guide == nil {
            Toggle("Include AI-written questions", isOn: Binding(
                get: { store.isAITestQuestionsEnabled }, set: { store.isAITestQuestionsEnabled = $0 }
            ))
            if store.isAITestQuestionsEnabled {
                let saved = store.codeQuestionCount(inDecks: deckIds)
                Text(saved > 0
                     ? "Also mixes in some of this deck's \(saved) saved practice problem\(saved == 1 ? "" : "s"), up to a third of the test."
                     : "Short questions are written from your notes as the test starts. Full practice problems (code, matrices, calculations) can be saved ahead of time with a deck's Problems button on the Mac.")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            }

            if !allowMultipleChoice && !allowWritten && !allowTrueFalse {
                Text("Enable at least one question type.").font(.caption).foregroundStyle(.red)
            } else if noQuestions {
                Text("No cards match these settings, so there's nothing to test.")
                    .font(.caption).foregroundStyle(.red)
            }

            if let aiActivity {
                AIProgressStrip(
                    activity: aiActivity,
                    onStop: { store.skipAITestQuestions() },
                    stopTitle: "Skip",
                    stoppingTitle: "Starting…",
                    stopHelp: "Starts the test now, with any AI questions already written.",
                    isInline: true
                )
            }

            HStack(spacing: 8) {
                if isStarting, aiActivity == nil {
                    ProgressView().controlSize(.small)
                    Text(store.isAITestQuestionsEnabled ? "Generating AI questions…" : "Starting test…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isStarting)
                Button("Start Test") {
                    let config = TestBuilder.Config(
                        questionCount: questionCount, allowMultipleChoice: allowMultipleChoice,
                        allowWritten: allowWritten, allowTrueFalse: allowTrueFalse && guide == nil, shuffle: shuffle,
                        excludeMastered: excludeMastered, weakSpotsOnly: weakSpotsOnly
                    )
                    isStarting = true
                    noQuestions = false
                    let run = guide != nil ? nil
                        : (store.isAITestQuestionsEnabled && allowWritten)
                        ? AIActivity(headline: "Writing AI questions from your notes")
                        : nil
                    aiActivity = run
                    Task {
                        defer {
                            run?.finish()
                            aiActivity = nil
                            isStarting = false
                        }
                        let guide = self.guide
                        let start = {
                            if let guide {
                                return try await store.startGuideTest(page: guide.page, scopeKey: guide.scopeKey, config: config)
                            }
                            return try await store.startTest(deckIds: deckIds, config: config)
                        }
                        let result = if let run {
                            try? await AIProgress.$current.withValue(run.reporter(forUnit: 0)) { try await start() }
                        } else {
                            try? await start()
                        }
                        guard let (attemptId, questions, aiWarning) = result, !questions.isEmpty else {
                            noQuestions = true
                            return
                        }
                        onStart(attemptId, questions, aiWarning)
                    }
                }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
                .disabled(isStarting || (!allowMultipleChoice && !allowWritten && !allowTrueFalse))
            }
        }
        .padding(24)
        .macSheetFrame(width: 420)
        .background(GRASPColor.canvas)
        .task {
            store.addMissingChoicesInBackground()
            unfinished = store.unfinishedTest(forDecks: deckIds, scopeKey: guide?.scopeKey)
            history = store.testHistory(forDecks: deckIds)
            mostMissed = store.mostMissedCards(forDecks: deckIds)
        }
    }

    /// Recent scores as bars, and the cards missed most -- shown once there
    /// is something to show.
    @ViewBuilder
    private var historyBlock: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent scores")
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(GRASPColor.textTertiary)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(history) { entry in
                        VStack(spacing: 3) {
                            Text("\(Int((entry.fraction * 100).rounded()))")
                                .font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(GRASPColor.textTertiary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(entry.fraction >= 0.8 ? GRASPColor.success : GRASPColor.accent)
                                .frame(width: 18, height: max(4, 44 * entry.fraction))
                        }
                        .help("\(entry.correct) of \(entry.total), \(entry.startedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                    Spacer()
                }
                .frame(height: 62, alignment: .bottom)
                if !mostMissed.isEmpty {
                    Text("Missed most: " + mostMissed.prefix(3).map { "\($0.front) (\($0.misses)x)" }.joined(separator: ", "))
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct TestRunView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let attemptId: String
    let deckName: String
    let questions: [LearnEngine.RoundQuestion]
    /// Set when AI test questions were requested (Settings toggle + this
    /// test allows Written) but couldn't actually be produced -- unlike
    /// most `CardGenerator` failures, this one has an explicit ask-for
    /// behind it, so silently falling back to an all-card test the way
    /// `generateAdditionalCards` does would just look broken.
    let aiWarning: String?
    /// Answers already given, when this is an unfinished test picked up again.
    var answered: [GradedQuestion] = []
    let onFinished: ([GradedQuestion]) -> Void

    @State private var confirmingExit = false
    @State private var resumed = false
    @State private var index = 0
    @State private var selectedChoice: String?
    @State private var writtenAnswer = ""
    @State private var isAnswered = false
    @State private var lastCorrect = false
    @State private var wasOverridden = false
    @State private var graded: [GradedQuestion] = []
    @State private var warningDismissed = false
    @FocusState private var writtenFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if let aiWarning, !warningDismissed {
                warningBanner(aiWarning)
            }
            if index < questions.count {
                questionBody(questions[index])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GRASPColor.canvas)
        .macWindowFrame(minWidth: 620, minHeight: 520)
        .onAppear {
            // Picking an unfinished test up where it was left.
            guard !resumed else { return }
            resumed = true
            if !answered.isEmpty, answered.count < questions.count {
                graded = answered
                index = answered.count
            }
        }
        .confirmationDialog("Leave this test?", isPresented: $confirmingExit, titleVisibility: .visible) {
            Button("Save and Exit") { dismiss() }
            Button("Discard Test", role: .destructive) {
                store.discardTest(attemptId: attemptId)
                dismiss()
            }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("Saved tests can be continued from the deck, on this device or another.")
        }
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(GRASPColor.accent)
            Text(message)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                warningDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(GRASPColor.accentSoft)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    confirmingExit = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GRASPColor.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(GRASPColor.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Save this test for later, or discard it")

                VStack(alignment: .leading, spacing: 1) {
                    Text(deckName)
                        .graspType(.title)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .lineLimit(1)
                    Text("Test")
                        .graspType(.meta)
                        .textCase(.uppercase)
                        .tracking(0.7)
                        .foregroundStyle(GRASPColor.textTertiary)
                }

                Spacer(minLength: 12)

                if !graded.isEmpty {
                    Text("\(graded.filter(\.isCorrect).count) correct")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                }

                Text("\(index + 1) / \(questions.count)")
                    .graspType(.numeralSmall)
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            ProgressBar(value: index, total: questions.count, height: 2)
        }
    }

    @ViewBuilder
    private func questionBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 0) {
            if let code = question.code {
                Label("\(code.kind.label) · \(code.language.label)", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GRASPColor.accent)
                    .help("Written by AI, then compiled and run to check the answer")
                    .padding(.top, 42)
            } else if let problem = question.problem {
                Label("\(problem.kind.label) · \(problem.subject.label)", systemImage: "function")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GRASPColor.accent)
                    .help("Written by AI, then checked before it was saved")
                    .padding(.top, 42)
            } else if question.cardId == nil {
                Label("AI-generated", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GRASPColor.accent)
                    .help("AI-generated for this test -- not saved as a card, worth double-checking")
                    .padding(.top, 42)
            }

            if question.problem != nil || (question.cardId == nil && question.prompt.contains("\n")) {
                // A problem can hold a matrix, which only lines up in a
                // fixed-width font, so it reads left to right.
                GuideText(text: question.prompt, style: .prose, color: GRASPColor.textPrimary)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.top, 10)
            } else {
                Text(question.prompt)
                    .graspType(.studyPrompt)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560)
                    .padding(.top, question.cardId == nil ? 10 : 42)
                    .padding(.bottom, question.code == nil ? 0 : 6)
            }

            Spacer(minLength: 28)

            VStack(spacing: 14) {
                switch question.type {
                case .multipleChoice:
                    if let code = question.code {
                        // The program the choices are about, with the one
                        // open blank marked.
                        ScrollView {
                            Text(CodeQuestion.fill(code.code) { _ in "_____" })
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(GRASPColor.textPrimary)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: 560, maxHeight: 220)
                        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    choiceList(question)
                case .trueFalse:
                    VStack(spacing: 18) {
                        Text(question.statement ?? "")
                            .graspType(.studyAnswer)
                            .foregroundStyle(GRASPColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .frame(maxWidth: 520)
                        HStack(spacing: 10) {
                            trueFalseButton("True", question)
                            trueFalseButton("False", question)
                        }
                        .frame(maxWidth: 340)
                    }
                case .written where question.problem != nil:
                    ProblemQuestionView(problem: question.problem!, isAnswered: isAnswered) { given, correct in
                        submit(correct, given: given, question: question)
                    }
                    .id(question.id)
                case .written where question.code != nil:
                    ScrollView {
                        CodeQuestionView(question: question.code!, isAnswered: isAnswered) { given, correct in
                            submit(correct, given: given, question: question)
                        }
                        .id(question.id)
                    }
                    .frame(maxHeight: 380)
                case .written:
                    TextField("Type the answer", text: $writtenAnswer)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(GRASPColor.inset)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    writtenFieldFocused ? GRASPColor.accent : GRASPColor.hairlineStrong,
                                    lineWidth: 1
                                )
                        )
                        .focused($writtenFieldFocused)
                        .disabled(isAnswered)
                        .onSubmit {
                            guard !isAnswered, !writtenAnswer.isEmpty else { return }
                            let verdict = AnswerGrading.grade(given: writtenAnswer, correct: question.correctAnswer)
                            submit(verdict != .incorrect, given: writtenAnswer, question: question)
                        }
                        .frame(maxWidth: 420)
                        .task { writtenFieldFocused = true }
                }

                if isAnswered, question.type == .multipleChoice, let explanation = question.problem?.explanation {
                    Text(explanation)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isAnswered {
                    HStack(spacing: 6) {
                        Image(systemName: lastCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12))
                        Text(lastCorrect
                             ? (wasOverridden ? "Marked correct" : "Correct")
                             : (question.code == nil && question.problem == nil
                                ? "Not quite -- \(question.correctAnswer)" : "Not quite"))
                            .graspType(.body)
                    }
                    .foregroundStyle(lastCorrect ? GRASPColor.success : GRASPColor.accent)

                    HStack(spacing: 8) {
                        // Exact/fuzzy text matching is a poor judge of a
                        // long or loaded free-response answer -- offered
                        // only for written questions, and only while still
                        // wrong. Same shape as the next-question button
                        // beside it, tinted green for "this was actually
                        // correct" rather than the app's normal accent.
                        if question.type == .written && !lastCorrect {
                            Button("I actually got this right") { override(question) }
                                .buttonStyle(GRASPProminentButton(tint: GRASPColor.success))
                        }

                        Button(index == questions.count - 1 ? "Finish test" : "Next question") { advance() }
                            .buttonStyle(GRASPProminentButton())
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
    }

    private func choiceList(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 7) {
            ForEach(Array((question.choices ?? []).enumerated()), id: \.offset) { position, choice in
                Button {
                    guard !isAnswered else { return }
                    selectedChoice = choice
                    submit(choice == question.correctAnswer, given: choice, question: question)
                } label: {
                    HStack(alignment: .top, spacing: 11) {
                        marker(choice, position: position, correct: question.correctAnswer)
                        if question.code != nil {
                            Text(choice)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(GRASPColor.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if question.problem?.kind == .matrix {
                            GuideText(text: choice, style: .body, color: GRASPColor.textPrimary)
                        } else {
                            Text(choice)
                                .graspType(.body)
                                .foregroundStyle(GRASPColor.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(background(choice, correct: question.correctAnswer))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(border(choice, correct: question.correctAnswer), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAnswered)
            }
        }
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private func marker(_ choice: String, position: Int, correct: String) -> some View {
        Group {
            if isAnswered && choice == correct {
                Image(systemName: "checkmark").foregroundStyle(GRASPColor.success)
            } else if isAnswered && choice == selectedChoice {
                Image(systemName: "xmark").foregroundStyle(GRASPColor.accent)
            } else {
                Text(String(UnicodeScalar(65 + min(position, 25))!))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 17, height: 17)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(GRASPColor.inset))
        .padding(.top, 1)
    }

    private func trueFalseButton(_ label: String, _ question: LearnEngine.RoundQuestion) -> some View {
        Button(label) {
            guard !isAnswered else { return }
            selectedChoice = label
            submit(question.correctAnswer == label, given: label, question: question)
        }
        .buttonStyle(GRASPVerdictButton(tint: tint(for: label, question: question)))
        .disabled(isAnswered)
    }

    private func tint(for label: String, question: LearnEngine.RoundQuestion) -> Color {
        guard isAnswered else { return GRASPColor.textSecondary }
        if label == question.correctAnswer { return GRASPColor.success }
        return label == selectedChoice ? GRASPColor.accent : GRASPColor.textTertiary
    }

    private func background(_ choice: String, correct: String) -> Color {
        guard isAnswered else { return GRASPColor.surface }
        if choice == correct { return GRASPColor.successSoft }
        if choice == selectedChoice { return GRASPColor.accentSoft }
        return GRASPColor.surface
    }

    private func border(_ choice: String, correct: String) -> Color {
        guard isAnswered else { return GRASPColor.hairline }
        if choice == correct { return GRASPColor.success.opacity(0.55) }
        if choice == selectedChoice { return GRASPColor.accent.opacity(0.55) }
        return GRASPColor.hairline
    }

    private func submit(_ correct: Bool, given: String, question: LearnEngine.RoundQuestion) {
        lastCorrect = correct
        wasOverridden = false
        isAnswered = true
        try? store.submitTestAnswer(attemptId: attemptId, ordinal: index, given: given, isCorrect: correct)
        graded.append(GradedQuestion(question: question, ordinal: index, givenAnswer: given, isCorrect: correct))
    }

    /// The attempt isn't finished yet at this point, so this only needs to
    /// flip the just-saved `TestItem` row -- `AppStore.finishTest` will
    /// score correctly and grade it Good off this row once it runs, since
    /// a miss never gets graded in the first place.
    private func override(_ question: LearnEngine.RoundQuestion) {
        lastCorrect = true
        wasOverridden = true
        if let last = graded.indices.last {
            graded[last].isCorrect = true
        }
        try? store.overrideTestItemCorrect(attemptId: attemptId, ordinal: index, cardId: question.cardId)
    }

    private func advance() {
        index += 1
        selectedChoice = nil
        writtenAnswer = ""
        isAnswered = false
        wasOverridden = false
        if index >= questions.count {
            onFinished(graded)
        }
    }
}

struct TestResultsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckName: String
    let attemptId: String
    /// Starts a new test over the misses; nil hides the button.
    let onRetry: ((String, [LearnEngine.RoundQuestion]) -> Void)?
    let deckIds: [String]
    @State private var graded: [GradedQuestion]

    init(deckName: String, attemptId: String, graded: [GradedQuestion], deckIds: [String] = [],
         onRetry: ((String, [LearnEngine.RoundQuestion]) -> Void)? = nil) {
        self.deckName = deckName
        self.deckIds = deckIds
        self.onRetry = onRetry
        self.attemptId = attemptId
        self._graded = State(initialValue: graded)
    }

    /// Derived from `graded`, not stored separately -- overriding a
    /// question mutates `graded` and these recompute on the next render,
    /// which is what makes the score update live rather than needing its
    /// own explicit refresh step.
    private var correct: Int { graded.filter(\.isCorrect).count }
    private var total: Int { graded.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                SectionLabel("Test results")
                Text(deckName)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .padding(.top, 6)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(correct)")
                        .font(.system(size: 44, weight: .semibold)).monospacedDigit()
                        .tracking(-1.4)
                        .foregroundStyle(correct == total ? GRASPColor.success : GRASPColor.textPrimary)
                        .contentTransition(.numericText())
                    Text("/ \(total)")
                        .font(.system(size: 20, weight: .medium)).monospacedDigit()
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                .padding(.top, 14)
                .animation(.default, value: correct)

                ProgressBar(
                    value: correct, total: total,
                    tint: correct == total ? GRASPColor.success : GRASPColor.accent
                )
                .frame(maxWidth: 260)
                .padding(.top, 14)
                .animation(.default, value: correct)

                Text("Cards you got right just earned a longer flashcard interval. A miss here doesn't "
                     + "change anything -- it just tells you where to focus.")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                Rectangle().fill(GRASPColor.hairline).frame(height: 1)
            }

            List($graded) { $item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(item.isCorrect ? GRASPColor.success : GRASPColor.accent)
                        Text(item.question.prompt)
                            .graspType(.rowTitle)
                            .foregroundStyle(GRASPColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.question.cardId == nil {
                            Label("AI-generated", systemImage: "sparkles")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 11))
                                .foregroundStyle(GRASPColor.accent)
                                .help("AI-generated for this test -- not saved as a card, worth double-checking")
                        }
                    }
                    if !item.isCorrect {
                        Text("You answered: \(item.question.type == .multipleChoice ? item.givenAnswer : (item.question.code?.givenText(item.givenAnswer) ?? item.givenAnswer))")
                            .font(item.question.code == nil ? nil : .system(size: 12, design: .monospaced))
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(item.question.correctAnswer)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Exact/fuzzy text matching is a poor judge of a long or
                    // loaded free-response answer -- offered only for
                    // written questions, and only while still marked wrong.
                    if !item.isCorrect && item.question.type == .written {
                        Button("I actually got this right") { override(item) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(GRASPColor.accent)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                if let onRetry, graded.contains(where: { !$0.isCorrect }) {
                    Button("Retry \(graded.filter { !$0.isCorrect }.count) Missed") {
                        let missed = graded.filter { !$0.isCorrect }.map(\.question)
                        if let id = try? store.startRetryTest(questions: missed, deckIds: deckIds), !id.isEmpty {
                            onRetry(id, missed)
                        }
                    }
                    .buttonStyle(GRASPQuietButton())
                }
                Button("Done") { dismiss() }
                    .buttonStyle(GRASPProminentButton())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(alignment: .top) {
                Rectangle().fill(GRASPColor.hairline).frame(height: 1)
            }
        }
        .background(GRASPColor.canvas)
        .macWindowFrame(minWidth: 520, minHeight: 520)
    }

    /// Flips this one item locally (so the score/progress bar above update
    /// immediately) and persists the same change -- see
    /// `AppStore.overrideTestItemCorrect` for how it corrects the stored
    /// score and grades the card Good, since `finishTest` (which has
    /// already run, by the time this screen is showing) never graded a
    /// miss for it to undo.
    private func override(_ item: GradedQuestion) {
        guard let index = graded.firstIndex(where: { $0.id == item.id }) else { return }
        graded[index].isCorrect = true
        try? store.overrideTestItemCorrect(attemptId: attemptId, ordinal: item.ordinal, cardId: item.question.cardId)
    }
}
