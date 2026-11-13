import SwiftUI
import AppKit
import GRASPCore

/// The Library page: everything that acts on the whole collection of notes
/// and cards rather than on one course or deck -- importing the vault,
/// where it lives, what's hidden from it, and the two library-wide checks.
/// These used to be spread across three Settings tabs, four clicks deep.
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var showingArchivedCourses = false
    @State private var showingExcludedFolders = false
    @State private var showingDuplicateReview = false
    @State private var duplicateGroups: [AppStore.DuplicateGroup] = []
    /// Only meaningful right after a scan that found nothing -- a scan
    /// that found groups opens the review sheet instead.
    @State private var duplicateScanFoundNone = false
    @State private var contextSweepResult: AppStore.ContextCheckSummary?
    @State private var choosingCourses = false
    @State private var showingLayoutInfo = false
    @State private var cardCounts: (all: [String: Int], unchecked: [String: Int]) = ([:], [:])
    private var sweepActivity: AIActivity? { store.aiJob(AppStore.sweepJobKey)?.activity }

    private var totalCards: Int { store.deckCounts.values.reduce(0) { $0 + $1.cardCount } }
    private var courseCount: Int { store.coursesBySemester.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GRASPSpace.l) {
                header
                    .padding(.bottom, GRASPSpace.s)
                vaultCard
                    .revealOnAppear(index: 0)
                coursesCard
                    .revealOnAppear(index: 0)
                HStack(alignment: .top, spacing: GRASPSpace.l) {
                    LibraryHiddenTile(
                        icon: "archivebox", title: "Archived courses", count: store.archivedCourses.count,
                        detail: "Hidden from the sidebar and Home. Notes and cards are untouched."
                    ) { showingArchivedCourses = true }
                    LibraryHiddenTile(
                        icon: "folder.badge.minus", title: "Excluded folders", count: store.excludedFolders.count,
                        detail: "Skipped on every vault import until you bring them back."
                    ) { showingExcludedFolders = true }
                }
                .fixedSize(horizontal: false, vertical: true)
                .revealOnAppear(index: 1)
                checksCard
                    .revealOnAppear(index: 2)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 48)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GRASPColor.canvas)
        .navigationTitle("Library")
        .task(id: store.revision) { cardCounts = await store.courseCardCounts() }
        .sheet(isPresented: $showingLayoutInfo) { FolderLayoutInfoSheet(starting: store.notesLayout) }
        .sheet(isPresented: $choosingCourses) {
            OffTopicCoursesSheet(unchecked: cardCounts.unchecked) { ids in sweepCardsForContext(inCourses: ids) }
        }
        .sheet(isPresented: $showingArchivedCourses) { ArchivedCoursesSheet() }
        .sheet(isPresented: $showingExcludedFolders) { ExcludedFoldersSheet() }
        .sheet(isPresented: $showingDuplicateReview) {
            DuplicateReviewSheet(groups: duplicateGroups) { merges in
                try? store.mergeDuplicates(merges)
            }
        }
        .sheet(isPresented: Binding(get: { contextSweepResult != nil }, set: { if !$0 { contextSweepResult = nil } })) {
            if let contextSweepResult {
                ResultSheet(
                    icon: "checkmark.shield",
                    title: "Off-topic check complete",
                    leadText: contextSweepResult.isEmpty
                        ? "Every card checked out fine. Nothing looked like assignment text or an off-topic fragment. (If no AI model is set up, nothing was checked at all. See Settings → AI.)"
                        : nil,
                    sections: contextSweepSections(contextSweepResult)
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: GRASPSpace.l) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Library")
                Text("Everything, all at once")
                    .font(.graspDisplay(34))
                    .tracking(-0.8)
                    .foregroundStyle(GRASPColor.textPrimary)
                Text("Where your notes come from, what's hidden, and the checks that run across every course.")
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer(minLength: GRASPSpace.l)
            HStack(spacing: GRASPSpace.xl) {
                LibraryStat(value: courseCount, label: courseCount == 1 ? "course" : "courses")
                LibraryStat(value: totalCards, label: totalCards == 1 ? "card" : "cards")
            }
        }
    }

    // MARK: - Vault

    private var vaultCard: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: GRASPSpace.l) {
            HStack(alignment: .top, spacing: GRASPSpace.m) {
                PopupIconTile(systemImage: "books.vertical")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes folder")
                        .font(.graspDisplay(22))
                        .tracking(-0.4)
                        .foregroundStyle(GRASPColor.textPrimary)
                    Text(importSummaryText)
                        .graspType(.meta)
                        .monospacedDigit()
                        .foregroundStyle(GRASPColor.textTertiary)
                }
                Spacer(minLength: GRASPSpace.m)
                Button {
                    Task { await store.runImport() }
                } label: {
                    HStack(spacing: 7) {
                        if store.isImporting {
                            ProgressView().controlSize(.small)
                            Text("Importing…")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.graspUI(size: 12, weight: .semibold))
                            Text("Import folder")
                        }
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(GRASPProminentButton())
                .disabled(store.isImporting || store.notesLayout == .none)
                .help(store.notesLayout == .none ? "Folder reading is off. Add files to a course by hand" : "")
            }

            if store.notesLayout != .none {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Folder")
                HStack(spacing: GRASPSpace.s) {
                    FieldChrome {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.graspUI(size: 12))
                                .foregroundStyle(GRASPColor.textTertiary)
                            TextField("", text: $store.vaultPath)
                                .font(.graspMono(12.5))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Button("Choose…") { chooseVault() }
                        .buttonStyle(GRASPQuietButton())
                }
            }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    FieldLabel("Layout")
                    Button { showingLayoutInfo = true } label: {
                        Image(systemName: "info.circle")
                            .font(.graspUI(size: 13))
                            .foregroundStyle(GRASPColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("How GRASP reads your folder")
                    .accessibilityLabel("How GRASP reads your folder")
                }
                GRASPSegmented(selection: $store.notesLayout,
                               options: AppStore.NotesLayout.allCases.map { ($0, $0.title) })
                Text(layoutHelp)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.notesLayout == .automatic || store.notesLayout == .folders {
                    FieldLabel("Time frame for new courses (optional)").padding(.top, 6)
                    FieldChrome {
                        TextField("Fall 2026", text: $store.notesTimeframe)
                            .font(.graspUI(size: 13))
                    }
                    .frame(maxWidth: 260)
                }
            }

            if store.notesLayout != .none {
            HStack(spacing: 6) {
                Image(systemName: "lock")
                    .font(.graspUI(size: 10, weight: .semibold))
                Text("GRASP only reads from this folder. It never writes to it.")
            }
            .graspType(.meta)
            .foregroundStyle(GRASPColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .graspCard(padding: 24)
    }

    // MARK: - Courses

    /// Every course as a card, under the vault, grouped by time frame in the sidebar's order
    /// (newest term first, then No Timeline).
    private var coursesCard: some View {
        let groups = store.libraryCourseGroups()
        let total = groups.reduce(0) { $0 + $1.courses.count }
        return VStack(alignment: .leading, spacing: GRASPSpace.l) {
            HStack {
                SectionLabel("Courses")
                Spacer()
                Text("\(total)").graspType(.meta).monospacedDigit().foregroundStyle(GRASPColor.textTertiary)
            }
            if groups.isEmpty {
                Text("No courses yet. Import the vault to bring them in.")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            }
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: GRASPSpace.m) {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .font(.graspUI(size: 15, weight: .semibold))
                            .foregroundStyle(GRASPColor.textPrimary)
                        Text("\(group.courses.count)")
                            .graspType(.meta).monospacedDigit().foregroundStyle(GRASPColor.textTertiary)
                        Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: GRASPSpace.m, alignment: .top)], spacing: GRASPSpace.m) {
                        ForEach(group.courses.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { course in
                            LibraryCourseCard(
                                course: course, color: store.courseColor(course),
                                subtitle: course.code ?? "", cards: cardCounts.all[course.id] ?? 0
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .graspCard(padding: 24)
    }

    // MARK: - Checks

    private var checksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Check the whole library")
                .padding(.bottom, GRASPSpace.l)

            LibraryCheckRow(
                icon: "square.on.square",
                title: "Duplicate cards",
                detail: "Near-identical cards across every course, not just within one. Nothing is removed on its own: you review each group and pick which card stays, or delete the group."
            ) {
                HStack(spacing: GRASPSpace.s) {
                    if duplicateScanFoundNone {
                        Label("None found", systemImage: "checkmark")
                            .graspType(.meta)
                            .foregroundStyle(GRASPColor.success)
                            .transition(.opacity)
                    }
                    Button("Scan for duplicates") { scanForDuplicatesAcrossAllCourses() }
                        .buttonStyle(GRASPQuietButton())
                }
            }

            Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                .padding(.vertical, GRASPSpace.l)

            LibraryCheckRow(
                icon: AIGlyph.symbol, isAI: true,
                title: "Off-topic cards",
                detail: "Checks each card against its own note. A definition that reads like assignment instructions, or a vague fragment, is rewritten from the note or removed. Every change is listed afterwards and can be undone from the card's \u{201C}AI Refined\u{201D} badge."
            ) {
                if sweepActivity == nil {
                    Button("Choose courses…") { choosingCourses = true }
                        .buttonStyle(GRASPQuietButton())
                        .help("Check only the courses you pick. Much faster than the whole library")
                    Button {
                        sweepAllCardsForContext()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: AIGlyph.symbol)
                                .font(.graspUI(size: 11, weight: .semibold))
                                .foregroundStyle(GRASPColor.accent)
                            Text("Check all cards")
                        }
                    }
                    .buttonStyle(GRASPQuietButton())
                }
            }
            if let sweepActivity {
                AIProgressStrip(
                    activity: sweepActivity,
                    onStop: { store.stopAIJob(AppStore.sweepJobKey) },
                    stopHelp: "Stops now. Cards already checked keep their changes; the rest are left as they are.",
                    isInline: true
                )
                .popupGroup(padding: 14)
                .padding(.top, GRASPSpace.m)
                .padding(.leading, 50)
            }
            if let warning = AIQuotaEstimate.warning(
                needed: AIQuotaEstimate.contextCheckRequests(cards: totalCards),
                mode: store.aiMode
            ), store.hasCloudKey {
                Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .padding(.top, GRASPSpace.s)
                    .padding(.leading, 50)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .graspCard(padding: 24)
        .animation(Motion.fade, value: duplicateScanFoundNone)
    }

    private var layoutHelp: String {
        switch store.notesLayout {
        case .automatic: return "A folder with a College folder inside is read as a vault. Any other folder is read as courses."
        case .vault: return "Reads College/<Semester>/<Course>/ the way the Obsidian vault is laid out."
        case .none: return "GRASP does not read any folder. You add each document yourself: make a course, then use Add Files or Folder… on it. Nothing is picked up from your disk unless you choose it."
        case .folders: return "Each folder inside this one becomes a course, named after the folder, with every note, PDF, Word, slide, notebook and picture below it. A time frame, if you type one, files them under that term."
        }
    }

    private var importSummaryText: String {
        guard let summary = store.lastImportSummary else { return "Scan the folder for new or changed notes." }
        var text = "Last import: \(summary.filesImportedOrUpdated) updated, \(summary.cardsCreated) cards created"
        if summary.duplicatesSkipped > 0 { text += ", \(summary.duplicatesSkipped) duplicates skipped" }
        return text
    }

    private func scanForDuplicatesAcrossAllCourses() {
        duplicateScanFoundNone = false
        let groups = (try? store.duplicateGroupsAcrossAllCourses()) ?? []
        if groups.isEmpty {
            duplicateScanFoundNone = true
        } else {
            duplicateGroups = groups
            showingDuplicateReview = true
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.vaultPath)
        if panel.runModal() == .OK, let url = panel.url {
            store.vaultPath = url.path
        }
    }

    private func contextSweepSections(_ result: AppStore.ContextCheckSummary) -> [ResultSheet.Section] {
        var sections: [ResultSheet.Section] = []
        if !result.refined.isEmpty {
            sections.append(.init(
                icon: "arrow.triangle.2.circlepath", tint: GRASPColor.success, title: "Rewrote",
                items: result.refined.map { "\($0.front) (\($0.courseName))" }
            ))
        }
        if !result.removed.isEmpty {
            sections.append(.init(
                icon: "trash", tint: GRASPColor.rejected, title: "Removed",
                items: result.removed.map { "\($0.front) (\($0.courseName))" }
            ))
        }
        return sections
    }

    private func sweepCardsForContext(inCourses ids: Set<String>) {
        let run = AIActivity(headline: ids.count == 1 ? "Checking one course against its notes" : "Checking \(ids.count) courses against their notes")
        store.runAIJob(AppStore.sweepJobKey, activity: run) { [store] run in
            let result = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await store.sweepCardsForContext(inCourses: ids)
            }
            if !(run.stopRequested && result.isEmpty) { contextSweepResult = result }
        }
    }

    private func sweepAllCardsForContext() {
        let run = AIActivity(headline: "Checking every card against its note")
        store.runAIJob(AppStore.sweepJobKey, activity: run) { [store] run in
            let result = await AIProgress.$current.withValue(run.reporter(forUnit: 0)) {
                await store.sweepAllCardsForContext()
            }
            if !(run.stopRequested && result.isEmpty) { contextSweepResult = result }
        }
    }
}

