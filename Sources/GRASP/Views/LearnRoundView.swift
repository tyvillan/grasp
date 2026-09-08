import SwiftUI
import GRASPCore

/// One Quizlet-style Learn round: multiple choice / true-false / written
/// questions, escalating with each card's own ladder level. A miss doesn't
/// drop the card -- it's requeued a few slots further back in this same
/// round's live queue, so it comes back before the round ends.
struct LearnRoundView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckId: String
    let deckName: String

    @State private var queue: [LearnEngine.RoundQuestion] = []
    @State private var completedCardIds: Set<String> = []
    @State private var selectedChoice: String?
    @State private var writtenAnswer = ""
    @State private var verdict: AnswerGrading.Verdict?
    @State private var isAnswered = false
    @State private var isComplete = false
    @FocusState private var writtenFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isComplete {
                completionView
            } else if queue.isEmpty {
                ContentUnavailableView(
                    "Nothing to learn", systemImage: "checkmark.circle",
                    description: Text("Every card in \(deckName) is already mastered, or the deck has no active cards yet.")
                )
                .frame(maxHeight: .infinity)
            } else {
                questionView(queue[0])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .task { load() }
    }

    private var header: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            Text(deckName).font(.headline)
            Spacer()
            Text("\(completedCardIds.count) correct this round")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var completionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "party.popper").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Round complete").font(.title2.bold())
            Text("\(completedCardIds.count) card\(completedCardIds.count == 1 ? "" : "s") answered correctly.")
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        queue = (try? store.learnRound(deckId: deckId)) ?? []
    }

    @ViewBuilder
    private func questionView(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 20) {
            Text(question.prompt)
                .font(.title2.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            switch question.type {
            case .multipleChoice:
                multipleChoiceBody(question)
            case .trueFalse:
                trueFalseBody(question)
            case .written:
                writtenBody(question)
            }

            if let verdict {
                verdictBanner(verdict)
            }

            Spacer()

            if isAnswered {
                Button(queue.count == 1 ? "Finish" : "Next") { advance(question, wasCorrect: lastAnswerCorrect) }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 24)
            }
        }
    }

    @State private var lastAnswerCorrect = false

    private func multipleChoiceBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(question.choices ?? [], id: \.self) { choice in
                Button {
                    guard !isAnswered else { return }
                    selectedChoice = choice
                    submit(choice == question.correctAnswer, question: question)
                } label: {
                    HStack {
                        Text(choice)
                        Spacer()
                    }
                    .padding(10)
                    .background(choiceBackground(choice, correct: question.correctAnswer), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isAnswered)
            }
        }
        .padding(.horizontal, 40)
    }

    private func choiceBackground(_ choice: String, correct: String) -> Color {
        guard isAnswered else { return .secondary.opacity(0.1) }
        if choice == correct { return .green.opacity(0.3) }
        if choice == selectedChoice { return .red.opacity(0.3) }
        return .secondary.opacity(0.1)
    }

    private func trueFalseBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 16) {
            Text(question.statement ?? "")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            HStack(spacing: 12) {
                Button("True") {
                    guard !isAnswered else { return }
                    selectedChoice = "True"
                    submit(question.correctAnswer == "True", question: question)
                }
                .disabled(isAnswered)
                Button("False") {
                    guard !isAnswered else { return }
                    selectedChoice = "False"
                    submit(question.correctAnswer == "False", question: question)
                }
                .disabled(isAnswered)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func writtenBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 12) {
            TextField("Type the answer", text: $writtenAnswer)
                .textFieldStyle(.roundedBorder)
                .focused($writtenFieldFocused)
                .disabled(isAnswered)
                .onSubmit {
                    guard !isAnswered, !writtenAnswer.isEmpty else { return }
                    let result = AnswerGrading.grade(given: writtenAnswer, correct: question.correctAnswer)
                    verdict = result
                    submit(result != .incorrect, question: question)
                }
                .padding(.horizontal, 40)
            if isAnswered, verdict != .correct {
                Text("Correct answer: \(question.correctAnswer)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .task { writtenFieldFocused = true }
    }

    @ViewBuilder
    private func verdictBanner(_ verdict: AnswerGrading.Verdict) -> some View {
        switch verdict {
        case .correct:
            Label("Correct", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .close:
            Label("Close -- check your spelling", systemImage: "checkmark.circle").foregroundStyle(.orange)
        case .incorrect:
            Label("Not quite", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func submit(_ correct: Bool, question: LearnEngine.RoundQuestion) {
        lastAnswerCorrect = correct
        if verdict == nil { verdict = correct ? .correct : .incorrect }
        isAnswered = true
    }

    private func advance(_ question: LearnEngine.RoundQuestion, wasCorrect: Bool) {
        try? store.recordLearnAnswer(cardId: question.cardId, wasCorrect: wasCorrect)
        queue.removeFirst()
        if wasCorrect {
            completedCardIds.insert(question.cardId)
        } else {
            // Requeue a few slots back so it resurfaces before the round
            // ends, rather than dropping it entirely on a miss.
            let insertAt = min(2, queue.count)
            queue.insert(question, at: insertAt)
        }
        selectedChoice = nil
        writtenAnswer = ""
        verdict = nil
        isAnswered = false
        if queue.isEmpty { isComplete = true }
    }
}
