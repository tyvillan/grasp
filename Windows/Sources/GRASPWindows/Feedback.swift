import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import WinSDK
#endif

// Send feedback, after the Mac's `Sources/GRASP/Shared/Feedback/`.
//
// What leaves the PC is built only from what is in this file: strings,
// numbers and booleans the sheet hands in, and a few facts about this
// install. Nothing here imports or names anything from the library (notes,
// cards, questions, decks, courses) or from key storage.

/// What kind of feedback it is.
enum FeedbackType: String, CaseIterable, Sendable {
    case bug, confusing, idea, love

    var title: String {
        switch self {
        case .bug: return "Bug"
        case .confusing: return "Confusing"
        case .idea: return "Idea"
        case .love: return "Love it"
        }
    }
}

nonisolated enum FeedbackLimits {
    static let messageMax = 4000
    /// The counter shows from here.
    static let counterStart = 3600
    static let nameMax = 100
    static let emailMax = 254
    /// A screenshot is scaled to this long edge, then squeezed under the cap.
    static let screenshotLongEdge = 1600
    static let screenshotMaxBytes = 500_000
    /// Sends one install may make per day.
    static let sendsPerDay = 5
}

/// What the person filled in.
struct FeedbackDraft: Equatable {
    var type: FeedbackType?
    var rating: Int?
    var message = ""
    var anonymous = true
    var name = ""
    var email = ""
    /// A JPEG already scaled and capped (`FeedbackImage`). Never attached on its own.
    var screenshot: Data?

    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why it can't be sent yet, in a sentence, or nil.
    var problem: String? {
        if type == nil { return "Pick what kind of feedback this is." }
        if trimmedMessage.isEmpty { return "Write a message first." }
        if message.count > FeedbackLimits.messageMax { return "That message is too long. The limit is \(FeedbackLimits.messageMax) characters." }
        if let rating, !(1...5).contains(rating) { return "The rating is 1 to 5." }
        if !anonymous {
            if name.trimmingCharacters(in: .whitespaces).count > FeedbackLimits.nameMax { return "That name is too long." }
            let mail = email.trimmingCharacters(in: .whitespaces)
            if mail.count > FeedbackLimits.emailMax { return "That email is too long." }
            if !mail.isEmpty, !Self.looksLikeEmail(mail) { return "That email doesn't look right. You can also leave it empty." }
        }
        if let screenshot, screenshot.count > FeedbackLimits.screenshotMaxBytes { return "That screenshot is too big." }
        return nil
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ")
    }
}

/// The facts about this install that travel with feedback.
struct FeedbackContext: Equatable {
    var appVersion: String
    var build: String
    /// "windows" here ("mac" or "iphone" on the others).
    var platform: String
    var osVersion: String
    var deviceModel: String
    /// A fixed phrase such as "Deck > Questions". Never a name from the library.
    var screen: String
    /// "cloud", "local" or "off".
    var aiMode: String
    /// Random, made on this install, used only to limit duplicates.
    var installId: String

    /// The rows of "What gets sent", in the words a person would use.
    var disclosure: [(label: String, value: String)] {
        [
            ("App version", "\(appVersion) (build \(build))"),
            ("Platform", "Windows"),
            ("OS version", osVersion),
            ("Device", deviceModel),
            ("Screen you were on", screen),
            ("AI", aiMode == "cloud" ? "Cloud" : aiMode == "local" ? "Local" : "Off"),
            ("Install ID", installId),
        ]
    }
}

/// One feedback row, exactly as the `feedback` table takes it.
struct FeedbackPayload: Codable, Equatable {
    var id: String
    var type: String
    var rating: Int?
    var message: String
    var anonymous: Bool
    var name: String?
    var email: String?
    var screen: String
    var appVersion: String
    var build: String
    var platform: String
    var osVersion: String
    var deviceModel: String
    var aiMode: String
    var installId: String
    var screenshotPath: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, type, rating, message, anonymous, name, email, screen
        case appVersion = "app_version"
        case build, platform
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case aiMode = "ai_mode"
        case installId = "install_id"
        case screenshotPath = "screenshot_path"
    }

    /// Builds the row. Anonymous drops the name and email entirely.
    static func make(draft: FeedbackDraft, context: FeedbackContext, id: Foundation.UUID = Foundation.UUID()) -> FeedbackPayload {
        let key = id.uuidString.lowercased()
        func clean(_ text: String, max: Int) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value.prefix(max))
        }
        return FeedbackPayload(
            id: key,
            type: (draft.type ?? .idea).rawValue,
            rating: draft.rating.flatMap { (1...5).contains($0) ? $0 : nil },
            message: String(draft.trimmedMessage.prefix(FeedbackLimits.messageMax)),
            anonymous: draft.anonymous,
            name: draft.anonymous ? nil : clean(draft.name, max: FeedbackLimits.nameMax),
            email: draft.anonymous ? nil : clean(draft.email, max: FeedbackLimits.emailMax),
            screen: context.screen,
            appVersion: context.appVersion,
            build: context.build,
            platform: context.platform,
            osVersion: context.osVersion,
            deviceModel: context.deviceModel,
            aiMode: context.aiMode,
            installId: context.installId,
            screenshotPath: draft.screenshot == nil ? nil : "\(key).jpg"
        )
    }
}