/// A big count over a small word, for the Library header.
private struct LibraryStat: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(value)")
                .font(.graspDisplay(30))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .foregroundStyle(GRASPColor.textPrimary)
            Text(label)
                .graspType(.meta)
                .foregroundStyle(GRASPColor.textTertiary)
        }
    }
}

/// One of the two "what's hidden" cards: an icon, the count large, a line
/// of explanation; the whole card opens its list. Lifts a little on hover.
private struct LibraryHiddenTile: View {
    let icon: String
    let title: String
    let count: Int
    let detail: String
    let action: () -> Void
    @State private var hovering = false
    private var reduceMotion: Bool { Motion.isReduced }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: GRASPSpace.m) {
                HStack {
                    Image(systemName: icon)
                        .font(.graspUI(size: 14, weight: .semibold))
                        .foregroundStyle(hovering ? GRASPColor.accent : GRASPColor.textSecondary)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.graspUI(size: 11, weight: .semibold))
                        .foregroundStyle(hovering ? GRASPColor.textPrimary : GRASPColor.textTertiary)
                        .offset(x: hovering && !reduceMotion ? 3 : 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(count)")
                        .font(.graspDisplay(40))
                        .monospacedDigit()
                        .foregroundStyle(count > 0 ? GRASPColor.textPrimary : GRASPColor.textTertiary)
                    Text(title)
                        .font(.graspUI(size: 14, weight: .semibold))
                        .foregroundStyle(GRASPColor.textPrimary)
                }
                Text(detail)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(22)
            .background(hovering ? GRASPColor.surfaceRaised : GRASPColor.surface,
                        in: RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GRASPRadius.card, style: .continuous)
                    .strokeBorder(hovering ? GRASPColor.hairlineStrong : GRASPColor.hairline, lineWidth: 1)
            )
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: GRASPRadius.card))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .accessibilityLabel("\(title), \(count)")
    }
}

