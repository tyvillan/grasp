import Foundation
import GRASPCore
import SwiftCrossUI

extension Library {
    /// The course a deck page belongs to.
    func courseId(of scope: DeckScope) -> String? {
        if scope.id.hasPrefix("all:") { return String(scope.id.dropFirst(4)) }
        return decks.first { $0.id == scope.id }?.courseId
    }

    /// The course a card's deck belongs to.
    func courseId(ofCard cardId: String) -> String? {
        let deckId = try? database.queue.read { try CardActions.deckId(ofCard: cardId, db: $0) }
        return decks.first { $0.id == deckId }?.courseId
    }
}

/// A card AI job in progress, or what it did once it's done.
struct CardJobStrip: View {
    let job: CardAIJob
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(job.isFinished ? (job.result ?? "Done.") : job.headline)
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                Spacer()
                if job.isFinished {
                    Button("Dismiss") { dismiss() }.fixedSize()
                } else {
                    Button("Stop") { job.stop() }.fixedSize()
                }
            }
            if !job.isFinished {
                ProgressBar(fraction: job.fraction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.accentSoft)
    }
}

/// "Fill Gaps with AI", after the Mac's `GenerateCardsSheet`: how many new
/// cards a note may get, and optionally a topic to focus on.
struct FillGapsSheet: View {
    let start: (_ perNote: Int, _ topic: String?) -> Void
    let close: () -> Void
    @State var perNote = CardAI.defaultMaxGeneratedPerNote
    @State var topic = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fill Gaps with AI")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            Text("The local model reads each note behind this deck and writes cards for concepts your cards don't cover yet. New cards arrive as drafts marked AI, for you to review.")
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Cards per note, at most")
                HStack(spacing: 10) {
                    Button("−") { perNote = max(1, perNote - 1) }.fixedSize()
                    Text("\(perNote)").font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary).frame(width: 30.0)
                    Button("+") { perNote = min(10, perNote + 1) }.fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Focus (optional)")
                TextField("e.g. the Calvin cycle", text: $topic)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { close() }.fixedSize()
                Button("Fill Gaps") {
                    let trimmed = topic.trimmingCharacters(in: .whitespaces)
                    start(perNote, trimmed.isEmpty ? nil : trimmed)
                    close()
                }
                .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 460.0)
        .background(GRASPColor.canvas)
    }
}

/// Review Duplicates, after the Mac's `DuplicateReviewSheet`: each group of
/// near-identical cards, which one to keep (GRASP's pick preselected), or
/// keep them all. Merging folds the others into the kept card, keeping its
/// study history.
struct DuplicateReviewSheet: View {
    let groups: [CardAI.DuplicateGroup]
    let merge: ([DuplicateDetector.Merge]) -> Void
    let close: () -> Void
    /// Group id -> the card kept, or nil for "keep all".
    @State var keep: [String: String?]

    init(groups: [CardAI.DuplicateGroup], merge: @escaping ([DuplicateDetector.Merge]) -> Void, close: @escaping () -> Void) {
        self.groups = groups
        self.merge = merge
        self.close = close
        _keep = State(wrappedValue: Dictionary(uniqueKeysWithValues: groups.map {
            // A confident pick unless two cards both have study history.
            ($0.id, $0.hasCompetingHistory ? nil : $0.suggestedKeepId)
        }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(groups.isEmpty ? "No Duplicates" : "Review \(groups.count) Duplicate Group\(groups.count == 1 ? "" : "s")")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            if groups.isEmpty {
                Text("No near-identical cards in this deck.").font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
            } else {
                Text("Pick the card to keep in each group. The others are folded into it, and its review history is kept.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.id) { group in
                            DuplicateGroupView(group: group, keptId: keep[group.id] ?? nil) { keep[group.id] = $0 }
                        }
                    }
                }
                .frame(height: 380.0)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(groups.isEmpty ? "Done" : "Cancel") { close() }.fixedSize()
                if !groups.isEmpty {
                    Button("Merge") {
                        merge(merges)
                        close()
                    }
                    .disabled(merges.isEmpty)
                    .fixedSize()
                }
            }
        }
        .padding(24)
        .frame(width: 560.0)
        .background(GRASPColor.canvas)
    }

    private var merges: [DuplicateDetector.Merge] {
        groups.compactMap { group in
            guard let survivor = keep[group.id] ?? nil else { return nil }
            return DuplicateDetector.Merge(survivorId: survivor, losingIds: group.cards.map(\.id).filter { $0 != survivor })
        }
    }
}

private struct DuplicateGroupView: View {
    let group: CardAI.DuplicateGroup
    let keptId: String?
    let choose: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(group.cards, id: \.id) { card in
                HStack(alignment: .top, spacing: 10) {
                    Text(keptId == card.id ? "● Keep" : "○")
                        .font(GRASPFont.meta.weight(.semibold))
                        .foregroundColor(keptId == card.id ? GRASPColor.accent : GRASPColor.textTertiary)
                        .frame(width: 48.0, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.front).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary)
                        Text(card.back).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary).lineLimit(2)
                        Text(details(card)).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                    }
                    Spacer()
                }
                .onTapGesture { choose(card.id) }
            }
            QuietLink(title: keptId == nil ? "● Keep all of them" : "Keep all of them") { choose(nil) }
            if group.hasCompetingHistory {
                Text("More than one of these has study history; only the kept card's history stays.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.accent)
            }
        }
        .padding(12)
        .background(GRASPColor.surface)
        .cornerRadius(8)
    }

    private func details(_ card: Card) -> String {
        var parts = [card.status == .active ? "Approved" : card.status == .draft ? "Pending" : "Suspended"]
        if card.reps > 0 { parts.append("reviewed \(card.reps)×") }
        if card.origin == .manual { parts.append("edited by hand") }
        return parts.joined(separator: " · ")
    }
}
