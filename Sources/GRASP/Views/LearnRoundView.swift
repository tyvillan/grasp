import SwiftUI
import GRASPCore

/// One Quizlet-style Learn round: multiple choice / true-false / written
/// questions, escalating with each card's own ladder level. A miss doesn't
/// drop the card -- it's requeued a few slots further back in this same
/// round's live queue, so it comes back before the round ends. Answering
/// is select-then-submit, not tap-to-grade: choosing an option only
/// highlights it (tap again to deselect, or pick a different one) until
/// Submit locks it in and reveals correctness. A round-progress bar and a
/// deck-wide mastery bar both track live, and each round ends at a
/// checkpoint -- a summary with the choice to keep going or stop, rather
/// than silently starting another round or ending the session outright.
struct LearnRoundView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckId: String
    let deckName: String

    @State private var queue: [LearnEngine.RoundQuestion] = []
    @State private var roundTotal = 0
    @State private var completedCardIds: Set<String> = []
    @State private var roundCorrect = 0
    @State private var roundIncorrect = 0
    @State private var deckMastery: (mastered: Int, total: Int) = (0, 0)
    @State private var selectedChoice: String?
    @State private var writtenAnswer = ""
    @State private var verdict: AnswerGrading.Verdict?
    @State private var isAnswered = false
    @State private var isAtCheckpoint = false
    @State private var isEmpty = false
    @FocusState private var writtenFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            progressBars
            Divider()
            if isEmpty {
                ContentUnavailableView(
                    "Nothing to learn", systemImage: "checkmark.circle",
                    description: Text("Every card in \(deckName) is already understood, or the deck has no active cards yet.")
                )
                .frame(maxHeight: .infinity)
            } else if isAtCheckpoint {
                checkpointView
            } else if !queue.isEmpty {
                questionView(queue[0])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 500)
        .task { startRound() }
    }

    private var header: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            Text(deckName).font(.headline)
            Spacer()
            Text("\(roundCorrect + roundIncorrect)/\(LearnEngine.roundSize) this round")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding()
    }

    /// `queue.count + completedCardIds.count` is invariant across a round:
    /// a miss requeues (removes one, reinserts one) and a correct answer
    /// only removes -- so completed-so-far divided by that sum is exactly
    /// how far through the round's original cards this is, reaching 1.0
    /// precisely when the round ends.
    private var progressBars: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(value: completedCardIds.count, total: roundTotal)
                Text("Question \(min(completedCardIds.count + 1, roundTotal)) of \(roundTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(value: deckMastery.mastered, total: deckMastery.total)
                Text("\(deckMastery.mastered)/\(deckMastery.total) cards understood")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private var checkpointView: some View {
        VStack(spacing: 16) {
            Image(systemName: "flag.checkered.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(GRASPColor.accent)
            Text("Checkpoint").font(.title2.bold())
            VStack(spacing: 4) {
                Text("\(roundCorrect) correct, \(roundIncorrect) need more review this round")
                    .foregroundStyle(.secondary)
                Text("\(deckMastery.mastered) of \(deckMastery.total) cards understood overall")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Done for now") { dismiss() }
                Button("Continue Studying") { startRound() }
                    .buttonStyle(.borderedProminent)
                    .tint(GRASPColor.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startRound() {
        queue = (try? store.learnRound(deckId: deckId)) ?? []
        roundTotal = queue.count
        completedCardIds = []
        roundCorrect = 0
        roundIncorrect = 0
        isAtCheckpoint = false
        isEmpty = queue.isEmpty
        resetAnswerState()
        refreshMastery()
    }

    private func refreshMastery() {
        deckMastery = (try? store.deckMastery(deckId: deckId)) ?? (0, 0)
    }

    @ViewBuilder
    private func questionView(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 20) {
            Text(question.prompt)
                .font(.title2.weight(.medium))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
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

            actionButton(question)
                .padding(.bottom, 24)
        }
    }

    @State private var lastAnswerCorrect = false

    @ViewBuilder
    private func actionButton(_ question: LearnEngine.RoundQuestion) -> some View {
        if isAnswered {
            Button(queue.count == 1 ? "Finish Round" : "Next") { advance(question, wasCorrect: lastAnswerCorrect) }
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Submit") { trySubmit(question) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit(question))
        }
    }

    private func canSubmit(_ question: LearnEngine.RoundQuestion) -> Bool {
        switch question.type {
        case .multipleChoice, .trueFalse:
            return selectedChoice != nil
        case .written:
            return !writtenAnswer.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func trySubmit(_ question: LearnEngine.RoundQuestion) {
        guard canSubmit(question) else { return }
        switch question.type {
        case .multipleChoice, .trueFalse:
            guard let selectedChoice else { return }
            submit(selectedChoice == question.correctAnswer, question: question)
        case .written:
            let result = AnswerGrading.grade(given: writtenAnswer, correct: question.correctAnswer)
            verdict = result
            submit(result != .incorrect, question: question)
        }
    }

    private func multipleChoiceBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(question.choices ?? [], id: \.self) { choice in
                Button {
                    toggleSelection(choice)
                } label: {
                    HStack {
                        Text(choice).textSelection(.enabled)
                        Spacer()
                    }
                    .padding(10)
                    .background(choiceBackground(choice, correct: question.correctAnswer), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isPendingSelection(choice) ? GRASPColor.accent : .clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAnswered)
            }
        }
        .padding(.horizontal, 40)
    }

    /// Tapping the already-selected choice deselects it -- picking an
    /// answer isn't a one-way commitment until Submit.
    private func toggleSelection(_ choice: String) {
        guard !isAnswered else { return }
        selectedChoice = (selectedChoice == choice) ? nil : choice
    }

    private func isPendingSelection(_ choice: String) -> Bool {
        !isAnswered && selectedChoice == choice
    }

    private func choiceBackground(_ choice: String, correct: String) -> Color {
        if isAnswered {
            if choice == correct { return .green.opacity(0.3) }
            if choice == selectedChoice { return .red.opacity(0.3) }
            return .secondary.opacity(0.1)
        }
        return choice == selectedChoice ? GRASPColor.accentSoft : Color.secondary.opacity(0.1)
    }

    private func trueFalseBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 16) {
            Text(question.statement ?? "")
                .font(.title3)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 40)
            HStack(spacing: 12) {
                trueFalseButton("True")
                trueFalseButton("False")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func trueFalseButton(_ label: String) -> some View {
        Button(label) { toggleSelection(label) }
            .tint(isPendingSelection(label) ? GRASPColor.accent : nil)
            .disabled(isAnswered)
    }

    private func writtenBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 12) {
            TextField("Type the answer", text: $writtenAnswer)
                .textFieldStyle(.roundedBorder)
                .focused($writtenFieldFocused)
                .disabled(isAnswered)
                .onSubmit { trySubmit(question) }
                .padding(.horizontal, 40)
            if isAnswered, verdict != .correct {
                Text("Correct answer: \(question.correctAnswer)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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

    private func resetAnswerState() {
        selectedChoice = nil
        writtenAnswer = ""
        verdict = nil
        isAnswered = false
    }

    private func advance(_ question: LearnEngine.RoundQuestion, wasCorrect: Bool) {
        try? store.recordLearnAnswer(cardId: question.cardId, wasCorrect: wasCorrect)
        if wasCorrect { roundCorrect += 1 } else { roundIncorrect += 1 }
        refreshMastery()

        queue.removeFirst()
        if wasCorrect {
            completedCardIds.insert(question.cardId)
        } else {
            // Requeue a few slots back so it resurfaces before the round
            // ends, rather than dropping it entirely on a miss.
            let insertAt = min(2, queue.count)
            queue.insert(question, at: insertAt)
        }
        resetAnswerState()
        if queue.isEmpty { isAtCheckpoint = true }
    }
}
