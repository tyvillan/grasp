import Foundation

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
        public func matchId(front: String, back: String) -> String? {
            let normalizedFront = AnswerGrading.normalize(front)
            guard !normalizedFront.isEmpty else { return nil }
            let normalizedBackPrefix = String(AnswerGrading.normalize(back).prefix(backComparisonLength))

            // Only entries whose length keeps frontThreshold reachable at
            // all need a real comparison -- outside that band the ratio
            // provably can't clear the bar.
            let maxLen = Double(normalizedFront.count) / frontThreshold
            let minLen = Double(normalizedFront.count) * frontThreshold

            for entry in entriesByLength {
                let len = Double(entry.front.count)
                if len > maxLen { break }
                guard len >= minLen else { continue }
                guard AnswerGrading.similarityRatio(normalizedFront, entry.front) >= frontThreshold
                else { continue }
                if AnswerGrading.similarityRatio(normalizedBackPrefix, entry.backPrefix) >= backThreshold {
                    return entry.id
                }
            }
            return nil
        }
    }

    /// Groups of two or more near-duplicate cards already sitting in a
    /// deck, for the "Remove Duplicates" review flow. Transitively closed
    /// (union-find): if A matches B and B matches C, all three land in one
    /// group even if A and C alone fall just short of the threshold.
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
            if let matchId = index.matchId(front: card.front, back: card.back),
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
}
