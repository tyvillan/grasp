import Foundation
import GRASPCore
import SwiftCrossUI

/// Which way a deck is being studied, after the Mac's three: Study
/// (flashcards), Learn (a ladder of question types until each card is
/// understood), and Test.
enum StudyMode {
    case flashcards([Card])
    case learn
    case test
}

/// The frame every study mode shares, like the Mac's session windows: a
/// close button, the deck and mode, a count on the right, a progress line.
struct StudyHeader: View {
    let deckName: String
    let mode: String
    let counter: String?
    let fraction: Double
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("✕")
                    .font(Font.system(size: 12, weight: .semibold))
                    .foregroundColor(GRASPColor.textSecondary)
                    .frame(width: 26.0, height: 26.0)
                    .background(GRASPColor.surface)
                    .cornerRadius(13)
                    .onTapGesture(perform: close)
                VStack(alignment: .leading, spacing: 1) {
                    Text(deckName).font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary).lineLimit(1)
                    Text(mode.uppercased()).font(GRASPFont.eyebrow).foregroundColor(GRASPColor.textTertiary)
                }
                Spacer()
                if let counter {
                    Text(counter).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textSecondary).fixedSize()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            ProgressBar(fraction: fraction, height: 2.0)
        }
    }
}

/// A big number over a small label, for the end-of-session tallies.
struct Tally: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(GRASPFont.numeral).foregroundColor(tint)
            Text(label).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
        }
    }
}

// MARK: - Flashcards

/// Flashcards, after the Mac's `FlashcardStudyView`: the prompt, the answer
/// revealed beneath it, then "Needs Review" or "I Know This". Those two
/// verdicts schedule the card and move its Learn level, as on the Mac.
struct FlashcardSession: View {
    let library: Library
    let deckName: String
    let finish: () -> Void
    @State var queue: [Card]
    @State var index = 0
    @State var isFlipped = false
    @State var understood = 0
    @State var toReview = 0
    @State var editing: CardEditorTarget?

    init(library: Library, deckName: String, cards: [Card], finish: @escaping () -> Void) {
        self.library = library
        self.deckName = deckName
        self.finish = finish
        _queue = State(wrappedValue: cards)
    }

