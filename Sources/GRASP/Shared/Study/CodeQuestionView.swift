import SwiftUI
import GRASPCore

/// One code question in a test: the program, and the way to answer it that
/// suits its kind -- fields in the blanks, a box for the output, a tap on
/// the wrong line, or an editor for the missing code. Reports once, with
/// what was given and whether it was right; the test view around it shows
/// the verdict and moves on.
struct CodeQuestionView: View {
    @Environment(AppStore.self) private var store
    let question: CodeQuestion
    let isAnswered: Bool
    let onSubmit: (_ given: String, _ correct: Bool) -> Void

    @State private var blankAnswers: [Int: String] = [:]
    @State private var outputAnswer = ""
    @State private var functionAnswer = ""
    @State private var chosenLine: Int?
    @State private var isChecking = false
    @State private var runMessage: String?
    /// For a function written where it can't be run: the reference is shown
    /// and the student marks themselves.
    @State private var selfChecking = false

    private let codeFont = Font.system(size: 13, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            codeBlock
            answerArea
            if isAnswered { feedback }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    // MARK: - The program

    private var codeBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                switch question.kind {
                case .codeBlanks:
                    ForEach(Array(question.linePieces.enumerated()), id: \.offset) { index, pieces in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            lineNumber(index + 1)
                            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                                switch piece {
                                case .text(let text): Text(text).font(codeFont).foregroundStyle(GRASPColor.textPrimary)
                                case .blank(let number): blankField(number)
                                }
                            }
                        }
                    }
                case .findBug:
                    ForEach(Array(question.code.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                        bugLine(number: index + 1, text: line)
                    }
                case .predictOutput:
                    ForEach(Array(question.code.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            lineNumber(index + 1)
                            Text(line.isEmpty ? " " : line).font(codeFont).foregroundStyle(GRASPColor.textPrimary)
                        }
                    }
                case .completeFunction:
                    ForEach(Array(question.code.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            lineNumber(index + 1)
                            Text(line.contains("[[1]]")
                                 ? line.replacingOccurrences(of: "[[1]]", with: "⟨ your code ⟩")
                                 : (line.isEmpty ? " " : line))
                                .font(codeFont)
                                .foregroundStyle(line.contains("[[1]]") ? GRASPColor.accent : GRASPColor.textPrimary)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(GRASPColor.hairline))
    }

    private func lineNumber(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(GRASPColor.textTertiary)
            .frame(width: 26, alignment: .trailing)
            .padding(.trailing, 10)
    }

    private func blankField(_ number: Int) -> some View {
        let accepted = question.blanks.flatMap { number - 1 < $0.count && number >= 1 ? $0[number - 1] : nil } ?? []
        let width = CGFloat(max(6, (accepted.map(\.count).max() ?? 6) + 2)) * 8.4
        let given = blankAnswers[number] ?? ""
        let marks = CodeAnswerGrading.gradeBlanks([given], against: [accepted])
        let right = isAnswered && (marks.first ?? false)
        let wrong = isAnswered && !right
        return TextField("", text: Binding(get: { blankAnswers[number] ?? "" }, set: { blankAnswers[number] = $0 }),
                         prompt: Text("\(number)").foregroundStyle(GRASPColor.textTertiary))
            .textFieldStyle(.plain)
            .font(codeFont)
            .autocorrectionDisabledIfAvailable()
            .padding(.horizontal, 6)
            .frame(width: width, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(right ? GRASPColor.successSoft : wrong ? GRASPColor.accentSoft : GRASPColor.inset))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(right ? GRASPColor.success : wrong ? GRASPColor.accent : GRASPColor.hairlineStrong))
            .disabled(isAnswered)
            .padding(.horizontal, 2)
    }

