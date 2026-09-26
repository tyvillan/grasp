import DefaultBackend
import Foundation
import GRASPCore
import SwiftCrossUI

/// Started by `Launcher`, which sets up logging first.
struct GRASPWindowsApp: App {
    @State var opened = Result { try Library() }

    init() {
        #if os(Windows)
        WindowIcon.applyWhenWindowAppears()
        #endif
    }

    var body: some Scene {
        WindowGroup("GRASP") {
            switch opened {
            case .success(let library):
                ContentView(library: library)
            case .failure(let error):
                VStack(spacing: 8) {
                    Text("GRASP couldn't open your library").font(.title2)
                    Text(String(describing: error))
                }
                .padding(24)
            }
        }
        .defaultSize(width: 1100, height: 720)
    }
}

/// Where the main pane is.
enum Route: Hashable {
    case home
    case calendar
    case settings
    case course(String)
}

/// The window, laid out like the Mac's `ContentView`: a sidebar of
/// semesters and courses, then a detail pane. A course's detail splits into
/// a deck column and the selected deck's page.
///
/// A plain HStack rather than NavigationSplitView: WinUI's SplitView can't
/// be dragged to resize anyway, and on first layout SwiftCrossUI positions
/// its sidebar using the pane's stale width, which clipped the column.
struct ContentView: View {
    let library: Library
    @State var route: Route = .home
    /// The deck picked in each course's deck column, so switching courses
    /// and back keeps your place. A missing entry means "All Cards".
    @State var selectedDecks: [String: String] = [:]

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(library: library, route: $route)
                .frame(width: 240.0)
                .frame(maxHeight: .infinity)
                .background(GRASPColor.sidebar)
            Rectangle().fill(GRASPColor.hairline).frame(width: 1.0)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GRASPColor.canvas)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .home:
            HomeView(library: library, route: $route, onStudy: study)
        case .calendar:
            CalendarScreen(library: library, onStudy: study)
        case .settings:
            SettingsScreen(library: library)
        case .course(let courseId):
            if let course = library.course(courseId) {
                CourseView(
                    library: library,
                    course: course,
                    selectedDeckId: Binding(
                        get: { selectedDecks[courseId] },
                        set: { selectedDecks[courseId] = $0 }
                    )
                )
            } else {
                // The course went away (archived or deleted on another device).
                HomeView(library: library, route: $route, onStudy: study)
            }
        }
    }

    /// Straight into the deck an exam is about, or the course's All Cards
    /// when the event names no deck.
    private func study(courseId: String, deckId: String?) {
        selectedDecks[courseId] = deckId
        route = .course(courseId)
    }
}

// MARK: - Sidebar

/// "Home", then courses under their semesters, newest first, as on the Mac.
/// The list scrolls, so a big library can't push the window off the
/// screen; import and the account panel stay pinned at the bottom.
struct Sidebar: View {
    let library: Library
    @Binding var route: Route
    @Environment(\.chooseFile) var chooseFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GRASP")
                .font(GRASPFont.title)
                .foregroundColor(GRASPColor.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(title: "Home", dot: nil, isSelected: route == .home) {
                        route = .home
                    }
                    SidebarRow(title: "Calendar", dot: nil, isSelected: route == .calendar) {
                        route = .calendar
                    }
                    ForEach(library.courseSections, id: \.title) { section in
                        SectionLabel(section.title)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(section.courses, id: \.id) { course in
                            SidebarRow(
                                title: course.name,
                                dot: course.colorHex.map { Color(hex: $0) } ?? GRASPColor.hairlineStrong,
                                isSelected: route == .course(course.id)
                            ) {
                                route = .course(course.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
                Button("Import notes folder…") {
                    Task {
                        guard let folder = await chooseFile(
                            title: "Choose your notes folder",
                            defaultButtonLabel: "Import",
                            allowSelectingFiles: false,
                            allowSelectingDirectories: true
                        ) else { return }
                        // Remembered for Settings' "Import Now".
                        library.settings.notesFolder = folder.path
                        await library.importVault(at: folder)
                    }
                }
                .disabled(library.isImporting)
                if library.decks.isEmpty {
                    Button("Try sample notes") {
                        Task { await library.importSample() }
                    }
                    .disabled(library.isImporting)
                }
                if library.isImporting {
                    ProgressView("Importing…")
                } else if let status = library.status {
                    Text(status).font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary)
                }
                SidebarRow(title: "Settings", dot: nil, isSelected: route == .settings) {
                    route = .settings
                }
                AccountPanel(account: library.account)
            }
            .padding(12)
        }
    }
}

/// One sidebar row: an optional colour dot in a fixed slot (so every name
/// starts on the same x), then the name. Selected rows use GRASP's amber.
struct SidebarRow: View {
    let title: String
    let dot: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if let dot {
                Circle().fill(dot).frame(width: 7.0, height: 7.0).frame(width: 16.0)
            }
            Text(title)
                .font(GRASPFont.rowTitle)
                .foregroundColor(isSelected ? GRASPColor.accent : GRASPColor.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? GRASPColor.accentSoft : Color.clear)
        .cornerRadius(6)
        .onTapGesture(perform: action)
    }
}

