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
                .toolbarVisibility(.hidden, for: .tabBar)
            }
            Tab(value: "study") {
                NavigationStack { CoursesView() }
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
            Tab(value: "calendar") {
                NavigationStack { CalendarScreen() }
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
            Tab(value: "settings") {
                NavigationStack { SettingsScreen(onSwitchProfile: onSwitchProfile) }
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
            Tab(value: "search") {
                NavigationStack { SearchScreen() }
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        // Feedback: the soft asks sit just above the tab bar.
        .feedbackAskHost()
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .tint(GRASPColor.accent)
        // The first-run tutorial: it lights up the real controls and only
        // navigates (a tab, or a deck pushed on Today).
        .environment(store.tutorial)
        .overlay { TutorialOverlay().environment(store.tutorial) }
        .onChange(of: store.tutorial.token) { _, _ in prepareTutorialScreen() }
        .task { store.startTutorialIfFirstTime() }
        .feedbackSheet()
        .task { store.startFeedback() }
        .onChange(of: tab, initial: true) { _, new in
            let screen: FeedbackScreen = switch new {
            case "study": .courses
            case "calendar": .calendar
            case "settings": .settings
            case "search": .search
            default: .today
            }
            FeedbackScreen.base = screen
            FeedbackScreen.current = screen
        }
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
                .tutorialTarget(spec.id == "study" ? TutorialTarget.coursesTab : spec.id == "settings" ? .settingsTab : nil)
            }
        }
        .background(alignment: .top) { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
        .background(GRASPColor.surface.ignoresSafeArea(edges: .bottom))
    }

    /// Puts the screen the tutorial step is about behind it. Navigation only:
    /// a tab, or the first deck pushed on Today. Closing the tour puts it back.
    private func prepareTutorialScreen() {
        let tutorial = store.tutorial
        guard tutorial.isActive else {
            if let before = preTutorialScreen {
                preTutorialScreen = nil
                tab = before.tab
                widgetDeck = before.deck
            }
            return
        }
        let step = tutorial.current
        let needsDeck = step.needsDeckPage && !tutorial.ignoresDeckPage
        let needsCourses = step.targets.contains(.importNotes)
        guard needsDeck || needsCourses else { return }
        if preTutorialScreen == nil { preTutorialScreen = PreTutorialScreen(tab: tab, deck: widgetDeck) }
        if needsCourses {
            tab = "study"
        } else if let course = store.firstCourseWithDeck() {
            tab = "today"
            widgetDeck = DeckRoute(scope: .course(course.id), name: course.name)
        }
    }

    private struct PreTutorialScreen { let tab: String; let deck: DeckRoute? }
    @State private var preTutorialScreen: PreTutorialScreen?

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
