import Testing
@testable import GRASPCore

/// The chunker's whole reason to exist is that a whole-note overview can't
/// tolerate silent truncation the way a per-card refinement can. So the two
/// claims worth protecting hardest are: a note that fits comes through
/// untouched, and a note that doesn't is never cut mid-sentence.
@Suite("Overview chunker")
struct OverviewChunkerTests {

    private func words(_ count: Int, sentenceLength: Int = 10) -> String {
        var sentences: [String] = []
        var written = 0
        var index = 0
        while written < count {
            let take = min(sentenceLength, count - written)
            let body = (0..<take).map { "word\(index + $0)" }.joined(separator: " ")
            sentences.append(body.prefix(1).uppercased() + body.dropFirst() + ".")
            written += take
            index += take
        }
        return sentences.joined(separator: " ")
    }

    private func chunks(_ plan: OverviewChunker.Plan) -> [OverviewChunker.Chunk] {
        if case .chunks(let value) = plan { return value }
        return []
    }

    @Test("rejects a note too short to be worth summarising")
    func tooShort() {
        let plan = OverviewChunker.plan(
            reflowed: words(40), wordCount: 40, hasMath: false, wordBudget: 1_200
        )
        #expect(plan == .tooShort(wordCount: 40))
    }

    @Test("rejects a note long enough to stop being a study aid")
    func tooLong() {
        let plan = OverviewChunker.plan(
            reflowed: "x", wordCount: 200_000, hasMath: false, wordBudget: 1_200
        )
        #expect(plan == .tooLong(wordCount: 200_000))
    }

    @Test("passes a note that fits through byte-for-byte, with no truncation")
    func shortNoteIsUntouched() {
        let text = words(800)
        let plan = OverviewChunker.plan(
            reflowed: text, wordCount: 800, hasMath: false, wordBudget: 1_200
        )
        let result = chunks(plan)
        #expect(result.count == 1)
        #expect(result.first?.text == text)
    }

    @Test("keeps every sentence when it has to split a long note")
    func nothingIsLost() {
        let text = words(3_000)
        let result = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 3_000, hasMath: false, wordBudget: 1_200
        ))
        #expect(result.count > 1)
        let combined = result.map(\.text).joined(separator: " ")
        // Every original sentence survives somewhere.
        for sentence in OverviewChunker.sentences(of: text) {
            #expect(combined.contains(sentence))
        }
    }

    @Test("never ends a chunk in the middle of a sentence")
    func neverSplitsMidSentence() {
        let text = words(4_000)
        let result = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 4_000, hasMath: false, wordBudget: 900
        ))
        #expect(result.count > 1)
        for chunk in result {
            let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = trimmed.last
            #expect(last == "." || last == "?" || last == "!")
        }
    }

    @Test("splits on the note's own headings and remembers them")
    func splitsOnHeadings() {
        let text = """
            # Interphase
            \(words(700))

            # Mitosis
            \(words(700))

            # Cytokinesis
            \(words(700))
            """
        let result = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 2_100, hasMath: false, wordBudget: 800
        ))
        #expect(result.count >= 3)
        let headings = result.compactMap(\.heading)
        #expect(headings.contains("# Interphase") || headings.contains("Interphase"))
    }

    @Test("falls back to paragraphs when a note has no headings")
    func headinglessNote() {
        let text = (0..<8).map { _ in words(400) }.joined(separator: "\n\n")
        let result = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 3_200, hasMath: false, wordBudget: 1_000
        ))
        #expect(result.count > 1)
        #expect(result.allSatisfy { $0.heading == nil })
    }

    @Test("breaks up a single oversized section rather than emitting it whole")
    func oversizedSection() {
        let text = "# One Huge Section\n" + words(3_000)
        let result = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 3_000, hasMath: false, wordBudget: 800
        ))
        #expect(result.count > 1)
    }

    @Test("shrinks the budget for a note with math in it")
    func mathShrinksBudget() {
        let text = words(3_000)
        let plain = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 3_000, hasMath: false, wordBudget: 1_200
        ))
        let withMath = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 3_000, hasMath: true, wordBudget: 1_200
        ))
        #expect(withMath.count > plain.count)
    }

    @Test("never exceeds the chunk cap, however badly a note packs")
    func chunkCap() {
        let text = (0..<200).map { _ in words(60) }.joined(separator: "\n\n")
        let result = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 12_000, hasMath: false, wordBudget: 300
        ))
        #expect(result.count <= OverviewChunker.maximumChunks)
    }

    @Test("a smaller generator budget produces more chunks for the same note")
    func budgetDrivesChunkCount() {
        let text = words(3_000)
        let large = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 3_000, hasMath: false, wordBudget: 1_200
        ))
        let small = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 3_000, hasMath: false, wordBudget: 500
        ))
        #expect(small.count > large.count)
    }

    @Test("treats a hash tag as text, not a heading")
    func hashTagIsNotAHeading() {
        let text = "#biology is not a heading.\n" + words(200)
        let result = chunks(OverviewChunker.plan(
            reflowed: text, wordCount: 205, hasMath: false, wordBudget: 1_200
        ))
        #expect(result.count == 1)
        #expect(result.first?.heading == nil)
    }
}
