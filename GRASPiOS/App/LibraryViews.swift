import SwiftUI
import GRASPCore

/// Every course, grouped by semester, with what's due in each.
struct CoursesView: View {
    @Environment(AppStore.self) private var store
    @State private var openedCourse: Course?
    @State private var importing = false

    var body: some View {
        List {
            if store.semesters.isEmpty && store.coursesBySemester.isEmpty {
                ContentUnavailableView(
                    "No courses yet",
                    systemImage: "tray",
                    description: Text(store.sync.account == nil
                        ? "Sign in from Settings to bring your library over from your Mac."
                        : "Your library is on its way -- it appears here as soon as it has synced.")
                )
            }
            ForEach(semesterSections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.courses) { course in
                        NavigationLink {
                            CourseView(course: course)
                        } label: {
                            CourseRow(course: course, counts: counts(for: course))
                        }
                    }
                }
                .graspSection()
            }
        }
        .graspList()
        .navigationTitle("Courses")
        .navigationDestination(item: $openedCourse) { CourseView(course: $0) }
        .onAppear {
            guard openedCourse == nil, let name = DebugLaunch.course else { return }
            openedCourse = store.coursesBySemester.values.joined().first { $0.name == name }
        }
        .refreshable { store.sync.syncNow() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { SyncIndicator() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { importing = true } label: { Label("Import Notes", systemImage: "square.and.arrow.down") }
            }
        }
        .sheet(isPresented: $importing) { ImportScreen() }
    }

    /// Newest semester first; undated ones ("Other") and courses with no
    /// semester last.
    private var semesterSections: [(title: String, courses: [Course])] {
        let ordered = store.semesters.sorted { a, b in
            let aUndated = a.sortKey == Int.max, bUndated = b.sortKey == Int.max
            if aUndated != bUndated { return !aUndated }
            return a.sortKey > b.sortKey
        }
        var sections = ordered.compactMap { semester -> (String, [Course])? in
            guard let courses = store.coursesBySemester[semester.id], !courses.isEmpty else { return nil }
            return (semester.name, courses)
        }
        if let loose = store.coursesBySemester[nil], !loose.isEmpty { sections.append(("Other", loose)) }
        return sections
    }

    private func counts(for course: Course) -> (cards: Int, due: Int) {
        let decks = (try? store.decks(inCourse: course.id)) ?? []
        return decks.reduce((0, 0)) { total, deck in
            let c = store.deckCounts[deck.id] ?? (0, 0)
            return (total.0 + c.cardCount, total.1 + c.dueCount)
        }
    }
}

private struct CourseRow: View {
    let course: Course
    let counts: (cards: Int, due: Int)

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(course.name).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary)
                Text("\(counts.cards) cards" + (course.code.map { " · \($0)" } ?? ""))
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer()
            if counts.due > 0 { DueBadge(count: counts.due) }
        }
        .padding(.vertical, 2)
    }
}

struct DueBadge: View {
    let count: Int
    var body: some View {
        Text("\(count) due")
            .graspType(.meta)
            .foregroundStyle(GRASPColor.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(GRASPColor.accentSoft, in: Capsule())
    }
}

/// Shows sync at a glance in the navigation bar: spinning while syncing,
/// a warning when it last failed.
struct SyncIndicator: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.sync.state {
        case .syncing:
            ProgressView()
        case .failed:
            Image(systemName: "exclamationmark.icloud").foregroundStyle(GRASPColor.rejected)
        case .signedOut:
            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(GRASPColor.rejected)
        default:
            EmptyView()
        }
    }
}

/// A course's decks, with "All Cards" first -- the same scopes as the Mac.
struct CourseView: View {
    @Environment(AppStore.self) private var store
    let course: Course
    @State private var openedDeck: DeckRoute?
    @State private var openedExam: String?
    @State private var choosingGuide = false
    @State private var guideMessage: String?
    @State private var settingLectureDateFor: Deck?

