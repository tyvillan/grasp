import SwiftUI
import GRASPCore

/// "Why": the muted explanation that comes with a question, under the
/// correct answer. Shows nothing when there is none.
struct WhyBlock: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Why")
                    .graspType(.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(GRASPColor.textTertiary)
                Text(text)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A wrong fill-in-the-blank, shown as code: the right text filled in and
/// highlighted, and what was typed in the same places. Side by side on the
/// Mac, stacked on the iPhone.
struct FilledBlankComparison: View {
    let question: CodeQuestion
    let given: String

    private var typed: [String] { CodeAnswers.decode(given) }
    private var correct: [String] { (question.blanks ?? []).map { $0.first ?? "" } }
    private var marks: [Bool] { CodeAnswerGrading.gradeBlanks(typed, against: question.blanks ?? []) }

    var body: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 12) {
            panel("Correct", content: correctCode)
            panel("You typed", content: typedCode)
        }
        #else
        VStack(alignment: .leading, spacing: 10) {
            panel("Correct", content: correctCode)
            panel("You typed", content: typedCode)
        }
        #endif
    }

    private func panel(_ title: String, content: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .graspType(.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(GRASPColor.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(GRASPColor.textPrimary)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var correctCode: AttributedString {
        highlighted { number in (correct.indices.contains(number - 1) ? correct[number - 1] : "", GRASPColor.successSoft) }
    }

    private var typedCode: AttributedString {
        highlighted { number in
            let index = number - 1
            let text = typed.indices.contains(index) ? typed[index] : ""
            let right = marks.indices.contains(index) && marks[index]
            return (text.isEmpty ? "(blank)" : text, right ? GRASPColor.successSoft : GRASPColor.rejectedSoft)
        }
    }

    /// The code with each blank replaced by `fill(n)`'s text, highlighted
    /// in its colour.
    private func highlighted(_ fill: (Int) -> (String, Color)) -> AttributedString {
        var result = AttributedString()
        for piece in question.pieces {
            switch piece {
            case .text(let text):
                result += AttributedString(text)
            case .blank(let number):
                let (text, color) = fill(number)
                var run = AttributedString(text)
                run.backgroundColor = color
                result += run
            }
        }
        return result
    }
}

/// "Explain this" on a wrong answer: an outlined AI button that asks once
/// for a short explanation of this answer, shows it inline, and never runs
/// by itself.
struct ExplainThisBlock: View {
    @Environment(AppStore.self) private var store
    let question: LearnEngine.RoundQuestion
    let given: String

    private enum Phase: Equatable { case idle, loading, done(String), failed(String) }
    @State private var phase: Phase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .idle:
                button("Explain this")
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Explaining…").graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                }
            case .done(let text):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explanation of your answer")
                        .graspType(.eyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(GRASPColor.textTertiary)
                    Text(text)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            case .failed(let message):
                Text(message).graspType(.meta).foregroundStyle(GRASPColor.rejected)
                    .fixedSize(horizontal: false, vertical: true)
                button("Try again")
            }
        }
        .animation(Motion.fade, value: phase)
    }

    private func button(_ title: String) -> some View {
        Button { run() } label: {
            HStack(spacing: 6) {
                Image(systemName: AIGlyph.symbol)
                    .font(.graspUI(size: 11, weight: .semibold))
                    .foregroundStyle(GRASPColor.accent)
                Text(title)
            }
        }
        .buttonStyle(GRASPQuietButton())
        .disabled(phase == .loading)
    }

    private func run() {
        phase = .loading
        Task {
            do {
                phase = .done(try await store.explainWrongAnswer(for: question, given: given))
            } catch AppStore.ExplainThisError.message(let message) {
                phase = .failed(message)
            } catch {
                phase = .failed(PlainError.message(error, couldnt: "explain this"))
            }
        }
    }
}

/// "Flag this question" on an AI-written question: it isn't asked again.
struct FlagQuestionButton: View {
    let onFlag: () -> Void
    @State private var flagged = false

    var body: some View {
        if flagged {
            Text("Flagged. It won't be asked again.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        } else {
            Button {
                flagged = true
                onFlag()
            } label: {
                Label("Flag this question", systemImage: "flag")
                    .labelStyle(.titleAndIcon)
                    .font(.graspUI(size: 12, weight: .medium))
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .buttonStyle(.plain)
            .help("This question is wrong or unclear. GRASP won't ask it again.")
        }
    }
}
