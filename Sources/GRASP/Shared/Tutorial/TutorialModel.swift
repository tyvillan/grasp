import Foundation
import Observation
import CoreGraphics

/// The first-run tutorial: what it says, in what order, and where it is.
/// Pure state, no views and no database. The steps are data (`TutorialSteps`),
/// so the wording and the order can change without touching a screen.
///
/// The tutorial only navigates and highlights. It never writes to the library,
/// and the one thing it saves is its own "seen" flag (`TutorialSeenStore`).

/// A real control the tutorial can point at. Screens mark their control with
/// `.tutorialTarget(_:)`; the tutorial never draws a copy of it.
enum TutorialTarget: String, CaseIterable, Hashable, Sendable {
    /// Mac: the sidebar with Home, the courses and Library.
    case sidebar
    /// iPhone: the Courses tab in the bottom bar.
    case coursesTab
    /// Mac: the plus button that adds a course or uploads a document.
    case addCourseMenu
    /// iPhone: the Import Notes button on the Courses screen.
    case importNotes
    /// The Overview, Cards and Questions switch on a deck page.
    case deckTabs
    case studyButton
    case learnButton
    case testButton
    /// The Add menu on a deck page (Cards or Questions).
    case addMenu
    /// iPhone: the Settings tab in the bottom bar.
    case settingsTab

    /// Controls that only exist on a deck page. With no deck there is
    /// nothing to point at, so these steps become plain coach cards.
    var isOnDeckPage: Bool {
        switch self {
        case .deckTabs, .studyButton, .learnButton, .testButton, .addMenu: return true
        case .sidebar, .coursesTab, .addCourseMenu, .importNotes, .settingsTab: return false
        }
    }
}

/// A real tap the tutorial can wait for. Only navigation counts.
enum TutorialEvent: Hashable, Sendable {
    /// A tap on a deck page tab, by its name ("Cards", "Questions").
    case deckTab(String)
}

enum TutorialPlatform: Sendable {
    case mac, phone
}

struct TutorialStep: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    /// The real controls to highlight. The spotlight covers all of them.
    var targets: [TutorialTarget] = []
    /// Taps the step waits for, in order. Empty: the step has a Next button.
    var waitsFor: [TutorialEvent] = []
    /// What to say while waiting for each of those taps.
    var waitPrompts: [String] = []
    /// One line about AI, marked with the sparkle. Nothing else is.
    var aiLine: String?
    /// Said when the targets are not on screen (a first-time user has no
    /// course yet): a plain card with the icon below, and no waiting.
    var fallbackNote = "Once you add a course you'll see this."
    var symbol = "questionmark"
    /// The steps that need a deck page open behind them.
    var needsDeckPage: Bool { targets.contains { $0.isOnDeckPage } }
}

