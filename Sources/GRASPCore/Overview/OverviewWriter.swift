import Foundation
import GRDB

/// Writes one note's overview with a local model and saves it -- the Mac's
/// `AppStore.writeOverview`, moved here so the Windows app writes lessons
/// exactly the way the Mac does. The caller picks the generator
/// (`CardGenerators.select()`) and drives the per-note loop, so each lesson
/// lands in the reader as it finishes rather than all at the end of a run
/// that can take many minutes.
///
/// Fails soft at every step like every other generator-backed flow: no
/// generator, no note text, or a write error leaves the existing overview
/// (if any) exactly as it was.
public enum OverviewWriter {
    /// What happened to one note. Every case is distinguishable because the
    /// UI names what it skipped and why -- "3 notes are too long" is
    /// actionable where "3 skipped" isn't.
    public enum Outcome: Sendable, Equatable {
        case written
        /// Already current, and `force` wasn't set.
        case unchanged
        case tooShort
        case tooLong
        /// The model ran and had nothing usable to say.
        case empty
        /// No generator, no note text, or a database error.
        case unavailable
        /// Stopped before it finished. Nothing was saved.
        case cancelled
    }

    public static func write(
        materialId: String, force: Bool = false,
        using generator: any CardGenerator, database: GRASPDatabase
    ) async -> Outcome {
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
            let ollama = generator as? OllamaGenerator
            do {
                try await database.queue.write { db in
                    try NoteOverview(
                        materialId: materialId,
                        bodyJSON: OverviewCoding.encode(result.document),
                        mermaidSource: result.mermaidSource,
                        sourceContentHash: context.material.contentHash,
                        sourceWordCount: context.note.wordCount,
                        chunkCount: result.chunkCount,
                        generator: ollama != nil ? .ollama : .appleOnDevice,
                        model: ollama?.modelName
                    ).save(db)
                }
            } catch {
                return .unavailable
            }
            return .written
        }
    }
}
