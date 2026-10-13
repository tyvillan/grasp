import Foundation

/// Canned AI replies for screenshots and demos when no model is reachable
/// (`GRASP_STUB_JUDGE`, `GRASP_STUB_EXPLAIN`). They exist only in debug
/// builds and then need the explicit launch flag `-GRASPAllowStubs 1` as
/// well, so an installed release build can never act on them.
enum StubHooks {
    static func enabled(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowFlag: Bool = UserDefaults.standard.bool(forKey: "GRASPAllowStubs")
    ) -> Bool {
        #if DEBUG
        return allowFlag && environment[name] == "1"
        #else
        return false
        #endif
    }
}
