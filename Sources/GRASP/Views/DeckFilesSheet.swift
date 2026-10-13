import SwiftUI
import AppKit
import GRASPCore

/// Every source file behind a deck: which notes its cards came from, how
/// many cards each one gave, and a way to open any of them.
struct DeckFilesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deckIds: [String]
    let scopeName: String
    /// "deck" or "course", for the wording.
    let scopeNoun: String

    @State private var files: [AppStore.DeckFile] = []
    @State private var handTypedCount = 0
    @State private var query = ""
    @State private var viewingMaterialId: String?

    private var filtered: [AppStore.DeckFile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return files }
        return files.filter {
            $0.material.title.localizedCaseInsensitiveContains(trimmed)
                || $0.material.relativePath.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        GRASPSheet(eyebrow: "Source files", title: scopeName, message: summary, icon: "doc.on.doc", width: 640) {
            VStack(alignment: .leading, spacing: GRASPSpace.m) {
                if files.count > 5 {
                    FieldChrome {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.graspUI(size: 12))
                                .foregroundStyle(GRASPColor.textTertiary)
                            TextField("Filter by name or folder", text: $query)
                        }
                    }
                }
                if files.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.questionmark")
                            .font(.graspUI(size: 22))
                            .foregroundStyle(GRASPColor.textTertiary)
                        Text(handTypedCount > 0
                             ? "Every card in this \(scopeNoun) was typed by hand, so none of them came from a file."
                             : "This \(scopeNoun) has no cards yet, so no files are behind it.")
                            .graspType(.body)
                            .foregroundStyle(GRASPColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .popupGroup()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, file in
                                if index > 0 { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                                row(file)
                            }
                        }
                        .padding(.horizontal, GRASPSpace.m)
                    }
                    .frame(height: 320)
                    .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous)
                            .strokeBorder(GRASPColor.hairline, lineWidth: 1)
                    )
                    .overlay {
                        if filtered.isEmpty {
                            Text("No files match \u{201C}\(query)\u{201D}")
                                .graspType(.body)
                                .foregroundStyle(GRASPColor.textTertiary)
                        }
                    }
                }
            }
        } footer: {
            footer
        }
        .task { load() }
        .sheet(item: Binding(
            get: { viewingMaterialId.map { FileIdentifier(id: $0) } },
            set: { viewingMaterialId = $0?.id }
        )) { wrapped in
            NoteViewerView(materialId: wrapped.id)
        }
    }

    private var summary: String {
        let cardTotal = files.reduce(0) { $0 + $1.cardCount }
        var text = "\(files.count) file\(files.count == 1 ? "" : "s") · "
            + "\(cardTotal) card\(cardTotal == 1 ? "" : "s") made from them"
        if handTypedCount > 0 {
            text += " · \(handTypedCount) typed by hand"
        }
        return text
    }

    private func row(_ file: AppStore.DeckFile) -> some View {
        let exists = file.existsOnDisk
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: file.material.kind))
                .font(.graspUI(size: 15))
                .foregroundStyle(GRASPColor.accent)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.material.title)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(location(of: file))
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.url.path)
                if !exists {
                    Text("Not found on disk. Moved or deleted since it was imported")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.rejected)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(file.cardCount) card\(file.cardCount == 1 ? "" : "s")")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                if file.draftCount > 0 {
                    Text("\(file.draftCount) awaiting review")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
            }
            IconMenu(help: "File actions") {
                [
                    .action("View note text", systemImage: "doc.text.magnifyingglass") { viewingMaterialId = file.id },
                    .action("Open in default app", systemImage: "arrow.up.forward.app", disabled: !exists) {
                        NSWorkspace.shared.open(file.url)
                    },
                    .action("Show in Finder", systemImage: "folder", disabled: !exists) {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    },
                    .divider,
                    .action("Copy path", systemImage: "doc.on.clipboard") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.url.path, forType: .string)
                    },
                ]
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { viewingMaterialId = file.id }
    }

    @ViewBuilder private var footer: some View {
        Text("Double-click a file to read its text here.")
            .graspType(.meta)
            .foregroundStyle(GRASPColor.textTertiary)
        Spacer()
        Button("Done") { dismiss() }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
    }

    // MARK: - Helpers

    private func load() {
        let result = (try? store.deckFiles(inDecks: deckIds)) ?? (files: [], handTypedCardCount: 0)
        files = result.files
        handTypedCount = result.handTypedCardCount
    }

    /// The folder, relative to the vault when it's inside it -- the full
    /// iCloud path is mostly "Library/Mobile Documents/iCloud~md~obsidian".
    private func location(of file: AppStore.DeckFile) -> String {
        let folder = file.url.deletingLastPathComponent().path
        let vault = URL(fileURLWithPath: store.vaultPath).path
        if folder == vault { return "Vault" }
        if folder.hasPrefix(vault + "/") {
            return String(folder.dropFirst(vault.count + 1)).replacingOccurrences(of: "/", with: " › ")
        }
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    private func icon(for kind: MaterialKind) -> String {
        switch kind {
        case .markdown: return "doc.text"
        case .pdf: return "doc.richtext"
        case .docx: return "doc"
        case .pptx: return "rectangle.on.rectangle"
        case .ipynb: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        }
    }
}

private struct FileIdentifier: Identifiable { let id: String }
