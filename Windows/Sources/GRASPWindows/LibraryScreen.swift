import Foundation
import GRASPCore
import SwiftCrossUI

/// The Library page, after the Mac's `LibraryView`: everything that acts on
/// the whole collection rather than one course. A header with the course
/// and card counts, the notes folder card (the page's one yellow button,
/// Import folder), every course by time frame, two "hidden" tiles that open
/// their lists, and the library-wide checks. These used to sit in Settings.
struct LibraryScreen: View {
    let library: Library
    @Environment(\.chooseFile) var chooseFile
    /// Cards per course, and per course still to be checked for off-topic
    /// text. Read off the main thread when the page opens and after changes.
    @State var counts = CourseCounts()
    @State var showing: Panel?
    @State var duplicateGroups: [CardAI.DuplicateGroup] = []
    /// Only right after a duplicate scan that found nothing.
    @State var foundNoDuplicates = false

    enum Panel { case archived, excluded, duplicates, chooseCourses }

    struct CourseCounts: Equatable {
        var all: [String: Int] = [:]
        var unchecked: [String: Int] = [:]
    }

    private static let sidePadding = 40.0
    private static let maxWidth = 1180.0
    private static let gap = 16.0

    private var settings: AppSettings { library.settings }

    var body: some View {
        let groups = courseGroups
        GeometryReader { proxy in
            let available = PaneWidth.width(proxy.size.width)
            let width = min(Self.maxWidth, max(320, available - 2 * Self.sidePadding))
            ScrollView {
                VStack(alignment: .leading, spacing: Int(Self.gap)) {
                    header(groups: groups).padding(.bottom, 8)
                    vaultCard(width: width)
                    coursesCard(groups: groups, width: width)
                    hiddenTiles(width: width)
                    checksCard(width: width)
                }
                .frame(width: width, alignment: .leading)
                .padding(.leading, Int(Self.sidePadding))
                .padding(.top, 32)
                .padding(.bottom, 48)
            }
        }
        .watch(library.revision) { refreshCounts() }
        .quietTask { await loadCounts() }
        .sheet(isPresented: Binding(get: { showing != nil }, set: { if !$0, showing != nil { showing = nil } })) {
            switch showing {
            case .archived:
                LibraryListSheet(
                    title: "Archived courses",
                    message: "Hidden from the sidebar and Home. Their notes and cards are untouched.",
                    emptyTitle: "No archived courses",
                    emptyDetail: "Courses you archive from a course's \u{2022}\u{2022}\u{2022} menu appear here.",
                    rows: library.archivedCourses.map { course in
                        LibraryListSheet.Row(id: course.id, title: course.name, detail: course.code, actionTitle: "Unarchive") {
                            library.unarchiveCourse(course.id)
                        }
                    },
                    close: { showing = nil })
            case .excluded:
                LibraryListSheet(
                    title: "Excluded folders",
                    message: "Skipped on your next import. Adding files back to one of these folders includes it again on its own.",
                    emptyTitle: "No excluded folders",
                    emptyDetail: "Deleting a course that came from your notes folder excludes its folder here.",
                    rows: library.excludedFolders.map { path in
                        LibraryListSheet.Row(id: path, title: Self.folderName(path), detail: path, actionTitle: "Include again") {
                            library.includeFolder(path)
                        }
                    },
                    close: { showing = nil })
            case .duplicates:
                DuplicateReviewSheet(groups: duplicateGroups, merge: { library.mergeDuplicates($0) }) { showing = nil }
            case .chooseCourses:
                ChooseCoursesSheet(groups: groups, unchecked: counts.unchecked, start: { ids in
                    library.sweepCardsWithAI(inCourses: ids)
                }, close: { showing = nil })
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: - Header

    private func header(groups: [(title: String, courses: [Course])]) -> some View {
        let courseCount = groups.reduce(0) { $0 + $1.courses.count }
        let cardCount = counts.all.values.reduce(0, +)
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Library")
                Text("Everything, all at once")
                    .font(Font.system(size: 34, weight: .heavy))
                    .foregroundColor(GRASPColor.textPrimary)
                Text("Where your notes come from, what's hidden, and the checks that run across every course.")
                    .font(GRASPFont.body)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 32) {
                stat(courseCount, courseCount == 1 ? "course" : "courses")
                stat(cardCount, cardCount == 1 ? "card" : "cards")
            }
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value.formatted())
                .font(GRASPFont.numeral)
                .foregroundColor(GRASPColor.textPrimary)
                .fixedSize()
            Text(label)
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
                .fixedSize()
        }
    }

    // MARK: - Notes folder

