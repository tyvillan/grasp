import Foundation
import GRDB
import GRASPCore

/// One note's overview as the reader consumes it: the stored document plus
/// everything derived from it -- stable ids for `ForEach`, resolved
/// flashcard links, and the parsed and laid-out diagram.
///
/// None of the derived parts are persisted. Each has a different lifetime
/// than the note's content hash: cards get renamed and deleted without the
/// note changing, and `MermaidParser` improves between releases. Computing
/// them here means they are always current and never need invalidating.
struct RenderedOverview: Identifiable, Sendable {
    var id: String { materialId }
    let materialId: String
    /// "LECTURE 1 · AUG 25" -- where this sits in the course, parsed from
    /// the note's filename. nil when the filename carries neither.
    let kicker: String?
    let title: String
    let hook: String?
    let objectives: [String]
    let sections: [RenderedSection]
    let takeaways: [String]
    let formulas: [IdentifiedFormula]
    /// nil when the model drew nothing, or when what it drew couldn't be
    /// parsed -- `mermaidSource` is kept either way so the reader can show
    /// the source instead of an error.
    let diagram: LaidOutDiagram?
    let mermaidSource: String?
    /// Node ids whose label resolves to a card, so the canvas knows which
    /// boxes are worth highlighting on hover.
    let linkedNodes: [String: [String]]
    let isStale: Bool
    let generatedAt: Date
    let generator: OverviewOrigin
    let chunkCount: Int

    var hasContent: Bool { !sections.isEmpty }
}

/// Ids are assigned by position, which is stable because a stored document
/// never changes between rewrites. They double as scroll anchors for the
/// "On this page" list.
struct RenderedSection: Identifiable, Sendable {
    let id: String
    let heading: String
    let paragraphs: [String]
    let terms: [LinkedDefinition]
    let figure: RenderedFigure?
    let check: OverviewCheck?
}

/// A figure with its geometry already computed from the model's numbers.
enum RenderedFigure: Sendable {
    case lines(LinesFigure)
    case transform(TransformFigure)
}

struct LinesFigure: Sendable {
    let caption: String?
    /// The system before any step, then after each one -- `states.count`
    /// is always `steps.count + 1`.
    let states: [LinearSystem2]
    let steps: [RowOperation]
}

struct TransformFigure: Sendable {
    let caption: String?
    let matrix: Matrix2
}

struct LinkedDefinition: Identifiable, Sendable {
    let id: String
    let term: String
    let text: String
    /// Cards from this same note whose front names this term. Empty is the
    /// ordinary case.
    let cardIds: [String]
}

struct IdentifiedFormula: Identifiable, Sendable {
    let id: String
    let name: String
    /// Readable text -- the model's own plain form where it gave one,
    /// otherwise `LatexPlainText`'s rendering of the LaTeX.
    let plain: String
    /// The original LaTeX, kept for copy and for a tooltip. Nothing tries
    /// to typeset it.
    let latex: String?
    let meaning: String?
}

/// A deck's overview: one entry per note behind it, in reading order, plus
/// what is missing and why. The stitching *is* the read -- there is no
/// per-deck stored document.
struct DeckOverview: Sendable {
    let entries: [RenderedOverview]
    let missing: [MissingOverview]
    /// Cards in scope that were typed by hand, so the reader can say
    /// plainly that they aren't covered here.
    let handTypedCardCount: Int

    var isEmpty: Bool { entries.isEmpty }
    var staleEntries: [RenderedOverview] { entries.filter(\.isStale) }
    /// The notes a "Write Overviews" action would actually act on.
    var writable: [MissingOverview] { missing.filter(\.reason.isWritable) }
}

struct MissingOverview: Identifiable, Sendable {
    var id: String { materialId }
    let materialId: String
    let title: String
    let reason: Reason

    enum Reason: Sendable, Equatable {
        case neverWritten
        case tooShort(wordCount: Int)
        case tooLong(wordCount: Int)
        /// Stored by a version of the document shape this build can't read.
        /// Treated exactly like `neverWritten` everywhere.
        case unreadable

