import Foundation
import SwiftUI
import GRASPCore
import GRDB

/// A short-lived "Deleted 3 cards. Undo" notice.
struct UndoNotice: Identifiable {
    let id = UUID()
    let message: String
    let undo: @MainActor () -> Void
}

extension AppStore {
    /// Shows an Undo notice for a few seconds; a newer one replaces it.
    func postUndo(_ message: String, seconds: Double = 8, undo: @escaping @MainActor () -> Void) {
        let notice = UndoNotice(message: message, undo: undo)
        undoNotice = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.undoNotice?.id == notice.id { self?.undoNotice = nil }
        }
    }

    func dismissUndo() { undoNotice = nil }

    func restoreCards(_ cardIds: [String]) {
        guard !cardIds.isEmpty else { return }
        _ = try? database.queue.write { db in try CardActions.restore(cardIds, db: db) }
        reload()
    }

    @discardableResult
    func restoreDeck(_ deckId: String) -> Int {
        let count = (try? database.queue.write { db in try LibraryActions.restoreDeck(deckId, db: db) }) ?? 0
        reload()
        return count
    }

    func recentlyDeletedCards() -> [CardActions.DeletedCard] {
        (try? database.queue.read { db in try CardActions.recentlyDeleted(db: db) }) ?? []
    }

    func recentlyDeletedDecks() -> [LibraryActions.DeletedDeck] {
        (try? database.queue.read { db in try LibraryActions.recentlyDeletedDecks(db: db) }) ?? []
    }

    /// The ids of a deck's live cards, so deleting it by moving them elsewhere can be undone exactly.
    func cardIds(inDeck deckId: String) -> [String] {
        (try? database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT deckCard.cardId FROM deckCard JOIN card ON card.id = deckCard.cardId
                WHERE deckCard.deckId = ? AND card.deletedAt IS NULL ORDER BY deckCard.sortIndex
                """, arguments: [deckId])
        }) ?? []
    }
}

/// The bar at the bottom of the window while an undo is on offer.
struct UndoBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let notice = store.undoNotice {
            HStack(spacing: 14) {
                Text(notice.message)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(2)
                Button("Undo") {
                    notice.undo()
                    store.dismissUndo()
                }
                .buttonStyle(GRASPQuietButton())
                Button {
                    store.dismissUndo()
                } label: {
                    Image(systemName: "xmark").font(.graspUI(size: 10, weight: .semibold))
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(GRASPColor.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(GRASPColor.hairlineStrong))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(notice.id)
        }
    }
}

extension AppStore {
    /// The course's files, oldest note first, for choosing which to write cards from.
    func courseMaterials(inCourse courseId: String) -> [GRASPCore.Material] {
        (try? database.queue.read { db in
            try GRASPCore.Material
                .filter(Column("courseId") == courseId && Column("deletedAt") == nil)
                .order(sql: "noteDate IS NULL, noteDate, title")
                .fetchAll(db)
        }) ?? []
    }
}