    private func vaultCard(width: Double) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes folder")
                        .font(Font.system(size: 22, weight: .heavy))
                        .foregroundColor(GRASPColor.textPrimary)
                    Text(importLine)
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                }
                Spacer()
                GRASPButton(library.isImporting ? "Importing\u{2026}" : "\u{21BB}  Import folder", kind: .primary) {
                    importNow()
                }
                .disabled(library.isImporting || settings.notesLayout == .none || settings.notesFolder == nil)
            }
            if settings.notesLayout != .none {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Folder")
                    HStack(spacing: 8) {
                        Text(settings.notesFolder ?? "None chosen yet")
                            .font(Font.system(size: 12.5).monospaced())
                            .foregroundColor(settings.notesFolder == nil ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .edged(fill: GRASPColor.surfaceRaised, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
                        GRASPButton("Choose\u{2026}") { chooseFolder() }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Layout")
                SegmentedChoice(options: AppSettings.NotesLayout.allCases, selection: settings.notesLayout,
                                label: \.title) { settings.notesLayout = $0 }
                Text(layoutHelp)
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
                if settings.notesLayout == .automatic || settings.notesLayout == .folders {
                    fieldLabel("Time frame for new courses (optional)").padding(.top, 6)
                    TextField("Fall 2026", text: Binding(get: { settings.notesTimeframe },
                                                         set: { if $0 != settings.notesTimeframe { settings.notesTimeframe = $0 } }))
                        .frame(width: 260.0)
                }
            }
            if settings.notesLayout != .none {
                Text("GRASP only reads from this folder. It never writes to it.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
        }
        .card(padding: 24, width: width)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Font.system(size: 12.5, weight: .semibold))
            .foregroundColor(GRASPColor.textSecondary)
    }

    private var importLine: String {
        if library.isImporting { return "Reading the folder\u{2026}" }
        guard let summary = library.lastImportSummary else {
            return library.status ?? "Scan the folder for new or changed notes."
        }
        var text = "Last import: \(summary.filesImportedOrUpdated) updated, \(summary.cardsCreated) cards created"
        if summary.duplicatesSkipped > 0 { text += ", \(summary.duplicatesSkipped) duplicates skipped" }
        return text
    }

    private var layoutHelp: String {
        switch settings.notesLayout {
        case .automatic: return "A folder with a College folder inside is read as a vault. Any other folder is read as courses."
        case .vault: return "Reads College\\<Semester>\\<Course> the way the Obsidian vault is laid out."
        case .folders: return "Each folder inside this one becomes a course, named after the folder, with every note, PDF, Word file, slide, notebook and picture below it. A time frame, if you type one, files them under that term."
        case .none: return "GRASP doesn't read any folder. You add each document yourself: make a course, then use Add Files on it. Nothing is picked up from your disk unless you choose it."
        }
    }

    private func chooseFolder() {
        Task {
            guard let folder = await chooseFile(
                title: "Choose your notes folder", defaultButtonLabel: "Choose",
                allowSelectingFiles: false, allowSelectingDirectories: true
            ) else { return }
            settings.notesFolder = folder.path
        }
    }

    private func importNow() {
        guard let path = settings.notesFolder else { return }
        Task { await library.importVault(at: URL(fileURLWithPath: path, isDirectory: true)) }
    }

    // MARK: - Courses

    /// The sidebar's groups in its order, then every past term.
    private var courseGroups: [(title: String, courses: [Course])] {
        let groups = library.sidebarGroups
        return (groups.current + groups.past).filter { !$0.courses.isEmpty }
    }

    private func coursesCard(groups: [(title: String, courses: [Course])], width: Double) -> some View {
        let total = groups.reduce(0) { $0 + $1.courses.count }
        let inner = width - 50
        let columns = max(1, Int((inner + 12) / (230 + 12)))
        let tileWidth = ((inner - Double(columns - 1) * 12) / Double(columns)).rounded(.down)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                SectionLabel("Courses")
                Spacer()
                Text("\(total)").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
            }
            if groups.isEmpty {
                Text("No courses yet. Import your notes folder to bring them in.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .font(Font.system(size: 15, weight: .semibold))
                            .foregroundColor(GRASPColor.textPrimary)
                            .fixedSize()
                        Text("\(group.courses.count)")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.textTertiary)
                            .fixedSize()
                        HairlineRule()
                    }
                    let sorted = group.courses.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    let rows = stride(from: 0, to: sorted.count, by: columns).map { Array(sorted[$0..<min($0 + columns, sorted.count)]) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row, id: \.id) { course in
                                CourseTile(course: course, cards: counts.all[course.id] ?? 0, width: tileWidth)
                            }
                        }
                    }
                }
            }
        }
        .card(padding: 24, width: width)
    }

    // MARK: - Hidden

    private func hiddenTiles(width: Double) -> some View {
        let tileWidth = ((width - Self.gap) / 2).rounded(.down)
        return HStack(alignment: .top, spacing: Int(Self.gap)) {
            HiddenTile(title: "Archived courses", count: library.archivedCourses.count,
                       detail: "Hidden from the sidebar and Home. Notes and cards are untouched.",
                       width: tileWidth) { showing = .archived }
            HiddenTile(title: "Excluded folders", count: library.excludedFolders.count,
                       detail: "Skipped on every import until you bring them back.",
                       width: tileWidth) { showing = .excluded }
        }
    }

    // MARK: - Checks

    private func checksCard(width: Double) -> some View {
        let job = library.cardJob(forCourse: nil)
        let running = job.map { !$0.isFinished } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Check the whole library").padding(.bottom, 16)
            checkRow(title: "Duplicate cards",
                     detail: "Near-identical cards across every course, not just within one. Nothing is removed on its own: you review each group and pick which card stays, or delete the group.") {
                HStack(spacing: 8) {
                    if foundNoDuplicates {
                        Text("\u{2713} None found")
                            .font(GRASPFont.meta)
                            .foregroundColor(GRASPColor.success)
                            .fixedSize()
                    }
                    GRASPButton("Scan for duplicates") { scanForDuplicates() }
                }
            }
            HairlineRule().padding(.vertical, 16)
            checkRow(title: "Off-topic cards", ai: true,
                     detail: "Checks each card against its own note. A definition that reads like assignment instructions, or a vague fragment, is rewritten from the note or removed. Every rewrite can be reverted from the card.") {
                HStack(spacing: 8) {
                    GRASPButton("Choose courses\u{2026}") { showing = .chooseCourses }.disabled(running)
                    GRASPButton("Check all cards", ai: true) { library.sweepAllCardsWithAI() }.disabled(running)
                }
            }
            if let job {
                CardJobStrip(job: job) { library.dismissCardJob(forCourse: nil) }
                    .cornerRadius(GRASPRadius.inner)
                    .padding(.top, 12)
            }
        }
        .card(padding: 24, width: width)
    }

    private func checkRow<Trailing: View>(title: String, ai: Bool = false, detail: String,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if ai { AIGlyph(size: 13) }
                    Text(title)
                        .font(Font.system(size: 15, weight: .semibold))
                        .foregroundColor(GRASPColor.textPrimary)
                }
                Text(detail)
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            .frame(maxWidth: 520.0, alignment: .leading)
            Spacer()
            trailing()
        }
    }

    private func scanForDuplicates() {
        let groups = library.duplicateGroupsAcrossAllCourses()
        if groups.isEmpty {
            if !foundNoDuplicates { foundNoDuplicates = true }
        } else {
            foundNoDuplicates = false
            duplicateGroups = groups
            showing = .duplicates
        }
    }

    // MARK: - Counts

    private func refreshCounts() {
        Task { await loadCounts() }
    }

    private func loadCounts() async {
        let database = library.database
        let fresh = CourseCounts(all: await CardAI.cardCountsByCourse(database: database),
                                 unchecked: await CardAI.cardCountsByCourse(unchecked: true, database: database))
        if fresh != counts { counts = fresh }
    }

    private static func folderName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }
}

