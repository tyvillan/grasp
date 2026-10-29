import SwiftUI
import GRASPCore

/// Write or edit a question: multiple choice (2 to 6 choices, one right),
/// written (an answer and other wordings that count), or true / false.
/// Saves as active. Used on the Mac and the iPhone.
struct QuestionEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Decks a new question can go in. Editing keeps its deck.
    let decks: [Deck]
    /// Set when editing a saved question.
    var editing: TestQuestion? = nil

    @State private var input = UserQuestionInput()
    @State private var deckId: String?
    @State private var cards: [Card] = []
    @State private var saveError: String?
    @FocusState private var promptFocused: Bool
    @State private var enlarging = false

    private var isEditing: Bool { editing != nil }
    /// The picture a photo question was read from, if this device has it.
    private var photoData: Data? { editing?.imageId.flatMap { store.questionImage($0)?.jpegData } }

    var body: some View {
        GRASPSheet(eyebrow: "Question", title: isEditing ? "Edit question" : "Write a question",
                   icon: "square.and.pencil", width: 520) {
            VStack(alignment: .leading, spacing: 14) {
                if !isEditing {
                    GRASPSegmented(
                        selection: $input.kind,
                        options: UserQuestionInput.writableKinds.map { ($0, kindTitle($0)) },
                        fillsWidth: true
                    )
                } else {
                    Text(input.kind.label)
                        .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                }

                if let photo = photoData {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Photo")
                        Button { enlarging = true } label: {
                            MarkedPhoto(data: photo, box: PhotoBox(encoded: editing?.imageCrop))
                                .frame(maxWidth: .infinity, maxHeight: 220)
                                .background(GRASPColor.inset, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("See the whole photo")
                        .accessibilityLabel("Enlarge the photo")
                        if let editing, QuestionBank.needsAnswerCheck(editing) {
                            Text(editing.verifiedBy.contains(QuestionBank.readCheckMarker)
                                 ? "The photo was hard to read, so the words may be wrong. Check them against the photo before you save."
                                 : "The photo did not print this answer. The AI wrote it, so check it against the photo before you save.")
                                .graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !isEditing, decks.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Deck")
                        GRASPPicker(selection: $deckId, options: decks.map { ($0.id as String?, $0.name) })
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(input.kind == .trueFalse ? "Statement" : "Question")
                    TextEditor(text: $input.prompt)
                        .graspEditorChrome(minHeight: 72)
                        .focused($promptFocused)
                }

                switch input.kind {
                case .multipleChoice: choiceFields
                case .written: writtenFields
                default: trueFalseFields
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Why (optional)")
                    TextEditor(text: $input.explanation).graspEditorChrome(minHeight: 52)
                }

                if !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Helps this card (optional)")
                        GRASPPicker(
                            selection: $input.cardId,
                            options: [(String?.none, "No card")] + cards.map { ($0.id as String?, $0.front) }
                        )
                        Text("Answering it moves that card's understanding meter. It never changes when the card comes back in flashcards.")
                            .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let saveError {
                    Text(saveError).graspType(.meta).foregroundStyle(GRASPColor.rejected)
                }
            }
            .animation(Motion.snappy, value: input.kind)
        } footer: {
            if let problem = input.problem, !input.prompt.isEmpty || input.kind != .multipleChoice {
                Text(problem).graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button(isEditing ? "Save" : "Add question") { save() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
                .disabled(input.problem != nil || (!isEditing && deckId == nil))
        }
        .task {
            if let editing, let existing = UserQuestionInput(editing) {
                input = existing
                deckId = editing.deckId
            } else {
                deckId = decks.first?.id
            }
            cards = store.linkableCards(inDecks: deckId.map { [$0] } ?? decks.map(\.id))
            // With a photo to compare against, the keyboard stays down until you tap the text.
            promptFocused = photoData == nil
            #if DEBUG
            if ProcessInfo.processInfo.environment["GRASP_EDITOR_ENLARGE"] == "1" {
                try? await Task.sleep(for: .milliseconds(900))
                enlarging = true
            }
            #endif
        }
        .sheet(isPresented: $enlarging) {
            if let photo = photoData { QuestionPhotoSheet(data: photo, box: PhotoBox(encoded: editing?.imageCrop)) }
        }
        .onChange(of: deckId) { _, new in
            cards = store.linkableCards(inDecks: new.map { [$0] } ?? [])
            if let linked = input.cardId, !cards.contains(where: { $0.id == linked }) { input.cardId = nil }
        }
    }

    /// "Multiple choice" does not fit three segments on an iPhone SE.
    private func kindTitle(_ kind: ProblemKind) -> String {
        #if os(iOS)
        kind == .multipleChoice ? "Choice" : kind.label
        #else
        kind.label
        #endif
    }

    // MARK: Fields by kind

    private var choiceFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Choices (tap the circle beside the right one)")
            ForEach(input.choices.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Button { input.correct = index } label: {
                        Image(systemName: input.correct == index ? "checkmark.circle.fill" : "circle")
                            .font(.graspUI(size: 18))
                            .foregroundStyle(input.correct == index ? GRASPColor.success : GRASPColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(input.correct == index ? "Right answer" : "Mark as the right answer")
                    TextField("Choice \(index + 1)", text: $input.choices[index])
                        .textFieldStyle(GRASPFieldStyle())
                    if input.choices.count > UserQuestionInput.choiceRange.lowerBound {
                        Button { removeChoice(index) } label: {
                            Image(systemName: "minus.circle").foregroundStyle(GRASPColor.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove choice \(index + 1)")
                    }
                }
            }
            if input.choices.count < UserQuestionInput.choiceRange.upperBound {
                Button { input.choices.append("") } label: { Label("Add a choice", systemImage: "plus") }
                    .buttonStyle(GRASPQuietButton())
            }
        }
    }

    private func removeChoice(_ index: Int) {
        input.choices.remove(at: index)
        if input.correct == index { input.correct = 0 } else if input.correct > index { input.correct -= 1 }
    }

    private var writtenFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Answer")
                TextField("The answer", text: $input.answer).textFieldStyle(GRASPFieldStyle())
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Other wordings that count (optional, one per line)")
                TextEditor(text: Binding(
                    get: { input.accepted.joined(separator: "\n") },
                    set: { input.accepted = $0.components(separatedBy: "\n") }
                ))
                .graspEditorChrome(minHeight: 52)
                Text("Typed answers are checked by meaning too, so small differences in wording are fine.")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trueFalseFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("The statement is")
            GRASPSegmented(selection: $input.isTrue, options: [(true, "True"), (false, "False")], fillsWidth: true)
        }
    }

    // MARK: Save

    private func save() {
        saveError = nil
        do {
            if let editing {
                try store.updateQuestion(editing.id, with: input)
            } else if let deckId {
                try store.saveQuestion(input, deckId: deckId)
            }
            dismiss()
        } catch {
            saveError = PlainError.message(error, couldnt: "save the question")
        }
    }
}
