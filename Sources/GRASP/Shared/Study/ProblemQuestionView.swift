import SwiftUI
import GRASPCore

/// A number or matrix problem in a test: a box to type the answer in, and
/// the working shown once it has been checked. (Multiple choice problems use
/// the ordinary choice list.)
struct ProblemQuestionView: View {
    let problem: ProblemQuestion
    let isAnswered: Bool
    let onSubmit: (_ given: String, _ correct: Bool) -> Void

    @State private var answer = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch problem.kind {
            case .number:
                HStack(spacing: 8) {
                    TextField(problem.unit.map { "Type a number (\($0))" } ?? "Type a number", text: $answer)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GRASPColor.inset))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(focused ? GRASPColor.accent : GRASPColor.hairlineStrong))
                        .focused($focused)
                        .disabled(isAnswered)
                        .onSubmit(check)
                        .frame(maxWidth: 320)
                    if let unit = problem.unit {
                        Text(unit).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    }
                }
                .task { focused = true }
            case .matrix:
                Text("Write the rows on separate lines, entries separated by spaces. Fractions like 1/2 are fine.")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                TextEditor(text: $answer)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled(true)
                    .padding(6)
                    .frame(height: CGFloat(max(3, min(5, problem.matrix?.count ?? 3))) * 21 + 16)
                    .background(RoundedRectangle(cornerRadius: 8).fill(GRASPColor.inset))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(GRASPColor.hairlineStrong))
                    .disabled(isAnswered)
                    .frame(maxWidth: 360)
            case .multipleChoice:
                EmptyView()
            }
            if !isAnswered {
                Button("Check", action: check)
                    .buttonStyle(GRASPProminentButton())
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                feedback
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func check() {
        guard !isAnswered, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit(answer, ProblemAnswerGrading.grade(problem, given: answer) ?? false)
    }

    @ViewBuilder
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Answer").graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            Text(problem.answerText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(GRASPColor.textPrimary)
                .textSelection(.enabled)
            if let explanation = problem.explanation {
                Text(explanation)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GRASPColor.successSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