/// A library-wide check: icon tile, name and what it does, its button on
/// the right.
private struct LibraryCheckRow<Trailing: View>: View {
    let icon: String
    var isAI = false
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: GRASPSpace.m) {
            PopupIconTile(systemImage: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.graspUI(size: 15, weight: .semibold))
                    .foregroundStyle(GRASPColor.textPrimary)
                Text(detail)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520, alignment: .leading)
            Spacer(minLength: GRASPSpace.l)
            trailing()
        }
    }
}

/// A row in one of the Library's lists: the name, a detail line, and its
/// one action on the right.
private struct LibraryListRow: View {
    let title: String
    var detail: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: GRASPSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.graspUI(size: 14, weight: .medium))
                    .foregroundStyle(GRASPColor.textPrimary)
                if let detail {
                    Text(detail)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: GRASPSpace.s)
            Button(actionTitle, action: action)
                .buttonStyle(GRASPQuietButton())
        }
        .padding(.vertical, 10)
    }
}

/// Shared shell for the Library's two "what's hidden" lists.
private struct LibraryListSheet<Item, ID: Hashable>: View {
    let title: String
    let message: String
    let icon: String
    let items: [Item]
    let id: KeyPath<Item, ID>
    let emptyTitle: String
    let emptyDetail: String
    let row: (Item) -> LibraryListRow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GRASPSheet(eyebrow: "Library", title: title, message: message, icon: icon, width: 500) {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Text(emptyTitle)
                        .font(.graspUI(size: 14, weight: .semibold))
                        .foregroundStyle(GRASPColor.textSecondary)
                    Text(emptyDetail)
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .popupGroup()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            if index > 0 { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                            row(item)
                        }
                    }
                    .padding(.horizontal, GRASPSpace.l)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous)
                        .strokeBorder(GRASPColor.hairline, lineWidth: 1)
                )
            }
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(GRASPProminentButton())
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Every course `setCourseArchived` has hidden, with a one-click way back.
/// The only place an archived course is still visible at all -- neither the
/// sidebar nor the dashboard shows it, by design.
struct ArchivedCoursesSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        LibraryListSheet(
            title: "Archived courses",
            message: "Hidden from the sidebar and Home, but their notes and cards are untouched.",
            icon: "archivebox", items: store.archivedCourses, id: \.id,
            emptyTitle: "No archived courses",
            emptyDetail: "Courses you archive from the sidebar appear here."
        ) { course in
            LibraryListRow(title: course.name, detail: course.code, actionTitle: "Unarchive") {
                try? store.setCourseArchived(course.id, archived: false)
            }
        }
    }
}

