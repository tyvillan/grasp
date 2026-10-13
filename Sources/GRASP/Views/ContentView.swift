import SwiftUI
import GRASPCore

/// Root layout: sidebar (Home + semesters/courses) and a single wide
/// detail pane. Home gets the pane's full width, matching a dashboard's
/// proportions -- when a course is selected instead, that same pane
/// splits itself into a deck list and deck detail side by side, rather
/// than reserving a third `NavigationSplitView` column (and that column's
/// width) for every screen even when Home has no use for it.
struct ContentView: View {
    /// Sentinel selection value for "Home", sharing `selectedCourseId`'s
    /// single-selection binding with real course ids instead of a second
    /// piece of state that could disagree with it.
    static let homeRoute = "home"
    /// The calendar destination, a second sentinel alongside `homeRoute` --
    /// same trick, same single selection binding, so adding a whole new
    /// top-level screen costs no extra navigation state.
    static let calendarRoute = "calendar"
    /// The Study Guide page, a third sentinel beside Home and Calendar.
    static let studyGuideRoute = "studyGuide"
    /// The Library page: vault import, hidden courses and library-wide checks.
    static let libraryRoute = "library"

    @Environment(AppStore.self) private var store
    @State private var selectedCourseId: String? = ContentView.homeRoute
    @State private var selectedDeckId: String?
    @State private var showingAddCourse = false
    @State private var showingUploadPicker = false
    @State private var uploadTargetCourseId: String?
    @State private var showingSearch = false
    // Shared by "Upload Document to Course" and the per-course "Add Files"
    // toolbar button -- the two flows never run at once, so one alert
    // does for both.
    @State private var importResult: ImportResultMessage?
    /// Held back while the duplicate sheet is up: SwiftUI shows one sheet at
    /// a time, and the import summary requested alongside it was lost.
    @State private var deferredImportResult: ImportResultMessage?
    // Persisted rather than session-only: a preference about how much of
    // the window to dedicate to the deck list, not a piece of navigation
    // state that should reset the moment the app relaunches.
    @AppStorage("deckListCollapsed") private var isDeckListCollapsed = false
    @AppStorage("sidebarCollapsed") private var isSidebarCollapsed = false
    /// The study guide open from the Study guides page, if any.
    @State private var studyGuideTarget: StudyGuideHubTarget?
    /// The window's width. Below `narrowBreakpoint` the deck list gives its
    /// column back to the deck, and the sidebar steps aside for it when
    /// asked for.
    @State private var windowWidth: CGFloat = 1280
    @State private var narrowShowsDeckList = false
    private static let narrowBreakpoint: CGFloat = 1000
    private var isNarrow: Bool { windowWidth < Self.narrowBreakpoint }
    /// What is left for the deck once the sidebar and deck list have theirs.
    private func deckPaneWidth(listShown: Bool) -> CGFloat {
        windowWidth - (showsSidebar ? Self.sidebarWidth + 1 : 0) - (listShown ? 261 : 0)
    }
    private var showsDeckList: Bool { isNarrow ? narrowShowsDeckList : !isDeckListCollapsed }
    /// With the deck list open in a narrow window the sidebar is what gives
    /// way, so the deck keeps room to breathe.
    private var showsSidebar: Bool {
        !isSidebarCollapsed && !(isNarrow && narrowShowsDeckList && activeCourseId != nil)
    }

    // New Deck and Add Files live next to what they act on (DeckListView's
    // header, DeckDetailView's); `CourseEmptyStateView` carries its own
    // copies for the zero-deck case where neither view is mounted.
    @State private var showingNewDeck = false

