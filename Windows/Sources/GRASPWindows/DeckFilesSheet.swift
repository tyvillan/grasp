import Foundation
import GRASPCore
import SwiftCrossUI

extension Library {
    func deckFiles(inDecks deckIds: [String]) -> (files: [DeckFiles.File], handTypedCardCount: Int) {
        (try? database.queue.read { try DeckFiles.list(inDecks: deckIds, db: $0) }) ?? ([], 0)
    }

    /// Where a note lives on this PC. A note imported on the Mac carries its
    /// Mac path; if that's in iCloud, it's found under iCloud for Windows.
    func fileURL(for material: Material) -> URL? {
        let paths = vaultPaths()
        let local = paths.local(forStored: material.relativePath)
        if local != material.relativePath { return URL(fileURLWithPath: local) }
        return DeckFiles.url(for: material, vaultRoot: settings.notesFolder.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("iCloudDrive")
}

/// "Files in this deck", after the Mac's `DeckFilesSheet`: every note a
/// deck's cards came from, with how many cards each gave, and ways to read
/// it here, open it, show it in Explorer or copy its path.
struct DeckFilesSheet: View {
    let library: Library
    let scope: DeckScope
    let close: () -> Void
    @State var query = ""
    @State var reading: NoteTarget?

    var body: some View {
        // In place rather than as its own sheet: WinUI crashes when a sheet
        // opens another sheet.
        if let reading {
            NoteReader(library: library, materialId: reading.materialId, closeLabel: "Back") { self.reading = nil }
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        let result = library.deckFiles(inDecks: scope.deckIds)
        let files = filtered(result.files)
        VStack(alignment: .leading, spacing: 12) {
            Text("Files in \(scope.title)")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            Text(summary(result.files, handTyped: result.handTypedCardCount))
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
            if result.files.count > 5 {
                TextField("Filter by name or folder", text: $query)
            }
            if result.files.contains(where: { library.fileURL(for: $0.material) == nil }) {
                Text("Choose your notes folder in Settings to open these files from here.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.accent)
            }
            if result.files.isEmpty {
                Text(result.handTypedCardCount > 0
                     ? "Every card here was typed by hand, so none of them came from a file."
                     : "No cards yet, so no files are behind this deck.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                    .frame(height: 300.0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(files, id: \.id) { file in
                            FileRow(file: file, url: library.fileURL(for: file.material)) {
                                reading = NoteTarget(materialId: file.id)
                            }
                        }
                        if files.isEmpty {
                            Text("No files match \"\(query)\"").font(GRASPFont.body).foregroundColor(GRASPColor.textTertiary)
                                .padding(12)
                        }
                    }
                    .background(GRASPColor.surface)
                    .cornerRadius(8)
                }
                .frame(height: 340.0)
            }
            HStack {
                Spacer()
                Button("Done") { close() }.fixedSize()
            }
        }
        .padding(24)
        .frame(width: 640.0)
        .background(GRASPColor.canvas)
    }

    private func filtered(_ files: [DeckFiles.File]) -> [DeckFiles.File] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return files }
        return files.filter {
            $0.material.title.lowercased().contains(trimmed) || $0.material.relativePath.lowercased().contains(trimmed)
        }
    }

    private func summary(_ files: [DeckFiles.File], handTyped: Int) -> String {
        let cards = files.reduce(0) { $0 + $1.cardCount }
        var text = "\(files.count) file\(files.count == 1 ? "" : "s") · \(cards) card\(cards == 1 ? "" : "s") made from them"
        if handTyped > 0 { text += " · \(handTyped) typed by hand" }
        return text
    }
}

private struct FileRow: View {
    let file: DeckFiles.File
    let url: URL?
    let read: () -> Void

    var body: some View {
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(kindLabel)
                    .font(GRASPFont.badge)
                    .foregroundColor(GRASPColor.accent)
                    .frame(width: 38.0, alignment: .leading)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.material.title).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary).lineLimit(1)
                    Text(folder).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).lineLimit(1)
                    if url != nil && !exists {
                        Text("Not found on this PC -- moved, deleted, or not synced here")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.rejected)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(file.cardCount) card\(file.cardCount == 1 ? "" : "s")")
                        .font(GRASPFont.body)
                        .foregroundColor(GRASPColor.textSecondary)
                        .fixedSize()
                    if file.draftCount > 0 {
                        Text("\(file.draftCount) awaiting review").font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textTertiary).fixedSize()
                    }
                }
                Menu("•••") {
                    Button("View Note Text") { read() }
                    if let url, exists {
                        Button("Open in Default App") { ExternalLink.openFile(url) }
                        Button("Show in Explorer") { ExternalLink.showInExplorer(url) }
                    }
                    Button("Copy Path") { Clipboard.copy(url?.path ?? file.material.relativePath) }
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
        }
    }

    private var folder: String {
        let parts = file.material.relativePath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast()
        return parts.isEmpty ? "Notes folder" : parts.joined(separator: " › ")
    }

    private var kindLabel: String {
        switch file.material.kind {
        case .markdown: return "NOTE"
        case .pdf: return "PDF"
        case .docx: return "DOCX"
        case .pptx: return "SLIDES"
        case .ipynb: return "NB"
        case .image: return "IMAGE"
        }
    }
}