/// The places feedback can be sent from, named in plain words. A fixed list,
/// so a course or deck name can never end up in what is sent.
enum FeedbackScreen: String {
    case home = "Home"
    case calendar = "Calendar"
    case studyGuides = "Study guides"
    case library = "Library"
    case course = "Course"
    case deckCards = "Deck > Cards"
    case deckOverview = "Deck > Overview"
    case deckQuestions = "Deck > Questions"
    case study = "Study"
    case learn = "Learn"
    case test = "Test"
    case settings = "Settings"
    case search = "Search"

    /// The last screen the person was on. Set by the screens as they change.
    nonisolated(unsafe) static var current: FeedbackScreen = .home

    /// During Study, Learn or a Test, when no ask may appear.
    static var isStudying: Bool { [.study, .learn, .test].contains(current) }
}

// MARK: - Transport

/// How feedback leaves the PC. The real one talks to Supabase; screenshot
/// and test runs use a stand-in, so nothing real is ever sent from them.
protocol FeedbackTransport: Sendable {
    func upload(screenshot: Data, path: String) async throws
    func insert(row: Data) async throws
}

enum FeedbackError: LocalizedError, Equatable {
    case rejected(status: Int)
    case temporary(status: Int)

    var errorDescription: String? {
        switch self {
        case .rejected: return "The feedback server didn't accept it."
        case .temporary: return "The feedback server is busy."
        }
    }
}

/// The Supabase project over plain HTTP with only the public (anon) key: no
/// sign-in, the `anon` role the table's insert-only policy is written for.
struct SupabaseFeedbackTransport: FeedbackTransport {
    let baseURL: URL
    let anonKey: String

    private func request(_ path: String, contentType: String, body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedbackError.temporary(status: 0) }
        switch http.statusCode {
        case 200..<300: return
        // The same id again: an earlier try got through. That is a success.
        case 409: return
        case 408, 429, 500..<600: throw FeedbackError.temporary(status: http.statusCode)
        default: throw FeedbackError.rejected(status: http.statusCode)
        }
    }

    /// `POST /storage/v1/object/feedback-screenshots/<id>.jpg`
    func upload(screenshot: Data, path: String) async throws {
        var req = request("storage/v1/object/feedback-screenshots/\(path)", contentType: "image/jpeg", body: screenshot)
        req.setValue("false", forHTTPHeaderField: "x-upsert")
        try await send(req)
    }

    /// `POST /rest/v1/feedback`, insert only: nothing is read back.
    func insert(row: Data) async throws {
        var req = request("rest/v1/feedback", contentType: "application/json", body: row)
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        try await send(req)
    }
}

#if DEBUG
/// A stand-in for the server: nothing leaves the PC. Debug builds with
/// `-GRASPAllowStubs 1` and `GRASP_STUB_FEEDBACK=ok|offline|reject`. With
/// `ok`, each row and picture it would have sent is written to
/// `FeedbackStubSent` in the support folder, to check what would go.
struct StubFeedbackTransport: FeedbackTransport {
    enum Mode: Sendable { case ok, offline, reject }
    let mode: Mode
    let folder: URL

    private func check() throws {
        switch mode {
        case .ok: return
        case .offline: throw URLError(.notConnectedToInternet)
        case .reject: throw FeedbackError.rejected(status: 400)
        }
    }

    func upload(screenshot: Data, path: String) async throws {
        try check()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? screenshot.write(to: folder.appendingPathComponent(path))
    }

    func insert(row: Data) async throws {
        try check()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? row.write(to: folder.appendingPathComponent("row-\(Foundation.UUID().uuidString.prefix(8)).json"))
    }
}
#endif

