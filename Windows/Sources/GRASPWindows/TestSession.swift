import Foundation
import GRASPCore
import SwiftCrossUI

/// A test, after the Mac's `TestFlowView`: choose how many questions and
/// which kinds, answer them one by one, then see the score and every
/// question with its answer. Missed questions from cards go back into the
/// flashcard queue when the test is finished. With "AI test questions" on
/// in Settings, the local model adds written questions from the notes.
struct TestSession: View {
    let library: Library
    let deckName: String
    let deckIds: [String]
    let finish: () -> Void

    @State var phase: Phase = .setup

    enum Phase {
        case setup
        case running(attemptId: String, questions: [LearnEngine.RoundQuestion], warning: String?)
        case results(attemptId: String, graded: [GradedQuestion])
    }

    var body: some View {
        switch phase {
        case .setup:
            TestSetup(library: library, deckName: deckName, deckIds: deckIds, cancel: finish) { attemptId, questions, warning in
                phase = .running(attemptId: attemptId, questions: questions, warning: warning)
            }
        case .running(let attemptId, let questions, let warning):
            TestRun(library: library, deckName: deckName, attemptId: attemptId, questions: questions,
                    warning: warning, close: finish) { graded in
                library.finishTest(attemptId: attemptId)
                phase = .results(attemptId: attemptId, graded: graded)
            }
        case .results(let attemptId, let graded):
            TestResults(library: library, deckName: deckName, attemptId: attemptId, graded: graded, close: finish)
        }
    }
}

struct GradedQuestion {
    let question: LearnEngine.RoundQuestion
    let ordinal: Int
    var givenAnswer: String
    var isCorrect: Bool
}

/// "Skip" while AI questions are being written: read from the writing task.
nonisolated final class SkipFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

struct SkipBox {
    var flag = SkipFlag()
}

// MARK: - Setup

private struct TestSetup: View {
    let library: Library
    let deckName: String
    let deckIds: [String]
    let cancel: () -> Void
    let start: (String, [LearnEngine.RoundQuestion], String?) -> Void

    @State var questionCount = 20
    @State var multipleChoice = true
    @State var written = true
    @State var trueFalse = true
    @State var shuffle = true
    @State var excludeKnown = false
    @State var noQuestions = false
    /// While the model writes questions: what it's doing, and how far along.
    @State var writing: String?
    @State var writingFraction = 0.0
    /// A struct around the flag: SwiftCrossUI state must not be a plain class.
    @State var skip = SkipBox()

    private var anyType: Bool { multipleChoice || written || trueFalse }
    private var usesAI: Bool { library.settings.aiTestQuestions && written }

    var body: some View {
        VStack(spacing: 0) {
            StudyHeader(deckName: deckName, mode: "Test", counter: nil, fraction: 0, close: cancel)
            VStack(alignment: .leading, spacing: 18) {
                Text("New test").font(Font.system(size: 22, weight: .semibold)).foregroundColor(GRASPColor.textPrimary)
                row("Questions") {
                    HStack(spacing: 10) {
                        Button("−") { questionCount = max(5, questionCount - 5) }.fixedSize()
                        Text("\(questionCount)").font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
                            .frame(width: 40.0)
                        Button("+") { questionCount = min(100, questionCount + 5) }.fixedSize()
                    }
                }
                row("Question types") {
                    HStack(spacing: 6) {
                        Pill(title: "Multiple choice", isOn: multipleChoice) { multipleChoice.toggle() }
                        Pill(title: "Written", isOn: written) { written.toggle() }
                        Pill(title: "True / False", isOn: trueFalse) { trueFalse.toggle() }
                    }
                }
                row("Options") {
                    HStack(spacing: 6) {
                        Pill(title: "Shuffle order", isOn: shuffle) { shuffle.toggle() }
                        Pill(title: "Only cards I haven't marked as known", isOn: excludeKnown) { excludeKnown.toggle() }
                    }
                }
                if usesAI {
                    Text("AI test questions are on (Settings): about \(Study.aiQuestionBudget(for: questionCount)) of these will be written questions the local model writes from your notes.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !anyType {
                    Text("Pick at least one question type.").font(GRASPFont.meta).foregroundColor(GRASPColor.rejected)
                } else if noQuestions {
                    Text(excludeKnown
                         ? "No cards match -- every card here is marked as known. Turn off \"Only cards I haven't marked as known\" to test on them anyway."
                         : "No approved cards match these settings, so there's nothing to test.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.rejected)
                }
                if let writing {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text(writing).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                            Spacer()
                            Button("Skip") { skip.flag.set() }.fixedSize()
                        }
                        ProgressBar(fraction: writingFraction)
                    }
                    .padding(12)
                    .background(GRASPColor.accentSoft)
                    .cornerRadius(8)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { cancel() }.disabled(writing != nil).fixedSize()
                    Button("Start Test") { begin() }.disabled(!anyType || writing != nil).fixedSize()
                }
            }
            .frame(maxWidth: 560.0)
            .padding(32)
            Spacer()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            content()
        }
    }

