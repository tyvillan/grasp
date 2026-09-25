import Foundation

/// The persisted body of a `NoteOverview`: a short lesson built from one
/// lecture note, holding only what a model actually said.
///
/// Shaped like a lesson rather than a summary, after two earlier shapes
/// taught the same thing the hard way. A takeaways-and-outline document
/// read back as a reformatted copy of the student's notes; an
/// explanations-and-glossary document explained better but still read as a
/// stack of labelled boxes. What works for teaching -- and what the
/// reference page this is modelled on does -- is headed sections whose
/// headings are *claims* ("Row operations never move the answer"), with the
/// key term, a figure and a self-check placed right where the idea is
/// introduced instead of gathered into lists at the bottom.
///
/// No card links, laid-out figures or display ids live here. Figures are
/// stored as the model's *specification* -- which equations, which row
/// operations, which matrix -- and every line, intersection and
/// intermediate matrix is computed from that at read time by
/// `OverviewFigures`. Storing derived geometry would freeze any arithmetic
/// mistake into the row; recomputing it means a figure is only ever as
/// wrong as the numbers the note itself contained.
public struct OverviewDocument: Codable, Sendable, Equatable {
    /// A claim-style title for the lesson. nil falls back to the note's own
    /// topic, parsed from its filename.
    public var title: String?
    /// The opening: a concrete question or puzzle that makes the lecture
    /// worth reading. nil when the model had nothing better than a summary.
    public var hook: String?
    /// "By the end you should be able to..." -- things the reader can do.
    public var objectives: [String]
    public var sections: [OverviewSection]
    public var takeaways: [String]
    public var formulas: [OverviewFormula]

    public init(title: String? = nil, hook: String? = nil, objectives: [String] = [],
                sections: [OverviewSection] = [], takeaways: [String] = [],
                formulas: [OverviewFormula] = []) {
        self.title = title
        self.hook = hook
        self.objectives = objectives
        self.sections = sections
        self.takeaways = takeaways
        self.formulas = formulas
    }

    public static let empty = OverviewDocument()

    /// A lesson with no sections teaches nothing, whatever else it managed
    /// to produce around the edges.
    public var isEmpty: Bool { sections.isEmpty }

    /// Every key term in reading order -- for card linking, and for the
    /// diagram pass's summary of what the lesson covers.
    public var allTerms: [OverviewDefinition] { sections.flatMap(\.terms) }
}

/// One idea, taught.
public struct OverviewSection: Codable, Sendable, Equatable {
    /// A claim, not a topic: "Swapping two equations can't change the
    /// answer", not "Interchange". The heading *is* the takeaway, so a
    /// reader skimming only the headings still learns something.
    public var heading: String
    /// Short paragraphs, each a few sentences. Several short ones rather
    /// than one long one -- that's most of the difference between prose
    /// that reads as a lesson and prose that reads as a wall.
    public var paragraphs: [String]
    /// Key terms introduced in this section, shown right beside it.
    public var terms: [OverviewDefinition]
    public var figure: OverviewFigure?
    /// A procedure the note works through, shown as numbered steps instead
    /// of narrated in a paragraph. Optional (and absent from bodies written
    /// before it existed), so older lessons still decode.
    public var example: OverviewWorkedExample?
    public var check: OverviewCheck?

    public init(heading: String, paragraphs: [String], terms: [OverviewDefinition] = [],
                figure: OverviewFigure? = nil, example: OverviewWorkedExample? = nil,
                check: OverviewCheck? = nil) {
        self.heading = heading
        self.paragraphs = paragraphs
        self.terms = terms
        self.figure = figure
        self.example = example
        self.check = check
    }
}

/// A worked example, step by step: what was done, what it produced, and
/// why. The general answer to a paragraph like "performing R3 -> R3 + R1
/// turns that bottom -1 into a zero, creating a staircase..." -- a process
/// described in prose is unreadable, the same process as numbered steps
/// with the state after each one is not. Any course: a proof's moves, a
/// refactoring's stages, an algorithm's passes, a pathway's reactions.
public struct OverviewWorkedExample: Codable, Sendable, Equatable {
    /// What's being worked, e.g. "Exercise 12: solving a 3-equation system".
    public var title: String?
    /// The starting point, stated concretely.
    public var setup: String?
    public var steps: [OverviewExampleStep]
    /// What the example shows, once it's done.
    public var outcome: String?

    public init(title: String? = nil, setup: String? = nil, steps: [OverviewExampleStep], outcome: String? = nil) {
        self.title = title
        self.setup = setup
        self.steps = steps
        self.outcome = outcome
    }
}