// MARK: - Course

/// A course: its deck column, then the selected deck's page. "All Cards"
/// sits above the real decks and covers every deck in the course.
struct CourseView: View {
    let library: Library
    let course: Course
    @Binding var selectedDeckId: String?

    var body: some View {
        let decks = library.decks(inCourse: course.id)
        let allCards = DeckScope(allCardsIn: decks, courseId: course.id, courseName: course.name)
        let selected = decks.first { $0.id == selectedDeckId }.map(DeckScope.init(deck:)) ?? allCards

        HStack(spacing: 0) {
            DeckColumn(
                decks: decks,
                allCards: allCards,
                selectedId: selected.id,
                select: { selectedDeckId = $0 }
            )
            .frame(width: 260.0)
            .frame(maxHeight: .infinity)
            .background(GRASPColor.surface)
            Rectangle().fill(GRASPColor.hairlineStrong).frame(width: 1.0)
            if decks.isEmpty {
                VStack(spacing: 8) {
                    Text(course.name).font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
                    Text("No decks yet. Import this course's notes to make some.")
                        .foregroundColor(GRASPColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DeckView(library: library, scope: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The course's decks, laid out like the Mac's `DeckListView`: name on the
/// left, then the due badge and the card count in a right-aligned column.
struct DeckColumn: View {
    let decks: [DeckRow]
    let allCards: DeckScope
    let selectedId: String
    /// Called with a deck id, or nil for "All Cards".
    let select: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Decks")
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    DeckColumnRow(
                        name: "All Cards", isAllCards: true, cards: allCards.total, due: allCards.due,
                        isSelected: selectedId == allCards.id
                    ) { select(nil) }
                    ForEach(decks, id: \.id) { deck in
                        DeckColumnRow(
                            name: deck.name, isAllCards: false, cards: deck.total, due: deck.due,
                            isSelected: selectedId == deck.id
                        ) { select(deck.id) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct DeckColumnRow: View {
    let name: String
    let isAllCards: Bool
    let cards: Int
    let due: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(isAllCards ? GRASPFont.rowTitle.weight(.semibold) : GRASPFont.rowTitle)
                .foregroundColor(isSelected ? GRASPColor.accent : GRASPColor.textPrimary)
                .lineLimit(1)
            Spacer()
            if due > 0 {
                DueBadge(count: due)
            }
            Text("\(cards)")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
                .frame(width: 30.0, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? GRASPColor.accentSoft : Color.clear)
        .cornerRadius(6)
        .onTapGesture(perform: action)
    }
}

// MARK: - Deck page

/// A deck (or a course's All Cards): study what's due, approve drafts, and
/// see the row reduction from its notes.
struct DeckView: View {
    let library: Library
    let scope: DeckScope
    @State var session: [Card]? = nil
    /// Cards or Overview, as on the Mac. Kept when you switch decks, so
    /// reading through a course's lessons stays on the Overview tab.
    @State var tab: DeckTab = .cards

    enum DeckTab: String, CaseIterable {
        case cards = "Cards"
        case overview = "Overview"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(scope.courseName)
                    Text(scope.title).font(GRASPFont.display).foregroundColor(GRASPColor.textPrimary)
                    Text(summary).font(GRASPFont.body).foregroundColor(GRASPColor.textSecondary)
                }
                Spacer()
                // A study session owns the page until it ends.
                if session == nil {
                    SegmentedChoice(options: DeckTab.allCases, selection: tab, label: \.rawValue) { tab = $0 }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)
            Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)

            if tab == .overview && session == nil {
                OverviewPane(library: library, scope: scope)
            } else {
                cardsPage
            }
        }
        // A new deck starts fresh, not mid-way through the last one's session.
        .onChange(of: scope.id) { session = nil }
    }

    private var cardsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let cards = session {
                    StudySessionView(library: library, cards: cards) { session = nil }
                } else {
                    HStack(spacing: 10) {
                        Button(scope.due == 0 ? "Nothing due" : "Study \(scope.due) due") {
                            session = library.dueCards(inDecks: scope.deckIds)
                        }
                        .disabled(scope.due == 0)
                        .fixedSize()
                        if scope.drafts > 0 {
                            Button("Approve \(scope.drafts) drafts") {
                                library.approveDrafts(inDecks: scope.deckIds)
                            }
                            .fixedSize()
                        }
                    }
                    if scope.drafts > 0 && scope.due == 0 {
                        Text("New cards start as drafts. Approve them to study them.")
                            .foregroundColor(GRASPColor.textSecondary)
                    }
                }

                if let reduction = library.rowReduction(inDecks: scope.deckIds) {
                    RowReductionView(reduction: reduction)
                }
            }
            .padding(28)
        }
    }

    private var summary: String {
        var parts = ["\(scope.total) cards"]
        if scope.due > 0 { parts.append("\(scope.due) due") }
        if scope.drafts > 0 { parts.append("\(scope.drafts) drafts") }
        return parts.joined(separator: " · ")
    }
}
