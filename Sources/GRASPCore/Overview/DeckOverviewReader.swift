import Foundation
import GRDB

// A deck's overview as a reader shows it, assembled from the stored
// `NoteOverview` rows. Moved here from the Mac app's OverviewStore so the
// Mac and Windows readers can't drift apart; the behaviour is the Mac's.

/// One note's overview as the reader consumes it: the stored document plus
/// everything derived from it -- stable ids for `ForEach`, resolved
/// flashcard links, and the parsed and laid-out diagram.
///
/// None of the derived parts are persisted. Each has a different lifetime
/// than the note's content hash: cards get renamed and deleted without the
/// note changing, and `MermaidParser` improves between releases. Computing
/// them here means they are always current and never need invalidating.
public struct RenderedOverview: Identifiable, Sendable {
    public var id: String { materialId }
    public let materialId: String
    /// "LECTURE 1 · AUG 25" -- where this sits in the course, parsed from
    /// the note's filename. nil when the filename carries neither.
    public let kicker: String?
    public let title: String
    public let hook: String?
    public let objectives: [String]
    public let sections: [RenderedSection]
    public let takeaways: [String]
    public let formulas: [IdentifiedFormula]
    /// nil when the model drew nothing, or when what it drew couldn't be
    /// parsed -- `mermaidSource` is kept either way so the reader can show
    /// the source instead of an error.
    public let diagram: LaidOutDiagram?
    public let mermaidSource: String?
    /// Node ids whose label resolves to a card, so the canvas knows which
    /// boxes are worth highlighting on hover.
    public let linkedNodes: [String: [String]]
    public let isStale: Bool
    public let generatedAt: Date
    public let generator: OverviewOrigin
    public let chunkCount: Int

    public var hasContent: Bool { !sections.isEmpty }
}

/// Ids are assigned by position, which is stable because a stored document
/// never changes between rewrites. They double as scroll anchors for the
/// "On this page" list.
public struct RenderedSection: Identifiable, Sendable {
    public let id: String
    public let heading: String
    public let paragraphs: [String]
    public let terms: [LinkedDefinition]
    public let figure: RenderedFigure?
    public let example: OverviewWorkedExample?
    public let check: OverviewCheck?
    /// The note is about math, so plain-text notation is drawn as math.
    public let isMath: Bool
    /// Code from the note that this section talks about.
    public let code: NoteCode.Snippet?
}

/// A figure with its geometry already computed from the model's numbers.
public enum RenderedFigure: Sendable {
    case lines(LinesFigure)
    case transform(TransformFigure)
    case rowReduction(RowReductionFigure)

    public var caption: String? {
        switch self {
        case .lines(let lines): return lines.caption
        case .transform(let transform): return transform.caption
        case .rowReduction(let walk): return walk.caption
        }
    }
}

public struct RowReductionFigure: Sendable {
    public let caption: String?
    /// The matrix before any step, then after each -- `states.count` is
    /// always `steps.count + 1`.
    public let states: [RationalMatrix]
    public let steps: [RowOperation]
    public let stepsFromNote: Bool
}

public struct LinesFigure: Sendable {
    public let caption: String?
    /// The system before any step, then after each one -- `states.count`
    /// is always `steps.count + 1`.
    public let states: [LinearSystem2]
    public let steps: [RowOperation]
}

public struct TransformFigure: Sendable {
    public let caption: String?
    public let matrix: Matrix2
}

public struct LinkedDefinition: Identifiable, Sendable {
    public let id: String
    public let term: String
    public let text: String
    /// Cards from this same note whose front names this term. Empty is the
    /// ordinary case.
    public let cardIds: [String]
    public let example: String?
    public let nonExample: String?
    /// Two matrices, one that is this and one that isn't -- for the terms
    /// of linear algebra that describe a matrix's shape.
    public let matrixContrast: MatrixContrasts.Contrast?
}

public struct IdentifiedFormula: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Readable text -- the model's own plain form where it gave one,
    /// otherwise `LatexPlainText`'s rendering of the LaTeX.
    public let plain: String
    /// The original LaTeX, kept for copy and for a tooltip. Nothing tries
    /// to typeset it.
    public let latex: String?
    public let meaning: String?
}

/// A deck's overview: one entry per note behind it, in reading order, plus
/// what is missing and why. The stitching *is* the read -- there is no
/// per-deck stored document.
public struct DeckOverview: Sendable {
    public let entries: [RenderedOverview]
    public let missing: [MissingOverview]
    /// Cards in scope that were typed by hand, so the reader can say
    /// plainly that they aren't covered here.
    public let handTypedCardCount: Int

    public var isEmpty: Bool { entries.isEmpty }
    public var staleEntries: [RenderedOverview] { entries.filter(\.isStale) }
    /// The notes a "Write Overviews" action would actually act on.
    public var writable: [MissingOverview] { missing.filter(\.reason.isWritable) }
}

public struct MissingOverview: Identifiable, Sendable {
    public var id: String { materialId }
    public let materialId: String
    public let title: String
    public let reason: Reason

    public enum Reason: Sendable, Equatable {
        case neverWritten
        case tooShort(wordCount: Int)
        case tooLong(wordCount: Int)
        /// Stored by a version of the document shape this build can't read.
        /// Treated exactly like `neverWritten` everywhere.
        case unreadable

        public var isWritable: Bool {
            switch self {
            case .neverWritten, .unreadable: return true
            case .tooShort, .tooLong: return false
            }
        }

