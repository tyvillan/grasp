import Foundation
import GRASPCore
import SwiftCrossUI

/// The program of a code question, line by line with numbers, in a
/// monospaced font. Shared by the question, its multiple-choice version and
/// the results list. `highlight` marks a line (the bug, once answered).
struct CodeBlockView: View {
    let code: String
    var highlight: Int?
    var wrongPick: Int?
    /// Blanks left open show as a marker, not their `[[n]]` source.
    var onTapLine: ((Int) -> Void)?

    static let font = Font.system(size: 13).monospaced()

    var body: some View {
        let lines = code.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { item in
                let number = item.offset + 1
                HStack(alignment: .top, spacing: 10) {
                    Text("\(number)")
                        .font(Font.system(size: 11).monospaced())
                        .foregroundColor(GRASPColor.textTertiary)
                        .frame(width: 24.0, alignment: .trailing)
                    Text(Self.display(item.element))
                        .font(Self.font)
                        .foregroundColor(GRASPColor.textPrimary)
                    Spacer()
                }
                .padding(.vertical, 1)
                .background(number == highlight ? GRASPColor.successSoft
                            : number == wrongPick ? GRASPColor.rejectedSoft : Color.clear)
                .onTapGesture { onTapLine?(number) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.surface)
        .cornerRadius(9)
    }

    /// An empty line still takes its height; `[[n]]` reads as an open slot, __n__.
    static func display(_ line: String) -> String {
        if line.isEmpty { return " " }
        return CodeQuestion.fill(line) { "__\($0)__" }
    }
}

/// The answer area for a code question asked as a written one: fields in
/// the blanks, a box for the output, a tap on the wrong line, or the
/// student's own code, which this PC can't run, so they mark it themselves.
struct CodeAnswerArea: View {
    let code: CodeQuestion
    @Binding var answer: AnswerState
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch code.kind {
            case .codeBlanks: blanks
            case .predictOutput: output
            case .findBug: bug
            case .completeFunction: function
            }
        }
        .frame(maxWidth: 560.0, alignment: .leading)
    }

    // MARK: Fill in the blanks

    private var blanks: some View {
        let marks = CodeAnswerGrading.gradeBlanks(answer.blanks, against: code.blanks ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            CodeBlockView(code: code.code)
            ForEach(Array((code.blanks ?? []).indices), id: \.self) { index in
                let ok = answer.isAnswered && index < marks.count && marks[index]
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(Font.system(size: 12, weight: .semibold))
                        .foregroundColor(GRASPColor.accent)
                        .frame(width: 18.0)
                    TextField("Fill in blank \(index + 1)", text: Binding(
                        get: { index < answer.blanks.count ? answer.blanks[index] : "" },
                        set: { value in
                            while answer.blanks.count <= index { answer.blanks.append("") }
                            answer.blanks[index] = value
                            answer.written = CodeAnswers.encode(answer.blanks)
                        }))
                        .font(CodeBlockView.font)
                        .frame(width: 320.0)
                        .disabled(answer.isAnswered)
                        .onSubmit(perform: submit)
                    if answer.isAnswered {
                        Text(ok ? "✓" : "✕ \(code.blanks?[index].first ?? "")")
                            .font(CodeBlockView.font)
                            .foregroundColor(ok ? GRASPColor.success : GRASPColor.accent)
                            .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: Predict the output

    private var output: some View {
        VStack(alignment: .leading, spacing: 10) {
            CodeBlockView(code: code.code)
            Text("What does it print? One line per line of output.")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
            TextEditor(text: $answer.written)
                .font(CodeBlockView.font)
                .frame(height: 96.0)
                .padding(6)
                .background(GRASPColor.inset)
                .cornerRadius(7)
                .disabled(answer.isAnswered)
            if answer.isAnswered, !answer.wasCorrect {
                Text("It prints").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                Text(code.expectedOutput ?? "")
                    .font(CodeBlockView.font)
                    .foregroundColor(GRASPColor.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GRASPColor.successSoft)
                    .cornerRadius(7)
            }
        }
    }

    // MARK: Find the bug

    private var bug: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer.isAnswered ? "The bug is on line \(code.buggyLine ?? 0)." : "Tap the line with the bug.")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
            CodeBlockView(
                code: code.code,
                highlight: answer.isAnswered ? code.buggyLine : nil,
                wrongPick: answer.isAnswered ? answer.selectedLine : nil
            ) { number in
                guard !answer.isAnswered else { return }
                answer.selectedLine = number
                answer.written = "Line \(number)"
                submit()
            }
            if answer.isAnswered, let fixed = code.fixedLine {
                Text("It should read").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                Text(fixed)
                    .font(CodeBlockView.font)
                    .foregroundColor(GRASPColor.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GRASPColor.successSoft)
                    .cornerRadius(7)
            }
        }
    }

    // MARK: Complete the function

    private var function: some View {
        VStack(alignment: .leading, spacing: 10) {
            CodeBlockView(code: code.code)
            Text("Write the missing code.")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
            TextEditor(text: $answer.written)
                .font(CodeBlockView.font)
                .frame(height: 110.0)
                .padding(6)
                .background(GRASPColor.inset)
                .cornerRadius(7)
                .disabled(answer.checkingFunction || answer.isAnswered)
            if answer.checkingFunction || answer.isAnswered {
                Text("A reference answer").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                Text(code.blanks?.first?.first ?? "")
                    .font(CodeBlockView.font)
                    .foregroundColor(GRASPColor.textPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GRASPColor.successSoft)
                    .cornerRadius(7)
                if !answer.isAnswered {
                    Text("GRASP can't run code on this PC, so compare yours with the reference and mark it yourself.")
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A code question asked as multiple choice: its program above the options.
struct CodeContextBlock: View {
    let code: CodeQuestion

    var body: some View {
        CodeBlockView(code: code.code)
            .frame(maxWidth: 560.0)
    }
}