    /// The selection when it's a real course, not one of the sentinel
    /// routes -- every course-scoped branch and toolbar button keys off
    /// this rather than re-listing which sentinels to exclude, which is
    /// how the Exams button ended up trying to open for "Home" the first
    /// time a second sentinel was added.
    private var activeCourseId: String? {
        guard let id = selectedCourseId, id != Self.homeRoute, id != Self.calendarRoute,
              id != Self.studyGuideRoute, id != Self.libraryRoute else { return nil }
        return id
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(sidebarWidth: Self.sidebarWidth, showsSidebar: showsSidebar,
                   onHome: { selectedCourseId = Self.homeRoute }) {
                topBarActions
            }
            HStack(spacing: 0) {
                if showsSidebar {
                    SidebarView(selectedCourseId: $selectedCourseId)
                        .frame(width: Self.sidebarWidth)
                        .transition(.move(edge: .leading))
                    Rectangle().fill(GRASPColor.hairline).frame(width: 1)
                }
                detail
            }
        }
        .background(GRASPColor.canvas)
        // The window's own width, read from the window: a layout that
        // measured itself would only ever read as wide as its contents want
        // to be.
        .background(WindowWidthReader { windowWidth = $0 })
        // Picking a deck in a narrow window puts the list away again.
        .onChange(of: selectedDeckId) { _, _ in
            if isNarrow, narrowShowsDeckList {
                withAnimation(Motion.snappy) { narrowShowsDeckList = false }
            }
        }
        // The system's sheet scrim leaves the page readable around a study
        // sheet; this takes it down to a shadow.
        .overlay {
            Color.black
                .opacity(store.presentedStudySheets > 0 ? 0.92 : 0)
                .allowsHitTesting(false)
                .animation(Motion.fade, value: store.presentedStudySheets > 0)
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(.hidden, for: .windowToolbar)
        .tint(GRASPColor.accent)
        .sheet(isPresented: $showingAddCourse) {
            AddCourseSheet()
        }
        .sheet(isPresented: $showingSearch) {
            SearchView()
        }
        .sheet(isPresented: $showingUploadPicker, onDismiss: runUploadPanel) {
            UploadToCourseSheet(selection: $uploadTargetCourseId)
        }
        .sheet(isPresented: $showingNewDeck) {
            if let courseId = activeCourseId {
                DeckCreateSheet(courseId: courseId) { newDeckId in
                    selectedDeckId = newDeckId
                }
            }
        }
        // Continuous duplicate detection: every import/rescan re-scans the
        // whole vault (`AppStore.scanForDuplicatesAfterImport`), and this
        // surfaces the result the moment it finds something, root-level so
        // it works no matter which course was open when the import ran.
        .sheet(isPresented: Binding(
            get: { !store.pendingDuplicateGroups.isEmpty },
            set: { if !$0 { store.clearPendingDuplicates() } }
        ), onDismiss: {
            if let deferred = deferredImportResult {
                deferredImportResult = nil
                importResult = deferred
            }
        }) {
            DuplicateReviewSheet(groups: store.pendingDuplicateGroups) { merges in
                try? store.mergeDuplicates(merges)
                store.clearPendingDuplicates()
            }
        }
        .sheet(item: $importResult) { result in
            ResultSheet(icon: "tray.and.arrow.down", title: result.title, leadText: result.body)
        }
        // Home's two "jump to a specific deck" tap handlers set both ids
        // together (see HomeView's continue-card and recents-row taps) --
        // that combination must be honored as-is. Everything else that
        // changes the course (a sidebar click, a course tile, or Home's
        // own course-tile tap, which sets only the course id) needs the
        // stale deck cleared: without this, the detail pane can keep
        // showing a deck that belongs to the course you just left.
        .onChange(of: selectedCourseId) { _, _ in
            studyGuideTarget = nil
            guard let courseId = activeCourseId else { return }
            if let deckId = selectedDeckId,
               deckId == DeckListView.allCardsId
               || (try? store.deck(deckId)).flatMap({ $0?.courseId == courseId && $0?.deletedAt == nil }) == true
               // An exam's study page in this course (opened from Home or
               // the calendar, which set the course and the row together).
               || DeckListView.examEventId(fromRow: deckId)
                    .flatMap({ store.calendarEvent($0)?.courseId == courseId }) == true {
                return
            }
            // "All Cards" -- the master category pinned above every real
            // deck -- rather than whichever deck happens to sort first:
            // landing on one arbitrary deck read as landing in the wrong
            // place, and "All Cards" is the one selection that's never
            // wrong for a course you just clicked into.
            selectedDeckId = DeckListView.allCardsId
        }
        .onAppear {
            openWidgetLink()
            openLaunchScreen()
        }
        .task { await store.refreshStaleStudyGuides() }
        .onChange(of: WidgetRouter.shared.pending) { _, _ in openWidgetLink() }
    }

    private static let sidebarWidth: CGFloat = 248