// MARK: - Per-install state and the local queue

/// This PC's feedback state, the Mac's UserDefaults keys in one file beside
/// the profiles (so it follows `GRASP_SUPPORT_DIR`): the install id, today's
/// send count, and the two asks. Per device and never synced.
struct FeedbackState: Codable {
    var installId: String?
    var sendDay: String?
    var sendCount = 0
    var firstLaunch: Date?
    var firstTestFinished = false
    var firstTestShown = false
    var weekShown = false
    var optedOut = false

    static func load(_ url: URL) -> FeedbackState {
        (try? JSONDecoder().decode(FeedbackState.self, from: Data(contentsOf: url))) ?? FeedbackState()
    }

    /// Not atomic: Windows refuses the rename an atomic write ends with while
    /// anything has the file open.
    func save(_ url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url) }
    }
}

/// One piece of feedback waiting to send.
struct FeedbackQueueEntry: Codable, Equatable {
    var id: String
    var row: Data
    var hasScreenshot: Bool
    var screenshotUploaded = false
    var queuedAt: Date
}

/// Files in a folder, not the database: one JSON per entry, and its picture.
final class FileFeedbackQueue {
    private let folder: URL
    private let fm = FileManager.default

    init(folder: URL) {
        self.folder = folder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func entries() -> [FeedbackQueueEntry] {
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(FeedbackQueueEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.queuedAt < $1.queuedAt }
    }

    func save(_ entry: FeedbackQueueEntry, screenshot: Data?) {
        if let screenshot { try? screenshot.write(to: folder.appendingPathComponent("\(entry.id).jpg")) }
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: folder.appendingPathComponent("\(entry.id).json"))
        }
    }

    func screenshot(for id: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent("\(id).jpg")) }

    func remove(_ id: String) {
        try? fm.removeItem(at: folder.appendingPathComponent("\(id).json"))
        try? fm.removeItem(at: folder.appendingPathComponent("\(id).jpg"))
    }
}

// MARK: - The service

enum FeedbackOutcome: Equatable {
    case sent
    /// Kept on this PC. `offline` is true for a connection problem.
    case queued(offline: Bool, message: String)
    case rateLimited
    case invalid(String)
}

/// Sends, queues, limits and asks, for this install. One per app run.
@Observable
final class FeedbackService {
    @ObservationIgnored private let transport: any FeedbackTransport
    @ObservationIgnored private let queue: FileFeedbackQueue
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var state: FeedbackState
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// The Send feedback sheet is open.
    var isPresenting = false
    /// A picture of the window taken as the sheet opened, offered (never
    /// attached on its own) in the sheet.
    var windowSnapshot: URL?
    /// The soft ask on screen, if any.
    private(set) var showingAsk: FeedbackAsk?
    private(set) var queuedCount = 0
    private(set) var isSending = false

    static let shared = FeedbackService()

    private init() {
        let support = (try? Library.supportDirectory()) ?? FileManager.default.temporaryDirectory
        stateURL = support.appendingPathComponent("feedback.json")
        queue = FileFeedbackQueue(folder: support.appendingPathComponent("FeedbackQueue", isDirectory: true))
        state = FeedbackState.load(stateURL)
        var transport: any FeedbackTransport = SupabaseFeedbackTransport(
            baseURL: SupabaseSettings.project.url, anonKey: SupabaseSettings.project.anonKey)
        #if DEBUG
        if StubHooks.enabled("GRASP_STUB_FEEDBACK") || StubHooks.value("GRASP_STUB_FEEDBACK") != nil {
            let mode = StubHooks.value("GRASP_STUB_FEEDBACK")
            transport = StubFeedbackTransport(mode: mode == "offline" ? .offline : mode == "reject" ? .reject : .ok,
                                              folder: support.appendingPathComponent("FeedbackStubSent", isDirectory: true))
        }
        #endif
        self.transport = transport
        queuedCount = queue.entries().count
    }

    // MARK: Install id and the daily limit

