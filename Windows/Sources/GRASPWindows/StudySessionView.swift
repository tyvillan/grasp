import Foundation
import GRASPCore
import SwiftCrossUI

/// Which way a deck is being studied, after the Mac's three: Study
/// (flashcards), Learn (a ladder of question types until each card is
/// understood), and Test.
enum StudyMode {
    case flashcards([Card])
    case learn
    /// A Learn round on just these cards ("Practice weakest").
    case practice(Set<String>)
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
                    Text(counter).font(Font.system(size: 17, weight: .semibold)).foregroundColor(GRASPColor.textSecondary).fixedSize()
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
    /// 30 on a Learn checkpoint, 44 on the flashcard finish, as on the Mac.
    var size = 30.0

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(Font.system(size: size, weight: .heavy)).foregroundColor(tint)
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
    /// The finish screen's one follow-on ("Learn the 3 you missed", "Take a
    /// test"); nil hides it.
    var onNext: ((StudyNextStep) -> Void)?
    /// The deck's ids, to offer "Take a test" when it has approved cards.
    var deckIds: [String] = []
    @State var queue: [Card]
    @State var missed: Set<String> = []
    @State var index = 0
    @State var isFlipped = false
    @State var understood = 0
    @State var toReview = 0
    @State var editing: CardEditorTarget?
    @State var timer: FocusTimerModel

    init(library: Library, deckName: String, cards: [Card], finish: @escaping () -> Void,
         deckIds: [String] = [], onNext: ((StudyNextStep) -> Void)? = nil) {
        self.library = library
        self.deckName = deckName
        self.finish = finish
        self.deckIds = deckIds
        self.onNext = onNext
        _queue = State(wrappedValue: cards)
        let settings = library.settings
        _timer = State(wrappedValue: FocusTimerModel(workMinutes: settings.focusWorkMinutes,
                                                     breakMinutes: settings.focusBreakMinutes,
                                                     cardTarget: settings.focusCardTarget))
    }