    private var detail: some View {
        Group {
            if selectedCourseId == Self.homeRoute || selectedCourseId == nil {
                HomeView(selectedCourseId: $selectedCourseId, selectedDeckId: $selectedDeckId)
            } else if selectedCourseId == Self.calendarRoute {
                CalendarView(selectedCourseId: $selectedCourseId, selectedDeckId: $selectedDeckId)
            } else if selectedCourseId == Self.libraryRoute {
                LibraryView()
            } else if selectedCourseId == Self.studyGuideRoute {
                if let target = studyGuideTarget {
                    VStack(spacing: 0) {
                        BackBar(title: "Study guides") { studyGuideTarget = nil }
                        studyGuidePage(target)
                    }
                } else {
                    StudyGuideHubView(standalone: false, onOpen: { studyGuideTarget = $0 }) { studyGuidePage($0) }
                }
            } else if let courseId = activeCourseId, store.hasDecks(inCourse: courseId) {
                // Three tiers of ground, narrowest to widest: the
                // vibrant sidebar, then the deck list on a lifted
                // surface, then the card canvas on the app's darkest
                // ground. Depth increases as the panes get wider, so
                // the eye lands on the content pane rather than
                // treating all three as equal columns.
                HStack(spacing: 0) {
                    if showsDeckList {
                        DeckListView(
                            courseId: courseId, selectedDeckId: $selectedDeckId,
                            onNewDeck: { showingNewDeck = true }
                        )
                        .frame(width: 260)
                        .background(GRASPColor.surface)
                        .transition(.move(edge: .leading))
                        Rectangle()
                            .fill(GRASPColor.hairlineStrong)
                            .frame(width: 1)
                    }
                    if let deckId = selectedDeckId,
                       let examEventId = DeckListView.examEventId(fromRow: deckId) {
                        ExamStudyView(courseId: courseId, examEventId: examEventId)
                            .id(examEventId)
                    } else if let deckId = selectedDeckId {
                        DeckDetailView(
                            scope: deckId == DeckListView.allCardsId
                                ? .course(courseId) : .deck(deckId),
                            onAddFiles: { chooseAndImport(for: courseId) },
                            onAddStudyGuide: { chooseAndImportGuide(for: courseId) },
                            onDeckDeleted: { selectedDeckId = DeckListView.allCardsId }
                        )
                    } else {
                        ContentUnavailableView("Select a deck", systemImage: "rectangle.stack")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                // The pane's full size whatever is in it: with only the
                // placeholder's own width, the row shrank to the middle
                // and left grey bars either side.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .environment(\.deckPaneWidth, deckPaneWidth(listShown: showsDeckList))
            } else if let courseId = activeCourseId {
                // A course with no decks at all: one clean empty state
                // spanning the full width, not a narrow "No decks yet"
                // column sitting next to a second, redundant "Select a
                // deck" placeholder -- the bug this branch replaces.
                CourseEmptyStateView(
                    onAddFiles: { chooseAndImport(for: courseId) },
                    onNewDeck: { showingNewDeck = true }
                )
            }
        }
        .background(GRASPColor.canvas)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = store.databaseOpenError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GRASPColor.rejected)
                    Text(error)
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(GRASPColor.rejectedSoft)
            }
        }
    }

    @ViewBuilder
    private func studyGuidePage(_ target: StudyGuideHubTarget) -> some View {
        switch target {
        case .exam(let courseId, let examEventId):
            ExamStudyView(courseId: courseId, examEventId: examEventId).id(examEventId)
        case .practice(let courseId, let guideId):
            ExamStudyView(courseId: courseId, examEventId: "", practiceGuideId: guideId).id(guideId)
        }
    }

    /// The window's global actions, in the top bar: the deck-list and
    /// sidebar toggles, search, and Add.
    @ViewBuilder
    private var topBarActions: some View {
        if activeCourseId != nil {
            TopBarButton(systemImage: "sidebar.squares.leading",
                         help: showsDeckList ? "Hide deck list" : "Show deck list") {
                withAnimation(Motion.snappy) {
                    if isNarrow { narrowShowsDeckList.toggle() } else { isDeckListCollapsed.toggle() }
                }
            }
        }
        TopBarButton(systemImage: "sidebar.left",
                     help: showsSidebar ? "Hide sidebar" : "Show sidebar") {
            withAnimation(Motion.snappy) {
                // Stepped aside for the deck list: bringing the sidebar back
                // puts the deck list away.
                if isNarrow, narrowShowsDeckList, !isSidebarCollapsed {
                    narrowShowsDeckList = false
                } else {
                    isSidebarCollapsed.toggle()
                }
            }
        }
        .keyboardShortcut("s", modifiers: [.command, .control])
        TopBarButton(systemImage: "magnifyingglass", help: "Search") { showingSearch = true }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        Menu {
            Button("Add New Course…") { showingAddCourse = true }
            Button("Upload Document to Course…") { showingUploadPicker = true }
        } label: {
            Image(systemName: "plus")
                .font(.graspUI(size: 14, weight: .medium))
                .foregroundStyle(GRASPColor.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a course or upload a document")
    }

    /// `GRASP_OPEN_COURSE` (a course's name) and `GRASP_OPEN_DECK` (a
    /// deck's name, "All Cards", or "exam" for the course's next exam with a
    /// study guide) open that screen on launch -- for screenshots and QA
    /// where clicking through isn't possible, like `GRASP_SKIP_PICKER`. Off
    /// unless set, so a normal launch never sees it.
    private func openLaunchScreen() {
        let env = ProcessInfo.processInfo.environment
        // `GRASP_OPEN_ROUTE`: home, calendar, studyGuide or library.
        if let route = env["GRASP_OPEN_ROUTE"] {
            selectedCourseId = route
            return
        }
        guard let name = env["GRASP_OPEN_COURSE"],
              let course = store.coursesBySemester.values.joined().first(where: { $0.name == name })
        else { return }
        switch env["GRASP_OPEN_DECK"] {
        case nil, "All Cards":
            selectedDeckId = DeckListView.allCardsId
        case "exam":
            selectedDeckId = store.guidedExams(courseId: course.id).first.map { DeckListView.examRowId($0.id) }
        case let deckName?:
            selectedDeckId = ((try? store.decks(inCourse: course.id)) ?? []).first { $0.name == deckName }?.id
        }
        selectedCourseId = course.id
    }

    /// A widget tap: Home, the calendar, or straight to a deck.
    private func openWidgetLink() {
        guard let link = WidgetRouter.shared.consume() else { return }
        switch link {
        case .today:
            selectedCourseId = Self.homeRoute
        case .calendar:
            selectedCourseId = Self.calendarRoute
        case .deck(let id):
            guard let deck = try? store.deck(id), deck.deletedAt == nil else {
                selectedCourseId = Self.homeRoute
                return
            }
            // Deck first: the course change handler keeps a deck that
            // belongs to the new course.
            selectedDeckId = id
            selectedCourseId = deck.courseId
        }
    }

    /// The course-picker sheet only records which course was chosen and
    /// dismisses -- the file panel itself must run after that sheet is
    /// gone, not from inside it, since a modal `NSOpenPanel` launched from
    /// a still-presented SwiftUI sheet behaves unreliably on macOS.
    private func showImportResult(_ result: ImportResultMessage) {
        if store.pendingDuplicateGroups.isEmpty {
            importResult = result
        } else {
            deferredImportResult = result
        }
    }

    private func runUploadPanel() {
        guard let courseId = uploadTargetCourseId else { return }
        uploadTargetCourseId = nil
        let urls = ImportPanel.pickFilesOrFolders(message: "Choose files or a folder to upload")
        guard !urls.isEmpty else { return }
        Task {
            let summary = await store.importFiles(urls, intoCourse: courseId)
            showImportResult(ImportResultMessage(summary: summary))
        }
    }

    /// A native open panel with both files and folders enabled in one
    /// picker -- exactly "a folder or any specific files" in a single
    /// selection, rather than two separate flows for the two cases.
    /// A study guide lands on its exam's page: the importer links it to the
    /// exam it names (or the next one), and that exam's row opens.
    private func chooseAndImportGuide(for courseId: String) {
        let urls = ImportPanel.pickFilesOrFolders(message: "Choose a study guide for an exam in this course")
        guard !urls.isEmpty else { return }
        Task {
            let summary = await store.importStudyGuides(urls, intoCourse: courseId)
            if summary.studyGuidesImported == 0 {
                showImportResult(ImportResultMessage(summary: summary))
            } else if let exam = store.guidedExams(courseId: courseId).first {
                selectedDeckId = DeckListView.examRowId(exam.id)
            }
        }
    }

    private func chooseAndImport(for courseId: String) {
        let urls = ImportPanel.pickFilesOrFolders(
            message: "Choose files or a folder to add to this course"
        )
        guard !urls.isEmpty else { return }
        Task {
            let summary = await store.importFiles(urls, intoCourse: courseId)
            showImportResult(ImportResultMessage(summary: summary))
        }
    }
}

/// Shown in place of the deck-list/deck-detail split for a course that has
/// no decks at all yet -- fills the whole detail pane rather than sitting
/// alongside a second, redundant empty placeholder.
private struct CourseEmptyStateView: View {
    let onAddFiles: () -> Void
    let onNewDeck: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No decks yet", systemImage: "tray")
        } description: {
            Text("Import the vault, or add files, a folder, or a new deck directly to this course.")
        } actions: {
            Button("Add Files or Folder…", action: onAddFiles)
            Button("New Deck…", action: onNewDeck)
        }
    }
}

