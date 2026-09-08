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
            Divider()
            if index < questions.count {
                questionBody(questions[index])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Text(deckName).font(.headline)
            Spacer()
            Text("\(index + 1)/\(questions.count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .padding()
    }

    @ViewBuilder
    private func questionBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 20) {
            Text(question.prompt).font(.title2.weight(.medium)).multilineTextAlignment(.center).padding(.top, 24)
            switch question.type {
            case .multipleChoice:
                VStack(spacing: 8) {
                    ForEach(question.choices ?? [], id: \.self) { choice in
                        Button {
                            guard !isAnswered else { return }
                            selectedChoice = choice
                            submit(choice == question.correctAnswer, given: choice, question: question)
                        } label: {
                            HStack { Text(choice); Spacer() }
                                .padding(10)
                                .background(background(choice, correct: question.correctAnswer), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(isAnswered)
                    }
                }
                .padding(.horizontal, 40)
            case .trueFalse:
                VStack(spacing: 16) {
                    Text(question.statement ?? "").font(.title3).multilineTextAlignment(.center).padding(.horizontal, 40)
                    HStack(spacing: 12) {
                        Button("True") {
                            guard !isAnswered else { return }
                            submit(question.correctAnswer == "True", given: "True", question: question)
                        }.disabled(isAnswered)
                        Button("False") {
                            guard !isAnswered else { return }
                            submit(question.correctAnswer == "False", given: "False", question: question)
                        }.disabled(isAnswered)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            case .written:
                TextField("Type the answer", text: $writtenAnswer)
                    .textFieldStyle(.roundedBorder)
                    .focused($writtenFieldFocused)
                    .disabled(isAnswered)
                    .onSubmit {
                        guard !isAnswered, !writtenAnswer.isEmpty else { return }
                        let verdict = AnswerGrading.grade(given: writtenAnswer, correct: question.correctAnswer)
                        submit(verdict != .incorrect, given: writtenAnswer, question: question)
                    }
                    .padding(.horizontal, 40)
                    .task { writtenFieldFocused = true }
            }

            if isAnswered {
                Label(lastCorrect ? "Correct" : "Not quite (\(question.correctAnswer))",
                      systemImage: lastCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(lastCorrect ? .green : .red)
            }

            Spacer()

            if isAnswered {
                Button(index == questions.count - 1 ? "Finish" : "Next") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 24)
            }
        }
    }

    private func background(_ choice: String, correct: String) -> Color {
        guard isAnswered else { return .secondary.opacity(0.1) }
        if choice == correct { return .green.opacity(0.3) }
        if choice == selectedChoice { return .red.opacity(0.3) }
        return .secondary.opacity(0.1)
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
            VStack(spacing: 8) {
                Text("Test Results").font(.title2.bold())
                Text(deckName).foregroundStyle(.secondary)
                Text("\(correct) / \(total)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(correct == total ? .green : .primary)
                Text("Missed questions were added back to your flashcard queue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()
            List(questions) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.prompt).font(.body.weight(.medium))
                    Text(question.correctAnswer).font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).padding()
        }
        .frame(minWidth: 480, minHeight: 480)
    }
}
