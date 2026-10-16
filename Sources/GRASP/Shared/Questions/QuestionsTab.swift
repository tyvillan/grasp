import SwiftUI
import GRASPCore

/// A deck's Questions tab: the deck's saved questions, each with where it
/// came from, what kind it is, and how it did lately. Questions are for
/// practicing like the exam; cards are for remembering. No Learn ladder or
/// meter here. Shared by the Mac and the iPhone.
struct QuestionsTab: View {
    @Environment(AppStore.self) private var store
    let deckIds: [String]
    var query = ""
    /// Opens the editor for a new question (the Add menu sets it).
    @Binding var isWriting: Bool
    /// The decks a new question can go in.
    let decks: [Deck]

    @State private var questions: [TestQuestion] = []
    @State private var history: [String: QuestionHistory] = [:]
    @State private var hasLoaded = false
    @State private var editing: TestQuestion?
    @State private var pendingDelete: TestQuestion?

    private var shown: [TestQuestion] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty ? questions : questions.filter { $0.promptText.lowercased().contains(needle) }
        // Suspended questions sink to the bottom of the list.
        return matching.filter { $0.statusKind != .suspended } + matching.filter { $0.statusKind == .suspended }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasLoaded && questions.isEmpty {
                QuestionsEmptyState { isWriting = true }
            } else if hasLoaded {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { question in
                        QuestionRow(
                            question: question, history: history[question.id],
                            onEdit: { editing = question },
                            onSetStatus: { store.setQuestionStatus(question.id, to: $0) },
                            onDelete: { pendingDelete = question }
                        )
                        Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                    }
                }
            }
        }
        .task(id: "\(store.revision)-\(deckIds.joined())") { load() }
        .sheet(isPresented: $isWriting) { QuestionEditorSheet(decks: decks) }
        .sheet(item: $editing) { question in QuestionEditorSheet(decks: decks, editing: question) }
        .sheet(item: $pendingDelete) { question in
            ConfirmationSheet(
                icon: "trash", title: "Delete This Question?",
                message: "It will no longer appear in tests. Past test results are kept.",
                confirmTitle: "Delete"
            ) {
                CodeQuestionBankDeleter.delete(question.id, store: store)
            }
        }
    }

    private func load() {
        questions = store.savedQuestions(inDecks: deckIds)
        history = store.questionHistory(of: questions.map(\.id))
        hasLoaded = true
    }
}

/// Soft delete through the bank; the questions' test history stays.
enum CodeQuestionBankDeleter {
    @MainActor static func delete(_ id: String, store: AppStore) { store.deleteCodeQuestion(id) }
}

// MARK: - Empty state

private struct QuestionsEmptyState: View {
    let onWrite: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.clipboard")
                .font(.graspUI(size: 26))
                .foregroundStyle(GRASPColor.textTertiary)
            Text("Cards are for remembering. Questions are for practicing like the exam.")
                .graspType(.body)
                .foregroundStyle(GRASPColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Button("Write a question", action: onWrite)
                .buttonStyle(GRASPQuietButton())
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
    }
}

// MARK: - Row

private struct QuestionRow: View {
    let question: TestQuestion
    let history: QuestionHistory?
    let onEdit: () -> Void
    let onSetStatus: (QuestionStatus) -> Void
    let onDelete: () -> Void

    private var canEdit: Bool { UserQuestionInput(question) != nil }
    private var isSuspended: Bool { question.statusKind == .suspended }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text(question.promptText.isEmpty ? "(No text)" : question.promptText)
                    .font(.graspUI(size: 14, weight: .medium))
                    .foregroundStyle(isSuspended ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // The details wrap under the prompt on a narrow screen.
                FlowLine {
                    SourceBadge(source: question.sourceKind)
                    Text(question.summaryLine)
                        .font(.graspUI(size: 12))
                        .foregroundStyle(GRASPColor.textTertiary)
                    Text(history?.line ?? "Not asked yet")
                        .font(.graspUI(size: 12))
                        .foregroundStyle(GRASPColor.textTertiary)
                        .monospacedDigit()
                    if isSuspended {
                        Label("Suspended", systemImage: "pause.circle")
                            .font(.graspUI(size: 12, weight: .medium))
                            .foregroundStyle(GRASPColor.rejected)
                    } else if question.statusKind == .draft {
                        Text("Draft")
                            .font(.graspUI(size: 12, weight: .medium))
                            .foregroundStyle(GRASPColor.textSecondary)
                    }
                }
            }
            Spacer(minLength: 4)
            QuestionRowMenu(
                canEdit: canEdit, isSuspended: isSuspended, onEdit: onEdit,
                onSuspend: { onSetStatus(.suspended) }, onReactivate: { onSetStatus(.active) }, onDelete: onDelete
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

private extension TestQuestion {
    /// "Multiple choice", "Fill in the blanks · C++": the kind, in words.
    /// A concepts question needs no subject beside its kind.
    var summaryLine: String {
        if let code = question { return "\(code.kind.label) · \(code.language.label)" }
        if let problem {
            return problem.subject == .concepts ? problem.kind.label : "\(problem.kind.label) · \(problem.subject.label)"
        }
        return kind
    }
}

/// Where a question came from. The sparkle means AI, and only AI.
struct SourceBadge: View {
    let source: QuestionSource

    var body: some View {
        HStack(spacing: 4) {
            if source == .ai {
                Image(systemName: AIGlyph.symbol)
                    .font(.graspUI(size: 9, weight: .semibold))
                    .foregroundStyle(GRASPColor.accent)
            }
            Text(source.label)
                .font(.graspUI(size: 11, weight: .semibold))
                .foregroundStyle(GRASPColor.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(GRASPColor.inset, in: Capsule())
        .overlay(Capsule().strokeBorder(GRASPColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source: \(source.label)")
    }
}

/// Items in a line that wraps when the row is narrow.
private struct FlowLine<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content() }
            VStack(alignment: .leading, spacing: 5) { content() }
        }
    }
}

private struct QuestionRowMenu: View {
    let canEdit: Bool
    let isSuspended: Bool
    let onEdit: () -> Void
    let onSuspend: () -> Void
    let onReactivate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        #if os(macOS)
        IconMenu(help: "Question actions") {
            var items: [PillMenuItem] = []
            if canEdit { items.append(.action("Edit…", systemImage: "pencil") { onEdit() }) }
            items.append(isSuspended
                ? .action("Reactivate", systemImage: "play.circle") { onReactivate() }
                : .action("Suspend", systemImage: "pause.circle",
                          help: "Keeps it, but it won't come up in tests") { onSuspend() })
            items.append(.divider)
            items.append(.action("Delete…", systemImage: "trash", destructive: true) { onDelete() })
            return items
        }
        #else
        Menu {
            if canEdit { Button { onEdit() } label: { Label("Edit", systemImage: "pencil") } }
            if isSuspended {
                Button { onReactivate() } label: { Label("Reactivate", systemImage: "play.circle") }
            } else {
                Button { onSuspend() } label: { Label("Suspend", systemImage: "pause.circle") }
            }
            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.graspUI(size: 13, weight: .bold))
                .foregroundStyle(GRASPColor.textSecondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Question actions")
        #endif
    }
}