    /// A random id for this install, made once. It identifies nobody.
    var installId: String {
        if let existing = state.installId { return existing }
        let fresh = Foundation.UUID().uuidString.lowercased()
        state.installId = fresh
        state.save(stateURL)
        return fresh
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var sendsToday: Int { state.sendDay == Self.today() ? state.sendCount : 0 }
    var rateLimitReached: Bool { sendsToday >= FeedbackLimits.sendsPerDay }
    static let rateLimitMessage = "You've sent \(FeedbackLimits.sendsPerDay) pieces of feedback today. Please try again tomorrow."

    private func countThisSend() {
        let count = sendsToday + 1
        state.sendDay = Self.today()
        state.sendCount = count
        state.save(stateURL)
    }

    // MARK: Sending

    func send(draft: FeedbackDraft, context: FeedbackContext) async -> FeedbackOutcome {
        if let problem = draft.problem { return .invalid(problem) }
        if rateLimitReached { return .rateLimited }
        countThisSend()

        let payload = FeedbackPayload.make(draft: draft, context: context)
        guard let row = try? JSONEncoder().encode(payload) else { return .invalid("Couldn't read that message.") }
        let entry = FeedbackQueueEntry(id: payload.id, row: row, hasScreenshot: draft.screenshot != nil, queuedAt: Date())

        isSending = true
        defer { isSending = false }
        do {
            try await deliver(entry, screenshot: draft.screenshot)
            return .sent
        } catch {
            // Never lose the text: keep it and try again later.
            queue.save(entry, screenshot: draft.screenshot)
            queuedCount = queue.entries().count
            scheduleRetry()
            let offline = Self.isConnectionProblem(error)
            let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't send your feedback."
            return .queued(offline: offline, message: message)
        }
    }

    /// Uploads the picture (once), then inserts the row.
    private func deliver(_ entry: FeedbackQueueEntry, screenshot: Data?) async throws {
        var entry = entry
        if entry.hasScreenshot, !entry.screenshotUploaded {
            guard let picture = screenshot ?? queue.screenshot(for: entry.id) else {
                // The picture is gone; send the words without it.
                try await transport.insert(row: Self.row(entry.row, withoutScreenshot: true))
                return
            }
            try await transport.upload(screenshot: picture, path: "\(entry.id).jpg")
            entry.screenshotUploaded = true
            if queue.entries().contains(where: { $0.id == entry.id }) { queue.save(entry, screenshot: nil) }
        }
        try await transport.insert(row: entry.row)
    }

    private static func row(_ json: Data, withoutScreenshot: Bool) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return json }
        object["screenshot_path"] = nil
        return (try? JSONSerialization.data(withJSONObject: object)) ?? json
    }

    static func isConnectionProblem(_ error: Error) -> Bool {
        if let error = error as? FeedbackError, case .temporary = error { return true }
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .dnsLookupFailed].contains(url.code)
    }

    // MARK: Retrying

    /// Sends what is waiting, oldest first. Stops at the first connection
    /// problem; a refused entry stays and the next one is tried.
    func flushQueue() async {
        for entry in queue.entries() {
            do {
                try await deliver(entry, screenshot: nil)
                queue.remove(entry.id)
            } catch {
                if Self.isConnectionProblem(error) { break }
                continue
            }
        }
        queuedCount = queue.entries().count
        if queuedCount > 0 { scheduleRetry() }
    }

    /// Windows has no network monitor here (the Mac's `NWPathMonitor`), so
    /// waiting feedback is tried again every ten minutes while the app runs,
    /// as well as at launch.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            self?.retryTask = nil
            await self?.flushQueue()
        }
    }

    // MARK: The two soft asks

    /// Called when a profile opens: starts the seven days (and skips both
    /// asks for a library that already has content), and sends anything
    /// that was waiting.
    func start(libraryHasData: Bool) {
        if state.firstLaunch == nil {
            state.firstLaunch = Date()
            if libraryHasData {
                state.firstTestShown = true
                state.weekShown = true
            }
            state.save(stateURL)
        }
        Task { @MainActor in await flushQueue() }
        #if DEBUG
        switch StubHooks.value("GRASP_FEEDBACK_ASK") {
        case "test": showingAsk = .firstTest
        case "week": showingAsk = .week
        default: break
        }
        #endif
    }

    /// A Test was finished. Only the first one counts.
    func noteTestFinished() {
        guard !state.firstTestFinished else { return }
        state.firstTestFinished = true
        state.save(stateURL)
    }

    /// Shows the ask that is due, and counts it as shown at once. Never during
    /// Study, Learn or a Test, and only called when no sheet is up (a click in
    /// the sidebar, the end of a session, launch).
    func showAskIfDue() {
        guard showingAsk == nil, !isPresenting, !FeedbackScreen.isStudying, !state.optedOut else { return }
        if state.firstTestFinished, !state.firstTestShown {
            state.firstTestShown = true
            showingAsk = .firstTest
        } else if let first = state.firstLaunch, Date().timeIntervalSince(first) >= 7 * 24 * 60 * 60, !state.weekShown {
            state.weekShown = true
            showingAsk = .week
        } else {
            return
        }
        state.save(stateURL)
    }

    func dismissAsk() { showingAsk = nil }

    /// "Don't ask again": neither ask is ever shown.
    func neverAskAgain() {
        state.optedOut = true
        state.firstTestShown = true
        state.weekShown = true
        state.save(stateURL)
        showingAsk = nil
    }

    // MARK: Opening the sheet

    /// Opens the sheet, first taking a picture of the window as it is now
    /// (offered in the sheet, never attached unless chosen).
    func open() {
        windowSnapshot = WindowSnapshot.capture()
        showingAsk = nil
        isPresenting = true
    }
}

