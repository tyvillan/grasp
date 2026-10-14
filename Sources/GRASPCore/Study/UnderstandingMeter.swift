import Foundation
import GRDB

/// What the understanding meter shows for one card: three pips (recognition,
/// recall, mastered) that follow the Learn ladder. Pure data, so the Mac,
/// the iPhone and the Windows port all read a card the same way.
///
/// Shape carries the meaning and colour only reinforces it: a solid pip is
/// reached and shown, a dotted pip is claimed ("I know this" in Study) but
/// not yet shown, an outline is not reached.
public struct UnderstandingState: Equatable, Sendable {
    public enum Pip: Equatable, Sendable { case empty, solid, dotted }

    /// Recognition, recall, mastered, in that order.
    public var pips: [Pip]
    /// The card has been answered or rated at least once. A card nobody has
    /// asked about reads "New".
    public var asked: Bool
    public var level: LearnEngine.Level

    public var isMastered: Bool { level == .mastered }
    public var isSelfRated: Bool { level == .familiar }
    public var solidCount: Int { pips.filter { $0 == .solid }.count }

    /// A short word for the card itself: "New", "Recognition", "Recall",
    /// "Understood", "Self-rated", or "Not yet" for a card asked and missed.
    public var word: String {
        switch level {
        case .new: return asked ? "Not yet" : "New"
        case .recognition: return "Recognition"
        case .recall: return "Recall"
        case .mastered: return "Understood"
        case .familiar: return "Self-rated"
        }
    }

    /// The spoken label, for VoiceOver: "Recall, 2 of 3 steps".
    public var accessibilityLabel: String {
        switch level {
        case .new: return asked ? "Not yet recognized, 0 of 3 steps" : "New"
        case .recognition: return "Recognition, 1 of 3 steps"
        case .recall: return "Recall, 2 of 3 steps"
        case .mastered: return "Understood, 3 of 3 steps"
        case .familiar: return "Self-rated, not yet tested"
        }
    }

    /// Any pip filled or dotted: the card has Learn progress, so a row
    /// has no need to say "New".
    public var hasProgress: Bool { pips.contains { $0 != .empty } }

    /// Where the card stands after one more answer, by the existing
    /// ladder rules (`LearnEngine.advance`), nothing new.
    public func afterAnswer(correct: Bool) -> UnderstandingState {
        let next = LearnEngine.advance(level: level, consecutiveCorrect: 0, wasCorrect: correct).level
        return .of(level: next, asked: true)
    }

    /// One line for a change of level: "Recall to understood", "Back to
    /// recognition". nil when the level did not change.
    public static func changeCaption(from: UnderstandingState, to: UnderstandingState) -> String? {
        guard from.level != to.level else { return nil }
        func rank(_ level: LearnEngine.Level) -> Double {
            switch level {
            case .new: return 0
            case .recognition: return 1
            case .recall: return 2
            case .familiar: return 2.5
            case .mastered: return 3
            }
        }
        if rank(to.level) < rank(from.level) {
            return to.level == .new ? "Back to the start" : "Back to \(to.word.lowercased())"
        }
        return "\(from.word) to \(to.word.lowercased())"
    }

    /// `level` nil means the card has no learn row at all.
    public static func of(level: LearnEngine.Level?, asked: Bool? = nil) -> UnderstandingState {
        let level = level ?? .new
        let hasBeenAsked = asked ?? (level != .new)
        let pips: [Pip]
        switch level {
        case .new: pips = [.empty, .empty, .empty]
        case .recognition: pips = [.solid, .empty, .empty]
        case .recall: pips = [.solid, .solid, .empty]
        case .mastered: pips = [.solid, .solid, .solid]
        // Self-rated: recognition and recall claimed, mastered still to be
        // shown. One right answer in Learn completes it.
        case .familiar: pips = [.dotted, .dotted, .empty]
        }
        return UnderstandingState(pips: pips, asked: hasBeenAsked, level: level)
    }
}

/// One deck's cards grouped by how well they are understood, and its
/// weakest source notes.
public enum DeckUnderstanding {
    public struct Card: Equatable, Sendable {
        public var id: String
        public var materialId: String?
        public var state: UnderstandingState
        public init(id: String, materialId: String?, state: UnderstandingState) {
            self.id = id; self.materialId = materialId; self.state = state
        }
    }

    /// Counts for the stacked bar. `notAsked` holds every card with no
    /// pip reached and nothing claimed, whether or not it was ever shown.
    public struct Distribution: Equatable, Sendable {
        public var notAsked = 0
        public var recognition = 0
        public var recall = 0
        public var solid = 0
        public var selfRated = 0
        public init() {}
        public var total: Int { notAsked + recognition + recall + solid + selfRated }
        public var solidShare: Double { total == 0 ? 0 : Double(solid) / Double(total) }

        /// "14 understood, 9 recall, 6 recognition, 3 self-rated, 22 not asked",
        /// leaving out any part that is zero.
        public var line: String {
            guard total > 0 else { return "No cards yet" }
            let parts: [(Int, String)] = [(solid, "understood"), (recall, "recall"), (recognition, "recognition"),
                                          (selfRated, "self-rated"), (notAsked, "not asked")]
            return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        }

        mutating func add(_ state: UnderstandingState) {
            switch state.level {
            case .new: notAsked += 1
            case .recognition: recognition += 1
            case .recall: recall += 1
            case .mastered: solid += 1
            case .familiar: selfRated += 1
            }
        }
    }

    public static func distribution(of cards: [Card]) -> Distribution {
        var result = Distribution()
        for card in cards { result.add(card.state) }
        return result
    }

