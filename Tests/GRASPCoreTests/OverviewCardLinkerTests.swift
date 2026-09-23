import Testing
import Foundation
@testable import GRASPCore

/// The failure that matters here is a false positive, not a false negative.
/// A term that doesn't link just shows no chip; a term that links to the
/// wrong card silently sends a student to material about something else.
/// Most of what's asserted below is the parts this deliberately refuses to
/// match.
@Suite("Overview card linker")
struct OverviewCardLinkerTests {

    private func card(
        _ front: String, status: CardStatus = .active, deleted: Bool = false, line: Int? = nil
    ) -> Card {
        Card(
            materialId: "m1", front: front, back: "definition", sourceLine: line,
            origin: .parser, status: status, deletedAt: deleted ? Date() : nil
        )
    }

    @Test("links a term to a card whose front matches exactly")
    func exactMatch() {
        let cards = [card("Chromatid"), card("Centromere")]
        let links = OverviewCardLinker.link(terms: ["Chromatid"], to: cards)
        #expect(links["Chromatid"]?.count == 1)
        #expect(links["Chromatid"]?.first == cards[0].id)
    }

    @Test("forgives case, articles and punctuation")
    func normalisedMatch() {
        let cards = [card("The Cell Membrane")]
        let links = OverviewCardLinker.link(terms: ["cell membrane"], to: cards)
        #expect(links["cell membrane"]?.first == cards[0].id)
    }

    @Test("does not link a term to a card that merely contains it")
    func noSubstringMatching() {
        // "Cell" linking to "Cell Wall" and "Cell Membrane" would be
        // confidently wrong, which is worse than showing no link at all.
        let cards = [card("Cell Wall"), card("Cell Membrane")]
        let links = OverviewCardLinker.link(terms: ["Cell"], to: cards)
        #expect(links["Cell"] == nil)
    }

    @Test("links a long front with a one-character difference")
    func similarityCatchesLongNearMatches() {
        // At the 0.95 bar the fuzzy tier only fires on longer terms, which
        // are exactly the ones a transcription difference shows up in.
        let cards = [card("Deoxyribonucleic acid synthesis")]
        let links = OverviewCardLinker.link(terms: ["Deoxyribonucleic acid synthesus"], to: cards)
        #expect(links.values.first?.first == cards[0].id)
    }

    @Test("refuses a short near-match, and anything merely related")
    func similarityIsDeliberatelyStrict() {
        // "Chromatidd" is one character off "Chromatid" but only 0.91
        // similar over nine characters. Linking it would mean linking
        // "Chromatid"/"Chromosome" territory too, so the bar stays where a
        // wrong link can't happen.
        #expect(OverviewCardLinker.link(terms: ["Chromatid"], to: [card("Chromatidd")]).isEmpty)
        #expect(OverviewCardLinker.link(terms: ["Chromatid"], to: [card("Chromosome")]).isEmpty)
    }

    @Test("caps how many cards one term can pull in")
    func cap() {
        let cards = (0..<6).map { _ in card("Mitosis") }
        let links = OverviewCardLinker.link(terms: ["Mitosis"], to: cards)
        #expect(links["Mitosis"]?.count == OverviewCardLinker.maximumCardsPerTerm)
    }

    @Test("ranks an approved card above a draft, and a deleted one last")
    func ranking() {
        let deleted = card("Mitosis", deleted: true)
        let draft = card("Mitosis", status: .draft)
        let active = card("Mitosis", status: .active)
        let links = OverviewCardLinker.link(terms: ["Mitosis"], to: [deleted, draft, active])
        let ids = try! #require(links["Mitosis"])
        #expect(ids.first == active.id)
        #expect(ids.last == deleted.id)
    }

    @Test("breaks a tie by where the card came from in the note")
    func tieBreakBySourceLine() {
        let later = card("Mitosis", line: 90)
        let earlier = card("Mitosis", line: 10)
        let links = OverviewCardLinker.link(terms: ["Mitosis"], to: [later, earlier])
        #expect(links["Mitosis"]?.first == earlier.id)
    }

    @Test("handles empty inputs without crashing")
    func emptyInputs() {
        #expect(OverviewCardLinker.link(terms: [], to: [card("A")]).isEmpty)
        #expect(OverviewCardLinker.link(terms: ["A"], to: []).isEmpty)
        #expect(OverviewCardLinker.link(terms: ["   "], to: [card("A")]).isEmpty)
    }

    @Test("links several terms in one pass")
    func multipleTerms() {
        let cards = [card("Prophase"), card("Metaphase"), card("Anaphase")]
        let links = OverviewCardLinker.link(
            terms: ["Prophase", "Anaphase", "Telophase"], to: cards
        )
        #expect(links.count == 2)
        #expect(links["Telophase"] == nil)
    }
}
