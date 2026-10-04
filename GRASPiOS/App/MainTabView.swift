import SwiftUI
import GRASPCore

/// The signed-in app: your courses, what's coming up, and settings.
struct MainTabView: View {
    let onSwitchProfile: () -> Void
    @Environment(AppStore.self) private var store
    @State private var tab = DebugLaunch.tab ?? (DebugLaunch.course != nil ? "study" : "today")
    /// A deck a widget tap asked for, pushed onto Today's stack.
    @State private var widgetDeck: DeckRoute?

    var body: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "sun.max", value: "today") {
                NavigationStack {
                    TodayView()
                        .navigationDestination(item: $widgetDeck) { DeckScreen(route: $0) }
                }
            }
            Tab("Courses", systemImage: "rectangle.stack", value: "study") {
                NavigationStack { CoursesView() }
            }
            Tab("Calendar", systemImage: "calendar", value: "calendar") {
                NavigationStack { CalendarScreen() }
            }
            Tab("Study Guide", systemImage: "graduationcap", value: "guides") {
                StudyGuideHubView { target in
                    switch target {
                    case .exam(let courseId, let examEventId):
                        ExamScreen(courseId: courseId, examEventId: examEventId)
                    case .practice(let courseId, let guideId):
                        ExamScreen(courseId: courseId, examEventId: "", practiceGuideId: guideId)
                    }
                }
            }
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                NavigationStack { SettingsScreen(onSwitchProfile: onSwitchProfile) }
            }
            Tab(value: "search", role: .search) {
                NavigationStack { SearchScreen() }
            }
        }
        .onAppear(perform: openWidgetLink)
        .onChange(of: WidgetRouter.shared.pending) { _, _ in openWidgetLink() }
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
