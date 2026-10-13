import Foundation
import GRASPCore

/// Every number a deck page shows about its cards -- the filter pills, the
/// drafts strip, the live generation strip, the "Approve all" count -- read
/// from one place so they cannot disagree.
///
/// While the AI is writing, cards land in batches and their rows slide in
/// one at a time. `held` is the batch still sliding in: it is left out of
/// every figure until the whole batch is on screen, so the strip, the
/// pills and the deck list all move together and never run ahead of the
/// rows.
struct DeckCardCounts: Equatable {
    /// Every card in the deck's list, suspended ones included: what the
    /// "All" filter shows.
    var all = 0
    var drafts = 0
    var active = 0
    var suspended = 0
    var due = 0
    var understood = 0

    /// What the deck list's row for this deck says: suspended cards are not
    /// counted there.
    var inDeckList: Int { all - suspended }

    static func make(
        cards: [Card], levels: [String: LearnEngine.Level], held: Set<String> = [], now: Date = Date()
    ) -> DeckCardCounts {
        var counts = DeckCardCounts()
        for card in cards where !held.contains(card.id) {
            counts.all += 1
            switch card.status {
            case .draft:
                counts.drafts += 1
            case .suspended:
                counts.suspended += 1
            case .active:
                counts.active += 1
                if card.due <= now { counts.due += 1 }
                if levels[card.id] == .mastered { counts.understood += 1 }
            }
        }
        return counts
    }

    /// Cards the current generation run has written that are already
    /// counted: the strip's "N new".
    static func newCount(recent: [String], held: Set<String>) -> Int {
        recent.filter { !held.contains($0) }.count
    }
}
