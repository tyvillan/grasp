import Testing
import Foundation
@testable import GRASP

@Suite("Motion tokens")
struct MotionTests {
    @Test("three durations, none longer than 0.32 s")
    func durations() {
        #expect(Motion.quickDuration == 0.12)
        #expect(Motion.baseDuration == 0.20)
        #expect(Motion.glideDuration == 0.32)
        #expect(Motion.quickDuration < Motion.baseDuration && Motion.baseDuration < Motion.glideDuration)
    }

    @Test("the debug launch flag forces Reduce Motion on")
    func forcedFlag() {
        let key = "GRASPForceReduceMotion"
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: key)
        defer { if let before { defaults.set(before, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(true, forKey: key)
        #expect(Motion.isReduced)
    }

    @Test("no view code outside Theme.swift uses a literal duration, a spring, or a bare withAnimation")
    func noLiteralsInViews() throws {
        // Tests/GRASPTests/MotionTests.swift -> repo root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let patterns = [".easeOut(duration", ".easeIn(duration", ".easeInOut(duration", ".linear(duration",
                        ".spring(", ".interpolatingSpring", "withAnimation {", ".animation(.default"]
        var offenders: [String] = []
        for dir in ["Sources/GRASP", "GRASPiOS/App"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "Theme.swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for pattern in patterns where text.contains(pattern) {
                    offenders.append("\(url.lastPathComponent): \(pattern)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
