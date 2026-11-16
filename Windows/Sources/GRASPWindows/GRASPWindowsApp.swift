import DefaultBackend
import Foundation
import Observation
import GRASPCore
import SwiftCrossUI

/// Started by `Launcher`, which sets up logging first.
struct GRASPWindowsApp: App {
    @State var session = AppSession()

    init() {
        #if os(Windows)
        WindowIcon.applyWhenWindowAppears()
        #endif
    }

    var body: some Scene {
        WindowGroup("GRASP") {
            switch session.phase {
            case .picking(let profiles):
                ProfilePicker(profiles: profiles, open: { session.open($0) }, create: { session.create($0) })
            case .open(let library):
                ContentView(library: library, switchProfile: { session.switchProfile() })
            case .failed(let message):
                VStack(spacing: 8) {
                    Text("GRASP couldn't open your library").font(.title2)
                    Text(message)
                }
                .padding(24)
            }
        }
        .defaultSize(width: 1100, height: 720)
    }
}

/// Which profile is open. The Mac shows "Who's studying?" at every launch;
/// here it's skipped when there's one profile with no PIN, which is the
/// usual case on a personal PC, and shown otherwise or on "Switch Profile".
@Observable
final class AppSession {
    enum Phase {
        case picking([Profile])
        case open(Library)
        case failed(String)
    }

    private(set) var phase: Phase = .failed("Starting…")

