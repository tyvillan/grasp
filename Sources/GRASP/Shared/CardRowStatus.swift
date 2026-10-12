import Foundation
import GRASPCore

/// The one muted word at the right of a card row: where the card stands.
/// "Draft" and "Suspended" for cards not in the schedule; otherwise "New"
/// for a card never reviewed, "Due today" (or "Overdue" for days late),
/// and "in 3d" / "in 2w" / "in 3mo" for what's coming. Shared so the Mac
/// list and the iPhone's say the same thing.
enum CardRowStatus {
    static func text(for card: Card, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch card.status {
        case .draft: return "Draft"
        case .suspended: return "Suspended"
        case .active: break
        }
        if card.reps == 0 && card.lastReview == nil { return "New" }
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: card.due)
        let days = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
        if days < 0 { return "Overdue" }
        if days == 0 { return "Due today" }
        if days < 14 { return "in \(days)d" }
        if days < 60 { return "in \(days / 7)w" }
        return "in \(max(2, days / 30))mo"
    }
}