    /// One source note's cards. `materialId` nil is the "Other" group.
    public struct NoteGroup: Equatable, Sendable, Identifiable {
        public var materialId: String?
        public var distribution: Distribution
        public var cardIds: [String]
        public var id: String { materialId ?? "other" }
        public var solid: Int { distribution.solid }
        public var total: Int { distribution.total }
        /// "3 of 14 understood".
        public var summary: String { "\(solid) of \(total) understood" }
    }

    /// The deck's notes, weakest first: lowest share of solid cards, then
    /// the note with more cards. A note whose cards are all solid is not
    /// weak and is left out. Cards without a source note form one "Other"
    /// group, ranked like any other.
    public static func weakestNotes(of cards: [Card], limit: Int = 5) -> [NoteGroup] {
        var order: [String?] = []
        var byNote: [String?: NoteGroup] = [:]
        for card in cards {
            if byNote[card.materialId] == nil {
                order.append(card.materialId)
                byNote[card.materialId] = NoteGroup(materialId: card.materialId, distribution: Distribution(), cardIds: [])
            }
            byNote[card.materialId]!.distribution.add(card.state)
            byNote[card.materialId]!.cardIds.append(card.id)
        }
        let groups = order.compactMap { byNote[$0] }.filter { $0.solid < $0.total }
        let ranked = groups.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.distribution.solidShare != y.distribution.solidShare { return x.distribution.solidShare < y.distribution.solidShare }
            if x.total != y.total { return x.total > y.total }
            return a.offset < b.offset
        }
        return ranked.prefix(limit).map(\.element)
    }

    /// Cards for "Practice weakest": not mastered, weakest first (asked and
    /// missed, then never asked, then recognition, recall, self-rated), the
    /// weakest note's cards first within a rank, at most `limit`.
    public static func practiceCards(of cards: [Card], limit: Int = 8) -> [String] {
        func rank(_ state: UnderstandingState) -> Int {
            switch state.level {
            case .new: return state.asked ? 0 : 1
            case .recognition: return 2
            case .recall: return 3
            case .familiar: return 4
            case .mastered: return 5
            }
        }
        let noteOrder = weakestNotes(of: cards, limit: Int.max).enumerated()
            .reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        let open = cards.enumerated().filter { !$0.element.state.isMastered }
        let sorted = open.sorted { a, b in
            let (x, y) = (a.element, b.element)
            if rank(x.state) != rank(y.state) { return rank(x.state) < rank(y.state) }
            let nx = noteOrder[x.materialId ?? "other"] ?? Int.max, ny = noteOrder[y.materialId ?? "other"] ?? Int.max
            if nx != ny { return nx < ny }
            return a.offset < b.offset
        }
        return sorted.prefix(limit).map(\.element.id)
    }
}

extension Study {
    /// Each active card's meter state for these decks, with the note it
    /// came from. A card with no learn row is "New".
    public static func understanding(forDecks deckIds: [String], db: Database) throws -> [DeckUnderstanding.Card] {
        let rows = try learnCandidates(forDecks: deckIds, db: db)
        let ids = rows.map(\.candidate.cardId)
        guard !ids.isEmpty else { return [] }
        let materials = try Card.filter(ids.contains(Column("id"))).fetchAll(db)
        let materialById = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0.materialId) })
        return rows.map { row in
            let state = UnderstandingState.of(level: row.candidate.level, asked: row.lastSeenAt != nil)
            return DeckUnderstanding.Card(id: row.candidate.cardId, materialId: materialById[row.candidate.cardId] ?? nil,
                                          state: state)
        }
    }

    /// The meter state of every card in these decks, by card id.
    public static func understandingStates(forDecks deckIds: [String], db: Database) throws -> [String: UnderstandingState] {
        Dictionary(uniqueKeysWithValues: try understanding(forDecks: deckIds, db: db).map { ($0.id, $0.state) })
    }
}

/// A note's title as a person would say it.
public enum NoteTitle {
    /// The note's first heading when it has one, else the file name made
    /// readable.
    public static func readable(raw: String?, fileName: String) -> String {
        if let raw, let heading = firstHeading(in: raw) { return heading }
        return humanized(fileName)
    }

    static func firstHeading(in raw: String) -> String? {
        var lines = raw.components(separatedBy: "\n")
        // Skip a frontmatter block.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            while let line = lines.first {
                lines.removeFirst()
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            }
        }
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, trimmed.hasPrefix("#") else { continue }
            let text = trimmed.drop(while: { $0 == "#" })
            guard text.first == " " else { continue }
            let cleaned = text.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            // "2026-08-25 · Module 1" reads better as "Module 1".
            let undated = cleaned.replacingOccurrences(
                of: #"^\d{4}-\d{2}-\d{2}\s*[·:\-\u2013\u2014|]?\s*"#, with: "", options: .regularExpression)
            if !undated.isEmpty { return undated }
        }
        return nil
    }

    /// `2026-09-08_Module-03_C++-Basics-and-Functions.md` to
    /// `Module 03 C++ Basics and Functions`.
    static func humanized(_ fileName: String) -> String {
        var name = fileName
        if let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= 6 {
            name = String(name[..<dot])
        }
        name = name.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}[_\- ]*"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^\d{2}_"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        name = name.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return name.isEmpty ? fileName : name
    }
}

extension Study {
    /// Readable titles for notes, by material id.
    public static func noteTitles(forMaterials ids: [String], db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for id in ids {
            guard let material = try Material.fetchOne(db, key: id) else { continue }
            let raw = try NoteText.fetchOne(db, key: id)?.raw
            result[id] = NoteTitle.readable(raw: raw, fileName: material.title)
        }
        return result
    }
}
