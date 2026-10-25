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

extension Binding where Value == TestPhase? {
    /// Moves a Test sheet on to its next phase. On the Mac the sheet is sized
    /// when it opens (`presentationSizing(.page)`), so swapping the content of
    /// the open Setup sheet for the question screen left the window at its
    /// 680-point floor with the content laid out for the page-sized ideal --
    /// the first question came up shifted and clipped. Closing the sheet and
    /// opening the next phase as a fresh one gives it its real size, the same
    /// one Learn opens at.
    @MainActor
    func advance(to phase: TestPhase?, store: AppStore) {
        #if os(macOS)
        // The dimmed backdrop is held through the gap so it doesn't flash.
        store.presentedStudySheets += 1
        wrappedValue = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            wrappedValue = phase
            store.presentedStudySheets = Swift.max(0, store.presentedStudySheets - 1)
        }
        #else
        // Leaving the setup sheet for the full-screen run: the sheet has to
        // finish dismissing before the next presentation can start.
        if case .setup? = wrappedValue {
            wrappedValue = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                wrappedValue = phase
            }
        } else {
            wrappedValue = phase
        }
        #endif
    }
}

#if os(iOS)
/// A sheet whose detent is exactly as tall as the content it holds (plus the
/// home indicator), with the full height behind it for a larger type size
/// or a long list, and the grabber showing.
private struct FittedDetentSheet<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 560
    /// The home indicator's inset, which the detent has to include.
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        content()
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
            .onPreferenceChange(SheetFitHeightKey.self) { if $0 > 0 { height = $0 } }
            .presentationDetents([.height(height + bottomInset), .large])
            .presentationDragIndicator(.visible)
    }
}

