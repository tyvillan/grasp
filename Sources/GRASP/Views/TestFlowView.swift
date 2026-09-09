import SwiftUI
import GRASPCore

/// Drives the three-screen test flow (setup -> running -> results) as one
/// continuous `.sheet(item:)` presentation in the caller: changing this
/// value to a new case swaps the sheet's content in place rather than
/// dismissing and re-presenting, so the flow reads as one flow, not three.
enum TestPhase: Identifiable {
    case setup
    case running(attemptId: String, questions: [LearnEngine.RoundQuestion])
    case results(correct: Int, total: Int, questions: [LearnEngine.RoundQuestion])

    var id: String {
        switch self {
        case .setup: return "setup"
        case .running(let attemptId, _): return "running-\(attemptId)"
        case .results: return "results"
        }
    }
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
    let deckId: String
    let deckName: String
    let onStart: (String, [LearnEngine.RoundQuestion]) -> Void

    @State private var questionCount = 20
    @State private var allowMultipleChoice = true
    @State private var allowWritten = true
    @State private var allowTrueFalse = true
    @State private var shuffle = true
    @State private var excludeMastered = false

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
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Test") {
                    let config = TestBuilder.Config(
                        questionCount: questionCount, allowMultipleChoice: allowMultipleChoice,
                        allowWritten: allowWritten, allowTrueFalse: allowTrueFalse, shuffle: shuffle,
                        excludeMastered: excludeMastered
                    )
                    guard let (attemptId, questions) = try? store.startTest(deckId: deckId, config: config),
                          !questions.isEmpty else { return }
                    onStart(attemptId, questions)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!allowMultipleChoice && !allowWritten && !allowTrueFalse)
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
    let onFinished: () -> Void

    @State private var index = 0
    @State private var selectedChoice: String?
    @State private var writtenAnswer = ""
    @State private var isAnswered = false
    @State private var lastCorrect = false
    @FocusState private var writtenFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if index < questions.count {
                questionBody(questions[index])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GRASPColor.canvas)
        .frame(minWidth: 620, minHeight: 520)
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
            Text(question.prompt)
                .graspType(.studyPrompt)
                .foregroundStyle(GRASPColor.textPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 560)
                .padding(.top, 42)

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
                        Text(lastCorrect ? "Correct" : "Not quite -- \(question.correctAnswer)")
                            .graspType(.body)
                    }
                    .foregroundStyle(lastCorrect ? GRASPColor.success : GRASPColor.accent)

                    Button(index == questions.count - 1 ? "Finish test" : "Next question") { advance() }
                        .buttonStyle(GRASPProminentButton())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
    }

    private func choiceList(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 7) {
            ForEach(Array((question.choices ?? []).enumerated()), id: \.element) { position, choice in
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
        isAnswered = true
        try? store.submitTestAnswer(attemptId: attemptId, cardId: question.cardId, given: given, isCorrect: correct)
    }

    private func advance() {
        index += 1
        selectedChoice = nil
        writtenAnswer = ""
        isAnswered = false
        if index >= questions.count {
            onFinished()
        }
    }
}

struct TestResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let deckName: String
    let correct: Int
    let total: Int
    let questions: [LearnEngine.RoundQuestion]

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
                    Text("/ \(total)")
                        .font(.system(size: 20, weight: .medium)).monospacedDigit()
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                .padding(.top, 14)

                ProgressBar(
                    value: correct, total: total,
                    tint: correct == total ? GRASPColor.success : GRASPColor.accent
                )
                .frame(maxWidth: 260)
                .padding(.top, 14)

                Text("Missed questions were added back to your flashcard queue.")
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

            List(questions) { question in
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.prompt)
                        .graspType(.rowTitle)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question.correctAnswer)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
}