/// Every vault folder `AppStore.removeCourseAndExclude` has permanently
/// skipped, with a one-click way back -- the same reversal that also
/// happens automatically the moment matching files are added back to a
/// course by hand (see `VaultScanner.importPaths`).
struct ExcludedFoldersSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        LibraryListSheet(
            title: "Excluded folders",
            message: "Skipped on your next vault import. Adding files back to one of these folders includes it again on its own.",
            icon: "folder.badge.minus", items: store.excludedFolders, id: \.self,
            emptyTitle: "No excluded folders",
            emptyDetail: "Deleting a course that came from your vault excludes its folder here."
        ) { path in
            LibraryListRow(title: URL(fileURLWithPath: path).lastPathComponent, detail: path, actionTitle: "Re-include") {
                try? store.includeFolder(path)
            }
        }
    }
}

/// One course in the Library's list: its colour, name, where it sits and how many cards it has.
private struct LibraryCourseCard: View {
    let course: Course
    let color: Color
    let subtitle: String
    let cards: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(course.name)
                    .font(.graspUI(size: 14, weight: .semibold))
                    .foregroundStyle(GRASPColor.textPrimary)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).graspType(.meta).foregroundStyle(GRASPColor.textTertiary).lineLimit(1)
                }
                Text("\(cards) \(cards == 1 ? "card" : "cards")")
                    .graspType(.meta).monospacedDigit().foregroundStyle(GRASPColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
        .accessibilityElement(children: .combine)
    }
}

