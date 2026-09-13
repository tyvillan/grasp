import SwiftUI
import GRASPCore

/// Right-click actions for a deck row, mirroring `CourseContextMenu`'s
/// shape. "New Deck" lives on the toolbar, not here -- a context menu
/// needs an existing row to attach to.
struct DeckContextMenu: View {
    let deck: Deck
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("Rename…", action: onRename)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("New Deck").font(.headline)
            Text("A custom module or unit for cards you organize by hand.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Deck name (e.g. Midterm Review)", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if let id = try? store.createDeck(courseId: courseId, name: trimmed) {
                        onCreated(id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Deck").font(.headline)
            TextField("Deck name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    try? store.renameDeck(deck.id, name: name.trimmingCharacters(in: .whitespaces))
                    onRenamed()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \"\(deck.name)\"?").font(.headline)
            Text("This deck has \(cardCount) \(cardWord). Choose what happens to them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                if !siblings.isEmpty {
                    Toggle(isOn: Binding(get: { choice == .move }, set: { if $0 { choice = .move } })) {
                        Text("Move \(cardCount) \(cardWord) to another deck")
                    }
                    .toggleStyle(.radioGroupCompat)

                    if choice == .move {
                        Picker("Move to", selection: $targetId) {
                            ForEach(siblings) { sibling in
                                Text(sibling.name).tag(sibling.id as String?)
                            }
                        }
                        .labelsHidden()
                        .padding(.leading, 20)
                    }
                }

                Toggle(isOn: Binding(get: { choice == .deleteAll }, set: { if $0 { choice = .deleteAll } })) {
                    Text("Delete \(cardCount) \(cardWord) along with the deck")
                }
                .toggleStyle(.radioGroupCompat)
                Text("Review history is kept even when cards are deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(choice == .move ? "Move and Delete Deck" : "Delete Everything", role: .destructive) {
                    onConfirm(choice == .move ? targetId : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == .move && targetId == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private extension ToggleStyle where Self == RadioGroupCompatToggleStyle {
    static var radioGroupCompat: RadioGroupCompatToggleStyle { RadioGroupCompatToggleStyle() }
}

/// A plain checkbox-style toggle reads as "on/off", not "pick one of
/// these" -- this renders as a filled/empty circle instead, the shape a
/// mutually-exclusive choice actually needs, without pulling in a second
/// `Picker` just for two radio options.
private struct RadioGroupCompatToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(configuration.isOn ? GRASPColor.accent : .secondary)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
