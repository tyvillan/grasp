import AppKit
import SwiftUI
import GRASPCore

/// Measures diagram labels in the font they are actually drawn in.
///
/// Node sizes have to be known *before* layout runs, and `GraphicsContext`'s
/// own `resolve`/`measure` only exists inside the `Canvas` render closure --
/// by then positions are already fixed. AppKit measures the same font
/// synchronously and off-tree, so layout gets real sizes on the first pass
/// instead of settling into them over a frame or two.
///
/// Wholly `nonisolated`: the `GRASP` target defaults to `@MainActor`, but
/// `DiagramLayout` calls the measurement closure from wherever it runs, and
/// a font metric doesn't need the main thread.
nonisolated enum DiagramTextMeasurer {
    static let pointSize: CGFloat = 12
    static let weight: NSFont.Weight = .medium

    /// What `ConceptDiagramView` draws with. This and `measureFont`
    /// describe the same type and must stay in step -- measuring one face
    /// and drawing another is how the longest label in a diagram ends up
    /// clipped by two pixels while nothing else looks wrong.
    static var drawFont: Font { .system(size: pointSize, weight: .medium) }

    nonisolated(unsafe) private static let measureFont =
        NSFont.systemFont(ofSize: pointSize, weight: weight)

    /// Metrics for `DiagramLayout`, with the measurement closure filled in.
    /// The layout tests deliberately use the unmeasured default so their
    /// results stay deterministic and framework-free.
    static let metrics: DiagramMetrics = {
        var metrics = DiagramMetrics { line in
            let size = measure(line)
            return DiagramSize(width: size.width, height: size.height)
        }
        metrics.lineHeight = 16
        return metrics
    }()

    nonisolated(unsafe) private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private var storage: [String: CGSize] = [:]
        private let lock = NSLock()

        func value(for key: String, make: () -> CGSize) -> CGSize {
            lock.lock()
            defer { lock.unlock() }
            if let hit = storage[key] { return hit }
            let made = make()
            storage[key] = made
            return made
        }
    }

    static func measure(_ line: String) -> CGSize {
        cache.value(for: line) {
            let bounds = (line as NSString).boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: measureFont]
            )
            // A point of slack on width: `boundingRect` rounds down on
            // fractional advances, and a node label must never be the thing
            // that clips.
            return CGSize(width: ceil(bounds.width) + 1, height: ceil(bounds.height))
        }
    }
}