/// One course in the Library's list: its colour, name, code and card count.
private struct CourseTile: View {
    let course: Course
    let cards: Int
    let width: Double

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(course.colorHex.map { Color(hex: $0) } ?? GRASPColor.textTertiary)
                .frame(width: 10.0, height: 10.0)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                // A word joiner inside "C++": WinUI wraps between the pluses.
                Text(course.name.replacingOccurrences(of: "++", with: "+\u{2060}+"))
                    .font(Font.system(size: 14, weight: .semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                    .lineLimit(2)
                if let code = course.code, !code.isEmpty {
                    Text(code).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary).lineLimit(1)
                }
                Text("\(cards) \(cards == 1 ? "card" : "cards")")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textSecondary)
            }
            Spacer()
        }
        .frame(width: width - 34, alignment: .topLeading)
        .frame(minHeight: 52)
        .padding(16)
        .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
    }
}

/// One of the two "what's hidden" tiles: the count large, its name, a line
/// of explanation and an arrow; the whole tile opens its list.
private struct HiddenTile: View {
    let title: String
    let count: Int
    let detail: String
    let width: Double
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                Text("\(count)")
                    .font(Font.system(size: 40, weight: .heavy))
                    .foregroundColor(count > 0 ? GRASPColor.textPrimary : GRASPColor.textTertiary)
                    .fixedSize()
                Text(title)
                    .font(Font.system(size: 14, weight: .semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                    .fixedSize()
                    .padding(.bottom, 8)
                Spacer()
                Text("\u{2192}")
                    .font(Font.system(size: 13, weight: .semibold))
                    .foregroundColor(GRASPColor.textTertiary)
                    .padding(.bottom, 10)
            }
            Text(detail)
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
        }
        .card(padding: 22, width: width)
        .onTapGesture(perform: open)
    }
}