enum TutorialSteps {
    /// The core loop, in order. The wording differs only where the two apps
    /// do: the Mac has a sidebar, the iPhone a Courses tab.
    static func steps(for platform: TutorialPlatform) -> [TutorialStep] {
        let mac = platform == .mac
        return [
            TutorialStep(
                id: "welcome",
                title: "Welcome to GRASP",
                body: "Bring in your notes, and GRASP turns them into cards and questions. Then you study them. This takes about 2 minutes.",
                symbol: "graduationcap"),
            TutorialStep(
                id: "courses",
                title: "Your courses",
                body: mac
                    ? "Your courses live in the sidebar. Each one holds its notes, cards and questions. The plus button at the top right adds a new course."
                    : "Your courses live in the Courses tab. Each one holds its notes, cards and questions.",
                targets: mac ? [.sidebar] : [.coursesTab],
                fallbackNote: "The sidebar is hidden right now. Show it from the top bar to see your courses.",
                symbol: mac ? "sidebar.left" : "rectangle.stack"),
            TutorialStep(
                id: "notes",
                title: "Adding notes",
                body: mac
                    ? "This button adds a course or uploads a document into one. The tour only points at it. Nothing is imported."
                    : "This button imports notes or files into a course. The tour only points at it. Nothing is imported.",
                targets: mac ? [.addCourseMenu] : [.importNotes],
                symbol: mac ? "plus" : "square.and.arrow.down"),
            TutorialStep(
                id: "tabs",
                title: "Overview, Cards and Questions",
                body: "Cards are for remembering. Questions are for practicing like the exam. Overview summarizes the notes behind the deck.",
                targets: [.deckTabs],
                waitsFor: [.deckTab("Cards"), .deckTab("Questions")],
                waitPrompts: ["Tap Cards.", "Now tap Questions."],
                symbol: "rectangle.on.rectangle"),
            TutorialStep(
                id: "modes",
                title: "Study, Learn and Test",
                body: "Study reviews the cards that are due. Learn walks you through a deck in short rounds. Test quizzes you like an exam.",
                targets: [.studyButton, .learnButton, .testButton],
                symbol: "graduationcap.fill"),
            TutorialStep(
                id: "add",
                title: "Adding cards and questions",
                body: "The Add menu on Cards and Questions is where you write your own, read questions from a photo, or have them written for you.",
                targets: [.addMenu],
                symbol: "plus"),
            TutorialStep(
                id: "ai",
                title: "AI is optional",
                body: "Everything you just saw works without AI. You can write cards and questions yourself, and study as usual.",
                targets: mac ? [] : [.settingsTab],
                aiLine: "To have AI write cards and questions for you, open Settings, then AI.",
                symbol: "sparkles"),
            TutorialStep(
                id: "done",
                title: "You're set",
                body: "Replay this anytime in Settings.",
                symbol: "checkmark"),
        ]
    }
}

/// The one thing the tutorial saves: whether this profile has seen it.
/// It lives in the profile's own preferences (`AppStore.preferences`), so it
/// belongs to this device and this profile and is never synced. That is fine:
/// a second device you set up later should offer the tour again, and nothing
/// else depends on the flag.
struct TutorialSeenStore {
    static let key = "tutorialSeen"
    let defaults: UserDefaults
    var isSeen: Bool { defaults.bool(forKey: Self.key) }
    func markSeen() { defaults.set(true, forKey: Self.key) }
}

/// Where the tutorial is, and what it will do next.
@MainActor @Observable
final class TutorialFlow {
    let steps: [TutorialStep]
    @ObservationIgnored let seen: TutorialSeenStore

    private(set) var index = 0
    private(set) var isActive = false
    /// How many of the current step's taps have happened.
    private(set) var waitProgress = 0
    /// Bumps when a target moves while the tour is open, so the spotlight follows.
    private(set) var layoutRevision = 0
    /// The window, as the overlay last measured it.
    private(set) var viewport: CGRect = .zero

    @ObservationIgnored private var frames: [TutorialTarget: (owner: UUID, frame: CGRect)] = [:]
    /// Debug only: act as if no deck page exists (the empty library).
    @ObservationIgnored var ignoresDeckPage = false

    init(seen: TutorialSeenStore, platform: TutorialPlatform) {
        self.seen = seen
        self.steps = TutorialSteps.steps(for: platform)
    }

    // MARK: - Reading

    var current: TutorialStep { steps[min(index, steps.count - 1)] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }
    var progressLabel: String { "Step \(index + 1) of \(steps.count)" }
    /// Changes whenever the tour opens, closes or moves, for screens that
    /// need to navigate in response.
    var token: Int { isActive ? index : -1 }

    /// Where the current step's controls are, or nil when they are not on
    /// screen (and the step shows as a plain coach card instead).
    var spotlight: CGRect? {
        _ = layoutRevision
        let step = current
        guard !step.targets.isEmpty else { return nil }
        var union: CGRect?
        for target in step.targets {
            if ignoresDeckPage, target.isOnDeckPage { continue }
            guard let frame = frames[target]?.frame, isVisible(frame) else { continue }
            union = union.map { $0.union(frame) } ?? frame
        }
        return union
    }

