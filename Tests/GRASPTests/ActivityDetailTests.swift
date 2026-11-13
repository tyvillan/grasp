import Testing
import Foundation
@testable import GRASP
import GRASPCore

@Suite("AI activity detail line")
struct ActivityDetailTests {
    @Test("an overview run says which note it is on before the section count")
    @MainActor func noteBeforeSection() {
        let run = AIActivity(headline: "Writing overviews", units: 5, unitName: "Note")
        let progress = run.reporter(forUnit: 0)
        progress.begin("Writing section 4 of 4")
        // The snapshot reaches the activity on the main actor; give it the
        // value directly the way `receive` would.
        let line = run.detail(at: Date())
        #expect(line.hasPrefix("Note 1 of 5"))
        run.finish()
    }

    @Test("a job with one unit, or no unit name, gets no note count")
    @MainActor func noCountWhenSingle() {
        let single = AIActivity(headline: "Writing overviews", units: 1, unitName: "Note")
        #expect(!single.detail(at: Date()).contains("Note 1 of"))
        let unnamed = AIActivity(headline: "Refining", units: 5)
        #expect(!unnamed.detail(at: Date()).contains("of 5"))
        single.finish(); unnamed.finish()
    }

    @Test("the second note reads Note 2 of 5")
    @MainActor func secondNote() {
        let run = AIActivity(headline: "Writing overviews", units: 5, unitName: "Note")
        _ = run.reporter(forUnit: 1)
        #expect(run.detail(at: Date()).hasPrefix("Note 2 of 5"))
        run.finish()
    }
}
