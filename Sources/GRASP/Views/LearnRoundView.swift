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
        .background(GRASPColor.canvas)
        .frame(minWidth: 620, minHeight: 540)
        .task { startRound() }
    }

    /// Two progress readings sit in the chrome, and they answer different
    /// questions -- "how far through this round" (immediate, segmented by
    /// question) and "how much of the deck is understood" (the long arc).
    /// They're deliberately drawn at different weights and tints so they
    /// aren't mistaken for the same measurement stacked twice.
    ///
    /// `queue.count + completedCardIds.count` is invariant across a round:
    /// a miss requeues (removes one, reinserts one) and a correct answer
    /// only removes -- so completed-so-far divided by that sum is exactly
    /// how far through the round's original cards this is, reaching 1.0
    /// precisely when the round ends.
    private var header: some View {
        VStack(spacing: 14) {
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
                .help("Leave this round")

                VStack(alignment: .leading, spacing: 1) {
                    Text(deckName)
                        .graspType(.title)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .lineLimit(1)
                    Text("Learn")
                        .graspType(.meta)
                        .textCase(.uppercase)
                        .tracking(0.7)
                        .foregroundStyle(GRASPColor.textTertiary)
                }

                Spacer(minLength: 12)

                if !isEmpty && !isAtCheckpoint {
                    Text("Question \(min(completedCardIds.count + 1, roundTotal)) of \(roundTotal)")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .monospacedDigit()
                }
            }

            if !isEmpty {
                VStack(spacing: 8) {
                    ProgressBar(
                        value: completedCardIds.count, total: roundTotal,
                        checkpoints: roundTotal, height: 7
                    )
                    HStack(spacing: 8) {
                        ProgressBar(
                            value: deckMastery.mastered, total: deckMastery.total,
                            tint: GRASPColor.success, height: 3
                        )
                        Text("\(deckMastery.mastered)/\(deckMastery.total) understood")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(alignment: .bottom) {
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
        }
    }

    private var checkpointView: some View {
        VStack(spacing: 0) {
            SectionLabel("Checkpoint")
            Text(checkpointHeadline)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(GRASPColor.textPrimary)
                .padding(.top, 8)

            HStack(spacing: 0) {
                tally(roundCorrect, "correct", GRASPColor.success)
                Rectangle()
                    .fill(GRASPColor.hairline)
                    .frame(width: 1, height: 32)
                    .padding(.horizontal, 26)
                tally(roundIncorrect, "to revisit", GRASPColor.accent)
            }
            .padding(.top, 26)

            VStack(spacing: 7) {
                ProgressBar(
                    value: deckMastery.mastered, total: deckMastery.total,
                    tint: GRASPColor.success
                )
                Text("\(deckMastery.mastered) of \(deckMastery.total) cards in this deck understood")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .frame(maxWidth: 320)
            .padding(.top, 30)

            HStack(spacing: 8) {
                Button("Done for now") { dismiss() }
                    .buttonStyle(GRASPQuietButton())
                Button("Keep going") { startRound() }
                    .buttonStyle(GRASPProminentButton())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Names what just happened rather than repeating the word already
    /// used as the section label above it.
    private var checkpointHeadline: String {
        if roundIncorrect == 0 { return "Clean round" }
        if roundCorrect == 0 { return "Rough round -- worth another pass" }
        return "Round complete"
    }

    private func tally(_ value: Int, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").graspType(.numeral).foregroundStyle(tint)
            Text(label).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
        }
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

    /// The prompt gets the top third of the canvas to itself and the
    /// answer controls group tightly beneath it, rather than everything
    /// sharing one evenly-spaced stack -- the question is what's being
    /// read, the choices are what's being operated.
    @ViewBuilder
    private func questionView(_ question: LearnEngine.RoundQuestion) -> some View {
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
                    multipleChoiceBody(question)
                case .trueFalse:
                    trueFalseBody(question)
                case .written:
                    writtenBody(question)
                }

                if let verdict {
                    verdictBanner(verdict)
                }

                actionButton(question)
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
    }

    @State private var lastAnswerCorrect = false

    @ViewBuilder
    private func actionButton(_ question: LearnEngine.RoundQuestion) -> some View {
        if isAnswered {
            Button(queue.count == 1 ? "Finish round" : "Next question") {
                advance(question, wasCorrect: lastAnswerCorrect)
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
        } else {
            Button("Submit") { trySubmit(question) }
                .buttonStyle(GRASPProminentButton())
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

    /// Each choice is lettered. The letter sits in a fixed slot so every
    /// answer's text starts on the same x, and once graded the slot swaps
    /// to a check or cross -- the row's state reads from its shape, not
    /// from a tint alone.
    private func multipleChoiceBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 7) {
            ForEach(Array((question.choices ?? []).enumerated()), id: \.element) { index, choice in
                Button {
                    toggleSelection(choice)
                } label: {
                    HStack(alignment: .top, spacing: 11) {
                        choiceMarker(choice, index: index, correct: question.correctAnswer)
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
                            .fill(choiceBackground(choice, correct: question.correctAnswer))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                choiceBorder(choice, correct: question.correctAnswer),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAnswered)
            }
        }
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private func choiceMarker(_ choice: String, index: Int, correct: String) -> some View {
        let letter = String(UnicodeScalar(65 + min(index, 25))!)
        Group {
            if isAnswered && choice == correct {
                Image(systemName: "checkmark").foregroundStyle(GRASPColor.success)
            } else if isAnswered && choice == selectedChoice {
                Image(systemName: "xmark").foregroundStyle(GRASPColor.accent)
            } else {
                Text(letter)
                    .foregroundStyle(
                        isPendingSelection(choice) ? GRASPColor.accent : GRASPColor.textTertiary
                    )
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 17, height: 17)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isPendingSelection(choice) ? GRASPColor.accentSoft : GRASPColor.inset)
        )
        .padding(.top, 1)
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

    /// Correctness uses the palette's own success teal and accent amber
    /// rather than raw system green/red, so a graded question still looks
    /// like it belongs to this app.
    private func choiceBackground(_ choice: String, correct: String) -> Color {
        if isAnswered {
            if choice == correct { return GRASPColor.successSoft }
            if choice == selectedChoice { return GRASPColor.accentSoft }
            return GRASPColor.surface
        }
        return choice == selectedChoice ? GRASPColor.accentSoft : GRASPColor.surface
    }

    private func choiceBorder(_ choice: String, correct: String) -> Color {
        if isAnswered {
            if choice == correct { return GRASPColor.success.opacity(0.55) }
            if choice == selectedChoice { return GRASPColor.accent.opacity(0.55) }
            return GRASPColor.hairline
        }
        return isPendingSelection(choice) ? GRASPColor.accent : GRASPColor.hairline
    }

    private func trueFalseBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 18) {
            Text(question.statement ?? "")
                .graspType(.studyAnswer)
                .foregroundStyle(GRASPColor.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
            HStack(spacing: 10) {
                trueFalseButton("True")
                trueFalseButton("False")
            }
            .frame(maxWidth: 340)
        }
    }

    private func trueFalseButton(_ label: String) -> some View {
        Button(label) { toggleSelection(label) }
            .buttonStyle(
                GRASPVerdictButton(
                    tint: isPendingSelection(label) ? GRASPColor.accent : GRASPColor.textSecondary
                )
            )
            .disabled(isAnswered)
    }

    private func writtenBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 10) {
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
                .onSubmit { trySubmit(question) }
                .frame(maxWidth: 420)
            if isAnswered, verdict != .correct {
                HStack(spacing: 5) {
                    Text("Answer").graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    Text(question.correctAnswer)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .textSelection(.enabled)
                }
            }
        }
        .task { writtenFieldFocused = true }
    }

    @ViewBuilder
    private func verdictBanner(_ verdict: AnswerGrading.Verdict) -> some View {
        switch verdict {
        case .correct:
            verdictLabel("Correct", "checkmark.circle.fill", GRASPColor.success)
        case .close:
            verdictLabel("Close -- check your spelling", "checkmark.circle", GRASPColor.accent)
        case .incorrect:
            verdictLabel("Not quite", "xmark.circle.fill", GRASPColor.accent)
        }
    }

    private func verdictLabel(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(text).graspType(.body)
        }
        .foregroundStyle(tint)
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