public struct OverviewExampleStep: Codable, Sendable, Equatable {
    /// The move itself: "Add row 1 to row 3".
    public var action: String
    /// What it produced -- the new state, written out.
    public var result: String?
    /// Why this move, now.
    public var why: String?
    /// Two to four words naming the step, for the example's step map.
    public var label: String?
    /// A small picture of this step, when one helps.
    public var visual: OverviewStepVisual?

    public init(action: String, result: String? = nil, why: String? = nil,
                label: String? = nil, visual: OverviewStepVisual? = nil) {
        self.action = action
        self.result = result
        self.why = why
        self.label = label
        self.visual = visual
    }
}

/// A picture for one step of a worked example, as the model specified it.
/// Flat with optional fields for the same reason `OverviewFigure` is: it's
/// what a small model writes most reliably, and what decodes most
/// forgivingly. `StepVisuals.validate` decides whether it's drawable.
public struct OverviewStepVisual: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        /// A grid of numbers or symbols -- a matrix, or a small table.
        case matrix
        /// Arrows on a plane, optionally added tip to tail.
        case vectors
        /// Boxes joined by arrows: a process, with the current stage lit.
        case flow
    }

    public var kind: Kind
    public var caption: String?
    /// `.matrix`: entries as written ("a11", "3", "-1/2", "x1").
    public var rows: [[String]]?
    /// `.matrix`: columns right of an augmentation bar.
    public var bar: Int?
    /// `.matrix`: 0-based rows and columns to highlight.
    public var highlightRows: [Int]?
    public var highlightColumns: [Int]?
    /// `.vectors`: 2D vectors from the origin.
    public var vectors: [VisualVector]?
    /// `.vectors`: also draw the weighted sum, tip to tail.
    public var combine: Bool?
    /// `.flow`: the stages, in order.
    public var nodes: [String]?
    /// `.flow`: the stage this step is at, 0-based.
    public var highlight: Int?

    public init(kind: Kind, caption: String? = nil, rows: [[String]]? = nil, bar: Int? = nil,
                highlightRows: [Int]? = nil, highlightColumns: [Int]? = nil,
                vectors: [VisualVector]? = nil, combine: Bool? = nil,
                nodes: [String]? = nil, highlight: Int? = nil) {
        self.kind = kind
        self.caption = caption
        self.rows = rows
        self.bar = bar
        self.highlightRows = highlightRows
        self.highlightColumns = highlightColumns
        self.vectors = vectors
        self.combine = combine
        self.nodes = nodes
        self.highlight = highlight
    }
}

public struct VisualVector: Codable, Sendable, Equatable {
    public var label: String?
    public var x: Double
    public var y: Double
    /// The scalar in front of it in a linear combination; 1 when absent.
    public var weight: Double?

    public init(label: String? = nil, x: Double, y: Double, weight: Double? = nil) {
        self.label = label
        self.x = x
        self.y = y
        self.weight = weight
    }
}

/// A "pause and check" question, placed right after the idea it tests.
public struct OverviewCheck: Codable, Sendable, Equatable {
    public var question: String
    /// Revealed on request. A model-written question with no answer leaves
    /// a student unsure whether they got it, which defeats the point.
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

public struct OverviewDefinition: Codable, Sendable, Equatable {
    public var term: String
    public var text: String
    /// A concrete case that *is* this, from the notes.
    public var example: String?
    /// A near miss that *isn't*, and what disqualifies it. A definition is
    /// learned at its boundary: "echelon form" means little until you've
    /// seen the matrix that almost is and why it fails.
    public var nonExample: String?

    public init(term: String, text: String, example: String? = nil, nonExample: String? = nil) {
        self.term = term
        self.text = text
        self.example = example
        self.nonExample = nonExample
    }
}

public struct OverviewFormula: Codable, Sendable, Equatable {
    public var name: String
    /// nil when the note writes the formula in plain text only. Nothing
    /// here tries to synthesise LaTeX from plain text.
    public var latex: String?
    public var plain: String
    /// What the symbols stand for. nil when the note doesn't say.
    public var meaning: String?