    var body: some View {
        VStack(spacing: 0) {
            StudyHeader(deckName: deckName, mode: "Flashcards",
                        counter: "\(min(index, queue.count)) / \(queue.count)",
                        fraction: queue.isEmpty ? 1 : Double(index) / Double(queue.count),
                        close: finish)
            if index < queue.count {
                FlashcardFace(card: queue[index], isFlipped: isFlipped) { isFlipped.toggle() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
            } else {
                completion
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                CardEditor(library: library, target: editing, deckChoices: [], moveTargets: []) {
                    self.editing = nil
                    refreshCurrent()
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if isFlipped {
                HStack(spacing: 10) {
                    VerdictButton(title: "Needs Review", tint: GRASPColor.accent) { submit(false) }
                    VerdictButton(title: "I Know This", tint: GRASPColor.success) { submit(true) }
                }
            } else {
                VerdictButton(title: "Reveal Answer", tint: GRASPColor.textSecondary) { isFlipped = true }
            }
            HStack(spacing: 16) {
                QuietLink(title: "‹ Previous") {
                    if index > 0 { index -= 1; isFlipped = false }
                }
                QuietLink(title: "Edit Card") { editing = CardEditorTarget(card: queue[index], deckId: nil) }
                QuietLink(title: "Suspend") {
                    library.setStatus([queue[index].id], to: .suspended)
                    queue.remove(at: index)
                    isFlipped = false
                }
                Spacer()
                QuietLink(title: "Skip ›") {
                    if index < queue.count - 1 { index += 1; isFlipped = false }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var completion: some View {
        VStack(spacing: 0) {
            Text("Session complete")
                .font(Font.system(size: 22, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            HStack(spacing: 0) {
                Tally(value: understood, label: "understood", tint: GRASPColor.success)
                Rectangle().fill(GRASPColor.hairline).frame(width: 1.0, height: 32.0).padding(.horizontal, 26)
                Tally(value: toReview, label: "to review", tint: GRASPColor.accent)
            }
            .padding(.top, 24)
            Button("Done") { finish() }.fixedSize().padding(.top, 30)
        }
    }

    private func submit(_ knewIt: Bool) {
        guard index < queue.count else { return }
        library.mark(queue[index].id, understood: knewIt)
        if knewIt { understood += 1 } else { toReview += 1 }
        index += 1
        isFlipped = false
    }

    /// After an edit, show the card as it now reads.
    private func refreshCurrent() {
        guard index < queue.count, let fresh = library.card(queue[index].id) else { return }
        queue[index] = fresh
    }
}

/// The card itself: the prompt, and once flipped the answer beneath it, so
/// the question stays readable while you judge the answer.
private struct FlashcardFace: View {
    let card: Card
    let isFlipped: Bool
    let flip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(MathNotation.prettify(card.front))
                .font(Font.system(size: 24, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560.0)
            if isFlipped {
                Rectangle().fill(GRASPColor.hairlineStrong).frame(width: 40.0, height: 1.0).padding(.vertical, 24)
                Text(MathNotation.prettify(card.back))
                    .font(Font.system(size: 17))
                    .foregroundColor(GRASPColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560.0)
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GRASPColor.surface)
        .cornerRadius(16)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .onTapGesture(perform: flip)
    }
}

/// A wide, tinted answer button, like the Mac's `GRASPVerdictButton`.
struct VerdictButton: View {
    let title: String
    let tint: Color
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Text(title)
            .font(GRASPFont.rowTitle.weight(.semibold))
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 40.0)
            .background(isSelected ? GRASPColor.accentSoft : GRASPColor.surface)
            .cornerRadius(9)
            .onTapGesture(perform: action)
    }
}

/// A small text-only action.
struct QuietLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Text(title)
            .font(GRASPFont.meta)
            .foregroundColor(GRASPColor.textTertiary)
            .fixedSize()
            .onTapGesture(perform: action)
    }
}

// MARK: - Learn

/// Learn, after the Mac's `LearnRoundView`: rounds of up to seven cards,
/// each asked at its ladder level (multiple choice, then true / false,
/// then written). A miss comes back two questions later; a checkpoint
/// between rounds shows how the round went and how much of the deck is
/// understood.
struct LearnSession: View {
    let library: Library
    let deckName: String
    let deckIds: [String]
    let finish: () -> Void

    @State var queue: [LearnEngine.RoundQuestion] = []
    @State var roundTotal = 0
    @State var completed = 0
    @State var roundCorrect = 0
    @State var roundIncorrect = 0
    @State var mastery: (mastered: Int, total: Int) = (0, 0)
    @State var started = false
    @State var isAtCheckpoint = false
    @State var answer = AnswerState()

    var body: some View {
        VStack(spacing: 0) {
            StudyHeader(deckName: deckName, mode: "Learn",
                        counter: isAtCheckpoint || queue.isEmpty ? nil : "Question \(min(completed + 1, roundTotal)) of \(roundTotal)",
                        fraction: roundTotal == 0 ? 0 : Double(completed) / Double(roundTotal),
                        close: finish)
            if started && roundTotal == 0 {
                EmptyStudy(title: "Nothing to learn",
                           message: "Every card in \(deckName) is already understood, or the deck has no approved cards yet.",
                           close: finish)
            } else if isAtCheckpoint {
                checkpoint
            } else if let question = queue.first {
                MasteryLine(mastery: mastery)
                QuestionView(question: question, answer: $answer, nextTitle: queue.count == 1 ? "Finish Round" : "Next Question") {
                    advance(question)
                }
            }
        }
        .onAppear { if !started { startRound() } }
    }

    private var checkpoint: some View {
        VStack(spacing: 0) {
            SectionLabel("Checkpoint")
            Text(roundIncorrect == 0 ? "Clean round" : roundCorrect == 0 ? "Rough round -- worth another pass" : "Round complete")
                .font(Font.system(size: 22, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
                .padding(.top, 8)
            HStack(spacing: 0) {
                Tally(value: roundCorrect, label: "correct", tint: GRASPColor.success)
                Rectangle().fill(GRASPColor.hairline).frame(width: 1.0, height: 32.0).padding(.horizontal, 26)
                Tally(value: roundIncorrect, label: "to revisit", tint: GRASPColor.accent)
            }
            .padding(.top, 26)
            VStack(spacing: 7) {
                ProgressBar(fraction: mastery.total == 0 ? 0 : Double(mastery.mastered) / Double(mastery.total),
                            tint: GRASPColor.success)
                Text("\(mastery.mastered) of \(mastery.total) cards in this deck understood")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            .frame(width: 320.0)
            .padding(.top, 30)
            HStack(spacing: 8) {
                Button("Done for Now") { finish() }.fixedSize()
                Button("Keep Going") { startRound() }.fixedSize()
            }
            .padding(.top, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startRound() {
        queue = library.learnRound(inDecks: deckIds)
        roundTotal = queue.count
        completed = 0
        roundCorrect = 0
        roundIncorrect = 0
        isAtCheckpoint = false
        answer = AnswerState()
        mastery = library.mastery(inDecks: deckIds)
        started = true
    }

    private func advance(_ question: LearnEngine.RoundQuestion) {
        guard let cardId = question.cardId else { return }
        let wasCorrect = answer.wasCorrect
        library.recordLearnAnswer(cardId: cardId, wasCorrect: wasCorrect)
        if wasCorrect { roundCorrect += 1 } else { roundIncorrect += 1 }
        mastery = library.mastery(inDecks: deckIds)
        queue.removeFirst()
        if wasCorrect {
            completed += 1
        } else {
            // Back again two questions later, while the answer is fresh.
            queue.insert(question, at: min(2, queue.count))
        }
        answer = AnswerState()
        if queue.isEmpty { isAtCheckpoint = true }
    }
}

private struct MasteryLine: View {
    let mastery: (mastered: Int, total: Int)

    var body: some View {
        HStack(spacing: 8) {
            ProgressBar(fraction: mastery.total == 0 ? 0 : Double(mastery.mastered) / Double(mastery.total),
                        tint: GRASPColor.success, height: 3.0)
            Text("\(mastery.mastered)/\(mastery.total) understood")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }
}

struct EmptyStudy: View {
    let title: String
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
            Text(message)
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420.0)
            Button("Back to Deck") { close() }.fixedSize().padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One question

/// Where a question's answer stands.
struct AnswerState {
    var selected: String?
    var written = ""
    var verdict: AnswerGrading.Verdict?
    var isAnswered = false
    var wasCorrect = false
    var wasOverridden = false
}

/// One question of any type, shared by Learn and Test: the prompt, the
/// choices / statement / answer box, then the verdict and a Next button.
/// `submitsOnChoice` answers a choice on its first click (Test); Learn
/// selects first and waits for Submit, as on the Mac.
struct QuestionView: View {
    let question: LearnEngine.RoundQuestion
    @Binding var answer: AnswerState
    var submitsOnChoice = false
    let nextTitle: String
    var onAnswered: (() -> Void)?
    var onOverride: (() -> Void)?
    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if question.cardId == nil {
                    Chip(text: "AI-generated", tint: GRASPColor.accent, soft: GRASPColor.accentSoft)
                }
                Text(MathNotation.prettify(question.prompt))
                    .font(Font.system(size: 22, weight: .semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560.0)
                    .padding(.top, 30)
                switch question.type {
                case .multipleChoice:
                    ChoiceList(question: question, answer: answer, pick: pick)
                case .trueFalse:
                    TrueFalse(question: question, answer: answer, pick: pick)
                case .written:
                    WrittenAnswer(question: question, answer: $answer)
                }
                VerdictLine(question: question, answer: answer)
                actions
            }
            .frame(maxWidth: 600.0)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if answer.isAnswered {
                if question.type == .written, !answer.wasCorrect, let onOverride {
                    Button("I Actually Got This Right") {
                        answer.wasCorrect = true
                        answer.wasOverridden = true
                        onOverride()
                    }
                    .fixedSize()
                }
                Button(nextTitle) { next() }.fixedSize()
            } else if !submitsOnChoice || question.type == .written {
                Button("Submit") { submit() }
                    .disabled(!canSubmit)
                    .fixedSize()
            }
        }
    }

    private var canSubmit: Bool {
        question.type == .written
            ? !answer.written.trimmingCharacters(in: .whitespaces).isEmpty
            : answer.selected != nil
    }

    private func pick(_ choice: String) {
        guard !answer.isAnswered else { return }
        if submitsOnChoice {
            answer.selected = choice
            submit()
        } else {
            answer.selected = answer.selected == choice ? nil : choice
        }
    }

    private func submit() {
        guard canSubmit, !answer.isAnswered else { return }
        switch question.type {
        case .multipleChoice, .trueFalse:
            answer.wasCorrect = answer.selected == question.correctAnswer
            answer.verdict = answer.wasCorrect ? .correct : .incorrect
        case .written:
            let verdict = AnswerGrading.grade(given: answer.written, correct: question.correctAnswer)
            answer.verdict = verdict
            answer.wasCorrect = verdict != .incorrect
        }
        answer.isAnswered = true
        onAnswered?()
    }
}

private struct ChoiceList: View {
    let question: LearnEngine.RoundQuestion
    let answer: AnswerState
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array((question.choices ?? []).enumerated()), id: \.offset) { index, choice in
                ChoiceRow(letter: String(UnicodeScalar(65 + min(index, 25))!), choice: choice,
                          state: state(of: choice)) { pick(choice) }
            }
        }
        .frame(maxWidth: 560.0)
    }

    private func state(of choice: String) -> ChoiceRow.State {
        if answer.isAnswered {
            if choice == question.correctAnswer { return .right }
            if choice == answer.selected { return .wrong }
            return .idle
        }
        return choice == answer.selected ? .selected : .idle
    }
}

private struct ChoiceRow: View {
    enum State { case idle, selected, right, wrong }
    let letter: String
    let choice: String
    let state: State
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(marker)
                .font(Font.system(size: 11, weight: .semibold))
                .foregroundColor(markerTint)
                .frame(width: 18.0, height: 18.0)
                .background(state == .selected ? GRASPColor.accentSoft : GRASPColor.inset)
                .cornerRadius(5)
            Text(MathNotation.prettify(choice))
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(background)
        .cornerRadius(9)
        .onTapGesture(perform: action)
    }

    private var marker: String {
        switch state {
        case .right: return "✓"
        case .wrong: return "✕"
        default: return letter
        }
    }

    private var markerTint: Color {
        switch state {
        case .right: return GRASPColor.success
        case .wrong, .selected: return GRASPColor.accent
        case .idle: return GRASPColor.textTertiary
        }
    }

    private var background: Color {
        switch state {
        case .right: return GRASPColor.successSoft
        case .wrong, .selected: return GRASPColor.accentSoft
        case .idle: return GRASPColor.surface
        }
    }
}

private struct TrueFalse: View {
    let question: LearnEngine.RoundQuestion
    let answer: AnswerState
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(MathNotation.prettify(question.statement ?? ""))
                .font(Font.system(size: 17))
                .foregroundColor(GRASPColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520.0)
            HStack(spacing: 10) {
                option("True")
                option("False")
            }
            .frame(width: 340.0)
        }
    }

    private func option(_ label: String) -> some View {
        VerdictButton(title: label, tint: tint(label), isSelected: !answer.isAnswered && answer.selected == label) {
            pick(label)
        }
    }

    private func tint(_ label: String) -> Color {
        guard answer.isAnswered else {
            return answer.selected == label ? GRASPColor.accent : GRASPColor.textSecondary
        }
        if label == question.correctAnswer { return GRASPColor.success }
        return label == answer.selected ? GRASPColor.accent : GRASPColor.textTertiary
    }
}

private struct WrittenAnswer: View {
    let question: LearnEngine.RoundQuestion
    @Binding var answer: AnswerState

    var body: some View {
        VStack(spacing: 10) {
            TextField("Type the answer", text: $answer.written)
                .frame(width: 420.0)
                .disabled(answer.isAnswered)
            if answer.isAnswered, answer.verdict != .correct {
                HStack(spacing: 6) {
                    Text("Answer").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                    Text(MathNotation.prettify(question.correctAnswer))
                        .font(GRASPFont.body)
                        .foregroundColor(GRASPColor.textPrimary)
                }
            }
        }
    }
}

private struct VerdictLine: View {
    let question: LearnEngine.RoundQuestion
    let answer: AnswerState

    var body: some View {
        if answer.isAnswered {
            Text(text)
                .font(GRASPFont.body)
                .foregroundColor(answer.wasCorrect ? GRASPColor.success : GRASPColor.accent)
        }
    }

    private var text: String {
        if answer.wasOverridden { return "✓ Marked correct" }
        switch answer.verdict {
        case .correct: return "✓ Correct"
        case .close: return "✓ Close -- check your spelling"
        default:
            return question.type == .written ? "✕ Not quite" : "✕ Not quite -- \(MathNotation.prettify(question.correctAnswer))"
        }
    }
}
