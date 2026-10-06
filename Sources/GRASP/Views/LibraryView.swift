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
    private var sweepActivity: AIActivity? { store.aiJob(AppStore.sweepJobKey)?.activity }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Vault") {
                HStack {
                    Button {
                        Task { await store.runImport() }
                    } label: {
                        if store.isImporting {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Importing…") }
                        } else {
                            Label("Import Vault", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(store.isImporting)
                    Text(importSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vault Path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("", text: $store.vaultPath)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { chooseVault() }
                    }
                }
                Text("GRASP only reads from this folder -- it never writes to your Obsidian vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hidden") {
                SettingsManagementRow(
                    title: "Archived Courses", count: store.archivedCourses.count
                ) { showingArchivedCourses = true }
                SettingsManagementRow(
                    title: "Excluded Folders", count: store.excludedFolders.count
                ) { showingExcludedFolders = true }
            }

            Section("Check the Whole Library") {
                HStack {
                    Button("Scan All Courses for Duplicates…") { scanForDuplicatesAcrossAllCourses() }
                    if duplicateScanFoundNone {
                        Text("No duplicates found").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Looks for near-identical cards across every course, not just within one. Nothing is removed automatically: you review each group and pick which card survives, or delete the whole group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let sweepActivity {
                    AIProgressStrip(
                        activity: sweepActivity,
                        onStop: { store.stopAIJob(AppStore.sweepJobKey) },
                        stopHelp: "Stops now. Cards already checked keep their changes; the rest are left as they are.",
                        isInline: true
                    )
                } else {
                    Button("Check All Cards for Off-Topic Content…") { sweepAllCardsForContext() }
                }
                Text("Goes card by card against its own source note: a definition that reads like assignment instructions or a vague fragment is rewritten from the note's text, or removed if the note doesn't support one. Every change is listed afterwards and can be undone from the card's \"AI Refined\" badge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let warning = AIQuotaEstimate.warning(
                    needed: AIQuotaEstimate.contextCheckRequests(cards: store.deckCounts.values.reduce(0) { $0 + $1.cardCount }),
                    mode: store.aiMode
                ), store.hasCloudKey {
                    Label(warning, systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Library")
        .background(GRASPColor.canvas)
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
                    title: "Off-Topic Card Check Complete",
                    leadText: contextSweepResult.isEmpty
                        ? "Every card checked out fine -- nothing looked like assignment text or an off-topic fragment. (If no AI model is set up, nothing was checked at all -- see Settings → AI.)"
                        : nil,
                    sections: contextSweepSections(contextSweepResult)
                )
            }
        }
    }

    private var importSummaryText: String {
        guard let summary = store.lastImportSummary else { return "Scan the vault for new or changed notes." }
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

struct SettingsManagementRow: View {
    let title: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

/// Every course `setCourseArchived` has hidden, with a one-click way back.
/// The only place an archived course is still visible at all -- neither the
/// sidebar nor the dashboard shows it, by design.
struct ArchivedCoursesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Archived Courses").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if store.archivedCourses.isEmpty {
                ContentUnavailableView(
                    "No Archived Courses", systemImage: "archivebox",
                    description: Text("Courses you archive from the sidebar or dashboard appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.archivedCourses) { course in
                    HStack {
                        Text(course.name)
                        Spacer(minLength: 8)
                        Button("Unarchive") {
                            try? store.setCourseArchived(course.id, archived: false)
                        }
                    }
                }
                Text("Hidden from the sidebar and dashboard, but their notes and cards are untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .frame(width: 440, height: 380)
    }
}

/// Every vault folder `AppStore.removeCourseAndExclude` has permanently
/// skipped, with a one-click way back -- the same reversal that also
/// happens automatically the moment matching files are added back to a
/// course by hand (see `VaultScanner.importPaths`).
struct ExcludedFoldersSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Excluded Folders").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if store.excludedFolders.isEmpty {
                ContentUnavailableView(
                    "No Excluded Folders", systemImage: "folder.badge.minus",
                    description: Text("Choosing \"Delete\" on a vault-backed course excludes its folder here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.excludedFolders, id: \.self) { path in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button("Re-include") { try? store.includeFolder(path) }
                    }
                }
                Text("Skipped entirely on your next vault import. Adding files back to one of these folders re-includes it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .frame(width: 480, height: 380)
    }
}
