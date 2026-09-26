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

    /// Stitches a deck's notes' overviews into one document, measuring
    /// diagram labels in the reader's own font. `reload()` fires on every
    /// card mutation and the Overview tab re-reads on each one, so laid-out
    /// diagrams are kept in `diagramCache` between reads.
    func deckOverview(inDecks deckIds: [String]) throws -> DeckOverview {
        let metrics = DiagramTextMeasurer.metrics
        let cache = diagramCache
        return try database.queue.read { db in
            try DeckOverviewReader.read(deckIds: deckIds, db: db, metrics: metrics, cache: cache)
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

    /// Redraws just the diagram for a note that already has an overview --
    /// the recovery path for one that came back unparseable, in place of a
    /// hidden retry. One small call, asked for explicitly.
    @discardableResult
    func redrawDiagram(forMaterial materialId: String) async -> Bool {
        let generator = await CardGenerators.select()
        guard await generator.isAvailable else { return false }

        let context: (stored: NoteOverview, title: String, courseName: String)?
        do {
            context = try await database.queue.read { db in
                guard let stored = try NoteOverview.fetchOne(db, key: materialId),
                      let material = try Material.fetchOne(db, key: materialId)
                else { return nil }
                let course = try Course.fetchOne(db, key: material.courseId)
                return (stored, material.title, course?.name ?? "this course")
            }
        } catch {
            return false
        }
        guard let context, let document = context.stored.document() else { return false }

        let source = await generator.generateDiagram(
            noteTitle: context.title, courseName: context.courseName,
            conceptOutline: OverviewComposer.diagramSpine(of: document)
        )
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            try await database.queue.write { db in
                var updated = context.stored
                updated.mermaidSource = trimmed
                // Moves the cache key, so the redrawn diagram is the one
                // that gets laid out on the next read.
                updated.generatedAt = Date()
                try updated.save(db)
            }
        } catch {
            return false
        }
        reload()
        return true
    }

    func deleteOverview(forMaterial materialId: String) throws {
        try database.queue.write { db in
            _ = try NoteOverview.deleteOne(db, key: materialId)
        }
        reload()
    }
}