extension View {
    /// A test's phases on iPhone: setup is a proper sheet (grabber, fitted
    /// detent) and the questions and results are full screen.
    func testFlow<Setup: View, Run: View>(
        _ phase: Binding<TestPhase?>, onDismiss: @escaping () -> Void,
        @ViewBuilder setup: @escaping () -> Setup,
        @ViewBuilder run: @escaping (TestPhase) -> Run
    ) -> some View {
        let setupBinding = Binding<TestPhase?>(
            get: { if case .setup? = phase.wrappedValue { return phase.wrappedValue } else { return nil } },
            set: { if $0 == nil, case .setup? = phase.wrappedValue { phase.wrappedValue = nil } }
        )
        let runBinding = Binding<TestPhase?>(
            get: { if case .setup? = phase.wrappedValue { return nil } else { return phase.wrappedValue } },
            set: { if $0 == nil { phase.wrappedValue = nil } }
        )
        return self
            .sheet(item: setupBinding, onDismiss: onDismiss) { _ in
                FittedDetentSheet { setup() }
            }
            .fullScreenCover(item: runBinding, onDismiss: onDismiss) { run($0) }
    }
}
#endif

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
    /// For a typed answer: how it was judged, so "close enough" can be
    /// shown as its own thing while still counting as correct.
    var judged: JudgedAnswer? = nil
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

    @State private var questionCount = 10
    @State private var allowMultipleChoice = true
    @State private var allowWritten = false
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
    /// The deck's approved cards, so a deck with none starts a test from its
    /// saved questions alone. -1 until counted.
    @State private var cardCount = -1
    /// How many questions these settings can really ask. -1 until counted.
    @State private var matching = -1
    /// "Include questions" for a deck with no cards, which is on until turned off here.
    @State private var questionsWithoutCards = true

    private var hasCards: Bool { cardCount != 0 }
    /// What the test will really use, whatever the saved switches say.
    private var useFlashcards: Bool { guide != nil || (hasCards && store.isFlashcardQuizEnabled) }
    private var useQuestions: Bool { guide != nil || (hasCards ? store.isSavedQuestionsEnabled : questionsWithoutCards) }

    /// What a guide's test is made of, in the words of the questions it asks.
    static let guideSetupMessage = "Built from what the exam will ask: this guide's worked examples, asked in the "
        + "form the exam uses, plus the checked practice problems saved for the lectures it covers."

    var body: some View {
        GRASPSheet(
            eyebrow: "Test", title: deckName,
            message: guide != nil
                ? Self.guideSetupMessage
                : "A graded quiz on this deck's flashcards, its saved questions, or both: multiple choice, "
                  + "written, and true / false.",
            icon: "checklist", width: 460
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if let unfinished, let onResume {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Unfinished test")
                        Text("\(unfinished.answered) of \(unfinished.total) answered, started "
                             + unfinished.startedAt.formatted(.relative(presentation: .named)) + ".")
                            .graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                        HStack(spacing: 8) {
                            Button("Continue test") { onResume(unfinished.attemptId) }
                                .buttonStyle(GRASPProminentButton())
                            Button("Discard", role: .destructive) {
                                store.discardTest(attemptId: unfinished.attemptId)
                                self.unfinished = nil
                            }
                            .buttonStyle(GRASPQuietButton())
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GRASPColor.accentSoft, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Questions").graspType(.body)
                        Spacer()
                        Text("\(questionCount)")
                            .font(.graspUI(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(questionCount)))
                            .foregroundStyle(GRASPColor.textPrimary)
                        Stepper("", value: $questionCount.animation(Motion.snappy), in: 5...100, step: 5)
                            .labelsHidden()
                    }
                    if guide == nil, matching >= 0, matching < questionCount {
                        Text(matching == 0 ? "No questions match these types."
                             : "\(matching) question\(matching == 1 ? "" : "s") match these types. The test will have \(matching).")
                            .graspType(.meta)
                            .foregroundStyle(matching == 0 ? GRASPColor.rejected : GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                    FieldLabel("Question types")
                    Toggle("Multiple choice", isOn: $allowMultipleChoice)
                    Toggle("Written", isOn: $allowWritten)
                    if guide == nil {
                        // A guide's questions come from its worked examples,
                        // which have no true/false form.
                        Toggle("True / False", isOn: $allowTrueFalse)
                    }
                }
                .popupGroup()

                historyBlock

                if guide == nil {
                    // Two independent sources. Flashcards are what Test has
                    // always asked about; questions are the ones saved on the
                    // deck's Questions tab.
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Quiz me on flashcards", isOn: Binding(
                                get: { useFlashcards }, set: { store.isFlashcardQuizEnabled = $0 }
                            ))
                            .toggleStyle(GRASPSwitchStyle())
                            .disabled(!hasCards)
                            Text(hasCards ? "Questions made from this deck's cards." : "This deck has no cards.")
                                .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                            aiOption
                                .padding(.leading, 20)
                                .padding(.top, 8)
                        }
                        Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Include questions", isOn: Binding(
                                get: { useQuestions },
                                set: { if hasCards { store.isSavedQuestionsEnabled = $0 } else { questionsWithoutCards = $0 } }
                            ))
                            .toggleStyle(GRASPSwitchStyle())
                            Text(savedQuestionsCaption)
                                .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .popupGroup()

                }

                if let problem = Study.testSourcesProblem(includeFlashcards: useFlashcards, includeQuestions: useQuestions) {
                    Text(problem).graspType(.meta).foregroundStyle(GRASPColor.rejected)
                } else if !allowMultipleChoice && !allowWritten && !allowTrueFalse {
                    Text("Turn on at least one question type.").graspType(.meta).foregroundStyle(GRASPColor.rejected)
                } else if noQuestions {
                    Text(useFlashcards
                         ? "No cards or saved questions match these settings, so there's nothing to test."
                         : "No saved questions match these settings, so there's nothing to test.")
                        .graspType(.meta).foregroundStyle(GRASPColor.rejected)
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
                    .popupGroup(padding: 12)
                }
            }
        } footer: {
            if isStarting, aiActivity == nil {
                ProgressView().controlSize(.small)
                Text(useFlashcards && store.isAITestQuestionsEnabled ? "Writing AI questions…" : "Starting test…")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .disabled(isStarting)
            Button("Start test") { start() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
                .disabled(isStarting || (!allowMultipleChoice && !allowWritten && !allowTrueFalse) || (guide == nil && matching == 0)
                          || (guide == nil && Study.testSourcesProblem(includeFlashcards: useFlashcards,
                                                                       includeQuestions: useQuestions) != nil))
        }
        .task {
            cardCount = guide == nil ? store.activeCardCount(inDecks: deckIds) : -1
            unfinished = store.unfinishedTest(forDecks: deckIds, scopeKey: guide?.scopeKey)
            history = store.testHistory(forDecks: deckIds)
            mostMissed = store.mostMissedCards(forDecks: deckIds)
        }
        .task(id: matchKey) { recount() }
    }

    /// What changes the count of questions that can be asked.
    private var matchKey: String {
        "\(questionCount)\(allowMultipleChoice)\(allowWritten)\(allowTrueFalse)\(useFlashcards)\(useQuestions)\(cardCount)\(store.revision)"
    }

    private func recount() {
        guard guide == nil, cardCount >= 0 else { return }
        let config = TestBuilder.Config(
            questionCount: questionCount, allowMultipleChoice: allowMultipleChoice,
            allowWritten: allowWritten, allowTrueFalse: allowTrueFalse, shuffle: shuffle,
            excludeMastered: excludeMastered, weakSpotsOnly: weakSpotsOnly, includeFlashcards: useFlashcards)
        matching = store.matchingTestQuestionCount(deckIds: deckIds, config: config, includeQuestions: useQuestions)
    }

    /// "Add fresh AI questions": part of the flashcard side, so it sits under
    /// "Quiz me on flashcards", indented. Dimmed, with the reason, when it
    /// cannot do anything: flashcards off, or Written off (AI questions are
    /// typed answers).
    private var aiOption: some View {
        let flashcards = useFlashcards
        let available = flashcards && allowWritten
        return VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(
                get: { store.isAITestQuestionsEnabled }, set: { store.isAITestQuestionsEnabled = $0 }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: AIGlyph.symbol)
                        .font(.graspUI(size: 11, weight: .semibold))
                        .foregroundStyle(GRASPColor.accent)
                    Text("Add fresh AI questions")
                }
            }
            .toggleStyle(GRASPSwitchStyle())
            .disabled(!available)
            Text(!flashcards ? "Turn on Quiz me on flashcards to use this."
                 : !allowWritten ? "Turn on Written to use this."
                 : "Written by AI for this test only. Not saved.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(available ? 1 : 0.45)
        .animation(Motion.fade, value: available)
    }

    /// What "Include questions" will do, in a line.
    private var savedQuestionsCaption: String {
        let saved = store.activeQuestionCount(inDecks: deckIds)
        guard saved > 0 else { return "No saved questions yet. Add some on the deck's Questions tab." }
        let noun = "\(saved) saved question\(saved == 1 ? "" : "s")"
        return useFlashcards
            ? "\(noun) from this deck's Questions tab. About a third of the test."
            : "\(noun) from this deck's Questions tab. The whole test comes from them."
    }

    private func start() {
        let config = TestBuilder.Config(
            questionCount: questionCount, allowMultipleChoice: allowMultipleChoice,
            allowWritten: allowWritten, allowTrueFalse: allowTrueFalse && guide == nil, shuffle: shuffle,
            excludeMastered: excludeMastered, weakSpotsOnly: weakSpotsOnly,
            includeFlashcards: useFlashcards
        )
        isStarting = true
        noQuestions = false
        let run = guide != nil ? nil
            : (useFlashcards && store.isAITestQuestionsEnabled && allowWritten)
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
            let useQuestionsForStart = useQuestions
            let start = {
                if let guide {
                    return try await store.startGuideTest(page: guide.page, scopeKey: guide.scopeKey, config: config)
                }
                return try await store.startTest(deckIds: deckIds, config: config, includeQuestions: useQuestionsForStart)
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

    /// Recent scores as bars, and the cards missed most -- shown once there
    /// is something to show.
    @ViewBuilder
    private var historyBlock: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                FieldLabel("Recent scores")
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(history) { entry in
                        VStack(spacing: 3) {
                            Text("\(Int((entry.fraction * 100).rounded()))")
                                .font(.graspUI(size: 9)).monospacedDigit()
                                .foregroundStyle(GRASPColor.textTertiary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(entry.fraction >= 0.8 ? GRASPColor.success : GRASPColor.textTertiary)
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
            .popupGroup()
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
    @State private var judged: JudgedAnswer?
    @State private var isChecking = false
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
        .adaptiveStudySheet()
        .dimsWindowBehind()
        .onAppear {
            // Picking an unfinished test up where it was left.
            guard !resumed else { return }
            resumed = true
            if !answered.isEmpty, answered.count < questions.count {
                graded = answered
                index = answered.count
            }
        }
        .sheet(isPresented: $confirmingExit) {
            LeaveTestSheet(
                onSave: { confirmingExit = false; dismiss() },
                onDiscard: {
                    store.discardTest(attemptId: attemptId)
                    confirmingExit = false
                    dismiss()
                }
            )
        }
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.graspUI(size: 12))
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
                    .font(.graspUI(size: 9, weight: .semibold))
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
                        .font(.graspUI(size: 11, weight: .semibold))
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

    /// How wide the question column gets on a big window: wide enough for
    /// code, narrow enough to read.
    private let columnWidth: CGFloat = 860

    /// The question scrolls; what to do next stays pinned below it, so a long
    /// question can never push the Next button out of reach.
    @ViewBuilder
    private func questionBody(_ question: LearnEngine.RoundQuestion) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    questionLabel(question)
                    questionPrompt(question)
                    answerArea(question)
                    if isAnswered, question.type == .multipleChoice, let explanation = question.problem?.explanation {
                        WhyBlock(text: explanation)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // A one-line AI question carries its own explanation.
                    if isAnswered, question.code == nil, question.problem == nil, question.cardId == nil {
                        WhyBlock(text: question.explanation)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isAnswered, !lastCorrect {
                        ExplainThisBlock(question: question, given: graded.last?.givenAnswer ?? "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isAnswered, question.cardId == nil, question.bankSource != QuestionSource.yours.rawValue {
                        FlagQuestionButton { flagCurrent(question) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: columnWidth)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            if isAnswered { answeredBar(question) }
        }
    }

    @ViewBuilder
    private func questionLabel(_ question: LearnEngine.RoundQuestion) -> some View {
        if question.bankSource == QuestionSource.yours.rawValue {
            Label("Your question", systemImage: "pencil")
                .font(.graspUI(size: 11, weight: .medium))
                .foregroundStyle(GRASPColor.textTertiary)
        } else if let code = question.code {
            Label("\(code.kind.label) · \(code.language.label)", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.graspUI(size: 11, weight: .medium))
                .foregroundStyle(GRASPColor.accent)
                .help("A code question: from your study guide, or written by AI and checked by running it")
        } else if let problem = question.problem {
            Label("\(problem.kind.label) · \(problem.subject.label)", systemImage: "function")
                .font(.graspUI(size: 11, weight: .medium))
                .foregroundStyle(GRASPColor.accent)
                .help("Written by AI, then checked before it was saved")
        } else if question.cardId == nil {
            Label("No card", systemImage: "sparkles")
                .font(.graspUI(size: 11, weight: .medium))
                .foregroundStyle(GRASPColor.accent)
                .help("Not from one of your cards: from a study guide, or written by AI for this test")
        }
    }

    @ViewBuilder
    private func questionPrompt(_ question: LearnEngine.RoundQuestion) -> some View {
        if question.problem != nil || (question.cardId == nil && question.prompt.contains("\n")) {
            // Long or code-bearing prompts read left to right; a matrix only
            // lines up that way.
            GuideText(text: question.prompt, style: .prose, color: GRASPColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(question.prompt)
                .graspType(.studyPrompt)
                .foregroundStyle(GRASPColor.textPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 640)
                .padding(.vertical, question.cardId == nil ? 0 : 24)
        }
    }

    @ViewBuilder
    private func answerArea(_ question: LearnEngine.RoundQuestion) -> some View {
        switch question.type {
        case .multipleChoice:
            if let code = question.code {
                // The program the choices are about, with the open blank marked.
                ScrollView(.horizontal) {
                    Text(CodeQuestion.fill(code.code) { _ in "_____" })
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(GRASPColor.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            choiceList(question)
        case .trueFalse:
            VStack(spacing: 18) {
                // A saved true/false question's prompt is its statement;
                // showing it again underneath read as a mistake.
                if let statement = question.statement, statement != question.prompt {
                    Text(statement)
                        .graspType(.studyAnswer)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 640)
                }
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
            CodeQuestionView(question: question.code!, isAnswered: isAnswered) { given, correct in
                submit(correct, given: given, question: question)
            }
            .id(question.id)
        case .written:
            TextField("Type the answer", text: $writtenAnswer)
                .textFieldStyle(.plain)
                .font(.graspUI(size: 15))
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
                .disabled(isAnswered || isChecking)
                .onSubmit {
                    guard !isAnswered, !isChecking,
                          !writtenAnswer.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    isChecking = true
                    let given = writtenAnswer
                    Task {
                        let result = await store.judgeTypedAnswer(question: question, given: given)
                        isChecking = false
                        submit(result.outcome.countsAsCorrect, given: given, question: question, judged: result)
                    }
                }
                .frame(maxWidth: 520)
                .task { writtenFieldFocused = true }
            if isChecking {
                CheckingAnswerLabel()
                    .frame(maxWidth: 520, alignment: .leading)
            }
            if isAnswered, let judged, judged.outcome != .correct {
                TypedAnswerFeedback(judged: judged, given: writtenAnswer, expected: question.correctAnswer,
                                    hasCard: question.cardId != nil)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
    }

    /// The verdict and the way on, pinned under the scrolling question.
    private func answeredBar(_ question: LearnEngine.RoundQuestion) -> some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: lastCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.graspUI(size: 12))
                Text(lastCorrect
                     ? (wasOverridden ? "Marked correct"
                        : (judged?.outcome == .closeEnough ? "Close enough" : "Correct"))
                     : "Not quite")
                    .graspType(.body)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .foregroundStyle(lastCorrect ? GRASPColor.success : GRASPColor.rejected)
            Spacer(minLength: 12)
            // Text matching is a poor judge of a long or loaded answer --
            // offered only for written questions, and only while wrong.
            if question.allowsMarkCorrect && !lastCorrect {
                Button("I actually got this right") { override(question) }
                    .buttonStyle(GRASPProminentButton(tint: GRASPColor.success))
            }
            Button(index == questions.count - 1 ? "Finish test" : "Next question") { advance() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(GRASPColor.canvas)
        .background(alignment: .top) { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
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
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func marker(_ choice: String, position: Int, correct: String) -> some View {
        Group {
            if isAnswered && choice == correct {
                Image(systemName: "checkmark").foregroundStyle(GRASPColor.success)
            } else if isAnswered && choice == selectedChoice {
                Image(systemName: "xmark").foregroundStyle(GRASPColor.rejected)
            } else {
                Text(String(UnicodeScalar(65 + min(position, 25))!))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
        }
        .font(.graspUI(size: 11, weight: .semibold))
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
        return label == selectedChoice ? GRASPColor.rejected : GRASPColor.textTertiary
    }

    private func background(_ choice: String, correct: String) -> Color {
        guard isAnswered else { return GRASPColor.surface }
        if choice == correct { return GRASPColor.successSoft }
        if choice == selectedChoice { return GRASPColor.rejectedSoft }
        return GRASPColor.surface
    }

    private func border(_ choice: String, correct: String) -> Color {
        guard isAnswered else { return GRASPColor.hairline }
        if choice == correct { return GRASPColor.success.opacity(0.55) }
        if choice == selectedChoice { return GRASPColor.rejected.opacity(0.55) }
        return GRASPColor.hairline
    }

    private func submit(_ correct: Bool, given: String, question: LearnEngine.RoundQuestion,
                        judged: JudgedAnswer? = nil) {
        lastCorrect = correct
        wasOverridden = false
        self.judged = judged
        isAnswered = true
        try? store.submitTestAnswer(attemptId: attemptId, ordinal: index, given: given, isCorrect: correct)
        graded.append(GradedQuestion(question: question, ordinal: index, givenAnswer: given, isCorrect: correct,
                                     judged: judged))
    }

    /// The attempt isn't finished yet at this point, so this only needs to
    /// flip the just-saved `TestItem` row -- `AppStore.finishTest` will
    /// score correctly and grade it Good off this row once it runs, since
    /// a miss never gets graded in the first place.
    private func override(_ question: LearnEngine.RoundQuestion) {
        lastCorrect = true
        wasOverridden = true
        // The card remembers this wording, so it is accepted next time.
        if let cardId = question.cardId, let last = graded.last {
            store.rememberAcceptedAnswer(last.givenAnswer, forCard: cardId)
        }
        if let last = graded.indices.last {
            graded[last].isCorrect = true
            graded[last].judged = JudgedAnswer(outcome: .correct, source: .remembered)
        }
        try? store.overrideTestItemCorrect(attemptId: attemptId, ordinal: index, cardId: question.cardId)
    }

    /// The student flagged this AI-written question while looking at it:
    /// it stops counting here, and it won't be asked again.
    private func flagCurrent(_ question: LearnEngine.RoundQuestion) {
        store.flagQuestion(question)
        store.discardTestItem(attemptId: attemptId, ordinal: index)
        graded.removeAll { $0.ordinal == index }
        advance()
    }

    private func advance() {
        index += 1
        selectedChoice = nil
        writtenAnswer = ""
        isAnswered = false
        wasOverridden = false
        judged = nil
        isChecking = false
        if index >= questions.count {
            onFinished(graded)
        }
    }
}

struct TestResultsView: View {
    /// The line under the score. The flashcard sentence only when cards were asked.
    static func footnote(hasCards: Bool) -> String {
        (hasCards ? "Cards you got right just earned a longer flashcard interval. " : "")
            + "A miss here doesn't change anything. It just tells you where to focus."
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckName: String
    let attemptId: String
    /// Starts a new test over the misses; nil hides the button.
    let onRetry: ((String, [LearnEngine.RoundQuestion]) -> Void)?
    let deckIds: [String]
    @State private var graded: [GradedQuestion]
    /// Each card's stage after this test, read as its row appears.
    @State private var cardStates: [String: UnderstandingState] = [:]

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
                    .font(.graspUI(size: 20, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .padding(.top, 6)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(correct)")
                        .font(.graspUI(size: 44, weight: .semibold)).monospacedDigit()
                        .tracking(-1.4)
                        .foregroundStyle(correct == total ? GRASPColor.success : GRASPColor.textPrimary)
                        .contentTransition(.numericText())
                    Text("/ \(total)")
                        .font(.graspUI(size: 20, weight: .medium)).monospacedDigit()
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                .padding(.top, 14)
                .animation(Motion.base, value: correct)

                ProgressBar(
                    value: correct, total: total,
                    tint: correct == total ? GRASPColor.success : GRASPColor.brand
                )
                .frame(maxWidth: 260)
                .padding(.top, 14)
                .animation(Motion.base, value: correct)

                Text(Self.footnote(hasCards: graded.contains { $0.question.cardId != nil }))
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
                        Image(systemName: item.judged?.outcome == .closeEnough ? "checkmark.circle"
                              : (item.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill"))
                            .font(.graspUI(size: 11))
                            .foregroundStyle(item.judged?.outcome == .closeEnough ? GRASPColor.textSecondary
                                             : (item.isCorrect ? GRASPColor.success : GRASPColor.rejected))
                        Text(item.question.prompt)
                            .graspType(.rowTitle)
                            .foregroundStyle(GRASPColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.question.cardId == nil {
                            Label("AI-generated", systemImage: "sparkles")
                                .labelStyle(.iconOnly)
                                .font(.graspUI(size: 11))
                                .foregroundStyle(GRASPColor.accent)
                                .help("AI-generated for this test. Not saved as a card, worth double-checking")
                        }
                    }
                    if !item.isCorrect, let code = item.question.code, code.kind == .codeBlanks,
                       item.question.type != .multipleChoice {
                        // The code with the right text filled in beside what
                        // was typed, rather than two lists of numbers.
                        FilledBlankComparison(question: code, given: item.givenAnswer)
                            .padding(.top, 2)
                    } else if !item.isCorrect {
                        Text("You answered: \(item.question.type == .multipleChoice ? item.givenAnswer : (item.question.code?.givenText(item.givenAnswer) ?? item.givenAnswer))")
                            .font(item.question.code == nil ? nil : .system(size: 12, design: .monospaced))
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if item.question.type == .trueFalse, let statement = item.question.statement {
                        Text("Statement shown: \(statement)")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if item.isCorrect, item.judged?.outcome == .closeEnough {
                        // Counts as correct; says what the card said.
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Close enough")
                                .graspType(.eyebrow)
                                .textCase(.uppercase)
                                .foregroundStyle(GRASPColor.textTertiary)
                            TypedAnswerFeedback(judged: item.judged!, given: item.givenAnswer,
                                                expected: item.question.correctAnswer,
                                                hasCard: item.question.cardId != nil)
                        }
                        .padding(.top, 2)
                    } else if item.isCorrect {
                        Text(item.question.correctAnswer)
                            .graspType(.body)
                            .foregroundStyle(GRASPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if item.question.code?.kind == .codeBlanks, item.question.type != .multipleChoice {
                        // The comparison above already shows the right text.
                        EmptyView()
                    } else {
                        // A missed row always says which answer was right.
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Correct answer")
                                .graspType(.eyebrow)
                                .textCase(.uppercase)
                                .foregroundStyle(GRASPColor.textTertiary)
                            Text(item.question.correctAnswer)
                                .graspType(.body)
                                .foregroundStyle(GRASPColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }

                    WhyBlock(text: item.question.whyText)
                        .padding(.top, 2)
                    // Where this card stands now, in its stage colour.
                    if let cardId = item.question.cardId, let state = cardStates[cardId] {
                        HStack(spacing: 8) {
                            PipMeter(state: state, size: .card, showsWord: true)
                            Text("Now")
                                .font(.graspUI(size: 12))
                                .foregroundStyle(GRASPColor.textTertiary)
                        }
                        .padding(.top, 2)
                    }
                    if !item.isCorrect {
                        ExplainThisBlock(question: item.question, given: item.givenAnswer)
                            .padding(.top, 4)
                    }
                    if item.question.cardId == nil {
                        FlagQuestionButton {
                            store.flagQuestion(item.question)
                            store.discardTestItem(attemptId: attemptId, ordinal: item.ordinal)
                            withAnimation(Motion.fade) { graded.removeAll { $0.id == item.id } }
                        }
                        .padding(.top, 2)
                    }

                    // Exact/fuzzy text matching is a poor judge of a long or
                    // loaded free-response answer -- offered only for
                    // written questions, and only while still marked wrong.
                    if !item.isCorrect && item.question.allowsMarkCorrect {
                        Button("I actually got this right") { override(item) }
                            .buttonStyle(.plain)
                            .font(.graspUI(size: 12, weight: .medium))
                            .foregroundStyle(GRASPColor.accent)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 5)
                .onAppear {
                    if let id = item.question.cardId, cardStates[id] == nil {
                        cardStates[id] = store.understandingState(forCard: id)
                    }
                }
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
        .adaptiveStudySheet(minWidth: 560, minHeight: 520)
        .dimsWindowBehind()
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
        graded[index].judged = JudgedAnswer(outcome: .correct, source: .remembered)
        if let cardId = item.question.cardId {
            store.rememberAcceptedAnswer(item.givenAnswer, forCard: cardId)
        }
        try? store.overrideTestItemCorrect(attemptId: attemptId, ordinal: item.ordinal, cardId: item.question.cardId)
    }
}

/// "Leave this test?": save it for later, throw it away, or keep going.
private struct LeaveTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        GRASPSheet(
            title: "Leave this test?",
            message: "Saved tests can be continued from the deck, on this device or another.",
            icon: "pause.circle", width: 440
        ) {
            EmptyView()
        } footer: {
            Button("Discard test", role: .destructive, action: onDiscard)
            Spacer()
            Button("Keep going") { dismiss() }
            Button("Save and exit", action: onSave)
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
        }
        .presentationDetents([.medium])
    }
}