    private func begin() {
        let config = TestBuilder.Config(
            questionCount: questionCount, allowMultipleChoice: multipleChoice, allowWritten: written,
            allowTrueFalse: trueFalse, shuffle: shuffle, excludeMastered: excludeKnown
        )
        noQuestions = false
        guard usesAI else {
            launch(config, aiQuestions: [], warning: nil)
            return
        }
        writing = "Writing questions from your notes…"
        writingFraction = 0
        let flag = SkipFlag()
        skip = SkipBox(flag: flag)
        let budget = Study.aiQuestionBudget(for: questionCount)
        Task {
            let generator = await CardGenerators.select()
            let progress = AIProgress { snapshot in
                Task { @MainActor in
                    writingFraction = snapshot.fraction
                    if let step = snapshot.step { writing = step }
                }
            }
            let (questions, warning) = await AIProgress.$current.withValue(progress) {
                await CardAI.generateTestQuestions(inDecks: deckIds, maxCount: budget, using: generator,
                                                   database: library.database, skipped: { flag.isSet })
            }
            writing = nil
            launch(config, aiQuestions: questions, warning: warning)
        }
    }

    private func launch(_ config: TestBuilder.Config, aiQuestions: [LearnEngine.RoundQuestion], warning: String?) {
        guard let (attemptId, questions) = library.startTest(inDecks: deckIds, config: config, aiQuestions: aiQuestions) else {
            noQuestions = true
            return
        }
        start(attemptId, questions, warning)
    }
}

/// An on/off pill: GRASP's amber when on, instead of WinUI's toggle, which
/// draws in Windows' accent colour.
struct Pill: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Text((isOn ? "✓ " : "") + title)
            .font(GRASPFont.rowTitle)
            .foregroundColor(isOn ? GRASPColor.accent : GRASPColor.textSecondary)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isOn ? GRASPColor.accentSoft : GRASPColor.inset)
            .cornerRadius(7)
            .onTapGesture(perform: action)
    }
}

// MARK: - Running

private struct TestRun: View {
    let library: Library
    let deckName: String
    let attemptId: String
    let questions: [LearnEngine.RoundQuestion]
    let warning: String?
    let close: () -> Void
    let done: ([GradedQuestion]) -> Void