    public init(name: String, latex: String? = nil, plain: String, meaning: String? = nil) {
        self.name = name
        self.latex = latex
        self.plain = plain
        self.meaning = meaning
    }
}

// MARK: - Figures

/// A figure as the model specified it: which kind, and the numbers to draw.
///
/// Deliberately a flat struct with optional fields rather than an enum
/// with associated values -- it is the one part of the document a model
/// writes as nested JSON, and a flat shape with a `kind` string is both
/// what a 7B produces most reliably and what decodes most forgivingly. An
/// unrecognised kind, or a kind with its numbers missing, is simply not
/// drawn (see `OverviewFigures.validate`).
public struct OverviewFigure: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        /// Two equations in x and y, drawn as lines, optionally stepped
        /// through row operations.
        case systemOfLines
        /// A 2x2 matrix, drawn as the plane it deforms.
        case linearTransform
        /// A matrix of any size row-reduced one operation at a time, with
        /// the changed row, the pivots and the free variables shown.
        case rowReduction
    }

    public var kind: Kind
    public var caption: String?
    /// For `.systemOfLines`: each row is `[a, b, c]`, meaning a·x + b·y = c.
    public var equations: [[Double]]?
    /// For `.systemOfLines`: the row operations to step through, in order.
    public var steps: [RowOperation]?
    /// For `.linearTransform`: rows of a 2x2 matrix. For `.rowReduction`:
    /// the starting matrix, any size.
    public var matrix: [[Double]]?
    /// For `.rowReduction`: columns right of the augmentation bar.
    public var augmentedColumns: Int?
    /// For `.rowReduction`: the steps are the note's own rather than
    /// computed, so the figure can say whose they are.
    public var stepsFromNote: Bool?

    public init(kind: Kind, caption: String? = nil, equations: [[Double]]? = nil,
                steps: [RowOperation]? = nil, matrix: [[Double]]? = nil,
                augmentedColumns: Int? = nil, stepsFromNote: Bool? = nil) {
        self.kind = kind
        self.caption = caption
        self.equations = equations
        self.steps = steps
        self.matrix = matrix
        self.augmentedColumns = augmentedColumns
        self.stepsFromNote = stepsFromNote
    }
}

/// One elementary row operation, on 1-based row numbers.
public struct RowOperation: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        /// R_target -> R_target + multiplier * R_source
        case replace
        /// R_target <-> R_source
        case swap
        /// R_target -> multiplier * R_target
        case scale
    }

    public var kind: Kind
    public var target: Int
    /// Unused by `.scale`.
    public var source: Int?
    /// The k in R_target + k * R_source, or the scale factor. Unused by
    /// `.swap`.
    public var multiplier: Double?
    /// The same k as an exact fraction `[numerator, denominator]`, when it
    /// has one. A `Double` can't hold 1/3 exactly, and row reduction on a
    /// larger matrix produces fractions whose decimal form can't be turned
    /// back into the fraction it came from.
    public var exactMultiplier: [Int]?

    public init(kind: Kind, target: Int, source: Int? = nil, multiplier: Double? = nil) {
        self.kind = kind
        self.target = target
        self.source = source
        self.multiplier = multiplier
    }

    public init(kind: Kind, target: Int, source: Int? = nil, exact: Rational) {
        self.init(kind: kind, target: target, source: source, multiplier: exact.doubleValue)
        self.exactMultiplier = [exact.numerator, exact.denominator]
    }

    /// k exactly: the stored fraction, else the simple fraction nearest the
    /// stored decimal.
    public var rationalMultiplier: Rational? {
        if let pair = exactMultiplier, pair.count == 2, let exact = Rational(pair[0], pair[1]) { return exact }
        return multiplier.flatMap { Rational(approximating: $0) }
    }
}

/// Section caps, applied both when reading one model response and when
/// merging several. One unusually chatty response must not flood the
/// reader, and a merged long note must not concatenate to five screens.
public enum OverviewLimits {
    public static let objectives = 5
    public static let sections = 8
    public static let paragraphsPerSection = 4
    public static let termsPerSection = 4
    public static let takeaways = 6
    public static let formulas = 12
    /// A lesson with a figure in every section is a slideshow. Two
    /// well-chosen ones carry the visual weight of the whole page.
    public static let figures = 3
    public static let exampleSteps = 6
}

public enum OverviewCoding {
    /// `.sortedKeys` so the same document always encodes to byte-identical
    /// JSON: it makes the round-trip test an equality check on the string,
    /// and means a rewrite that changed nothing doesn't churn the row.
    public static func encode(_ document: OverviewDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(document),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    /// nil rather than a throw: a body this build can't read is treated
    /// exactly like one that was never written.
    public static func decode(_ json: String) -> OverviewDocument? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OverviewDocument.self, from: data)
    }
}
