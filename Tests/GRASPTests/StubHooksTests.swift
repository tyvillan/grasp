import Testing
@testable import GRASP

@Suite("Stub hooks")
struct StubHooksTests {
    @Test("a stub needs both its variable and the explicit flag")
    func needsBoth() {
        #expect(!StubHooks.enabled("GRASP_STUB_JUDGE", environment: [:], allowFlag: false))
        #expect(!StubHooks.enabled("GRASP_STUB_JUDGE", environment: ["GRASP_STUB_JUDGE": "1"], allowFlag: false))
        #expect(!StubHooks.enabled("GRASP_STUB_JUDGE", environment: [:], allowFlag: true))
        #expect(!StubHooks.enabled("GRASP_STUB_EXPLAIN", environment: ["GRASP_STUB_JUDGE": "1"], allowFlag: true))
    }

    @Test("only a debug build ever honours one")
    func debugOnly() {
        let on = StubHooks.enabled("GRASP_STUB_JUDGE", environment: ["GRASP_STUB_JUDGE": "1"], allowFlag: true)
        #if DEBUG
        #expect(on)
        #else
        #expect(!on)
        #endif
    }
}
