import SwiftUI
import UniformTypeIdentifiers

/// Makes a sidebar row (a deck or a course) draggable and a drop target for other rows, only
/// while the list is in the default order. Uses `onDrag`/`onDrop` so the list knows
/// which deck is being dragged and can draw where it would land.
struct ReorderDrag: ViewModifier {
    let enabled: Bool
    let deckId: String
    @Binding var dragging: String?
    @Binding var target: String?
    let onMove: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragging = deckId
                    // Plain text rather than a custom type: the drop matches on
                    // `dragging`, so no registered type can get in the way.
                    let provider = NSItemProvider(object: "grasp-deck:\(deckId)" as NSString)
                    return provider
                }
                .onDrop(of: [UTType.plainText, UTType.utf8PlainText, UTType.text], delegate: ReorderDelegate(
                    deckId: deckId, dragging: $dragging, target: $target, onMove: onMove))
        } else {
            content
        }
    }
}

struct ReorderDelegate: DropDelegate {
    let deckId: String
    @Binding var dragging: String?
    @Binding var target: String?
    let onMove: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool { return dragging != nil }
    func dropEntered(info: DropInfo) { if dragging != nil { target = deckId } }
    func dropExited(info: DropInfo) { if target == deckId { target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        defer { target = nil; dragging = nil }
        guard let dropped = dragging, dropped != deckId else { return false }
        onMove(dropped)
        return true
    }
}

