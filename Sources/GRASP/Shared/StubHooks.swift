import Foundation
import GRASPCore

/// Canned AI replies for screenshots and demos when no model is reachable
/// (`GRASP_STUB_JUDGE`, `GRASP_STUB_EXPLAIN`). They exist only in debug
/// builds and then need the explicit launch flag `-GRASPAllowStubs 1` as
/// well, so an installed release build can never act on them.
enum StubHooks {
    /// The value of a stub variable (`GRASP_STUB_CLOUD=slow`), under the
    /// same two conditions as `enabled`: a debug build and the launch flag.
    static func value(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowFlag: Bool = UserDefaults.standard.bool(forKey: "GRASPAllowStubs")
    ) -> String? {
        #if DEBUG
        return allowFlag ? environment[name] : nil
        #else
        return nil
        #endif
    }

    /// Called once at launch: points the cloud transport at the stand-in.
    static func installCloudStub() {
        #if DEBUG
        guard let mode = value("GRASP_STUB_CLOUD") else { return }
        CloudStub.mode = mode
        if let seconds = value("GRASP_STUB_CLOUD_SECONDS").flatMap(Double.init) { CloudStub.slowSeconds = seconds }
        #endif
    }

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
