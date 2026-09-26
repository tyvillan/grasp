import Foundation
import GRDB
import GRASPCore

// The reader's types (RenderedOverview, DeckOverview, ...) and the render
// path live in GRASPCore's DeckOverviewReader, shared with Windows.

extension AppStore {
    /// What happened to one note. Every case is distinguishable because the
    /// UI names what it skipped and why -- "3 notes are too long" is
    /// actionable where "3 skipped" isn't.
    enum OverviewOutcome: Sendable, Equatable {
        case written
        /// Already current, and `force` wasn't set.
        case unchanged
        case tooShort
        case tooLong
        /// The model ran and had nothing usable to say.
        case empty
        /// No generator, no note text, or a database error.
        case unavailable
        /// Stopped by the student before it finished. Nothing was saved.
        case cancelled
    }

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

    /// Writes one note's overview.
    ///
    /// Deliberately per-note rather than per-deck: the view drives the loop
    /// itself so each note's section lands in the reader as it finishes,
    /// instead of the whole deck appearing at the end of a run that can
    /// take minutes. A single deck-wide call would force a spinner with
    /// nothing behind it.
    ///
    /// Fails soft at every step like every other generator-backed flow
    /// here: no generator, no note text, or a write error leaves the
    /// existing overview (if any) exactly as it was.
    @discardableResult
    func writeOverview(forMaterial materialId: String, force: Bool = false) async -> OverviewOutcome {
        let generator = await CardGenerators.select()
        guard await generator.isAvailable else { return .unavailable }

        let context: (material: Material, note: NoteText, courseName: String, existing: NoteOverview?)?
        do {
            context = try await database.queue.read { db in
                guard let material = try Material.fetchOne(db, key: materialId),
                      material.deletedAt == nil,
                      let note = try NoteText.fetchOne(db, key: materialId)
                else { return nil }
                let course = try Course.fetchOne(db, key: material.courseId)
                let existing = try NoteOverview.fetchOne(db, key: materialId)
                return (material, note, course?.name ?? "this course", existing)
            }
        } catch {
            return .unavailable
        }
        guard let context else { return .unavailable }

        if !force, let existing = context.existing, !existing.isStale(for: context.material) {
            return .unchanged
        }

        let outcome = await OverviewComposer.compose(
            using: generator,
            noteTitle: context.material.title,
            courseName: context.courseName,
            note: context.note
        )

        // A stop cancels the requests in flight, so whatever `compose`
        // returns after one is built from whichever calls happened to
        // finish first -- a half-written lesson. Never save that over a
        // complete one.
        if Task.isCancelled { return .cancelled }

        switch outcome {
        case .tooShort: return .tooShort
        case .tooLong: return .tooLong
        case .empty: return .empty
        case .generated(let result):
            let origin: OverviewOrigin = generator is OllamaGenerator ? .ollama : .appleOnDevice
            do {
                try await database.queue.write { db in
                    try NoteOverview(
                        materialId: materialId,
                        bodyJSON: OverviewCoding.encode(result.document),
                        mermaidSource: result.mermaidSource,
                        sourceContentHash: context.material.contentHash,
                        sourceWordCount: context.note.wordCount,
                        chunkCount: result.chunkCount,
                        generator: origin,
                        model: (generator as? OllamaGenerator)?.modelName
                    ).save(db)
                }
            } catch {
                return .unavailable
            }
            reload()
            return .written
        }
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