/// Pick the courses the off-topic check should look at. Checking everything is slow and uses a
/// lot of the AI quota, so this starts with nothing ticked.
struct OffTopicCoursesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Cards each course still has to be checked (ones already rewritten are not looked at again).
    let unchecked: [String: Int]
    let onStart: (Set<String>) -> Void
    @State private var chosen: Set<String> = []

    private var groups: [(title: String, courses: [Course])] {
        store.libraryCourseGroups().map { ($0.title, $0.courses.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
    }
    private var courses: [Course] { groups.flatMap(\.courses) }
    private var cardTotal: Int { chosen.reduce(0) { $0 + (unchecked[$1] ?? 0) } }

    var body: some View {
        GRASPSheet(
            eyebrow: "Library", title: "Check Courses",
            message: "Each card in the courses you tick is checked against its own note. One that reads like assignment text is rewritten from the note or removed, and every change is listed afterwards.",
            icon: AIGlyph.symbol, width: 520
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("All") { chosen = Set(courses.filter { (unchecked[$0.id] ?? 0) > 0 }.map(\.id)) }
                        .help("Every course that has cards to check")
                    Button("None") { chosen = [] }
                    Spacer()
                    Text("\(cardTotal) \(cardTotal == 1 ? "card" : "cards")").graspType(.meta).monospacedDigit().foregroundStyle(GRASPColor.textTertiary)
                }
                .buttonStyle(GRASPQuietButton())
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(groups, id: \.title) { group in
                            let ids = group.courses.filter { (unchecked[$0.id] ?? 0) > 0 }.map(\.id)
                            let allChosen = !ids.isEmpty && ids.allSatisfy(chosen.contains)
                            HStack {
                                SectionLabel(group.title)
                                Spacer()
                                if !ids.isEmpty {
                                    Button(allChosen ? "None" : "All") {
                                        if allChosen { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.graspUI(size: 12, weight: .semibold))
                                    .foregroundStyle(GRASPColor.textSecondary)
                                }
                            }
                            .padding(.top, 14).padding(.bottom, 4)
                            ForEach(Array(group.courses.enumerated()), id: \.element.id) { index, course in
                                if index > 0 { Rectangle().fill(GRASPColor.hairline).frame(height: 1) }
                                let count = unchecked[course.id] ?? 0
                                Button { toggle(course.id) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: chosen.contains(course.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(chosen.contains(course.id) ? GRASPColor.textPrimary : GRASPColor.textTertiary)
                                        CourseDot(color: store.courseColor(course), size: 8)
                                        Text(course.name).font(.graspUI(size: 14, weight: .medium)).foregroundStyle(GRASPColor.textPrimary).lineLimit(1)
                                        Spacer()
                                        Text(count == 0 ? "nothing to check" : "\(count)").graspType(.meta).monospacedDigit().foregroundStyle(GRASPColor.textTertiary)
                                    }
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(count == 0)
                            }
                        }
                    }
                    .padding(.horizontal, GRASPSpace.l)
                }
                .frame(maxHeight: 320)
                .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: GRASPRadius.inner, style: .continuous).strokeBorder(GRASPColor.hairline))
                if let warning = AIQuotaEstimate.warning(needed: AIQuotaEstimate.contextCheckRequests(cards: cardTotal), mode: store.aiMode),
                   store.hasCloudKey {
                    Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                        .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
            Button {
                onStart(chosen)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: AIGlyph.symbol).font(.graspUI(size: 11, weight: .semibold))
                    Text(chosen.isEmpty ? "Check" : "Check \(chosen.count) \(chosen.count == 1 ? "course" : "courses")")
                }
            }
            .buttonStyle(GRASPProminentButton())
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
    }

    private func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }
}

extension AppStore {
    /// Courses by time frame in the sidebar's own order: this term, other named timelines,
    /// courses with no timeline, then each past term.
    func libraryCourseGroups() -> [(title: String, courses: [Course])] {
        var groups: [(title: String, courses: [Course])] = []
        if let term = currentTerm { groups.append((term.name, courses(inSemester: term.id))) }
        for semester in nonTermSemesters { groups.append((semester.name, courses(inSemester: semester.id))) }
        if !unfiledCourses.isEmpty { groups.append(("No timeline", unfiledCourses)) }
        for term in pastTerms { groups.append((term.name, courses(inSemester: term.id))) }
        return groups.filter { !$0.courses.isEmpty }
    }
}
