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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
            if files.isEmpty {
                ContentUnavailableView {
                    Label("No source files", systemImage: "doc.questionmark")
                } description: {
                    Text(handTypedCount > 0
                         ? "Every card in this \(scopeNoun) was typed by hand, so none of them came from a file."
                         : "This \(scopeNoun) has no cards yet, so no files are behind it.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { file in
                        row(file)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if filtered.isEmpty {
                        Text("No files match \"\(query)\"")
                            .graspType(.body)
                            .foregroundStyle(GRASPColor.textTertiary)
                    }
                }
            }
            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 620, height: 520)
        .background(GRASPColor.canvas)
        .task { load() }
        .sheet(item: Binding(
            get: { viewingMaterialId.map { FileIdentifier(id: $0) } },
            set: { viewingMaterialId = $0?.id }
        )) { wrapped in
            NoteViewerView(materialId: wrapped.id)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Files in \(scopeName)")
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(GRASPColor.textPrimary)
                    Text(summary)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                Spacer()
            }
            if files.count > 5 {
                TextField("Filter by name or folder", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
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
                .font(.system(size: 15))
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
                    Text("Not found on disk -- moved or deleted since it was imported")
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
            Menu {
                Button("View Note Text") { viewingMaterialId = file.id }
                Button("Open in Default App") { NSWorkspace.shared.open(file.url) }
                    .disabled(!exists)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    .disabled(!exists)
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.url.path, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { viewingMaterialId = file.id }
    }

    private var footer: some View {
        HStack {
            Text("Double-click a file to read its text here.")
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
        }
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
