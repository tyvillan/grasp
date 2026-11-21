import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GRASPCore

extension UTType {
    /// The file a deck is shared as. Not registered with the system; opened from inside GRASP.
    static let graspDeckFile = UTType(filenameExtension: "graspdeck", conformingTo: .json) ?? .json
}

/// "Share deck": a file another GRASP user imports, or a printable copy.
struct ShareDeckSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deck: Deck

    @State private var includeQuestions = true
    @State private var notice: String?
    @State private var cardCount = 0
    @State private var questionCount = 0

    var body: some View {
        GRASPSheet(
            eyebrow: "Share", title: deck.name,
            message: "Send a classmate this deck as a file. They open it in GRASP and it joins their course as a new deck. "
                + "Only approved cards are shared, never your study history.",
            icon: "square.and.arrow.up", width: 460
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(cardCount) approved card\(cardCount == 1 ? "" : "s")")
                    .graspType(.body).foregroundStyle(GRASPColor.textPrimary)
                if questionCount > 0 {
                    Toggle("Include \(questionCount) saved question\(questionCount == 1 ? "" : "s")", isOn: $includeQuestions)
                }
                if let notice {
                    Text(notice).graspType(.meta).foregroundStyle(GRASPColor.textSecondary)
                }
            }
            .popupGroup()
        } footer: {
            Menu("Printable copy") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.rawValue) { printable(format) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(cardCount == 0)
            Spacer()
            Button("Done") { dismiss() }
            Button("Save deck file…") { saveFile() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
                .disabled(cardCount == 0)
        }
        .task {
            cardCount = store.sharedDeck(deck.id, includeQuestions: false)?.cards.count ?? 0
            questionCount = store.sharedDeck(deck.id, includeQuestions: true)?.questions.count ?? 0
        }
    }

    private func saveFile() {
        guard let shared = store.sharedDeck(deck.id, includeQuestions: includeQuestions && questionCount > 0),
              let data = try? DeckShare.encode(shared) else { notice = "Couldn't prepare the deck."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.graspDeckFile]
        panel.nameFieldStringValue = "\(deck.name).graspdeck"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            notice = "Saved \(url.lastPathComponent)."
        } catch {
            notice = "Couldn't save the file."
        }
    }

    private func printable(_ format: ExportFormat) {
        guard let shared = store.sharedDeck(deck.id, includeQuestions: false) else { return }
        DocumentExporter.save(DeckShare.document(for: shared), as: format)
    }
}

/// Picks a deck file and adds it to the course.
enum DeckFileImporter {
    @MainActor
    static func chooseAndImport(into courseId: String, store: AppStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.graspDeckFile, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a GRASP deck file to add to this course"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try store.importSharedDeck(from: url, intoCourse: courseId)
        } catch {
            let alert = NSAlert()
            alert.messageText = AppStore.shareMessage(for: error)
            alert.runModal()
        }
    }
}