        var isWritable: Bool {
            switch self {
            case .neverWritten, .unreadable: return true
            case .tooShort, .tooLong: return false
            }
        }

        var explanation: String {
            switch self {
            case .neverWritten, .unreadable: return "No overview yet"
            case .tooShort: return "Too short to summarise"
            case .tooLong: return "Too long to summarise"
            }
        }
    }
}

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

    /// Stitches a deck's notes' overviews into one document.
    func deckOverview(inDecks deckIds: [String]) throws -> DeckOverview {
        let (materials, overviews, notes, cardsByMaterial, handTyped) = try database.queue.read { db in
            let materials = try OverviewQueries.materials(forDecks: deckIds, db: db)
            let ids = materials.map(\.id)
            let overviews = try NoteOverview
                .filter(ids.contains(Column("materialId")))
                .fetchAll(db)
                .reduce(into: [String: NoteOverview]()) { $0[$1.materialId] = $1 }
            let notes = try NoteText
                .filter(ids.contains(Column("materialId")))
                .fetchAll(db)
                .reduce(into: [String: NoteText]()) { $0[$1.materialId] = $1 }
            var cardsByMaterial: [String: [Card]] = [:]
            for id in ids {
                cardsByMaterial[id] = try OverviewQueries.cards(forMaterial: id, db: db)
            }
            let cardIds = try DeckCard
                .filter(deckIds.contains(Column("deckId")))
                .fetchAll(db)
                .map(\.cardId)
            let handTyped = cardIds.isEmpty ? 0 : try Card
                .filter(cardIds.contains(Column("id")))
                .filter(Column("deletedAt") == nil)
                .filter(Column("materialId") == nil)
                .fetchCount(db)
            return (materials, overviews, notes, cardsByMaterial, handTyped)
        }

        var entries: [RenderedOverview] = []
        var missing: [MissingOverview] = []

        for material in materials {
            guard let stored = overviews[material.id] else {
                missing.append(MissingOverview(
                    materialId: material.id, title: material.title,
                    reason: writabilityReason(for: material.id, notes: notes)
                ))
                continue
            }
            guard let document = stored.document() else {
                missing.append(MissingOverview(
                    materialId: material.id, title: material.title, reason: .unreadable
                ))
                continue
            }
            entries.append(render(
                material: material, stored: stored, document: document,
                cards: cardsByMaterial[material.id] ?? []
            ))
        }

        return DeckOverview(entries: entries, missing: missing, handTypedCardCount: handTyped)
    }

    /// Why a note with no overview doesn't have one. Asking the chunker
    /// rather than guessing keeps this answer and what generation actually
    /// does from drifting apart.
    private func writabilityReason(
        for materialId: String, notes: [String: NoteText]
    ) -> MissingOverview.Reason {
        guard let note = notes[materialId] else { return .neverWritten }
        if note.wordCount < OverviewChunker.minimumWords {
            return .tooShort(wordCount: note.wordCount)
        }
        if note.wordCount > OverviewChunker.maximumWords {
            return .tooLong(wordCount: note.wordCount)
        }
        return .neverWritten
    }

    private func render(
        material: Material, stored: NoteOverview, document: OverviewDocument, cards: [Card]
    ) -> RenderedOverview {
        let links = OverviewCardLinker.link(terms: document.allTerms.map(\.term), to: cards)
        let diagram = stored.mermaidSource.flatMap { laidOutDiagram(for: stored, source: $0) }
        let nodeLinks = diagram.map { laid in
            OverviewCardLinker.link(
                terms: laid.nodes.map { $0.lines.joined(separator: " ") }, to: cards
            )
        } ?? [:]
        let heading = Self.lessonHeading(for: material)

        return RenderedOverview(
            materialId: material.id,
            kicker: heading.kicker,
            title: document.title ?? heading.title,
            hook: document.hook,
            objectives: document.objectives,
            sections: document.sections.enumerated().map { index, section in
                RenderedSection(
                    id: "\(material.id)#s\(index)",
                    heading: section.heading,
                    paragraphs: section.paragraphs,
                    terms: section.terms.enumerated().map { termIndex, term in
                        LinkedDefinition(
                            id: "\(material.id)#s\(index)t\(termIndex)", term: term.term,
                            text: term.text, cardIds: links[term.term] ?? []
                        )
                    },
                    figure: section.figure.flatMap(Self.renderFigure),
                    check: section.check
                )
            },
            takeaways: document.takeaways,
            formulas: document.formulas.enumerated().map { index, formula in
                IdentifiedFormula(
                    id: "\(material.id)#f\(index)", name: formula.name,
                    plain: formula.plain, latex: formula.latex, meaning: formula.meaning
                )
            },
            diagram: diagram,
            mermaidSource: stored.mermaidSource,
            linkedNodes: nodeLinks,
            isStale: stored.isStale(for: material),
            generatedAt: stored.generatedAt,
            generator: stored.generator,
            chunkCount: stored.chunkCount
        )
    }

    /// Recomputed from the stored numbers on every read, so the drawn lines
    /// and matrices are always this build's arithmetic rather than a
    /// snapshot of whatever an older build (or the model) believed.
    private static func renderFigure(_ figure: OverviewFigure) -> RenderedFigure? {
        guard let valid = OverviewFigures.validate(figure) else { return nil }
        switch valid.kind {
        case .systemOfLines:
            guard let rows = valid.equations, let system = LinearSystem2(rows: rows) else { return nil }
            let steps = valid.steps ?? []
            return .lines(LinesFigure(
                caption: valid.caption,
                states: LinearSystem2.states(from: system, steps: steps),
                steps: steps
            ))
        case .linearTransform:
            guard let rows = valid.matrix, let matrix = Matrix2(rows: rows) else { return nil }
            return .transform(TransformFigure(caption: valid.caption, matrix: matrix))
        }
    }

    /// The note's place in the course and a readable fallback title, from
    /// the filename the vault already uses -- so a lesson reads "Lecture 1
    /// · Aug 25" over a real title, not
    /// `2026-08-25_Lecture-01_First-Day-Systems-of-Linear-Equations`.
    static func lessonHeading(for material: Material) -> (kicker: String?, title: String) {
        let parsed = FilenameParsing.parse(fileNameWithoutExtension: material.title)
        var parts: [String] = []
        if let unit = parsed.unitLabel { parts.append(unit) }
        if let date = material.noteDate ?? parsed.dateFromFilename {
            parts.append(date.formatted(.dateTime.month(.abbreviated).day()))
        }
        let topic = parsed.topic?
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let title = (topic?.isEmpty == false ? topic : nil) ?? material.title
        return (parts.isEmpty ? nil : parts.joined(separator: " · ").uppercased(), title)
    }

    /// Parsing and laying out a diagram is pure and fast, but `reload()`
    /// fires on every card mutation and the Overview tab re-reads on each
    /// one. Keyed on `generatedAt` so a rewrite invalidates its own entry
    /// with no explicit eviction.
    private func laidOutDiagram(for stored: NoteOverview, source: String) -> LaidOutDiagram? {
        let key = "\(stored.materialId)#\(stored.generatedAt.timeIntervalSince1970)"
        if let cached = diagramCache[key] { return cached.value }
        // `isWorthDrawing` filters out the collapsed single-box graph a
        // failed response produces -- the reader shows the raw source for
        // those, which is more use than one rectangle in an empty frame.
        let parsed = MermaidParser.parse(source)
        let laidOut = (parsed?.isWorthDrawing == true)
            ? parsed.map { DiagramLayout.layout($0, metrics: DiagramTextMeasurer.metrics) }
            : nil
        diagramCache[key] = DiagramCacheEntry(value: laidOut)
        return laidOut
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

/// Boxed so the cache can hold a successful parse that produced no diagram
/// distinctly from a note that hasn't been parsed yet.
struct DiagramCacheEntry {
    let value: LaidOutDiagram?
}