    var body: some View {
        let decks = (try? store.decks(inCourse: course.id)) ?? []
        let exams = store.guidedExams(courseId: course.id)
        let kickers = store.deckKickers(for: decks)
        List {
            Section {
                NavigationLink {
                    DeckScreen(route: DeckRoute(scope: .course(course.id), name: "All Cards"))
                } label: {
                    DeckRow(name: "All Cards", icon: "square.stack.3d.up",
                            counts: decks.reduce((0, 0)) { t, d in
                                let c = store.deckCounts[d.id] ?? (0, 0)
                                return (t.0 + c.cardCount, t.1 + c.dueCount)
                            })
                }
            }
            .graspSection()
            Section {
                ForEach(exams) { exam in
                    NavigationLink {
                        ExamScreen(courseId: course.id, examEventId: exam.id)
                    } label: {
                        ExamRow(exam: exam)
                    }
                }
                Button {
                    choosingGuide = true
                } label: {
                    Label("Add Study Guide…", systemImage: "doc.badge.plus")
                        .graspType(.body)
                }
            } header: {
                Text("Study guides")
            } footer: {
                if let guideMessage {
                    Text(guideMessage)
                } else if exams.isEmpty {
                    Text("A study guide attaches to the exam it's for, by the date or \"Exam 1\" in it.")
                }
            }
            .graspSection()
            Section("Decks") {
                ForEach(decks) { deck in
                    NavigationLink {
                        DeckScreen(route: DeckRoute(scope: .deck(deck.id), name: deck.name))
                    } label: {
                        DeckRow(name: deck.name, icon: "rectangle.stack", kicker: kickers[deck.id],
                                counts: store.deckCounts[deck.id].map { ($0.cardCount, $0.dueCount) } ?? (0, 0))
                    }
                    .contextMenu {
                        Button(deck.manualLessonDate == nil ? "Set Lecture Date…" : "Change Lecture Date…") {
                            settingLectureDateFor = deck
                        }
                    }
                }
            }
            .graspSection()
        }
        .graspList()
        .navigationTitle(course.name)
        .navigationDestination(item: $openedDeck) { DeckScreen(route: $0) }
        .navigationDestination(item: $openedExam) { ExamScreen(courseId: course.id, examEventId: $0) }
        .fileImporter(isPresented: $choosingGuide, allowedContentTypes: ExamScreen.guideTypes,
                      allowsMultipleSelection: true) { outcome in
            if case .success(let urls) = outcome { addGuides(urls) }
        }
        .sheet(item: $settingLectureDateFor) { deck in
            DeckLectureDateSheet(deck: deck, onSaved: {})
        }
        .onAppear {
            guard openedDeck == nil, openedExam == nil, let name = DebugLaunch.deck else { return }
            if name == "exam" {
                openedExam = store.guidedExams(courseId: course.id).first?.id
            } else if name == "All Cards" {
                openedDeck = DeckRoute(scope: .course(course.id), name: name)
            } else if let deck = ((try? store.decks(inCourse: course.id)) ?? []).first(where: { $0.name == name }) {
                openedDeck = DeckRoute(scope: .deck(deck.id), name: deck.name)
            }
        }
    }
}

extension CourseView {
    /// Guides picked here link to whichever exam they name (by date, then
    /// "Exam N"), the same matching the Mac's vault import does.
    private func addGuides(_ picked: [URL]) {
        guideMessage = "Reading guide…"
        Task {
            do {
                let copies = try ImportScreen.copyIntoLibrary(picked, courseId: course.id)
                let summary = await store.importStudyGuides(copies, intoCourse: course.id)
                guideMessage = summary.studyGuidesImported == 0
                    ? "That file didn't read as a study guide. Guides are recognized by name, like \"Exam 1 Study Guide\"."
                    : nil
            } catch {
                guideMessage = "Couldn't add the guide: \(error.localizedDescription)"
            }
        }
    }
}

struct DeckRoute: Hashable {
    let scope: AppStore.DeckScope
    let name: String
}

private struct DeckRow: View {
    let name: String
    let icon: String
    var kicker: String? = nil
    let counts: (cards: Int, due: Int)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(GRASPColor.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if let kicker {
                    Text(kicker).font(.caption2.weight(.semibold)).foregroundStyle(GRASPColor.accent)
                }
                Text(name).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary)
                Text("\(counts.cards) cards").graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer()
            if counts.due > 0 { DueBadge(count: counts.due) }
        }
    }
}

/// Lets the student assign a lecture date by hand when a deck's notes
/// carry none to extract -- the iPhone counterpart to the Mac's sheet of
/// the same name in `Sources/GRASP/Views/DeckActions.swift`. Never shown
/// as overriding an extracted date: `AppStore.deckKickers` always prefers
/// the extracted one, so this only ever fills in where extraction found
/// nothing.
private struct DeckLectureDateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deck: Deck
    let onSaved: () -> Void

    @State private var date: Date
    @State private var isRange: Bool
    @State private var endDate: Date

    init(deck: Deck, onSaved: @escaping () -> Void) {
        self.deck = deck
        self.onSaved = onSaved
        _date = State(initialValue: deck.manualLessonDate ?? Date())
        _isRange = State(initialValue: deck.manualLessonDateEnd != nil)
        _endDate = State(initialValue: deck.manualLessonDateEnd ?? deck.manualLessonDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(isRange ? "Starts" : "Date", selection: $date, displayedComponents: .date)
                    Toggle("This deck covers more than one lecture", isOn: $isRange)
                    if isRange {
                        DatePicker("Ends", selection: $endDate, in: date..., displayedComponents: .date)
                    }
                } footer: {
                    Text("Shown in the deck list when GRASP can't read a date from this deck's notes.")
                }
                if deck.manualLessonDate != nil {
                    Section {
                        Button("Clear Lecture Date", role: .destructive) {
                            try? store.setDeckManualLessonDate(deck.id, start: nil)
                            onSaved()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(deck.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        try? store.setDeckManualLessonDate(deck.id, start: date, end: isRange ? endDate : nil)
                        onSaved()
                        dismiss()
                    }
                }
            }
        }
    }
}

extension Course: @retroactive Hashable {
    public static func == (lhs: Course, rhs: Course) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
