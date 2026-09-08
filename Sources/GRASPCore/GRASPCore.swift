/// GRASPCore is the SwiftUI-free half of GRASP: vault ingestion, the
/// SQLite-backed store, card generation, and the study engine (FSRS,
/// Learn mode, test building) all live here so they can be unit tested
/// without pulling in AppKit/SwiftUI.
// Note: deliberately not named `GRASPCore` -- a top-level type sharing
// the module's name shadows `GRASPCore.<Type>` qualification everywhere
// in the app target, which matters here because `Material` collides with
// SwiftUI's own `Material` type.
public enum GRASPCoreInfo {
    public static let version = "0.1.0"
}