    /// A step with controls to point at, none of which can be found.
    var isFallback: Bool { !current.targets.isEmpty && spotlight == nil }

    /// Whether the step is waiting for the person to tap something real.
    var isWaiting: Bool {
        !current.waitsFor.isEmpty && !isFallback && waitProgress < current.waitsFor.count
    }

    var waitPrompt: String? {
        guard isWaiting else { return nil }
        let prompts = current.waitPrompts
        return waitProgress < prompts.count ? prompts[waitProgress] : nil
    }

    private func isVisible(_ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        guard viewport.width > 0 else { return true }
        let overlap = frame.intersection(viewport)
        guard !overlap.isNull else { return false }
        return overlap.width * overlap.height >= frame.width * frame.height * 0.95
    }

    // MARK: - Whether to run

    /// A first-time user: has not seen the tour and has nothing in the library.
    static func shouldRunAutomatically(seen: Bool, libraryHasData: Bool, linkedToAccount: Bool) -> Bool {
        !seen && !libraryHasData && !linkedToAccount
    }

    /// Called when the app opens a profile. Runs the tour for a first-time
    /// user. Someone who already has courses or cards never sees it on its
    /// own, and is marked as having seen it. A profile signed in to an
    /// account is left alone: on a new device its library may simply not
    /// have synced yet, so empty does not mean new.
    func launchIfFirstTime(libraryHasData: Bool, linkedToAccount: Bool) {
        guard !seen.isSeen, !isActive else { return }
        if libraryHasData {
            seen.markSeen()
            return
        }
        if Self.shouldRunAutomatically(seen: false, libraryHasData: false, linkedToAccount: linkedToAccount) {
            start()
        }
    }

    // MARK: - Moving

    /// Starts from the first step. Always works, seen or not.
    func start(at step: Int = 0) {
        index = min(max(step, 0), steps.count - 1)
        waitProgress = 0
        isActive = true
    }

    func next() {
        guard isActive, !isWaiting else { return }
        if isLast { finish() } else { move(to: index + 1) }
    }

    func back() {
        guard isActive, !isFirst else { return }
        move(to: index - 1)
    }

    /// Ends the tour. Counts as seen.
    func skip() { close() }
    func finish() { close() }

    private func close() {
        seen.markSeen()
        isActive = false
        index = 0
        waitProgress = 0
    }

    private func move(to newIndex: Int) {
        index = newIndex
        waitProgress = 0
    }

    /// A real tap happened. Advances only when it is the one the step is
    /// waiting for, in order.
    func didTap(_ event: TutorialEvent) {
        guard isActive, isWaiting else { return }
        guard current.waitsFor[waitProgress] == event else { return }
        waitProgress += 1
        if waitProgress >= current.waitsFor.count, !isLast { move(to: index + 1) }
    }

    // MARK: - Target frames

    /// A marked control reports where it is. Each marked view has its own
    /// `owner`, so when a layout swaps one copy of a control for another (a
    /// narrower window), the old copy leaving cannot erase the new one's frame.
    func setFrame(_ frame: CGRect, for target: TutorialTarget, owner: UUID = TutorialFlow.sharedOwner) {
        if let existing = frames[target], existing.owner == owner, existing.frame == frame { return }
        frames[target] = (owner, frame)
        if isActive { layoutRevision &+= 1 }
    }

    func clearFrame(for target: TutorialTarget, owner: UUID = TutorialFlow.sharedOwner) {
        guard frames[target]?.owner == owner else { return }
        frames.removeValue(forKey: target)
        if isActive { layoutRevision &+= 1 }
    }

    static let sharedOwner = UUID()

    func setViewport(_ rect: CGRect) {
        guard viewport != rect else { return }
        viewport = rect
    }
}