    var body: some View {
        VStack(spacing: 0) {
            StudyHeader(deckName: deckName, mode: "Flashcards",
                        counter: "\(min(index, queue.count)) / \(queue.count)",
                        fraction: queue.isEmpty ? 1 : Double(index) / Double(queue.count),
                        close: { timer.reset(); finish() })
            FocusTimerBar(model: timer, settings: library.settings)
            if index < queue.count {
                FlashcardFace(card: queue[index], state: library.understandingState(forCard: queue[index].id),
                              isFlipped: isFlipped) { isFlipped.toggle() }
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
        #if os(Windows)
        .onAppear { KeyCommands.set(owner: "flashcards") { handle($0) } }
        .onDisappear { KeyCommands.clear(owner: "flashcards") }
        #endif
    }

    #if os(Windows)
    /// The Mac's flashcard keys: Space flips, 1 / 2 answer once flipped, the
    /// arrows step back and forward, E edits, S suspends, Esc ends. Ignored
    /// while the edit sheet is open, so its text boxes get every key.
    private func handle(_ key: KeyCommands.Key) -> Bool {
        guard editing == nil else { return false }
        guard index < queue.count else {
            if key == .escape || key == .enter { finish(); return true }
            return false
        }
        switch key {
        case .space: isFlipped.toggle()
        case .character("1") where isFlipped: submit(false)
        case .character("2") where isFlipped: submit(true)
        case .left: if index > 0 { index -= 1; isFlipped = false }
        case .right: if index < queue.count - 1 { index += 1; isFlipped = false }
        case .character("e"): editing = CardEditorTarget(card: queue[index], deckId: nil)
        case .character("s"):
            library.setStatus([queue[index].id], to: .suspended)
            queue.remove(at: index)
            isFlipped = false
        case .escape:
            timer.reset()
            finish()
        default: return false
        }
        return true
    }
    #endif

    /// The Mac's footer: "Reveal answer" is the screen's one yellow control
    /// until the answer is up, then the two verdicts in coral and green.
    private var controls: some View {
        VStack(spacing: 10) {
            if isFlipped {
                HStack(spacing: 10) {
                    VerdictButton(title: "Needs Review", key: "1", tint: GRASPColor.rejected,
                                  soft: GRASPColor.rejectedSoft) { submit(false) }
                    VerdictButton(title: "I Know This", key: "2", tint: GRASPColor.success,
                                  soft: GRASPColor.successSoft) { submit(true) }
                }
            } else {
                HStack(spacing: 8) {
                    Text("Reveal answer").font(Font.system(size: 14, weight: .semibold)).foregroundColor(GRASPColor.ink)
                    Text("Space").font(GRASPFont.meta).foregroundColor(GRASPColor.ink)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46.0)
                .background(GRASPColor.brand)
                .cornerRadius(12)
                .onTapGesture { isFlipped = true }
            }
            HStack(spacing: 16) {
                QuietLink(title: "‹ Previous") {
                    if index > 0 { index -= 1; isFlipped = false }
                }
                QuietLink(title: "Edit card") { editing = CardEditorTarget(card: queue[index], deckId: nil) }
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

    /// The Mac's `SessionCompleteView`: "N cards done", the two tallies, the
    /// daily goal line, then Done (the one yellow button) with at most one
    /// outlined follow-on beside it.
    private var completion: some View {
        let done = understood + toReview
        let goal = library.settings.dailyGoal
        let reviewed = library.studyStreak().reviewsToday
        let next: StudyNextStep? = onNext == nil ? nil
            : !missed.isEmpty ? .learnMissed(missed) : (library.mastery(inDecks: deckIds).total > 0 ? .test : nil)
        return VStack(spacing: 0) {
            SectionLabel("Session complete")
            Text(done == 1 ? "1 card done" : "\(done) cards done")
                .font(Font.system(size: 34, weight: .heavy))
                .foregroundColor(GRASPColor.textPrimary)
                .padding(.top, 10)
            HStack(spacing: 0) {
                Tally(value: understood, label: "understood", tint: GRASPColor.success, size: 44)
                Rectangle().fill(GRASPColor.hairline).frame(width: 1.0, height: 40.0).padding(.horizontal, 30)
                Tally(value: toReview, label: "to review", tint: GRASPColor.accent, size: 44)
            }
            .padding(.top, 26)
            if goal > 0 {
                Text(reviewed >= goal ? "Daily goal reached" : "\(goal - reviewed) more to reach today's goal of \(goal)")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
                    .padding(.top, 20)
            }
            HStack(spacing: 12) {
                if let next, let onNext {
                    GRASPButton(next.title) { onNext(next) }
                }
                GRASPButton("Done", kind: .primary) { finish() }
            }
            .padding(.top, goal > 0 ? 20 : 32)
        }
    }

    private func submit(_ knewIt: Bool) {
        guard index < queue.count else { return }
        library.mark(queue[index].id, understood: knewIt)
        if knewIt { understood += 1 } else { toReview += 1; missed.insert(queue[index].id) }
        timer.countCard()
        index += 1
        isFlipped = false
        // The deck's done: the timer stops with it rather than running on.
        if index >= queue.count { timer.pause() }
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
    /// The card's understanding, as quiet pips in its top corner.
    let state: UnderstandingState
    let isFlipped: Bool
    let flip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(MathNotation.prettify(card.front))
                .font(GRASPFont.studyPrompt)
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
        .overlay(alignment: .topTrailing) {
            PipMeter(state: state).padding(.top, 16).padding(.trailing, 20)
        }
        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: 16)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .onTapGesture(perform: flip)
    }
}

/// A wide, tinted answer button, like the Mac's `GRASPVerdictButton`.
struct VerdictButton: View {
    let title: String
    /// The keyboard key, shown as a small hint after the title.
    var key: String?
    let tint: Color
    /// The tinted fill (the Mac's 9% tint); the surface when nil.
    var soft: Color?
    var isSelected = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(Font.system(size: 13, weight: .semibold)).foregroundColor(tint)
            if let key {
                Text(key).font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38.0)
        .edged(fill: isSelected ? GRASPColor.accentSoft : (soft ?? GRASPColor.surface),
               edge: isSelected ? GRASPColor.accent : GRASPColor.hairlineStrong, radius: 9)
        .onTapGesture(perform: action)
    }
}

/// What the flashcard finish screen can lead to next, as on the Mac.
enum StudyNextStep {
    case learnMissed(Set<String>)
    case test

    var title: String {
        switch self {
        case .learnMissed(let ids): return ids.count == 1 ? "Learn the 1 you missed" : "Learn the \(ids.count) you missed"
        case .test: return "Take a test"
        }
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
    /// Only these cards, for "Practice weakest"; empty for the whole deck.
    var focus: Set<String> = []
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
    /// The answered card's meter before this answer, for the pips that show
    /// after it (never before, so they can't bias the answer).
    @State var before: UnderstandingState?

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
                MasteryLine(mastery: mastery,
                            distribution: DeckUnderstanding.distribution(of: library.understanding(inDecks: deckIds).cards))
                QuestionView(question: question, answer: $answer, nextTitle: queue.count == 1 ? "Finish round" : "Next question",
                             onAnswered: { noteBefore(question) }, change: change) {
                    advance(question)
                }
            }
        }
        .onAppear { if !started { startRound() } }
        #if os(Windows)
        // At the checkpoint Return is Keep going, the yellow button.
        .watch(isAtCheckpoint) {
            if isAtCheckpoint {
                KeyCommands.set(owner: "checkpoint") { key in
                    guard key == .enter else { return false }
                    startRound()
                    return true
                }
            } else {
                KeyCommands.clear(owner: "checkpoint")
            }
        }
        #endif
    }

    private var checkpoint: some View {
        VStack(spacing: 0) {
            SectionLabel("Checkpoint")
            Text(roundIncorrect == 0 ? "Clean round" : roundCorrect == 0 ? "Rough round, worth another pass" : "Round complete")
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
                GRASPButton("Done for now") { finish() }
                GRASPButton("Keep going", kind: .primary) { startRound() }
            }
            .padding(.top, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noteBefore(_ question: LearnEngine.RoundQuestion) {
        before = question.cardId.map { library.understandingState(forCard: $0) }
    }

    /// Before and after this answer, once answered.
    private var change: (before: UnderstandingState, after: UnderstandingState)? {
        guard answer.isAnswered, let before else { return nil }
        return (before, before.afterAnswer(correct: answer.wasCorrect))
    }

    private func startRound() {
        queue = library.learnRound(inDecks: deckIds, focus: focus)
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
        before = nil
        if queue.isEmpty { isAtCheckpoint = true }
    }
}

/// The deck's understanding under Learn's header, as the Mac's: the stacked
/// bar (understood, recall, recognition, self-rated) and the count.
private struct MasteryLine: View {
    let mastery: (mastered: Int, total: Int)
    let distribution: DeckUnderstanding.Distribution

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            UnderstandingBar(distribution: distribution, width: 220.0, height: 4.0)
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
            GRASPButton("Back to deck", kind: .primary) { close() }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One question

/// Where a question's answer stands.
struct AnswerState {
    var selected: String?
    var written = ""
    /// A code question's blank answers, in order (`written` holds them encoded).
    var blanks: [String] = []
    /// A find-the-bug question's picked line.
    var selectedLine: Int?
    /// A complete-the-function answer waiting for the student's own verdict.
    var checkingFunction = false
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
    /// Learn's pips under the verdict once answered.
    var change: (before: UnderstandingState, after: UnderstandingState)? = nil
    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if question.isComeback {
                    Text(question.comebackWasUnderstood ? "Checking a card you understood"
                                                        : "Coming back to a card you answered before")
                        .font(Font.system(size: 12))
                        .foregroundColor(GRASPColor.textTertiary)
                        .padding(.top, 30)
                }
                if question.cardId == nil {
                    if question.code != nil || question.problem != nil {
                        Chip(text: "Practice question", tint: GRASPColor.success, soft: GRASPColor.successSoft)
                    } else {
                        Chip(text: "AI-generated", tint: GRASPColor.accent, soft: GRASPColor.accentSoft)
                    }
                }
                Text(MathNotation.prettify(question.prompt))
                    .font(GRASPFont.studyPrompt)
                    .foregroundColor(GRASPColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560.0)
                    .padding(.top, question.isComeback ? 0 : 30)
                switch question.type {
                case .multipleChoice:
                    if let code = question.code { CodeContextBlock(code: code) }
                    ChoiceList(question: question, answer: answer, pick: pick)
                case .trueFalse:
                    TrueFalse(question: question, answer: answer, pick: pick)
                case .written:
                    if let code = question.code {
                        CodeAnswerArea(code: code, answer: $answer, submit: submit)
                    } else {
                        WrittenAnswer(question: question, answer: $answer, submit: submit)
                    }
                }
                VerdictLine(question: question, answer: answer)
                if let change { PipChange(before: change.before, after: change.after) }
                actions
            }
            .frame(maxWidth: 600.0)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        #if os(Windows)
        // Return presses the yellow button (Submit, then Next), as the Mac's
        // default action. Set again for each question, so it never acts on
        // the one before.
        .onAppear { installReturn() }
        .watch(question.id) { installReturn() }
        .onDisappear { KeyCommands.clear(owner: "question") }
        #endif
    }

    #if os(Windows)
    private func installReturn() {
        KeyCommands.set(owner: "question") { key in
            guard key == .enter else { return false }
            if answer.isAnswered {
                next()
            } else if answer.checkingFunction {
                return false
            } else if (!submitsOnChoice || question.type == .written) && canSubmit {
                submit()
            } else {
                return false
            }
            return true
        }
    }
    #endif

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if answer.isAnswered {
                if question.allowsMarkCorrect, !answer.wasCorrect, let onOverride {
                    GRASPButton("I actually got this right") {
                        answer.wasCorrect = true
                        answer.wasOverridden = true
                        onOverride()
                    }
                }
                GRASPButton(nextTitle, kind: .primary) { next() }
            } else if answer.checkingFunction {
                // No compiler on this PC: the student marks their own code
                // against the reference, as the Mac does where it can't run.
                GRASPButton("Not yet") { finishFunction(correct: false) }
                GRASPButton("I got it", kind: .primary) { finishFunction(correct: true) }
            } else if question.code?.kind == .findBug && question.type == .written {
                // Tapping a line answers it.
            } else if !submitsOnChoice || question.type == .written {
                GRASPButton(question.code?.kind == .completeFunction ? "Check" : "Submit", kind: .primary) { submit() }
                    .disabled(!canSubmit)
            }
        }
    }

