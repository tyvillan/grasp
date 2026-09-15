import Foundation
import GRDB

/// Near-duplicate detection over card text, reusing `AnswerGrading`'s
/// Levenshtein similarity rather than inventing a second metric. Two cards
/// count as near-duplicates only when **both** their fronts and their
/// backs are similar -- the conjunction is what stops two cards that
/// merely share a similar answer (or a similar term with a genuinely
/// different definition) from colliding. Verified against real data: the
/// same lecture covered by both a lecture note and a separate Canvas-module
/// summary produces exactly this shape of duplicate in the live vault.
public enum DuplicateDetector {
    /// Fronts are usually a single term or short phrase, so a near-exact
    /// match is required. Backs are full sentences with more room for
    /// paraphrase between two notes covering the same material, so the
    /// bar is lower -- but not by much. Verified against the real vault,
    /// not guessed: at 0.75 this caught a genuine false positive ("AMH
    /// 2020 / Paper 1" due Feb 17 vs "AMH 2020 / Paper 2" due Mar 31, two
    /// different assignments whose shared boilerplate phrasing dominates
    /// the ratio over the one substituted date) at exactly 0.75 back
    /// similarity. 0.80 excludes that pair while a full-vault scan showed
    /// it doesn't lose any of the 44 genuine duplicate groups already
    /// found (52 of 54 total extra cards, down from 54).
    public static let frontThreshold = 0.90
    public static let backThreshold = 0.80

    /// A much stricter front-only bar that, on its own -- no back
    /// comparison at all -- is still enough to flag a likely duplicate for
    /// *review*. Verified against Tyler's real "Intro to Software Design"
    /// course, which independently covers the same ~15 core vocabulary
    /// terms (Abstraction, Class, Object, Getter, Setter, Inheritance,
    /// Polymorphism, ...) in both its own lecture notes and a separate
    /// exam-prep slide deck: 21 real duplicate pairs there share an
    /// exactly-matching front but a back-similarity as low as 0.20 --
    /// nowhere near `backThreshold`, because two independently-written
    /// definitions of the same term routinely diverge in wording far more
    /// than two paraphrases of the same sentence do. `frontThreshold`
    /// alone already tolerates minor noise (a typo, a stray character); at
    /// `sameTermFrontThreshold` there's essentially no daylight between
    /// the two fronts, and by itself that's strong evidence for the *same
    /// course's* flashcard deck, where seeing "Abstraction" twice is
    /// itself the signal, however differently each one explains it.
    ///
    /// Only ever pass `allowSameTermFallback: true` for a flow a human
    /// reviews before anything is removed (`groups`, and therefore the
    /// Review Duplicates sheet) -- never for import-time suppression or
    /// AI-generation dedup, where a false positive would silently discard
    /// a genuinely new card no one ever gets to see, let alone approve.
    public static let sameTermFrontThreshold = 0.95

    /// Backs compared only on their first 240 normalized characters.
    /// Levenshtein is O(n*m); two real definitions of the same term
    /// diverge late, not early, so a prefix is a good-enough proxy at a
    /// fraction of the cost, and it's what keeps this fast enough to run
    /// on every import rather than only in an offline batch job.
    private static let backComparisonLength = 240

    private struct Entry {
        let id: String
        let front: String
        let backPrefix: String
    }

    /// An incremental duplicate index, seeded from a deck's existing cards
    /// and grown one card at a time as new ones are created -- so two
    /// duplicate bullets inside the *same* note also collapse, not just
    /// duplicates across different notes feeding the same deck.
    ///
    /// Entries are kept sorted by normalized front length. `similarityRatio`
    /// is bounded by the length ratio of its two inputs (a distance-based
    /// ratio can never exceed `1 - |lenA - lenB| / max(lenA, lenB)`), so a
    /// front can only reach `frontThreshold` against another front within
    /// roughly 10% of its own length -- `matchId` uses that bound to skip
    /// the vast majority of entries instead of comparing against all of
    /// them, which is what keeps this near-linear instead of O(n^2).
    public struct Index: Sendable {
        private var entriesByLength: [Entry] = []

        public init(_ cards: [Card]) {
            for card in cards {
                insert(id: card.id, front: card.front, back: card.back)
            }
        }

        public mutating func insert(id: String, front: String, back: String) {
            let entry = Entry(
                id: id,
                front: AnswerGrading.normalize(front),
                backPrefix: String(AnswerGrading.normalize(back).prefix(backComparisonLength))
            )
            let insertAt = entriesByLength.firstIndex { $0.front.count >= entry.front.count }
                ?? entriesByLength.count
            entriesByLength.insert(entry, at: insertAt)
        }

        /// The id of an existing near-duplicate of `(front, back)`, if any.
        /// See `sameTermFrontThreshold`'s doc comment for what
        /// `allowSameTermFallback` does and why it must stay `false`
        /// everywhere except a human-reviewed flow.
        public func matchId(front: String, back: String, allowSameTermFallback: Bool = false) -> String? {
            let normalizedFront = AnswerGrading.normalize(front)
            guard !normalizedFront.isEmpty else { return nil }
            let normalizedBackPrefix = String(AnswerGrading.normalize(back).prefix(backComparisonLength))

            // Only entries whose length keeps frontThreshold reachable at
            // all need a real comparison -- outside that band the ratio
            // provably can't clear the bar. `sameTermFrontThreshold` is
            // stricter than `frontThreshold`, so this band (computed off
            // the looser bound) still safely covers it.
            let maxLen = Double(normalizedFront.count) / frontThreshold
            let minLen = Double(normalizedFront.count) * frontThreshold

            for entry in entriesByLength {
                let len = Double(entry.front.count)
                if len > maxLen { break }
                guard len >= minLen else { continue }
                let frontSimilarity = AnswerGrading.similarityRatio(normalizedFront, entry.front)
                guard frontSimilarity >= frontThreshold else { continue }
                if AnswerGrading.similarityRatio(normalizedBackPrefix, entry.backPrefix) >= backThreshold {
                    return entry.id
                }
                if allowSameTermFallback, frontSimilarity >= sameTermFrontThreshold {
                    return entry.id
                }
            }
            return nil
        }
    }

