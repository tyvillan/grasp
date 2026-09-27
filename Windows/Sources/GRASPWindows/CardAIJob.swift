import Foundation
import GRASPCore
import Observation

/// One AI action on a deck's cards running in the background -- refine the
/// drafts, fill gaps, check one card -- with the progress its strip shows,
/// Stop, and a sentence saying what it did. Owned by `Library`, one per
/// course, so it survives switching decks.
@Observable
final class CardAIJob {
    private(set) var headline: String
    private(set) var fraction = 0.0
    private(set) var isFinished = false
    private(set) var result: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(headline: String) {
        self.headline = headline
    }

    func stop() { task?.cancel() }

    /// Runs `work` with the local model and the job's progress reporter;
    /// `work` returns the sentence to show when it's done.
    func run(library: Library, _ work: @escaping (any CardGenerator, GRASPDatabase) async -> String) {
        task = Task { [weak self] in
            guard let self else { return }
            let generator = await CardGenerators.select()
            guard await generator.isAvailable else {
                result = "Ollama isn't running, so nothing was changed. Settings shows its status."
                isFinished = true
                return
            }
            let progress = AIProgress { [weak self] snapshot in
                Task { @MainActor in
                    self?.fraction = snapshot.fraction
                    if let step = snapshot.step { self?.headline = step }
                }
            }
            let message = await AIProgress.$current.withValue(progress) {
                await work(generator, library.database)
            }
            library.overviewsChanged()
            result = Task.isCancelled ? "Stopped. " + message : message
            isFinished = true
        }
    }
}

extension Library {
    /// "Refine Drafts with AI": check each draft against its note, then
    /// reword what's left.
    func refineDeckWithAI(inDecks deckIds: [String], courseId: String?) {
        startCardJob("Checking drafts against your notes…", courseId: courseId) { generator, database in
            let summary = await CardAI.refineDeck(inDecks: deckIds, using: generator, database: database)
            if summary.isEmpty {
                return "Every draft checked out fine -- nothing read like assignment text, and nothing needed rewording."
            }
            var parts: [String] = []
            if !summary.context.refined.isEmpty {
                parts.append("rewrote \(summary.context.refined.count) from the notes (each can be reverted from the card)")
            }
            if !summary.context.removed.isEmpty {
                parts.append("removed \(summary.context.removed.count) that weren't real definitions")
            }
            if summary.wordingRefinedCount > 0 {
                parts.append("reworded \(summary.wordingRefinedCount)")
            }
            return "Done: " + parts.joined(separator: ", ") + "."
        }
    }

    /// "Fill Gaps with AI": new drafts for what the cards miss.
    func fillGapsWithAI(inDecks deckIds: [String], courseId: String?, perNote: Int, topic: String?) {
        startCardJob("Reading your notes for missing concepts…", courseId: courseId) { generator, database in
            let added = await CardAI.generateAdditionalCards(inDecks: deckIds, maxPerNote: perNote, topic: topic,
                                                             using: generator, database: database)
            return added == 0
                ? "No gaps found -- the notes' concepts are already covered by cards."
                : "Added \(added) new card\(added == 1 ? "" : "s"), marked AI and waiting in Pending for your review."
        }
    }

    /// "Refine with AI" on one card.
    func refineCardWithAI(_ cardId: String, courseId: String?) {
        startCardJob("Checking this card against its note…", courseId: courseId) { generator, database in
            switch await CardAI.refineCard(cardId, using: generator, database: database) {
            case .refined: return "The card was refined. Revert AI Rewrite on the card undoes a rewrite from the notes."
            case .removed: return "The card was removed: its note doesn't support it as a real definition."
            case .unavailable: return "Nothing to change -- the card already reads well against its note."
            }
        }
    }

    /// Settings' one-time sweep of every card against its note.
    func sweepAllCardsWithAI() {
        startCardJob("Checking every card against its note…", courseId: nil) { generator, database in
            let summary = await CardAI.sweepAllCards(using: generator, database: database)
            return summary.isEmpty
                ? "Every card checked out against its note."
                : "Rewrote \(summary.refined.count) and removed \(summary.removed.count). Rewrites can be reverted from each card."
        }
    }

    func duplicateGroups(inDecks deckIds: [String]) -> [CardAI.DuplicateGroup] {
        CardAI.duplicateGroups(cards(inDecks: deckIds))
    }

    func mergeDuplicates(_ merges: [DuplicateDetector.Merge]) {
        guard !merges.isEmpty else { return }
        try? database.queue.write { try DuplicateDetector.applyMerges(merges, db: $0) }
        overviewsChanged()
    }
}
