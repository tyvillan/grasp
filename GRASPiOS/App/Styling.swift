import SwiftUI

/// GRASP's look on iPhone, matching the Mac: the palette's own canvas and
/// panels instead of iOS's stock grouped gray and white.
extension View {
    /// A list or form on GRASP's canvas.
    func graspList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(GRASPColor.canvas.ignoresSafeArea())
            .toolbarBackground(GRASPColor.canvas, for: .navigationBar)
    }

    /// A list section drawn as a GRASP panel.
    func graspSection() -> some View {
        self.listRowBackground(GRASPColor.surface)
    }
}

/// Light, dark, or following the phone. Defaults to dark: that's how GRASP
/// looks on the Mac, and the palette was drawn for it first.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }

    static let storageKey = "appearance"

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match iPhone"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}