    @State var index = 0
    @State var answer = AnswerState()
    @State var graded: [GradedQuestion] = []
    @State var warningDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            StudyHeader(deckName: deckName, mode: "Test",
                        counter: (graded.isEmpty ? "" : "\(graded.filter(\.isCorrect).count) correct · ")
                            + "\(min(index + 1, questions.count)) / \(questions.count)",
                        fraction: Double(index) / Double(max(1, questions.count)),
                        close: close)
            if let warning, !warningDismissed {
                HStack(spacing: 10) {
                    Text(warning)
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    QuietLink(title: "Dismiss") { warningDismissed = true }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(GRASPColor.accentSoft)
            }
            if index < questions.count {
                QuestionView(
                    question: questions[index], answer: $answer, submitsOnChoice: true,
                    nextTitle: index == questions.count - 1 ? "Finish Test" : "Next Question",
                    onAnswered: { record(questions[index]) },
                    onOverride: { override(questions[index]) },
                    next: advance
                )
            }
        }
    }

    private func record(_ question: LearnEngine.RoundQuestion) {
        let given = question.type == .written ? answer.written : (answer.selected ?? "")
        library.submitTestAnswer(attemptId: attemptId, ordinal: index, given: given, isCorrect: answer.wasCorrect)
        graded.append(GradedQuestion(question: question, ordinal: index, givenAnswer: given, isCorrect: answer.wasCorrect))
    }

    private func override(_ question: LearnEngine.RoundQuestion) {
        if let last = graded.indices.last { graded[last].isCorrect = true }
        library.overrideTestAnswer(attemptId: attemptId, ordinal: index, cardId: question.cardId)
    }

    private func advance() {
        index += 1
        answer = AnswerState()
        if index >= questions.count { done(graded) }
    }
}

// MARK: - Results

private struct TestResults: View {
    let library: Library
    let deckName: String
    let attemptId: String
    @State var graded: [GradedQuestion]
    let close: () -> Void

    init(library: Library, deckName: String, attemptId: String, graded: [GradedQuestion], close: @escaping () -> Void) {
        self.library = library
        self.deckName = deckName
        self.attemptId = attemptId
        self.close = close
        _graded = State(wrappedValue: graded)
    }

    var body: some View {
        let correct = graded.filter(\.isCorrect).count
        VStack(spacing: 0) {
            StudyHeader(deckName: deckName, mode: "Test results", counter: nil, fraction: 1, close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 4) {
                        Text("\(correct)").font(Font.system(size: 40, weight: .bold))
                            .foregroundColor(correct == graded.count ? GRASPColor.success : GRASPColor.accent)
                        Text("/ \(graded.count)").font(GRASPFont.title).foregroundColor(GRASPColor.textTertiary)
                    }
                    ProgressBar(fraction: graded.isEmpty ? 0 : Double(correct) / Double(graded.count),
                                tint: correct == graded.count ? GRASPColor.success : GRASPColor.accent)
                    Text("Missed questions from your cards were added back to your flashcard queue.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(graded.enumerated()), id: \.offset) { position, item in
                            ResultRow(item: item) { override(position) }
                        }
                    }
                    .background(GRASPColor.surface)
                    .cornerRadius(10)
                    HStack {
                        Spacer()
                        Button("Done") { close() }.fixedSize()
                    }
                }
                .frame(maxWidth: 640.0)
                .padding(28)
            }
        }
    }

    private func override(_ position: Int) {
        graded[position].isCorrect = true
        let item = graded[position]
        library.overrideTestAnswer(attemptId: attemptId, ordinal: item.ordinal, cardId: item.question.cardId)
    }
}

private struct ResultRow: View {
    let item: GradedQuestion
    let override: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(item.isCorrect ? "✓" : "✕")
                    .font(GRASPFont.rowTitle.weight(.bold))
                    .foregroundColor(item.isCorrect ? GRASPColor.success : GRASPColor.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(MathNotation.prettify(item.question.prompt))
                        .font(GRASPFont.rowTitle)
                        .foregroundColor(GRASPColor.textPrimary)
                    if !item.isCorrect {
                        Text("You answered: \(item.givenAnswer)")
                            .font(GRASPFont.body)
                            .foregroundColor(GRASPColor.textSecondary)
                    }
                    Text(MathNotation.prettify(item.question.correctAnswer))
                        .font(GRASPFont.body)
                        .foregroundColor(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.isCorrect && item.question.type == .written {
                        QuietLink(title: "I actually got this right", action: override)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
        }
    }
}