/// The two soft asks. Each is shown once ever on this PC.
enum FeedbackAsk {
    case firstTest, week

    var message: String {
        switch self {
        case .firstTest: return "You finished your first test. How did it go?"
        case .week: return "You've had GRASP for a week. How is it going?"
        }
    }
}

extension StubHooks {
    /// The value of a stub variable, under the same two conditions as
    /// `enabled`: a debug build and the launch flag.
    static func value(_ name: String) -> String? {
        #if DEBUG
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "-GRASPAllowStubs"), flag + 1 < args.count, args[flag + 1] == "1" else {
            return nil
        }
        return ProcessInfo.processInfo.environment[name]
        #else
        return nil
        #endif
    }
}

// MARK: - This install's facts

enum FeedbackFacts {
    /// From `AppVersion`, the one place the Windows version is kept.
    static let appVersion = AppVersion.number
    static let build = AppVersion.build

    /// "Windows 11 (10.0.26200)". Windows 11 still reports 10.0, so the
    /// build number tells them apart.
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let name = v.majorVersion == 10 && v.patchVersion >= 22000 ? "Windows 11" : "Windows \(v.majorVersion)"
        return "\(name) (\(v.majorVersion).\(v.minorVersion).\(v.patchVersion))"
    }()

    /// The PC's model as its maker names it ("ROG Strix G16"), from the BIOS
    /// entry in the registry, the counterpart of the Mac's "Mac14,2".
    static let deviceModel: String = {
        #if os(Windows)
        let key = "HARDWARE\\DESCRIPTION\\System\\BIOS"
        func read(_ value: String) -> String? {
            var size: DWORD = 0
            guard RegGetValueW(HKEY_LOCAL_MACHINE, key.wide, value.wide, DWORD(RRF_RT_REG_SZ), nil, nil, &size) == ERROR_SUCCESS,
                  size > 2 else { return nil }
            var buffer = [WCHAR](repeating: 0, count: Int(size) / 2 + 1)
            guard RegGetValueW(HKEY_LOCAL_MACHINE, key.wide, value.wide, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size) == ERROR_SUCCESS
            else { return nil }
            let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        let model = read("SystemProductName") ?? "unknown"
        return String(model.prefix(60))
        #else
        return "unknown"
        #endif
    }()

    /// "local" when Ollama answered at launch, else "off". Cloud AI isn't
    /// wired up on Windows yet.
    static var aiMode: String { (Library.lastLocalModel ?? nil) != nil ? "local" : "off" }

    static func context() -> FeedbackContext {
        FeedbackContext(appVersion: appVersion, build: build, platform: "windows", osVersion: osVersion,
                        deviceModel: deviceModel, screen: FeedbackScreen.current.rawValue, aiMode: aiMode,
                        installId: FeedbackService.shared.installId)
    }
}

#if os(Windows)
private extension String {
    nonisolated var wide: [WCHAR] { Array(utf16) + [0] }
}
#endif

// MARK: - Screenshots