    private func bugLine(number: Int, text: String) -> some View {
        let isBug = isAnswered && number == question.buggyLine
        let isWrongPick = isAnswered && chosenLine == number && number != question.buggyLine
        return Button {
            guard !isAnswered else { return }
            chosenLine = number
            let given = "Line \(number)"
            onSubmit(given, CodeAnswerGrading.grade(question, given: given) ?? false)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                lineNumber(number)
                Text(text.isEmpty ? " " : text).font(codeFont).foregroundStyle(GRASPColor.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .background(isBug ? GRASPColor.successSoft : isWrongPick ? GRASPColor.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAnswered)
    }

    // MARK: - Answering

    @ViewBuilder
    private var answerArea: some View {
        switch question.kind {
        case .codeBlanks:
            if !isAnswered {
                Button("Check") { checkBlanks() }
                    .buttonStyle(GRASPProminentButton())
                    .disabled(blankAnswers.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        case .predictOutput:
            editor(text: $outputAnswer, title: "What does it print?", lines: 4)
            if !isAnswered {
                Button("Check") {
                    onSubmit(outputAnswer, CodeAnswerGrading.grade(question, given: outputAnswer) ?? false)
                }
                .buttonStyle(GRASPProminentButton())
                .disabled(outputAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .findBug:
            if !isAnswered {
                Text("Tap the line that has the bug.")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
        case .completeFunction:
            editor(text: $functionAnswer, title: "Write the missing code", lines: 6)
            if selfChecking && !isAnswered {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This device can't run code, so compare yours with the answer:")
                        .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    Text(question.answerText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(GRASPColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GRASPColor.successSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(spacing: 8) {
                        Button("I got it right") { onSubmit(functionAnswer, true) }
                            .buttonStyle(GRASPProminentButton(tint: GRASPColor.success))
                        Button("I missed it") { onSubmit(functionAnswer, false) }
                            .buttonStyle(GRASPQuietButton())
                    }
                }
            } else if !isAnswered {
                HStack(spacing: 10) {
                    Button(canRunHere ? "Run and check" : "Show the answer") { checkFunction() }
                        .buttonStyle(GRASPProminentButton())
                        .disabled(functionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
                    if isChecking { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private func editor(text: Binding<String>, title: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            TextEditor(text: text)
                .font(codeFont)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabledIfAvailable()
                .padding(6)
                .frame(height: CGFloat(lines) * 19 + 16)
                .background(RoundedRectangle(cornerRadius: 8).fill(GRASPColor.inset))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(GRASPColor.hairlineStrong))
                .disabled(isAnswered)
        }
    }

    private func checkBlanks() {
        let answers = (1...max(1, question.blankCount)).map { blankAnswers[$0] ?? "" }
        let given = CodeAnswers.encode(answers)
        onSubmit(given, CodeAnswerGrading.grade(question, given: given) ?? false)
    }

    private var canRunHere: Bool {
        store.codeExecutor?.canRun(question.language) ?? false
    }

    /// Runs the student's code inside the program and compares what it
    /// prints. Where nothing can run it (the iPhone), the reference is
    /// shown and the student says how they did.
    private func checkFunction() {
        guard let executor = store.codeExecutor, executor.canRun(question.language) else {
            selfChecking = true
            return
        }
        isChecking = true
        let program = CodeQuestion.fillBlock(question.code, with: functionAnswer)
        let (expected, language, given) = (question.expectedOutput ?? "", question.language, functionAnswer)
        Task {
            let result = await executor.run(program, language: language)
            isChecking = false
            if !result.compiled {
                runMessage = "It didn't compile:\n" + String(result.stderr.prefix(400))
                onSubmit(given, false)
            } else if result.timedOut {
                runMessage = "It ran too long and was stopped."
                onSubmit(given, false)
            } else if result.exitCode != 0 {
                runMessage = "It crashed.\n" + String(result.stderr.prefix(300))
                onSubmit(given, false)
            } else {
                let right = CodeAnswerGrading.gradeOutput(result.stdout, expected: expected)
                if !right { runMessage = "Your code printed:\n" + result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
                onSubmit(given, right)
            }
        }
    }

    // MARK: - After answering

    @ViewBuilder
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let runMessage {
                Text(runMessage)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(GRASPColor.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.kind != .findBug {
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.kind == .predictOutput ? "It prints" : "Answer")
                        .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    Text(question.answerText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(GRASPColor.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GRASPColor.successSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let fixed = question.fixedLine {
                Text("Line \(question.buggyLine ?? 0) should read:  \(fixed)")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(GRASPColor.textPrimary)
                    .textSelection(.enabled)
            }
            if question.kind == .codeBlanks || question.kind == .completeFunction, let output = question.expectedOutput {
                Text("The finished program prints:  \(output.replacingOccurrences(of: "\n", with: " ⏎ "))")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            if let explanation = question.explanation {
                Text(explanation)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    /// Code isn't prose: no autocorrect, no smart quotes.
    @ViewBuilder
    func autocorrectionDisabledIfAvailable() -> some View {
        self.autocorrectionDisabled(true)
    }
}
