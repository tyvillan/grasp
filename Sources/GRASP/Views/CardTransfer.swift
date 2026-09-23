import CoreTransferable
import UniformTypeIdentifiers

/// The drag payload for moving a card between decks. Just the card id --
/// the target deck comes from wherever it's dropped, and there's no
/// "source deck" to carry since `AppStore.moveCard` doesn't need one (a
/// card belongs to exactly one deck by convention).
///
/// `nonisolated` is load-bearing, not stylistic: the GRASP executable
/// target sets `.defaultIsolation(MainActor.self)` in Package.swift, which
/// implicitly isolates every type declared here to the main actor --
/// `Transferable`'s `transferRepresentation` requirement is `nonisolated`,
/// so without this the type would fail to conform.
nonisolated struct CardTransfer: Codable, Transferable {
    /// Every card being dragged: the whole selection when the row dragged
    /// is part of one. With a single id, dragging five selected cards moved
    /// only the one under the pointer.
    let cardIds: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .graspCard)
    }
}

nonisolated extension UTType {
    /// Declared in Info.plist as an exported type so the system registers
    /// it -- a custom type (rather than reusing `.plainText`) is what
    /// keeps a deck row from also accepting arbitrary text dragged in from
    /// other apps. Marked `nonisolated` for the same reason as
    /// `CardTransfer` itself -- `transferRepresentation` reads this from a
    /// nonisolated context, and the target's default main-actor isolation
    /// would otherwise apply here too.
    static let graspCard = UTType(exportedAs: "com.tyvillan.grasp.card")
}