private struct AddCourseSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""
    @State private var timelineText = ""

    var body: some View {
        GRASPSheet(
            eyebrow: "Course", title: "Add a course",
            message: "For a class with no vault folder yet. Import its notes later, once you write them.",
            width: 440
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Name")
                    TextField("e.g. Intro to Software Design", text: $name)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Code (optional)")
                    TextField("e.g. COP 3014", text: $code)
                }
                TimelineField(text: $timelineText, allowsNoTimeline: false)
            }
        } footer: {
                Button("Cancel") { dismiss() }
                Button("Add course") {
                    guard let semesterId = try? store.findOrCreateSemester(
                        name: timelineText.trimmingCharacters(in: .whitespacesAndNewlines)
                    ) else { return }
                    try? store.addManualCourse(name: name, code: code.isEmpty ? nil : code, semesterId: semesterId)
                    dismiss()
                }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty
                        || timelineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
    }
}

/// Step one of "Upload Document to Course": pick which course, then the
/// caller runs the actual file panel once this sheet is dismissed.
private struct UploadToCourseSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?

    var body: some View {
        GRASPSheet(
            eyebrow: "Upload", title: "Add files to a course",
            message: "Choose a course, then pick the files or folder to add to it.",
            width: 460, showsClose: false
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: GRASPSpace.m) {
                    ForEach(store.coursePickerGroups(), id: \.title) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel(group.title)
                                .padding(.bottom, 4)
                            ForEach(group.courses) { course in
                                CoursePickRow(name: course.name, color: course.colorHex.map(CoursePalette.color(hex:)),
                                              isOn: selection == course.id) {
                                    selection = course.id
                                }
                            }
                        }
                    }
                }
                .padding(GRASPSpace.m)
            }
            .frame(height: 260)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous)
                    .strokeBorder(GRASPColor.hairline, lineWidth: 1)
            )
        } footer: {
                Button("Cancel") {
                    selection = nil
                    dismiss()
                }
                // Escape too: without the shortcut, Escape closed the sheet
                // with the course still chosen and the file panel opened
                // anyway.
                .keyboardShortcut(.cancelAction)
                Button("Choose files…") { dismiss() }
                    .buttonStyle(GRASPProminentButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
        }
    }
}