/// The Mac's `LibraryListSheet`: a list with one action per row, and Done.
private struct LibraryListSheet: View {
    struct Row {
        let id: String
        let title: String
        let detail: String?
        let actionTitle: String
        let action: () -> Void
    }

    let title: String
    let message: String
    let emptyTitle: String
    let emptyDetail: String
    let rows: [Row]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Library")
            Text(title)
                .font(Font.system(size: 22, weight: .heavy))
                .foregroundColor(GRASPColor.textPrimary)
            Text(message)
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Text(emptyTitle)
                        .font(Font.system(size: 14, weight: .semibold))
                        .foregroundColor(GRASPColor.textSecondary)
                    Text(emptyDetail)
                        .font(GRASPFont.meta)
                        .foregroundColor(GRASPColor.textTertiary)
                }
                .frame(width: 450.0)
                .padding(.vertical, 36)
                .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { HairlineRule() }
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .font(GRASPFont.rowTitle)
                                        .foregroundColor(GRASPColor.textPrimary)
                                    if let detail = row.detail {
                                        Text(detail)
                                            .font(GRASPFont.meta)
                                            .foregroundColor(GRASPColor.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                GRASPButton(row.actionTitle) { row.action() }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(width: 452.0, height: min(300.0, Double(rows.count) * 50 + 8))
                .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
            }
            HStack(spacing: 8) {
                Spacer()
                GRASPButton("Done", kind: .primary) { close() }
            }
            .returnConfirms { close() }
        }
        .padding(24)
        .frame(width: 500.0)
        .background(GRASPColor.canvas)
    }
}

/// Pick the courses the off-topic check looks at. Starts with nothing
/// ticked: checking everything is slow.
private struct ChooseCoursesSheet: View {
    let groups: [(title: String, courses: [Course])]
    let unchecked: [String: Int]
    let start: (Set<String>) -> Void
    let close: () -> Void
    @State var chosen: Set<String> = []

    var body: some View {
        let total = chosen.reduce(0) { $0 + (unchecked[$1] ?? 0) }
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Library")
            HStack(spacing: 8) {
                AIGlyph(size: 16)
                Text("Check courses")
                    .font(Font.system(size: 22, weight: .heavy))
                    .foregroundColor(GRASPColor.textPrimary)
            }
            Text("Each card in the courses you tick is checked against its own note. One that reads like assignment text is rewritten from the note or removed, and every change is listed afterwards.")
                .font(GRASPFont.meta)
                .foregroundColor(GRASPColor.textTertiary)
            HStack(spacing: 8) {
                GRASPButton("All") {
                    chosen = Set(groups.flatMap(\.courses).filter { (unchecked[$0.id] ?? 0) > 0 }.map(\.id))
                }
                GRASPButton("None") { chosen = [] }
                Spacer()
                Text("\(total) \(total == 1 ? "card" : "cards")")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.title) { group in
                        SectionLabel(group.title).padding(.top, 14).padding(.bottom, 4)
                        ForEach(group.courses, id: \.id) { course in
                            let count = unchecked[course.id] ?? 0
                            let isChosen = chosen.contains(course.id)
                            HStack(spacing: 10) {
                                Text(isChosen ? "\u{2713}" : " ")
                                    .font(Font.system(size: 12, weight: .bold))
                                    .foregroundColor(GRASPColor.ink)
                                    .frame(width: 18.0, height: 18.0)
                                    .background(isChosen ? GRASPColor.brand : GRASPColor.hairlineStrong)
                                    .cornerRadius(5)
                                Circle().fill(course.colorHex.map { Color(hex: $0) } ?? GRASPColor.textTertiary)
                                    .frame(width: 8.0, height: 8.0)
                                Text(course.name)
                                    .font(GRASPFont.rowTitle)
                                    .foregroundColor(count == 0 ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text(count == 0 ? "nothing to check" : "\(count)")
                                    .font(GRASPFont.meta)
                                    .foregroundColor(GRASPColor.textTertiary)
                                    .fixedSize()
                            }
                            .padding(.vertical, 8)
                            .onTapGesture {
                                guard count > 0 else { return }
                                if isChosen { chosen.remove(course.id) } else { chosen.insert(course.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(width: 472.0, height: 320.0)
            .edged(fill: GRASPColor.surface, edge: GRASPColor.hairline, radius: GRASPRadius.inner)
            HStack(spacing: 8) {
                Spacer()
                GRASPButton("Cancel") { close() }
                GRASPButton(chosen.isEmpty ? "Check" : "Check \(chosen.count) \(chosen.count == 1 ? "course" : "courses")",
                            kind: .primary) {
                    start(chosen)
                    close()
                }
                .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520.0)
        .background(GRASPColor.canvas)
    }
}
