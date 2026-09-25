import Foundation
import GRASPCore
import SwiftCrossUI

/// Flashcards: front, then back, then a grade -- the same four FSRS grades
/// as the Mac app, written through GRASPCore's `Study`.
struct StudySessionView: View {
    let library: Library
    let cards: [Card]
    let finish: () -> Void
    @State var index = 0
    @State var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if index < cards.count {
                let card = cards[index]
                Text("Card \(index + 1) of \(cards.count)").font(.caption).foregroundColor(.gray)
                VStack(alignment: .leading, spacing: 12) {
                    Text(MathNotation.prettify(card.front)).font(.title3)
                    if revealed {
                        Divider()
                        Text(MathNotation.prettify(card.back))
                    }
                }
                .padding(18)
                .frame(maxWidth: 640)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(10)

                if revealed {
                    HStack(spacing: 8) {
                        gradeButton("Again", .again, card)
                        gradeButton("Hard", .hard, card)
                        gradeButton("Good", .good, card)
                        gradeButton("Easy", .easy, card)
                    }
                } else {
                    Button("Show answer") { revealed = true }
                }
                Button("End session") { finish() }
            } else {
                Text("Done: \(cards.count) card(s) reviewed.").font(.title3)
                Button("Back to deck") { finish() }
            }
        }
    }

    private func gradeButton(_ title: String, _ grade: FSRS.Grade, _ card: Card) -> some View {
        Button(title) {
            library.grade(card, grade)
            revealed = false
            index += 1
        }
        // A row of buttons otherwise shrinks some of them to "…".
        .fixedSize()
    }
}