    init() {
        do {
            let profiles = try Library.profiles()
            if profiles.count == 1, profiles[0].pinHash == nil {
                open(profiles[0])
            } else {
                phase = .picking(profiles)
            }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func open(_ profile: Profile) {
        do {
            phase = .open(try Library(profile: profile))
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func create(_ profile: Profile) {
        do {
            try Library.addProfile(profile)
            open(profile)
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func switchProfile() {
        if case .open(let library) = phase { library.close() }
        phase = .picking((try? Library.profiles()) ?? [])
    }
}

/// Where the main pane is.
enum Route: Hashable {
    case home
    case calendar
    case settings
    case search
    case library
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
    let switchProfile: () -> Void
    @State var route: Route = .home
    /// The deck picked in each course's deck column, so switching courses
    /// and back keeps your place. A missing entry means "All Cards".
    @State var selectedDecks: [String: String] = [:]

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(library: library, route: $route)
                .frame(width: Sidebar.width)
                .frame(maxHeight: .infinity)
                .background(GRASPColor.sidebar)
            HairlineColumn()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GRASPColor.canvas)
        }
        #if os(Windows)
        .onAppear {
            KeyCommands.install()
            // Ask Ollama once now, so the first deck page already knows
            // whether its AI items show (see Library.lastLocalModel).
            Task { _ = await library.localModel() }
        }
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .home:
            HomeView(library: library, route: $route, onStudy: study)
        case .calendar:
            CalendarScreen(library: library, onStudy: study)
        case .settings:
            SettingsScreen(library: library, switchProfile: switchProfile)
        case .search:
            SearchScreen(library: library, onOpenDeck: study)
        case .library:
            LibraryScreen(library: library)
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

//// The Mac's sidebar (`SidebarView`): the wordmark, the places, then the
/// current term's courses and catch-all groups, with every older term folded
/// behind one "Past terms" row. Import sits as two quiet links above the
/// profile button, which opens Settings (account, profile, sign out).
struct Sidebar: View {
    /// Its fixed width; a 1 pt rule follows it.
    static let width = 240.0

    let library: Library
    @Binding var route: Route
    @Environment(\.chooseFile) var chooseFile
    @State var addingCourse = false
    @State var pastTermsOpen = false

    var body: some View {
        let groups = library.sidebarGroups
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(GRASPColor.brand).frame(width: 16.0, height: 16.0).cornerRadius(3)
                Text("GRASP")
                    .font(Font.system(size: 20, weight: .heavy))
                    .foregroundColor(GRASPColor.textPrimary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(title: "Home", dot: nil, isSelected: route == .home) { route = .home }
                    SidebarRow(title: "Calendar", dot: nil, isSelected: route == .calendar) { route = .calendar }
                    SidebarRow(title: "Library", dot: nil, isSelected: route == .library) { route = .library }
                    SidebarRow(title: "Search", dot: nil, isSelected: route == .search) { route = .search }
                    ForEach(groups.current, id: \.title) { section in
                        groupLabel(section.title)
                        courseRows(section.courses)
                    }
                    if !groups.past.isEmpty {
                        pastTerms(groups.past)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                HairlineRule()
                if library.isImporting {
                    ProgressView("Importing…")
                } else if let status = library.status {
                    Text(status).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).lineLimit(2)
                }
                if library.decks.isEmpty {
                    GRASPButton("Try sample notes") {
                        Task { await library.importSample() }
                    }
                    .disabled(library.isImporting)
                }
                HStack(spacing: 14) {
                    footerLink("Import notes", action: importFolder)
                    footerLink("New course") { addingCourse = true }
                }
                profileButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .sheet(isPresented: $addingCourse) {
            OrganizeSheetView(library: library, sheet: .newCourse,
                              onCreated: { route = .course($0) },
                              close: { addingCourse = false })
        }
    }

    private func groupLabel(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.leading, 12)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }

    private func courseRows(_ courses: [Course]) -> some View {
        ForEach(courses, id: \.id) { course in
            SidebarRow(
                title: course.name,
                dot: course.colorHex.map { Color(hex: $0) } ?? GRASPColor.textTertiary,
                isSelected: route == .course(course.id)
            ) {
                route = .course(course.id)
            }
        }
    }

    /// Every older term behind one row, open while a course inside it is
    /// the current page.
    @ViewBuilder
    private func pastTerms(_ terms: [(title: String, courses: [Course])]) -> some View {
        let count = terms.reduce(0) { $0 + $1.courses.count }
        let open = pastTermsOpen || terms.contains { $0.courses.contains { route == .course($0.id) } }
        HStack(spacing: 8) {
            Text(open ? "\u{2304}" : "\u{203A}")
                .font(Font.system(size: 13))
                .foregroundColor(GRASPColor.textTertiary)
                .frame(width: 10.0)
            Text("Past terms").font(Font.system(size: 13)).foregroundColor(GRASPColor.textTertiary)
            Spacer()
            Text("\(count) course\(count == 1 ? "" : "s")")
                .font(Font.system(size: 13))
                .foregroundColor(GRASPColor.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.top, 16)
        .onTapGesture { pastTermsOpen = !open }
        if open {
            ForEach(terms, id: \.title) { term in
                groupLabel(term.title)
                courseRows(term.courses)
            }
        }
    }

    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Text("+ \(title)")
            .font(Font.system(size: 12.5))
            .foregroundColor(GRASPColor.textTertiary)
            .onTapGesture(perform: action)
    }

    /// The Mac's profile button: a yellow avatar with the first initial and
    /// the first name, opening Settings. The second line is the sync state.
    private var profileButton: some View {
        let name = library.profile.name
        return HStack(spacing: 10) {
            Text((name.first.map { String($0) } ?? "?").uppercased())
                .font(Font.system(size: 12, weight: .bold))
                .foregroundColor(GRASPColor.ink)
                .frame(width: 28.0, height: 28.0)
                .background(GRASPColor.brand)
                .cornerRadius(14)
            VStack(alignment: .leading, spacing: 1) {
                Text(name.split(separator: " ").first.map(String.init) ?? name)
                    .font(Font.system(size: 13.5, weight: .medium))
                    .foregroundColor(route == .settings ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                    .lineLimit(1)
                Text(syncLine)
                    .font(Font.system(size: 11.5))
                    .foregroundColor(GRASPColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .onTapGesture { route = .settings }
    }

    private var syncLine: String {
        guard let account = library.account, account.email != nil else { return "Not syncing" }
        return account.isSyncing ? "Syncing…" : (account.status ?? "Signed in")
    }

    private func importFolder() {
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
}

/// One sidebar row: an optional colour dot in a fixed slot (so every name
/// starts on the same x), then the name, up to two lines as on the Mac. The
/// current row is bold cream with the 3 pt yellow bar; the others are
/// regular weight in the secondary tone.
struct SidebarRow: View {
    let title: String
    let dot: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // The bar is an overlay only on the current row: an overlay on
        // every row cost about 4 ms each, on every screen switch.
        if isSelected {
            row.overlay(alignment: .leading) {
                Rectangle().fill(GRASPColor.brand).frame(width: 3.0, height: 20.0).cornerRadius(1)
            }
            .onTapGesture(perform: action)
        } else {
            row.onTapGesture(perform: action)
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            if let dot {
                Circle().fill(dot).frame(width: 8.0, height: 8.0).frame(width: 18.0)
            }
            Text(title)
                .font(Font.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? GRASPColor.textPrimary : GRASPColor.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - Course

/// A course: its deck column, then the selected deck's page. "All Cards"
/// sits above the real decks and covers every deck in the course. The
/// column's ••• menu organises the course, as the Mac's right-click menus
/// do (SwiftCrossUI has no right-click on Windows).
struct CourseView: View {
    let library: Library
    let course: Course
    @Binding var selectedDeckId: String?
    @State var organizing: OrganizeSheet?
    @Environment(\.chooseFile) var chooseFile

    var body: some View {
        let decks = library.decks(inCourse: course.id)
        let exams = library.guidedExams(courseId: course.id)
        let allCards = DeckScope(allCardsIn: decks, courseId: course.id, courseName: course.name)
        let selectedRow = decks.first { $0.id == selectedDeckId }
        let selectedExam = DeckScope.examEventId(fromId: selectedDeckId).flatMap { id in exams.first { $0.id == id } }
        let selected = selectedRow.map(DeckScope.init(deck:)) ?? allCards

        HStack(spacing: 0) {
            DeckColumn(
                library: library,
                course: course,
                decks: decks,
                allCards: allCards,
                exams: exams,
                selectedId: selectedExam.map { DeckScope.examId($0.id) } ?? selected.id,
                select: { selectedDeckId = $0 },
                organize: { sheet in
                    // Archiving needs no questions: it's undone from Settings.
                    if case .archive(let course) = sheet {
                        library.setArchived(course.id, true)
                    } else if case .addStudyGuide(let course) = sheet {
                        addStudyGuide(to: course)
                    } else if case .addFiles(let course) = sheet {
                        Task {
                            guard let url = await chooseFile(
                                title: "Choose a file or folder to add to \(course.name)",
                                defaultButtonLabel: "Add",
                                allowSelectingFiles: true,
                                allowSelectingDirectories: true
                            ) else { return }
                            await library.importFiles([url], intoCourse: course.id)
                        }
                    } else {
                        organizing = sheet
                    }
                }
            )
            .frame(width: 260.0)
            .frame(maxHeight: .infinity)
            .background(GRASPColor.surface)
            Rectangle().fill(GRASPColor.hairlineStrong).frame(width: 1.0)
            if let selectedExam {
                ExamStudyView(library: library, course: course, exam: selectedExam) { organizing = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if decks.isEmpty {
                VStack(spacing: 8) {
                    Text(course.name).font(GRASPFont.title).foregroundColor(GRASPColor.textPrimary)
                    Text("No decks yet. Import this course's notes, or add a deck from the ••• menu.")
                        .foregroundColor(GRASPColor.textSecondary)
                    Button("New Deck…") { organizing = .newDeck(courseId: course.id) }.fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DeckView(library: library, scope: selected, deck: selectedRow) { organizing = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: Binding(get: { organizing != nil }, set: { if !$0 { organizing = nil } })) {
            if let organizing {
                OrganizeSheetView(library: library, sheet: organizing,
                                  onCreated: { selectedDeckId = $0 },
                                  onDeleted: { selectedDeckId = nil },
                                  close: { self.organizing = nil })
            }
        }
    }

    /// The Mac's graduation-cap button: a guide file into the course, which
    /// links itself to the exam its date matches, then that exam's page.
    private func addStudyGuide(to course: Course) {
        Task {
            guard let url = await chooseFile(
                title: "Choose a study guide for an exam in \(course.name)",
                defaultButtonLabel: "Add",
                allowSelectingFiles: true,
                allowSelectingDirectories: false
            ) else { return }
            let read = await library.importStudyGuides([url], intoCourse: course.id)
            if read == 0 {
                library.status = "That file didn't read as a study guide. Guides are recognised by name, like \"Exam 1 Study Guide\" or \"Midterm Review\"."
            } else if let exam = library.guidedExams(courseId: course.id).first {
                selectedDeckId = DeckScope.examId(exam.id)
            } else {
                library.status = "Guide added. Give it an exam in Dates for This Course… to see its study page."
            }
        }
    }
}

/// The course's decks, laid out like the Mac's `DeckListView`: name on the
/// left, then the due badge and the card count in a right-aligned column.
struct DeckColumn: View {
    let library: Library
    let course: Course
    let decks: [DeckRow]
    let allCards: DeckScope
    let exams: [CalendarEvent]
    let selectedId: String
    /// Called with a deck id, or nil for "All Cards".
    let select: (String?) -> Void
    let organize: (OrganizeSheet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SectionLabel("Decks")
                Spacer()
                Menu("•••") {
                    Button("New Deck…") { organize(.newDeck(courseId: course.id)) }
                    Button("Edit Course…") { organize(.editCourse(course)) }
                    Button("Dates for This Course…") { organize(.dates(course)) }
                    Button("Add Files…") { organize(.addFiles(course)) }
                    Button("Add Study Guide…") { organize(.addStudyGuide(course)) }
                    Button("Archive Course") { organize(.archive(course)) }
                    Button("Delete Course…") { organize(.deleteCourse(course)) }
                }
                .fixedSize()
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    DeckColumnRow(
                        name: "All Cards", kicker: nil, isAllCards: true, cards: allCards.total, due: allCards.due,
                        understanding: nil, isSelected: selectedId == allCards.id
                    ) { select(nil) }
                    ForEach(exams, id: \.id) { exam in
                        ExamColumnRow(exam: exam, isSelected: selectedId == DeckScope.examId(exam.id)) {
                            select(DeckScope.examId(exam.id))
                        }
                    }
                    ForEach(decks, id: \.id) { deck in
                        DeckColumnRow(
                            name: deck.name, kicker: deck.kicker, isAllCards: false, cards: deck.total, due: deck.due,
                            understanding: understanding(deck.id), isSelected: selectedId == deck.id
                        ) { select(deck.id) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// A deck's cards by stage, for the thin bar under its name; nil when
    /// nobody has been asked about any of them yet.
    private func understanding(_ deckId: String) -> DeckUnderstanding.Distribution? {
        let distribution = library.distribution(ofDeck: deckId)
        return distribution.total > distribution.notAsked ? distribution : nil
    }
}

/// A deck in the column, as the Mac's `DeckRow`: the lecture date above the
/// name, a thin understanding bar under it once cards have been asked, and
/// one labelled number on the right ("42 due", else "44 cards").
struct DeckColumnRow: View {
    let name: String
    /// The lecture date, small above the name.
    let kicker: String?
    let isAllCards: Bool
    let cards: Int
    let due: Int
    let understanding: DeckUnderstanding.Distribution?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        if isSelected {
            row.overlay(alignment: .leading) {
                Rectangle().fill(GRASPColor.brand).frame(width: 3.0, height: 18.0).cornerRadius(1)
            }
            .onTapGesture(perform: action)
        } else {
            row.onTapGesture(perform: action)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let kicker {
                    Text(kicker)
                        .font(Font.system(size: 10, weight: .semibold))
                        .foregroundColor(GRASPColor.textTertiary)
                        .lineLimit(1)
                }
                Text(name)
                    .font(isAllCards ? GRASPFont.rowTitle.weight(.semibold) : GRASPFont.rowTitle)
                    .foregroundColor(GRASPColor.textPrimary)
                    .lineLimit(1)
                if let understanding {
                    UnderstandingBar(distribution: understanding, width: 150.0, height: 4.0)
                        .padding(.top, 4)
                }
            }
            Spacer()
            // Plain text: yellow on the deck page belongs to Study.
            if due > 0 {
                Text("\(due) due")
                    .font(Font.system(size: 12, weight: .semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                    .fixedSize()
            } else {
                Text("\(cards) card\(cards == 1 ? "" : "s")")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? GRASPColor.surfaceRaised : Color.clear)
        .cornerRadius(GRASPRadius.inner)
    }
}

// MARK: - Deck page

/// A deck (or a course's All Cards), after the Mac's `DeckDetailView`: its
/// name and make-up, Study / Learn / Test, and the Cards and Overview tabs.
/// A study session takes over the whole page until it ends.
struct DeckView: View {
    let library: Library
    let scope: DeckScope
    /// The real deck, or nil for a course's All Cards.
    let deck: DeckRow?
    let organize: (OrganizeSheet) -> Void
    @State var mode: StudyMode?
    /// Cards or Overview, as on the Mac. Kept when you switch decks, so
    /// reading through a course's lessons stays on the Overview tab.
    @State var tab: DeckTab = .cards
    /// Cards picked from an overview's key term, shown alone on the Cards tab.
    @State var focusCards: Set<String>?

    enum DeckTab: String, CaseIterable {
        case overview = "Overview"
        case cards = "Cards"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let mode {
                session(mode)
            } else {
                header
                Rectangle().fill(GRASPColor.hairline).frame(height: 1.0)
                if let job = library.cardJob(forCourse: library.courseId(of: scope)) {
                    CardJobStrip(job: job) { library.dismissCardJob(forCourse: library.courseId(of: scope)) }
                }
                if tab == .overview {
                    OverviewPane(library: library, onOpenCards: { ids in
                        focusCards = Set(ids)
                        tab = .cards
                    }, scope: scope)
                } else {
                    cardsPage
                }
            }
        }
        // A new deck starts fresh, not mid-way through the last one's session.
        .watch(scope.id) {
            if mode != nil { end() }
            takeStudyRequest()
        }
        .onAppear { takeStudyRequest() }
        .quietTask {
            let found = await library.localModel() != nil
            if hasModel != found { hasModel = found }
        }
        .sheet(isPresented: Binding(get: { tool != nil }, set: { if !$0 { tool = nil } })) {
            switch tool {
            case .fillGaps:
                FillGapsSheet(start: { perNote, topic in
                    library.fillGapsWithAI(inDecks: scope.deckIds, courseId: library.courseId(of: scope),
                                           perNote: perNote, topic: topic)
                }, close: { tool = nil })
            case .duplicates:
                DuplicateReviewSheet(groups: library.duplicateGroups(inDecks: scope.deckIds),
                                     merge: { library.mergeDuplicates($0) }, close: { tool = nil })
            case .files:
                DeckFilesSheet(library: library, scope: scope) { tool = nil }
            case nil:
                EmptyView()
            }
        }
    }

    /// Whether Ollama is up, checked when the page opens: the AI items only
    /// appear when there's a model to run them, as on the Mac.
    @State var hasModel = (Library.lastLocalModel ?? nil) != nil
    @State var tool: DeckTool?

    enum DeckTool { case fillGaps, duplicates, files }

    @ViewBuilder
    private func session(_ mode: StudyMode) -> some View {
        switch mode {
        case .flashcards(let cards):
            FlashcardSession(library: library, deckName: scope.title, cards: cards, finish: end)
        case .learn:
            LearnSession(library: library, deckName: scope.title, deckIds: scope.deckIds, finish: end)
        case .practice(let cards):
            LearnSession(library: library, deckName: scope.title, deckIds: scope.deckIds, focus: cards, finish: end)
        case .test:
            TestSession(library: library, deckName: scope.title, deckIds: scope.deckIds, finish: end)
        }
    }

    private func end() {
        mode = nil
        library.finishSession()
    }

    /// Arrived from Home's "Continue": start the flashcards right away.
    private func takeStudyRequest() {
        guard library.takeStudyRequest(for: scope.id) else { return }
        let due = library.dueCards(inDecks: scope.deckIds)
        if !due.isEmpty { mode = .flashcards(due) }
    }

    /// The Mac's deck header: the deck's name large, the Overview / Cards
    /// tabs at the right, then Study (the page's one yellow button), Learn
    /// and Test as outlined pills, and one ••• menu for the deck's tools.
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text(scope.title)
                    .font(GRASPFont.display)
                    .foregroundColor(GRASPColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                SegmentedChoice(options: DeckTab.allCases, selection: tab, label: \.rawValue) { tab = $0 }
            }
            HStack(spacing: 10) {
                GRASPButton("Study", kind: .primary) {
                    mode = .flashcards(library.dueCards(inDecks: scope.deckIds))
                }
                .disabled(scope.due == 0)
                GRASPButton("Learn") { mode = .learn }.disabled(scope.total == scope.drafts)
                GRASPButton("Test") { mode = .test }.disabled(scope.total == scope.drafts)
                Spacer()
                deckMenu
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    /// The deck's own actions and the tools, in one menu: SwiftCrossUI has
    /// no right-click, and one menu on the page costs one view, not one a row.
    private var deckMenu: some View {
        Menu("•••") {
            if hasModel {
                if scope.drafts > 0 {
                    Button("Refine \(scope.drafts) drafts with AI") {
                        library.refineDeckWithAI(inDecks: scope.deckIds, courseId: library.courseId(of: scope))
                    }
                }
                Button("Fill gaps with AI…") { tool = .fillGaps }
            }
            Button("Review duplicates…") { tool = .duplicates }
            Button("Files in this deck…") { tool = .files }
            if let deck {
                Button(deck.kicker == nil ? "Set lecture date…" : "Change lecture date…") {
                    organize(.lectureDate(deck))
                }
                Button("Rename deck…") { organize(.renameDeck(deck)) }
                Button("Delete deck…") { organize(.deleteDeck(deck)) }
            }
        }
        .fixedSize()
    }

    private var cardsPage: some View {
        ScrollView {
            CardList(library: library, scope: scope, focus: $focusCards,
                     onPractice: { mode = .practice(Set($0)) })
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
        }
    }
}
