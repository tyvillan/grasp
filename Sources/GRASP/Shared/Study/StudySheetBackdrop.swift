import SwiftUI

extension View {
    /// Counts this view as an open study sheet while it is on screen, so the
    /// window behind it can dim further than the system's own sheet scrim.
    func dimsWindowBehind() -> some View {
        modifier(DimsWindowBehind())
    }
}

private struct DimsWindowBehind: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            .onAppear { store.presentedStudySheets += 1 }
            .onDisappear { store.presentedStudySheets = max(0, store.presentedStudySheets - 1) }
    }
}