    private var canSubmit: Bool {
        if question.type == .written, let code = question.code, code.kind == .codeBlanks {
            return answer.blanks.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return question.type == .written
            ? !answer.written.trimmingCharacters(in: .whitespaces).isEmpty
            : answer.selected != nil
    }

    private func finishFunction(correct: Bool) {
        answer.checkingFunction = false
        answer.wasCorrect = correct
        answer.verdict = correct ? .correct : .incorrect
        answer.isAnswered = true
        onAnswered?()
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
            if let code = question.code {
                // A program's blanks, output and bug line are compared
                // exactly; nothing here guesses at a loose answer.
                guard let result = CodeAnswerGrading.grade(code, given: answer.written) else {
                    answer.checkingFunction = true
                    return
                }
                answer.verdict = result ? .correct : .incorrect
                answer.wasCorrect = result
            } else {
                let verdict = AnswerGrading.grade(given: answer.written, correct: question.correctAnswer)
                answer.verdict = verdict
                answer.wasCorrect = verdict != .incorrect
            }
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
        .edged(fill: background, edge: edge, radius: 9)
        .onTapGesture(perform: action)
    }

    private var edge: Color {
        switch state {
        case .right: return GRASPColor.success
        case .wrong: return GRASPColor.rejected
        case .selected: return GRASPColor.accent
        case .idle: return GRASPColor.hairline
        }
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
        case .wrong: return GRASPColor.rejected
        case .selected: return GRASPColor.accent
        case .idle: return GRASPColor.textTertiary
        }
    }