/// Pictures for feedback. Windows has no ImageIO, so scaling and JPEG
/// encoding go through PowerShell's System.Drawing, as the OCR does.
nonisolated enum FeedbackImage {
    /// Scales an image file to a 1600 px long edge and saves it as a JPEG
    /// under 500 KB, or nil if it can't be read. Runs off the main thread.
    static func prepare(_ source: URL) async -> Data? {
        await Task.detached { () -> Data? in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-feedback-\(Foundation.UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: out) }
            guard let script = scriptURL() else { return nil }
            let process = Process()
            let windows = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
            process.executableURL = URL(fileURLWithPath: windows + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
            process.arguments = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", native(script),
                                 "-In", native(source), "-Out", native(out),
                                 "-Edge", "\(FeedbackLimits.screenshotLongEdge)", "-Max", "\(FeedbackLimits.screenshotMaxBytes)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0, let data = try? Data(contentsOf: out),
                  data.count <= FeedbackLimits.screenshotMaxBytes else { return nil }
            return data
        }.value
    }

    private static func native(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    private static func scriptURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-feedback-image-v1.ps1")
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try Data(script.utf8).write(to: url) } catch { return nil }
        }
        return url
    }

    /// Tries a 1600 px long edge at falling JPEG qualities, then 80% of the
    /// edge each round down to 600 px, as the Mac's `FeedbackImage` does.
    private static let script = #"""
    param([string]$In, [string]$Out, [int]$Edge = 1600, [int]$Max = 500000)
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Drawing
    $src = [System.Drawing.Image]::FromFile($In)
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    try {
      while ($Edge -ge 600) {
        $scale = [Math]::Min(1.0, $Edge / [double][Math]::Max($src.Width, $src.Height))
        $w = [int][Math]::Max(1, [Math]::Round($src.Width * $scale))
        $h = [int][Math]::Max(1, [Math]::Round($src.Height * $scale))
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, $w, $h)
        $g.Dispose()
        foreach ($q in 80, 65, 50, 35) {
          $p = New-Object System.Drawing.Imaging.EncoderParameters 1
          $p.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]$q)
          $ms = New-Object System.IO.MemoryStream
          $bmp.Save($ms, $codec, $p)
          if ($ms.Length -le $Max) { [System.IO.File]::WriteAllBytes($Out, $ms.ToArray()); $bmp.Dispose(); exit 0 }
        }
        $bmp.Dispose()
        $Edge = [int]($Edge * 0.8)
      }
      exit 2
    } finally { $src.Dispose() }
    """#
}

/// A picture of the GRASP window as it is, taken from the screen just before
/// the sheet opens (so the sheet isn't in it), saved as a BMP in the temp
/// folder. The sheet turns it into a JPEG only if the person attaches it.
enum WindowSnapshot {
    static func capture() -> URL? {
        #if os(Windows)
        guard let window = WindowIcon.mainWindowHandle() else { return nil }
        var rect = RECT()
        guard GetClientRect(window, &rect) else { return nil }
        var origin = POINT(x: 0, y: 0)
        ClientToScreen(window, &origin)
        let width = rect.right - rect.left, height = rect.bottom - rect.top
        guard width > 0, height > 0, let screen = GetDC(nil) else { return nil }
        defer { ReleaseDC(nil, screen) }
        guard let memory = CreateCompatibleDC(screen) else { return nil }
        defer { DeleteDC(memory) }
        guard let bitmap = CreateCompatibleBitmap(screen, width, height) else { return nil }
        defer { DeleteObject(UnsafeMutableRawPointer(bitmap)) }
        let previous = SelectObject(memory, UnsafeMutableRawPointer(bitmap))
        let copied = BitBlt(memory, 0, 0, width, height, screen, origin.x, origin.y, DWORD(0x00CC0020))
        SelectObject(memory, previous)
        guard copied else { return nil }

        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = width
        info.bmiHeader.biHeight = -height          // top-down rows
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(0)     // BI_RGB
        var pixels = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
        let rows = pixels.withUnsafeMutableBytes {
            GetDIBits(memory, bitmap, 0, UINT(height), $0.baseAddress, &info, UINT(0))
        }
        guard rows == height else { return nil }

        // A BMP: 14-byte file header, the 40-byte info header, the pixels.
        var file = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { file.append(contentsOf: $0) } }
        let headerSize = 14 + 40
        file.append(contentsOf: [0x42, 0x4D])
        put(UInt32(headerSize + pixels.count).littleEndian)
        put(UInt32(0))
        put(UInt32(headerSize).littleEndian)
        put(UInt32(40).littleEndian)
        put(Int32(width).littleEndian)
        put(Int32(-height).littleEndian)
        put(UInt16(1).littleEndian)
        put(UInt16(32).littleEndian)
        put(UInt32(0))
        put(UInt32(pixels.count).littleEndian)
        put(Int32(2835).littleEndian)
        put(Int32(2835).littleEndian)
        put(UInt32(0))
        put(UInt32(0))
        file.append(contentsOf: pixels)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-feedback-window.bmp")
        do { try file.write(to: url) } catch { return nil }
        return url
        #else
        return nil
        #endif
    }
}
