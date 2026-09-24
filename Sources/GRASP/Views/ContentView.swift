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

    // Exams stays a toolbar-level action rather than living inside
    // DeckListView: a zero-deck course renders no DeckListView at all (see
    // `CourseEmptyStateView` below), so anything that must still work on
    // an empty course can't be owned by a view that isn't mounted. New
    // Deck and Add Files used to live here for the same reason, but
    // `CourseEmptyStateView` already carries its own copies of both for
    // the zero-deck case, so the real ones could move next to what they
    // actually act on -- New Deck into `DeckListView`'s header, Add Files
    // into `DeckDetailView`'s -- instead of sitting side by side up here
    // looking like near-twins with different jobs.
    @State private var showingExams = false
    @State private var showingNewDeck = false

    /// The selection when it's a real course, not one of the sentinel
    /// routes -- every course-scoped branch and toolbar button keys off
    /// this rather than re-listing which sentinels to exclude, which is
    /// how the Exams button ended up trying to open for "Home" the first
    /// time a second sentinel was added.
    private var activeCourseId: String? {
        guard let id = selectedCourseId, id != Self.homeRoute, id != Self.calendarRoute else { return nil }
        return id
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedCourseId: $selectedCourseId)
                .navigationSplitViewColumnWidth(min: 200, ideal: 255)
        } detail: {
            Group {
                if selectedCourseId == Self.homeRoute || selectedCourseId == nil {
                    HomeView(selectedCourseId: $selectedCourseId, selectedDeckId: $selectedDeckId)
                } else if selectedCourseId == Self.calendarRoute {
                    CalendarView(selectedCourseId: $selectedCourseId, selectedDeckId: $selectedDeckId)
                } else if let courseId = activeCourseId, store.hasDecks(inCourse: courseId) {
                    // Three tiers of ground, narrowest to widest: the
                    // vibrant sidebar, then the deck list on a lifted
                    // surface, then the card canvas on the app's darkest
                    // ground. Depth increases as the panes get wider, so
                    // the eye lands on the content pane rather than
                    // treating all three as equal columns.
                    HStack(spacing: 0) {
                        if !isDeckListCollapsed {
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
                        if let deckId = selectedDeckId {
                            DeckDetailView(
                                scope: deckId == DeckListView.allCardsId
                                    ? .course(courseId) : .deck(deckId),
                                onAddFiles: { chooseAndImport(for: courseId) }
                            )
                        } else {
                            ContentUnavailableView("Select a deck", systemImage: "rectangle.stack")
                        }
                    }
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
        .toolbar {
            // The deck-list collapse toggle: the ask placed this control
            // inside the deck list's own toolbar, but a pane that's
            // collapsed can't host the button that un-collapses it -- and
            // the window's own main sidebar toggle already lives up here
            // rather than inside the sidebar for exactly that reason, so
            // this is the more faithful match to "the same behavior as the
            // main sidebar toggle", not a deviation from it.
            ToolbarItem(placement: .navigation) {
                if activeCourseId != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { isDeckListCollapsed.toggle() }
                    } label: {
                        Label("Toggle Deck List", systemImage: "sidebar.squares.leading")
                    }
                    .help(isDeckListCollapsed ? "Show deck list" : "Hide deck list")
                }
            }
            if activeCourseId != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingExams = true
                    } label: {
                        Label("Exams", systemImage: "calendar")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add New Course…") { showingAddCourse = true }
                    Button("Upload Document to Course…") { showingUploadPicker = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ImportButton()
            }
            ToolbarItem(placement: .primaryAction) {
                ProfileMenuButton()
            }
        }
        // Set at the window root rather than per-view: sidebar selection,
        // segmented controls, focus rings and every system control in the
        // window all draw from the tint, so one declaration here is what
        // keeps them from reverting to the OS accent (which is usually
        // blue, and reads as a stock app).
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
        .sheet(isPresented: $showingExams) {
            if let courseId = activeCourseId {
                ExamsSheet(courseId: courseId)
            }
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
            guard let courseId = activeCourseId else { return }
            if let deckId = selectedDeckId,
               deckId == DeckListView.allCardsId
               || (try? store.deck(deckId)).flatMap({ $0?.courseId == courseId && $0?.deletedAt == nil }) == true {
                return
            }
            // "All Cards" -- the master category pinned above every real
            // deck -- rather than whichever deck happens to sort first:
            // landing on one arbitrary deck read as landing in the wrong
            // place, and "All Cards" is the one selection that's never
            // wrong for a course you just clicked into.
            selectedDeckId = DeckListView.allCardsId
        }
        .onAppear(perform: openWidgetLink)
        .onChange(of: WidgetRouter.shared.pending) { _, _ in openWidgetLink() }
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

private struct ImportButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            Task { await store.runImport() }
        } label: {
            if store.isImporting {
                ProgressView().controlSize(.small)
            } else {
                Label("Import Vault", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(store.isImporting)
        .help(importHelp)
    }

    private var importHelp: String {
        guard let summary = store.lastImportSummary else { return "Scan the vault for new or changed notes" }
        var text = "Last import: \(summary.filesImportedOrUpdated) updated, \(summary.cardsCreated) cards created"
        if summary.duplicatesSkipped > 0 {
            text += ", \(summary.duplicatesSkipped) duplicates skipped"
        }
        return text
    }
}

private struct AddCourseSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""
    @State private var timelineText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Course")
                .font(.headline)
            Text("For a class with no vault folder yet -- import its notes later once you write them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Course name (e.g. Intro to Software Design)", text: $name)
            TextField("Course code (optional, e.g. COP 3014)", text: $code)
            TimelineField(text: $timelineText, allowsNoTimeline: false)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard let semesterId = try? store.findOrCreateSemester(
                        name: timelineText.trimmingCharacters(in: .whitespacesAndNewlines)
                    ) else { return }
                    try? store.addManualCourse(name: name, code: code.isEmpty ? nil : code, semesterId: semesterId)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty
                        || timelineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Step one of "Upload Document to Course": pick which course, then the
/// caller runs the actual file panel once this sheet is dismissed.
private struct UploadToCourseSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload Document to Course")
                .font(.headline)
            Text("Choose a course, then pick the files or folder to add to it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(store.coursePickerGroups(), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.courses) { course in
                            Text(course.name).tag(course.id as String?)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") {
                    selection = nil
                    dismiss()
                }
                // Escape too: without the shortcut, Escape closed the sheet
                // with the course still chosen and the file panel opened
                // anyway.
                .keyboardShortcut(.cancelAction)
                Button("Choose Files…") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

#Preview {
    ContentView()
        .environment(AppStore(profile: .preview))
}