    private var background: Color {
        switch state {
        case .right: return GRASPColor.successSoft
        case .wrong: return GRASPColor.rejectedSoft
        case .selected: return GRASPColor.accentSoft
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
        VerdictButton(title: label, tint: tint(label), soft: soft(label),
                      isSelected: !answer.isAnswered && answer.selected == label) {
            pick(label)
        }
    }

    private func soft(_ label: String) -> Color? {
        guard answer.isAnswered else { return nil }
        if label == question.correctAnswer { return GRASPColor.successSoft }
        return label == answer.selected ? GRASPColor.rejectedSoft : nil
    }

    private func tint(_ label: String) -> Color {
        guard answer.isAnswered else {
            return answer.selected == label ? GRASPColor.accent : GRASPColor.textSecondary
        }
        if label == question.correctAnswer { return GRASPColor.success }
        return label == answer.selected ? GRASPColor.rejected : GRASPColor.textTertiary
    }
}

private struct WrittenAnswer: View {
    let question: LearnEngine.RoundQuestion
    @Binding var answer: AnswerState
    /// Enter submits, as on the Mac.
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextField("Type the answer", text: $answer.written.changesOnly())
                .font(Font.system(size: 15))
                .frame(width: 418.0)
                .disabled(answer.isAnswered)
                .onSubmit(perform: submit)
                .padding(1)
                .edged(fill: GRASPColor.inset, edge: GRASPColor.hairlineStrong, radius: 9)
            if answer.isAnswered, answer.verdict == .close {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your answer works. The card says:").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                    Text(MathNotation.prettify(question.correctAnswer)).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                }
                .frame(width: 418.0, alignment: .leading)
            } else if answer.isAnswered, answer.verdict != .correct, !answer.wasOverridden {
                VStack(alignment: .leading, spacing: 3) {
                    Text("YOUR ANSWER").font(GRASPFont.eyebrow).foregroundColor(GRASPColor.textTertiary)
                    Text(answer.written).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                    Text("CARD SAYS").font(GRASPFont.eyebrow).foregroundColor(GRASPColor.textTertiary).padding(.top, 6)
                    Text(MathNotation.prettify(question.correctAnswer)).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                }
                .frame(width: 418.0, alignment: .leading)
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
                .foregroundColor(answer.wasCorrect ? (answer.verdict == .close ? GRASPColor.accent : GRASPColor.success)
                                                   : GRASPColor.rejected)
        }
    }

    private var text: String {
        if answer.wasOverridden { return "✓ Marked correct" }
        switch answer.verdict {
        case .correct: return "✓ Correct"
        case .close: return "✓ Close. Check your spelling"
        default:
            return "✕ Not quite"
        }
    }
}
