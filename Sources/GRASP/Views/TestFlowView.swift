import SwiftUI
import GRASPCore

/// Drives the three-screen test flow (setup -> running -> results) as one
/// continuous `.sheet(item:)` presentation in the caller: changing this
/// value to a new case swaps the sheet's content in place rather than
/// dismissing and re-presenting, so the flow reads as one flow, not three.
enum TestPhase: Identifiable {
    case setup
    case running(attemptId: String, questions: [LearnEngine.RoundQuestion], aiWarning: String?)
    case results(attemptId: String, graded: [GradedQuestion])

    var id: String {
        switch self {
        case .setup: return "setup"
        case .running(let attemptId, _, _): return "running-\(attemptId)"
        case .results(let attemptId, _): return "results-\(attemptId)"
        }
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
/// beside the correct answer. Every miss also gets fed back into FSRS as
/// an "Again" grade (`AppStore.finishTest`), so a test session also
/// tightens the flashcard schedule.
struct TestSetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckIds: [String]
    let deckName: String
    let onStart: (String, [LearnEngine.RoundQuestion], String?) -> Void

    @State private var questionCount = 20
    @State private var allowMultipleChoice = true
    @State private var allowWritten = true
    @State private var allowTrueFalse = true
    @State private var shuffle = true
    @State private var excludeMastered = false
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Test: \(deckName)").font(.headline)

            Stepper("Questions: \(questionCount)", value: $questionCount, in: 5...100, step: 5)

            GroupBox("Question Types") {
                VStack(alignment: .leading) {
                    Toggle("Multiple choice", isOn: $allowMultipleChoice)
                    Toggle("Written", isOn: $allowWritten)
                    Toggle("True / False", isOn: $allowTrueFalse)
                }
            }

            Toggle("Shuffle order", isOn: $shuffle)
            Toggle("Only cards I haven't marked as known", isOn: $excludeMastered)

            if !allowMultipleChoice && !allowWritten && !allowTrueFalse {
                Text("Enable at least one question type.").font(.caption).foregroundStyle(.red)
            } else if noQuestions {
                Text(excludeMastered
                     ? "No cards match -- every card here is marked as known. Turn off \"Only cards I haven't marked as known\" to test on them anyway."
                     : "No cards match these settings, so there's nothing to test.")
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
                        allowWritten: allowWritten, allowTrueFalse: allowTrueFalse, shuffle: shuffle,
                        excludeMastered: excludeMastered
                    )
                    isStarting = true
                    noQuestions = false
                    let run = (store.isAITestQuestionsEnabled && allowWritten)
                        ? AIActivity(headline: "Writing AI questions from your notes")
                        : nil
                    aiActivity = run
                    Task {
                        defer {
                            run?.finish()
                            aiActivity = nil
                            isStarting = false
                        }
                        let start = { try await store.startTest(deckIds: deckIds, config: config) }
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
                .keyboardShortcut(.defaultAction)
                .disabled(isStarting || (!allowMultipleChoice && !allowWritten && !allowTrueFalse))
            }
        }
        .padding(20)
        .frame(width: 380)
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
    let onFinished: ([GradedQuestion]) -> Void

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
        .frame(minWidth: 620, minHeight: 520)
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
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GRASPColor.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(GRASPColor.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Cancel this test")

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
            if question.cardId == nil {
                Label("AI-generated", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GRASPColor.accent)
                    .help("AI-generated for this test -- not saved as a card, worth double-checking")
                    .padding(.top, 42)
            }

            Text(question.prompt)
                .graspType(.studyPrompt)
                .foregroundStyle(GRASPColor.textPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 560)
                .padding(.top, question.cardId == nil ? 10 : 42)

            Spacer(minLength: 28)

            VStack(spacing: 14) {
                switch question.type {
                case .multipleChoice:
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

                if isAnswered {
                    HStack(spacing: 6) {
                        Image(systemName: lastCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12))
                        Text(lastCorrect
                             ? (wasOverridden ? "Marked correct" : "Correct")
                             : "Not quite -- \(question.correctAnswer)")
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
                        Text(choice)
                            .graspType(.body)
                            .foregroundStyle(GRASPColor.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
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
    /// score correctly off it later, and there's no FSRS "Again" grade to
    /// undo yet either (that only happens at finish time).
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
    @State private var graded: [GradedQuestion]

    init(deckName: String, attemptId: String, graded: [GradedQuestion]) {
        self.deckName = deckName
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

                Text("Missed questions from your cards were added back to your flashcard queue.")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
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
                        Text("You answered: \(item.givenAnswer)")
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
        .frame(minWidth: 520, minHeight: 520)
    }

    /// Flips this one item locally (so the score/progress bar above update
    /// immediately) and persists the same change -- see
    /// `AppStore.overrideTestItemCorrect` for how it corrects the stored
    /// score and, best-effort, the FSRS grade already applied for this
    /// miss when `finishTest` ran (which it always has, by the time this
    /// screen is showing).
    private func override(_ item: GradedQuestion) {
        guard let index = graded.firstIndex(where: { $0.id == item.id }) else { return }
        graded[index].isCorrect = true
        try? store.overrideTestItemCorrect(attemptId: attemptId, ordinal: item.ordinal, cardId: item.question.cardId)
    }
}
