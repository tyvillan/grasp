import Foundation

/// Resolves an overview's definition terms to the flashcards made from the
/// same note, so a student reading "Chromatid" in the overview can jump
/// straight to the card that tests it.
///
/// This runs at read time and its results are never stored. The overview's
/// staleness key is `Material.contentHash`, but a card's front is rewritten
/// by `refineWording`, replaced by `verifyContext`, and soft-deleted by a
/// `.reject` verdict -- none of which touches the note on disk. A stored
/// `cardIds` array would therefore be silently wrong within minutes of the
/// first "Refine Deck with AI", with nothing in the system able to notice.
/// Resolving on each read costs a few dozen string comparisons and is
/// always right.
public enum OverviewCardLinker {
    /// Matching is exact-after-normalisation, then a very high similarity
    /// bar, and nothing else. In particular there is **no substring
    /// fallback**: "Cell" would link to "Cell Wall" and "Cell Membrane",
    /// and a link that confidently sends a student to the wrong card is
    /// worse than no link at all.
    public static let similarityThreshold = DuplicateDetector.sameTermFrontThreshold

    /// More than this and the affordance stops being a shortcut and starts
    /// being a second card list.
    public static let maximumCardsPerTerm = 3

    /// Maps each term to the ids of cards that test it, best first.
    ///
    /// `cards` should already be scoped to the overview's own material. A
    /// term defined in lecture 4 that also appears as a card from lecture 7
    /// is a different card about a different framing, and linking across
    /// notes turns a precise affordance into a fuzzy one.
    public static func link(terms: [String], to cards: [Card]) -> [String: [String]] {
        guard !terms.isEmpty, !cards.isEmpty else { return [:] }

        let indexed = cards.map { (card: $0, normalized: AnswerGrading.normalize($0.front)) }
        var result: [String: [String]] = [:]

        for term in terms {
            let normalized = AnswerGrading.normalize(term)
            guard !normalized.isEmpty else { continue }

            var matches = indexed.filter { $0.normalized == normalized }
            if matches.isEmpty {
                matches = indexed.filter { candidate in
                    guard !candidate.normalized.isEmpty else { return false }
                    // A length ratio this far apart provably can't clear
                    // the bar, and skipping those avoids the Levenshtein
                    // cost on obvious non-matches.
                    let shorter = Double(min(candidate.normalized.count, normalized.count))
                    let longer = Double(max(candidate.normalized.count, normalized.count))
                    guard longer > 0, shorter / longer >= similarityThreshold else { return false }
                    return AnswerGrading.similarityRatio(candidate.normalized, normalized)
                        >= similarityThreshold
                }
            }
            guard !matches.isEmpty else { continue }

            let ranked = matches.sorted { first, second in
                let firstRank = rank(first.card)
                let secondRank = rank(second.card)
                if firstRank != secondRank { return firstRank < secondRank }
                return (first.card.sourceLine ?? Int.max) < (second.card.sourceLine ?? Int.max)
            }
            result[term] = ranked.prefix(maximumCardsPerTerm).map(\.card.id)
        }
        return result
    }

    /// A live, approved card is the one a student wants; a draft is still
    /// useful; a deleted one is only worth showing when nothing else matches.
    private static func rank(_ card: Card) -> Int {
        if card.deletedAt != nil { return 3 }
        switch card.status {
        case .active: return 0
        case .draft: return 1
        case .suspended: return 2
        }
    }
}
