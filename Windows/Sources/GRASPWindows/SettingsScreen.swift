import Foundation
import GRASPCore
import SwiftCrossUI

/// Settings, after the Mac's General and Advanced tabs, limited to what
/// works on Windows so far: profile, account and sync, the daily goal,
/// calendar preferences, the notes folder, local AI status, hidden courses
/// and excluded folders. The Mac's focus timer, AI test questions and
/// duplicate/off-topic sweeps arrive with those features.
struct SettingsScreen: View {
    let library: Library
    @Environment(\.chooseFile) var chooseFile
    @State var profileName = ""
    @State var showingSignIn = false
    @State var confirmingSignOut = false
    @State var ollama: OllamaStatus = .checking

    enum OllamaStatus: Equatable {
        case checking
        case notDetected
        case running(models: [String])
    }

    private var settings: AppSettings { library.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(GRASPFont.display)
                    .foregroundColor(GRASPColor.textPrimary)
                    .padding(.bottom, 4)
                profileSection
                accountSection
                studyGoalSection
                calendarSection
                notesFolderSection
                localAISection
                hiddenCoursesSection
                excludedFoldersSection
                aboutSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 700.0)
        }
        .onAppear {
            profileName = library.profile.name
            checkOllama()
        }
        .sheet(isPresented: $showingSignIn) {
            SignInSheet(account: library.account) { showingSignIn = false }
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        SettingsCard("Profile") {
            HStack(spacing: 8) {
                TextField("Your name", text: $profileName)
                Button("Save") { library.renameProfile(to: profileName) }
                    .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty
                              || profileName == library.profile.name)
                    .fixedSize()
            }
            Caption("Used for the greeting on Home. Each profile keeps its own library and settings on this PC.")
        }
    }

    private var accountSection: some View {
        let account = library.account!
        return SettingsCard("Account & Sync") {
            if let email = account.email {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in as \(email)").font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                        Text(account.isSyncing ? "Syncing…" : (account.status ?? "Not synced yet"))
                            .font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary)
                    }
                    Spacer()
                    Button("Sync Now") { Task { await account.syncNow() } }
                        .disabled(account.isSyncing)
                        .fixedSize()
                    Button("Sign Out…") { confirmingSignOut = true }.fixedSize()
                }
                if confirmingSignOut {
                    HStack(spacing: 8) {
                        Caption("Your library stays on this PC as a local profile. It stops syncing, and your other devices keep their own copies.")
                        Spacer()
                        Button("Sign Out") {
                            confirmingSignOut = false
                            Task { await account.signOut() }
                        }
                        .fixedSize()
                        Button("Cancel") { confirmingSignOut = false }.fixedSize()
                    }
                }
                Caption("Syncs when GRASP opens, a few seconds after you change something, and every couple of minutes while it's open. Courses, decks, cards, study progress, calendar events and overviews all sync; your note files stay where they are.")
            } else {
                HStack(spacing: 8) {
                    Text(account.status ?? "This profile's library is only on this PC.")
                        .font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                    Spacer()
                    Button("Sign In…") { showingSignIn = true }.fixedSize()
                }
                Caption("Sign in with the same email as your Mac or iPhone to sync this PC with them.")
            }
        }
    }

    private var studyGoalSection: some View {
        SettingsCard("Study Goal") {
            HStack(spacing: 10) {
                Button("−") { settings.dailyGoal = max(0, settings.dailyGoal - 5) }
                    .disabled(settings.dailyGoal == 0)
                    .fixedSize()
                Text(settings.dailyGoal == 0 ? "No daily goal" : "\(settings.dailyGoal) cards a day")
                    .font(GRASPFont.rowTitle)
                    .foregroundColor(GRASPColor.textPrimary)
                    .frame(width: 130.0)
                Button("+") { settings.dailyGoal = min(500, settings.dailyGoal + 5) }
                    .disabled(settings.dailyGoal >= 500)
                    .fixedSize()
                Spacer()
            }
            Caption("Sets the progress bar on Home and what counts as a full day. Your study streak counts any day with at least one review, whatever the goal, so a light day still keeps it alive.")
        }
    }

    private var calendarSection: some View {
        SettingsCard("Calendar") {
            settingRow("Week starts on") {
                SegmentedChoice(options: [false, true], selection: settings.weekStartsOnMonday,
                                label: { $0 ? "Monday" : "Sunday" }) { settings.weekStartsOnMonday = $0 }
            }
            settingRow("Opens in") {
                SegmentedChoice(options: AppSettings.CalendarMode.allCases, selection: settings.calendarMode,
                                label: \.rawValue) { settings.calendarMode = $0 }
            }
            Caption("The calendar remembers the last view you picked, too.")
        }
    }

    private var notesFolderSection: some View {
        SettingsCard("Notes Folder") {
            HStack(spacing: 8) {
                Text(settings.notesFolder ?? "None chosen yet")
                    .font(GRASPFont.body)
                    .foregroundColor(settings.notesFolder == nil ? GRASPColor.textTertiary : GRASPColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button("Choose…") {
                    Task {
                        guard let folder = await chooseFile(
                            title: "Choose your notes folder", defaultButtonLabel: "Choose",
                            allowSelectingFiles: false, allowSelectingDirectories: true
                        ) else { return }
                        settings.notesFolder = folder.path
                    }
                }
                .fixedSize()
                Button("Import Now") {
                    guard let path = settings.notesFolder else { return }
                    Task { await library.importVault(at: URL(fileURLWithPath: path, isDirectory: true)) }
                }
                .disabled(settings.notesFolder == nil || library.isImporting)
                .fixedSize()
            }
            if library.isImporting {
                Caption("Importing…")
            } else if let status = library.status {
                Caption(status)
            }
            Caption("GRASP only reads from this folder; it never writes to your notes. It looks for College\\<semester>\\<course> folders inside it. PDFs and images aren't read on Windows yet.")
        }
    }

    private var localAISection: some View {
        SettingsCard("Local AI (Ollama)") {
            HStack(spacing: 8) {
                StatusPill(text: ollamaHeadline, isPositive: {
                    if case .running = ollama { return true } else { return false }
                }())
                Spacer()
                Button("Check Again") { checkOllama() }
                    .disabled(ollama == .checking)
                    .fixedSize()
            }
            switch ollama {
            case .checking:
                EmptyView()
            case .notDetected:
                Caption("GRASP couldn't reach a local Ollama server on this PC. Install Ollama for Windows from ollama.com and pull a model, e.g. \"ollama pull qwen3.5:9b\".")
            case .running(let models) where models.isEmpty:
                Caption("Connected, but no models are pulled yet. Run \"ollama pull qwen3.5:9b\" in a terminal.")
            case .running(let models):
                Caption("Models on this PC: \(models.joined(separator: ", ")).")
            }
            Caption("AI card refinement, lessons and test questions come to Windows later; this shows whether GRASP can see Ollama.")
        }
    }

    private var ollamaHeadline: String {
        switch ollama {
        case .checking: return "Checking…"
        case .notDetected: return "Ollama Not Detected"
        case .running: return "Ollama Running"
        }
    }

    private var hiddenCoursesSection: some View {
        SettingsCard("Hidden Courses") {
            if library.archivedCourses.isEmpty {
                Caption("Courses you archive (on any device) appear here.")
            } else {
                ForEach(library.archivedCourses, id: \.id) { course in
                    HStack(spacing: 8) {
                        Text(course.name).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
                        Spacer()
                        Button("Unarchive") { library.unarchiveCourse(course.id) }.fixedSize()
                    }
                }
                Caption("Hidden from the sidebar and Home, but their notes and cards are untouched.")
            }
        }
    }

    private var excludedFoldersSection: some View {
        SettingsCard("Excluded Folders") {
            if library.excludedFolders.isEmpty {
                Caption("Deleting a course that came from your notes folder excludes its folder here, so the next import doesn't bring it back.")
            } else {
                ForEach(library.excludedFolders, id: \.self) { path in
                    HStack(spacing: 8) {
                        Text(path).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary).lineLimit(1)
                        Spacer()
                        Button("Re-include") { library.includeFolder(path) }.fixedSize()
                    }
                }
                Caption("Skipped entirely on your next import. Adding files back to one of these folders re-includes it automatically.")
            }
        }
    }

    private var aboutSection: some View {
        SettingsCard("About") {
            Caption("GRASP for Windows (prototype). Library and log: \(library.libraryFolder.path)")
        }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).font(GRASPFont.body).foregroundColor(GRASPColor.textPrimary)
            Spacer()
            content()
        }
    }

    private func checkOllama() {
        ollama = .checking
        Task {
            let generator = OllamaGenerator()
            if await generator.isAvailable {
                ollama = .running(models: await generator.installedModels())
            } else {
                ollama = .notDetected
            }
        }
    }
}

/// A titled group of settings, the Windows stand-in for a grouped Form section.
struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GRASPColor.surface)
            .cornerRadius(10)
        }
    }
}

/// Small grey explanatory text under a setting.
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary)
    }
}

/// A coloured capsule for a two-state fact, as on the Mac.
struct StatusPill: View {
    let text: String
    let isPositive: Bool

    var body: some View {
        Text(text)
            .font(GRASPFont.meta)
            .foregroundColor(isPositive ? GRASPColor.success : GRASPColor.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isPositive ? GRASPColor.successSoft : GRASPColor.inset)
            .cornerRadius(10)
    }
}