/// A course to pick in a popup: its color dot and name; the chosen one
/// gets the yellow edge and a check.
struct CoursePickRow: View {
    let name: String
    let color: Color?
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                CourseDot(color: color)
                Text(name)
                    .font(.graspUI(size: 13.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(GRASPColor.textPrimary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.graspUI(size: 11, weight: .bold))
                        .foregroundStyle(GRASPColor.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? GRASPColor.accentSoft : (hovering ? GRASPColor.surfaceRaised : .clear))
                    .overlay(alignment: .leading) {
                        if isOn {
                            Capsule().fill(GRASPColor.brand).frame(width: 3, height: 16).padding(.leading, 3)
                        }
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

#Preview {
    ContentView()
        .environment(AppStore(profile: .preview))
}

extension EnvironmentValues {
    /// The width the deck page has to work with; below about 640 it puts its
    /// toolbar in icons.
    @Entry var deckPaneWidth: CGFloat = 1000
}

/// Reports the hosting window's width, and again whenever it is resized.
private struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ReaderView)?.onChange = onChange
    }

    private final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            report(window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { self?.report(window) }
            }
        }

        private func report(_ window: NSWindow) {
            let width = window.frame.width
            DispatchQueue.main.async { [weak self] in self?.onChange?(width) }
        }

    }
}