    /// Groups of two or more near-duplicate cards already sitting in a
    /// deck, for the "Remove Duplicates" review flow -- a human always
    /// confirms before anything is removed, so this uses the more lenient
    /// `allowSameTermFallback` matching (see `sameTermFrontThreshold`)
    /// that import-time suppression and AI-generation dedup deliberately
    /// don't. Transitively closed (union-find): if A matches B and B
    /// matches C, all three land in one group even if A and C alone fall
    /// just short of the threshold.
    public static func groups(_ cards: [Card]) -> [[Card]] {
        guard cards.count > 1 else { return [] }
        var parent = Array(0..<cards.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[ra] = rb }
        }

        var index = Index([])
        // Build incrementally so `matchId` finds prior cards by original
        // index, then union each match into the running groups.
        var idToPosition: [String: Int] = [:]
        for (position, card) in cards.enumerated() {
            idToPosition[card.id] = position
            if let matchId = index.matchId(front: card.front, back: card.back, allowSameTermFallback: true),
               let matchPosition = idToPosition[matchId] {
                union(position, matchPosition)
            }
            index.insert(id: card.id, front: card.front, back: card.back)
        }

        var byRoot: [Int: [Card]] = [:]
        for (position, card) in cards.enumerated() {
            byRoot[find(position), default: []].append(card)
        }
        return byRoot.values.filter { $0.count > 1 }
    }

    /// One "keep this card, fold these into it" instruction, applied by
    /// `applyMerges`.
    public struct Merge: Sendable {
        public let survivorId: String
        public let losingIds: [String]
        public init(survivorId: String, losingIds: [String]) {
            self.survivorId = survivorId
            self.losingIds = losingIds
        }
    }

    /// Folds duplicate cards into their group's survivor instead of just
    /// deleting the losers outright: every `Review` row (the append-only
    /// study-history log) is re-pointed onto the survivor so past study
    /// effort isn't silently discarded, and at most one `LearnState` row
    /// survives per merge -- if the survivor already has one, the losers'
    /// are dropped rather than guessing how to combine ladder progress; if
    /// not, the first loser's carries over.
    ///
    /// A loser's `DeckCard` membership is always dropped, never moved onto
    /// the survivor, even when the loser was in a deck the survivor
    /// wasn't -- nothing else in the app expects one card to live in two
    /// decks of the same course (an earlier version of this function did
    /// move it, and a card that ended up in two decks at once crashed
    /// `AppStore.cards(inDecks:)`, which assumes a card appears at most
    /// once per deck scope it's asked about). The tradeoff is real: if a
    /// loser was the only card tying its content to a particular deck,
    /// that placement is gone after the merge, even though the surviving
    /// card (and its content) isn't -- it's still reachable via "All
    /// Cards" and search. That's the correct read of "these are
    /// duplicates, keep one," not a bug: picking a survivor also picks
    /// which deck placement wins.
    ///
    /// The survivor's own FSRS schedule (due, stability, difficulty) is
    /// left exactly as it was. Merging two independently-scheduled cards
    /// into one correct blended schedule isn't well-defined, so this
    /// preserves history for the record without pretending to recompute a
    /// schedule from it. The losers themselves are then soft-deleted,
    /// same semantics as a plain bulk delete elsewhere in the app.
    ///
    /// Must run inside an existing write transaction -- this performs no
    /// transaction management of its own, so a caller applying several
    /// merges (as `AppStore.mergeDuplicates` does for a whole review
    /// session) gets one atomic write, not one per group.
    public static func applyMerges(_ merges: [Merge], db: Database, now: Date = Date()) throws {
        for merge in merges {
            let losers = merge.losingIds.filter { $0 != merge.survivorId }
            guard !losers.isEmpty, try Card.fetchOne(db, key: merge.survivorId) != nil else { continue }

            try Review
                .filter(losers.contains(Column("cardId")))
                .updateAll(db, Column("cardId").set(to: merge.survivorId))

            try DeckCard.filter(losers.contains(Column("cardId"))).deleteAll(db)

            let loserLearnStates = try LearnState.filter(losers.contains(Column("cardId"))).fetchAll(db)
            try LearnState.filter(losers.contains(Column("cardId"))).deleteAll(db)
            if try LearnState.fetchOne(db, key: merge.survivorId) == nil, let toKeep = loserLearnStates.first {
                try LearnState(
                    cardId: merge.survivorId, level: toKeep.level,
                    consecutiveCorrect: toKeep.consecutiveCorrect, lastSeenAt: toKeep.lastSeenAt
                ).save(db)
            }

            try Card
                .filter(losers.contains(Column("id")))
                .updateAll(db, Column("deletedAt").set(to: now), Column("updatedAt").set(to: now))
        }
    }
}