        public var explanation: String {
            switch self {
            case .neverWritten, .unreadable: return "No overview yet"
            case .tooShort: return "Too short to summarise"
            case .tooLong: return "Too long to summarise"
            }
        }
    }
}

/// Parsed and laid-out diagrams, keyed on the overview's `generatedAt` so a
/// rewrite invalidates its own entry with no explicit eviction. Parsing and
/// laying out is pure and fast, but readers re-read on every card change.
public final class DiagramLayoutCache: @unchecked Sendable {
    private var storage: [String: LaidOutDiagram?] = [:]
    private let lock = NSLock()

    public init() {}

    func value(for key: String, make: () -> LaidOutDiagram?) -> LaidOutDiagram? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = storage[key] { return hit }
        let made = make()
        storage[key] = made
        return made
    }
}

public enum DeckOverviewReader {
    /// Stitches a deck's notes' overviews into one document.
    ///
    /// - Parameters:
    ///   - metrics: how diagram labels measure in the reader's font.
    ///   - cache: keeps laid-out diagrams between reads; nil lays out afresh.
    public static func read(
        deckIds: [String], db: Database, metrics: DiagramMetrics = DiagramMetrics(),
        cache: DiagramLayoutCache? = nil
    ) throws -> DeckOverview {
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
                cards: cardsByMaterial[material.id] ?? [],
                note: notes[material.id], metrics: metrics, cache: cache
            ))
        }

        return DeckOverview(entries: entries, missing: missing, handTypedCardCount: handTyped)
    }

    /// Why a note with no overview doesn't have one. Asking the chunker
    /// rather than guessing keeps this answer and what generation actually
    /// does from drifting apart.
    private static func writabilityReason(
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

    private static func render(
        material: Material, stored: NoteOverview, document storedDocument: OverviewDocument, cards: [Card],
        note: NoteText?, metrics: DiagramMetrics, cache: DiagramLayoutCache?
    ) -> RenderedOverview {
        let noteText = note?.reflowed ?? ""
        // The clean-up rules run on read too, so lessons written before a
        // rule existed get it without being rewritten.
        let document = OverviewReview.cleaned(storedDocument, noteText: noteText)
        let codePlacements = NoteCode.placements(of: NoteCode.snippets(in: note?.raw ?? ""), in: document.sections)
        let links = OverviewCardLinker.link(terms: document.allTerms.map(\.term), to: cards)
        let figures = document.sections.map { $0.figure.flatMap(renderFigure) }
        // Contrasts are computed at read time, so every lesson gets them --
        // including ones written before they existed. The pool is the
        // note's own matrices plus every state of its walkthroughs, which
        // is what lets "not echelon form" be the lecture's starting matrix
        // and "echelon form" the same matrix reduced.
        let linearAlgebra = NoteMath.isLinearAlgebra(noteText)
        let isMath = NoteMath.isMathematical(noteText)
        let contrastPool: [RationalMatrix] = linearAlgebra
            ? NoteMatrices.matrices(in: noteText).map(\.matrix) + figures.flatMap { figure -> [RationalMatrix] in
                if case .rowReduction(let walk) = figure { return walk.states }
                return []
            }
            : []
        let diagram = stored.mermaidSource.flatMap {
            laidOutDiagram(for: stored, source: $0, metrics: metrics, cache: cache)
        }
        let nodeLinks = diagram.map { laid in
            OverviewCardLinker.link(
                terms: laid.nodes.map { $0.lines.joined(separator: " ") }, to: cards
            )
        } ?? [:]
        let heading = lessonHeading(for: material)

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
                            text: term.text, cardIds: links[term.term] ?? [],
                            example: term.example, nonExample: term.nonExample,
                            matrixContrast: linearAlgebra
                                ? MatrixContrasts.contrast(forTerm: term.term, noteMatrices: contrastPool)
                                : nil
                        )
                    },
                    figure: figures[index],
                    example: section.example,
                    check: section.check,
                    isMath: isMath,
                    code: codePlacements[index]
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
    public static func renderFigure(_ figure: OverviewFigure) -> RenderedFigure? {
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
        case .rowReduction:
            guard let rows = valid.matrix,
                  let start = RationalMatrix(doubles: rows, augmentedColumns: valid.augmentedColumns ?? 0)
            else { return nil }
            let walked = start.walk(valid.steps ?? [])
            return .rowReduction(RowReductionFigure(
                caption: valid.caption, states: walked.states, steps: walked.steps,
                stepsFromNote: valid.stepsFromNote ?? false
            ))
        }
    }

    /// The note's place in the course and a readable fallback title, from
    /// the filename the vault already uses -- so a lesson reads "Lecture 1
    /// · Aug 25" over a real title, not
    /// `2026-08-25_Lecture-01_First-Day-Systems-of-Linear-Equations`.
    public static func lessonHeading(for material: Material) -> (kicker: String?, title: String) {
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

    /// `isWorthDrawing` filters out the collapsed single-box graph a failed
    /// response produces -- the reader shows the raw source for those,
    /// which is more use than one rectangle in an empty frame.
    private static func laidOutDiagram(
        for stored: NoteOverview, source: String, metrics: DiagramMetrics, cache: DiagramLayoutCache?
    ) -> LaidOutDiagram? {
        func make() -> LaidOutDiagram? {
            let parsed = MermaidParser.parse(source)
            return (parsed?.isWorthDrawing == true)
                ? parsed.map { DiagramLayout.layout($0, metrics: metrics) }
                : nil
        }
        guard let cache else { return make() }
        return cache.value(for: "\(stored.materialId)#\(stored.generatedAt.timeIntervalSince1970)", make: make)
    }
}
