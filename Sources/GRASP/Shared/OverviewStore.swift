import Foundation
import GRDB
import GRASPCore

// The reader's types (RenderedOverview, DeckOverview, ...) and the render
// path live in GRASPCore's DeckOverviewReader, shared with Windows.

extension AppStore {
    /// What happened to one note -- the core's `OverviewWriter.Outcome`.
    typealias OverviewOutcome = OverviewWriter.Outcome

    // MARK: - Reading

    /// The materials behind a scope, in reading order.
    func overviewMaterials(inDecks deckIds: [String]) throws -> [Material] {
        try database.queue.read { db in
            try OverviewQueries.materials(forDecks: deckIds, db: db)
        }
    }

    /// Stitches a deck's notes' overviews into one document.
    func deckOverview(inDecks deckIds: [String]) throws -> DeckOverview {
        try database.queue.read { db in
            try DeckOverviewReader.read(deckIds: deckIds, db: db)
        }
    }

    // MARK: - Writing

    /// Writes one note's overview with the selected generator. The work is
    /// GRASPCore's `OverviewWriter`, shared with Windows; the view drives the
    /// per-note loop so each section lands in the reader as it finishes.
    @discardableResult
    func writeOverview(forMaterial materialId: String, force: Bool = false) async -> OverviewOutcome {
        let outcome = await OverviewWriter.write(
            materialId: materialId, force: force,
            using: await CardGenerators.select(), database: database
        )
        if outcome == .written { reload() }
        return outcome
    }


    func deleteOverview(forMaterial materialId: String) throws {
        try database.queue.write { db in
            _ = try NoteOverview.deleteOne(db, key: materialId)
        }
        reload()
    }
}

