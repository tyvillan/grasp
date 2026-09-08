import Testing
@testable import GRASPCore

@Suite("FrontmatterParser")
struct FrontmatterTests {
    @Test("parses a YAML list of tags")
    func parsesTagList() {
        let text = """
        ---
        tags:
          - cda
          - computer-science
          - spring-2026
          - lecture
          - college
        ---

        # Body
        """
        let (fm, body) = FrontmatterParser.split(text)
        #expect(fm.tags == ["cda", "computer-science", "spring-2026", "lecture", "college"])
        #expect(body.contains("# Body"))
        #expect(fm.isAssetSidecar == false)
    }

    @Test("recognizes an asset sidecar via source_file")
    func recognizesAssetSidecar() {
        let text = """
        ---
        tags: [college, spring-2026, cda, computer-science, asset, image]
        type: image
        source_file: "AND_GATE.png"
        ---
        # AND_GATE
        Original file: [[AND_GATE.png]]
        """
        let (fm, _) = FrontmatterParser.split(text)
        #expect(fm.isAssetSidecar)
        #expect(fm.sourceFile == "AND_GATE.png")
    }

    @Test("returns empty frontmatter for a file with none")
    func handlesNoFrontmatter() {
        let (fm, body) = FrontmatterParser.split("# Just a heading\nSome text")
        #expect(fm.tags.isEmpty)
        #expect(body.contains("Just a heading"))
    }
}
