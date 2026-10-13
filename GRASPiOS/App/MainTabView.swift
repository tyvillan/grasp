import SwiftUI
import GRASPCore

/// The signed-in app: your courses, what's coming up, and settings.
struct MainTabView: View {
    let onSwitchProfile: () -> Void
    @Environment(AppStore.self) private var store
    @State private var tab = DebugLaunch.tab ?? (DebugLaunch.course != nil ? "study" : "today")
    /// A deck a widget tap asked for, pushed onto Today's stack.
    @State private var widgetDeck: DeckRoute?

    private struct TabSpec: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    private static let tabs = [
        TabSpec(id: "today", title: "Today", symbol: "sun.max"),
        TabSpec(id: "study", title: "Courses", symbol: "rectangle.stack"),
        TabSpec(id: "calendar", title: "Calendar", symbol: "calendar"),
        TabSpec(id: "settings", title: "Settings", symbol: "gearshape"),
        TabSpec(id: "search", title: "Search", symbol: "magnifyingglass"),
    ]

    var body: some View {
        // The system's tab bar is Liquid Glass and floats over the content,
        // so the bar is drawn here instead: a solid panel with a hairline,
        // sitting in the bottom safe area so nothing ends up beneath it.
        TabView(selection: $tab) {
            Tab(value: "today") {
                NavigationStack {
                    TodayView()
                        .navigationDestination(item: $widgetDeck) { DeckScreen(route: $0) }
                }
            }
            Tab(value: "study") {
                NavigationStack { CoursesView() }
            }
            Tab(value: "calendar") {
                NavigationStack { CalendarScreen() }
            }
            Tab(value: "settings") {
                NavigationStack { SettingsScreen(onSwitchProfile: onSwitchProfile) }
            }
            Tab(value: "search") {
                NavigationStack { SearchScreen() }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .tint(GRASPColor.accent)
        .onAppear(perform: openWidgetLink)
        .onChange(of: WidgetRouter.shared.pending) { _, _ in openWidgetLink() }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs) { spec in
                let selected = tab == spec.id
                Button {
                    tab = spec.id
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: selected && spec.symbol == "sun.max" ? "sun.max.fill" : spec.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 24)
                        Text(spec.title)
                            .font(.graspUI(size: 11, weight: selected ? .semibold : .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .foregroundStyle(selected ? GRASPColor.accent : GRASPColor.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spec.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(alignment: .top) { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
        .background(GRASPColor.surface.ignoresSafeArea(edges: .bottom))
    }

    private func openWidgetLink() {
        guard let link = WidgetRouter.shared.consume() else { return }
        switch link {
        case .today:
            tab = "today"
        case .calendar:
            tab = "calendar"
        case .deck(let id):
            tab = "today"
            if let deck = try? store.deck(id), deck.deletedAt == nil {
                widgetDeck = DeckRoute(scope: .deck(id), name: deck.name)
            }
        }
    }
}
