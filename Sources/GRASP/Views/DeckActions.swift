import SwiftUI
import GRASPCore

/// Right-click actions for a deck row, mirroring `CourseContextMenu`'s
/// shape. "New Deck" lives on the toolbar, not here -- a context menu
/// needs an existing row to attach to.
struct DeckContextMenu: View {
    let deck: Deck
    let onRename: () -> Void
    let onSetLectureDate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("Rename…", action: onRename)
        Button(deck.manualLessonDate == nil ? "Set Lecture Date…" : "Change Lecture Date…",
               action: onSetLectureDate)
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
    }
}

/// One text field, appended to the end of the course's deck ordering.
struct DeckCreateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let courseId: String
    let onCreated: (String) -> Void

    @State private var name = ""

    var body: some View {
        GRASPSheet(
            eyebrow: "Deck", title: "New deck",
            message: "A custom module or unit for cards you organize by hand.", width: 400
        ) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Name")
                TextField("e.g. Midterm Review", text: $name)
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button("Create deck") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if let id = try? store.createDeck(courseId: courseId, name: trimmed) {
                    onCreated(id)
                }
                dismiss()
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

struct DeckRenameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deck: Deck
    let onRenamed: () -> Void

    @State private var name: String

    init(deck: Deck, onRenamed: @escaping () -> Void) {
        self.deck = deck
        self.onRenamed = onRenamed
        _name = State(initialValue: deck.name)
    }

    var body: some View {
        GRASPSheet(eyebrow: "Deck", title: "Rename deck", width: 400) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Name")
                TextField("Deck name", text: $name)
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button("Save") {
                try? store.renameDeck(deck.id, name: name.trimmingCharacters(in: .whitespaces))
                onRenamed()
                dismiss()
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// Shown only when the deck has at least one card -- a caller checks
/// `deckCardCount` first and deletes an empty deck immediately, with no
/// prompt at all. `onConfirm` receives the chosen target deck id, or nil
/// for "delete the cards too".
struct DeckDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deck: Deck
    let cardCount: Int
    let siblings: [Deck]
    let onConfirm: (String?) -> Void

    private enum Choice: Hashable { case move, deleteAll }
    @State private var choice: Choice
    @State private var targetId: String?

    init(deck: Deck, cardCount: Int, siblings: [Deck], onConfirm: @escaping (String?) -> Void) {
        self.deck = deck
        self.cardCount = cardCount
        self.siblings = siblings
        self.onConfirm = onConfirm
        _choice = State(initialValue: siblings.isEmpty ? .deleteAll : .move)
        _targetId = State(initialValue: siblings.first?.id)
    }

    private var cardWord: String { cardCount == 1 ? "card" : "cards" }

    var body: some View {
        GRASPSheet(
            title: "Delete \u{201C}\(deck.name)\u{201D}?",
            message: "This deck has \(cardCount) \(cardWord). Choose what happens to them.",
            icon: "trash", tone: .destructive, width: 440
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !siblings.isEmpty {
                    GRASPRadioRow(isOn: choice == .move, action: { choice = .move }) {
                        Text("Move \(cardCount) \(cardWord) to another deck")
                    }
                    if choice == .move {
                        GRASPDropdown(selection: $targetId, options: siblings.map { ($0.id as String?, $0.name) })
                            .frame(maxWidth: 260)
                            .padding(.leading, 25)
                    }
                }
                GRASPRadioRow(isOn: choice == .deleteAll, action: { choice = .deleteAll }) {
                    Text("Delete \(cardCount) \(cardWord) along with the deck")
                }
                Text("Review history is kept even when cards are deleted.")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .padding(.leading, 25)
            }
            .popupGroup()
        } footer: {
            Button("Cancel") { dismiss() }
            Button(choice == .move ? "Move and delete deck" : "Delete everything") {
                onConfirm(choice == .move ? targetId : nil)
                dismiss()
            }
            .buttonStyle(GRASPProminentButton(tint: GRASPColor.rejected))
            .keyboardShortcut(.defaultAction)
            .disabled(choice == .move && targetId == nil)
        }
    }
}

/// Lets the student assign a lecture date by hand when a deck's notes
/// carry none to extract (no date in the filename or front matter). Never
/// shown as overriding an extracted date -- `AppStore.deckKickers` always
/// prefers the extracted one, so this only ever fills in where extraction
/// found nothing.
struct DeckLectureDateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deck: Deck
    let onSaved: () -> Void

    @State private var date: Date
    @State private var isRange: Bool
    @State private var endDate: Date

    init(deck: Deck, onSaved: @escaping () -> Void) {
        self.deck = deck
        self.onSaved = onSaved
        _date = State(initialValue: deck.manualLessonDate ?? Date())
        _isRange = State(initialValue: deck.manualLessonDateEnd != nil)
        _endDate = State(initialValue: deck.manualLessonDateEnd ?? deck.manualLessonDate ?? Date())
    }

    var body: some View {
        GRASPSheet(
            eyebrow: deck.name, title: "Lecture date",
            message: "Shown in the sidebar when GRASP can't read a date from this deck's notes.",
            icon: "calendar", width: 420
        ) {
            VStack(alignment: .leading, spacing: 12) {
                GRASPSegmented(selection: $isRange, options: [(false, "One lecture"), (true, "A range")])
                HStack(spacing: GRASPSpace.l) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(isRange ? "Starts" : "Date")
                        DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
                    }
                    if isRange {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel("Ends")
                            DatePicker("", selection: $endDate, in: date..., displayedComponents: .date).labelsHidden()
                        }
                    }
                }
            }
            .popupGroup()
        } footer: {
            if deck.manualLessonDate != nil {
                Button("Clear date", role: .destructive) {
                    try? store.setDeckManualLessonDate(deck.id, start: nil)
                    onSaved()
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") {
                try? store.setDeckManualLessonDate(deck.id, start: date, end: isRange ? endDate : nil)
                onSaved()
                dismiss()
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
        }
    }
}
