import Foundation
import GRASPCore
import SwiftCrossUI

/// One search box over everything: cards (front or back) and the full text
/// of every imported note, as the Mac's `SearchView` searches notes. A card
/// opens its deck; a note opens to read in full.
struct SearchScreen: View {
    let library: Library
    let onOpenDeck: (_ courseId: String, _ deckId: String?) -> Void
    @State var query = ""
    @State var reading: NoteTarget?

    var body: some View {
        let cards = library.searchCards(query)
        let notes = library.searchNotes(query)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search").font(GRASPFont.display).foregroundColor(GRASPColor.textPrimary)
                TextField("Search your cards and notes", text: $query)
                    .frame(maxWidth: 560.0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Type a word or two. Cards match on either side; notes match on words that start with what you type.")
                            .font(GRASPFont.body)
                            .foregroundColor(GRASPColor.textSecondary)
                    } else if cards.isEmpty && notes.isEmpty {
                        Text("No matches.").font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                    }
                    if !cards.isEmpty {
                        ResultSection(title: cards.count == 40 ? "Cards (first 40)" : "Cards (\(cards.count))") {
                            ForEach(cards, id: \.id) { match in
                                CardHit(match: match, where_: place(courseId: match.courseId, deckId: match.deckId)) {
                                    onOpenDeck(match.courseId, match.deckId)
                                }
                            }
                        }
                    }
                    if !notes.isEmpty {
                        ResultSection(title: notes.count == 40 ? "Notes (first 40)" : "Notes (\(notes.count))") {
                            ForEach(notes, id: \.id) { match in
                                NoteHit(match: match, where_: library.courseName(match.courseId) ?? "") {
                                    reading = NoteTarget(materialId: match.materialId)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 720.0)
                .padding(28)
            }
        }
        .sheet(isPresented: Binding(get: { reading != nil }, set: { if !$0 { reading = nil } })) {
            if let reading {
                NoteReader(library: library, materialId: reading.materialId) { self.reading = nil }
            }
        }
    }

    private func place(courseId: String, deckId: String) -> String {
        let deck = library.decks.first { $0.id == deckId }?.name
        return [library.courseName(courseId), deck].compactMap { $0 }.joined(separator: " · ")
    }
}

struct NoteTarget: Equatable {
    let materialId: String
}

private struct ResultSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(GRASPColor.surface)
            .cornerRadius(10)
        }
    }
}

private struct CardHit: View {
    let match: CardActions.CardMatch
    let where_: String
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(match.card.front).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary)
                    Text(match.card.back).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary).lineLimit(2)
                    Text(where_).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                }
                Spacer()
                if match.card.status == .draft {
                    Chip(text: "Pending", tint: GRASPColor.accent, soft: GRASPColor.accentSoft)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
        }
        .onTapGesture(perform: open)
    }
}

private struct NoteHit: View {
    let match: CardActions.NoteMatch
    let where_: String
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(match.title).font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary)
                // FTS marks each hit with \u{2}...\u{3}; plain Text can't
                // bold part of a line, so the hits are set off with quotes.
                Text(match.snippet.replacingOccurrences(of: "\u{2}", with: "“").replacingOccurrences(of: "\u{3}", with: "”"))
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textSecondary)
                    .lineLimit(2)
                Text(where_).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
        }
        .onTapGesture(perform: open)
    }
}

/// A note in full, as imported, like the Mac's `NoteViewerView`.
struct NoteReader: View {
    let library: Library
    let materialId: String
    let close: () -> Void

    var body: some View {
        let note = library.note(materialId)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(note?.title ?? "Note")
                    .font(Font.system(size: 18, weight: .semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                Spacer()
                Button("Close") { close() }.fixedSize()
            }
            ScrollView {
                Text(note?.text ?? "This note's text isn't in the library.")
                    .font(LessonFont.prose)
                    .foregroundColor(GRASPColor.textPrimary)
                    .frame(maxWidth: 640.0)
            }
            .frame(height: 480.0)
        }
        .padding(24)
        .frame(width: 700.0)
        .background(GRASPColor.canvas)
    }
}
