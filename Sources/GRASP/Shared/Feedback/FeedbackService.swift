import Foundation
import Observation
import ImageIO
import UniformTypeIdentifiers
#if canImport(Network)
import Network
#endif

// Sending, queueing and limiting feedback. Like `FeedbackModel`, nothing here
// reads the library: it is handed plain values and a transport.

// MARK: - Transport

/// How feedback leaves the device. The real one talks to Supabase; tests and
/// screenshot runs use a stand-in, so nothing real is ever sent from them.
protocol FeedbackTransport: Sendable {
    /// Puts a screenshot in the private `feedback-screenshots` bucket.
    func upload(screenshot: Data, path: String) async throws
    /// Inserts one row into the `feedback` table. `row` is the payload as JSON.
    func insert(row: Data) async throws
}

enum FeedbackError: LocalizedError, Equatable {
    /// This copy of GRASP has no Supabase project filled in.
    case notConfigured
    /// The server said no (a missing table, a policy, a size limit).
    case rejected(status: Int)
    /// A busy or broken server; worth trying again later.
    case temporary(status: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Feedback isn't set up in this copy of GRASP yet."
        case .rejected: return "The feedback server didn't accept it."
        case .temporary: return "The feedback server is busy."
        }
    }
}

/// The Supabase project, over plain HTTP with only the public (anon) key. No
/// sign-in is involved, so it works the same for everyone, and it is the
/// `anon` role the table's insert-only policy is written for.
struct SupabaseFeedbackTransport: FeedbackTransport {
    let baseURL: URL
    let anonKey: String
    var session: URLSession = .shared

    /// Nil when Info.plist has no Supabase project.
    init?(configuration: SyncConfiguration? = SyncConfiguration.current) {
        guard let configuration else { return nil }
        self.baseURL = configuration.url
        self.anonKey = configuration.anonKey
    }

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
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedbackError.temporary(status: 0) }
        switch http.statusCode {
        case 200..<300: return
        // The same id again: an earlier try got through. That is a success.
        case 409: return
        case 408, 429, 500..<600: throw FeedbackError.temporary(status: http.statusCode)
        default: throw FeedbackError.rejected(status: http.statusCode)
        }
    }

    func upload(screenshot: Data, path: String) async throws {
        var req = request("storage/v1/object/feedback-screenshots/\(path)", contentType: "image/jpeg", body: screenshot)
        req.setValue("false", forHTTPHeaderField: "x-upsert")
        try await send(req)
    }

    func insert(row: Data) async throws {
        var req = request("rest/v1/feedback", contentType: "application/json", body: row)
        // Insert-only: the app may not read rows back, so ask for nothing back.
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        try await send(req)
    }
}

#if DEBUG
/// A stand-in for the server, for tests and screenshot runs: nothing leaves
/// the machine. `GRASP_STUB_FEEDBACK=ok|offline|reject` picks how it answers
/// (debug builds with `-GRASPAllowStubs 1` only).
final class StubFeedbackTransport: FeedbackTransport, @unchecked Sendable {
    enum Mode: Sendable { case ok, offline, reject(Int) }
    var mode: Mode
    private(set) var rows: [Data] = []
    private(set) var uploads: [(path: String, bytes: Int)] = []

    init(mode: Mode = .ok) { self.mode = mode }

    private func check() throws {
        switch mode {
        case .ok: return
        case .offline: throw URLError(.notConnectedToInternet)
        case .reject(let status): throw FeedbackError.rejected(status: status)
        }
    }

    func upload(screenshot: Data, path: String) async throws {
        try check()
        uploads.append((path, screenshot.count))
    }

    func insert(row: Data) async throws {
        try check()
        rows.append(row)
    }
}
#endif

// MARK: - The local queue

/// One piece of feedback waiting to send.
struct FeedbackQueueEntry: Codable, Equatable, Sendable {
    var id: String
    var row: Data
    var hasScreenshot: Bool
    var screenshotUploaded = false
    var queuedAt: Date
}

protocol FeedbackQueueStoring {
    func entries() -> [FeedbackQueueEntry]
    func save(_ entry: FeedbackQueueEntry, screenshot: Data?)
    func screenshot(for id: String) -> Data?
    func remove(_ id: String)
}

/// Files in a folder, not the database: one JSON per entry, and its picture.
/// Per device, so it sits beside the app's data and follows `GRASP_SUPPORT_DIR`.
final class FileFeedbackQueue: FeedbackQueueStoring {
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
        if let screenshot { try? screenshot.write(to: folder.appendingPathComponent("\(entry.id).jpg"), options: .atomic) }
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: folder.appendingPathComponent("\(entry.id).json"), options: .atomic)
        }
    }

    func screenshot(for id: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent("\(id).jpg")) }

    func remove(_ id: String) {
        try? fm.removeItem(at: folder.appendingPathComponent("\(id).json"))
        try? fm.removeItem(at: folder.appendingPathComponent("\(id).jpg"))
    }
}

/// For tests.
final class MemoryFeedbackQueue: FeedbackQueueStoring {
    private var stored: [String: FeedbackQueueEntry] = [:]
    private var pictures: [String: Data] = [:]
    func entries() -> [FeedbackQueueEntry] { stored.values.sorted { $0.queuedAt < $1.queuedAt } }
    func save(_ entry: FeedbackQueueEntry, screenshot: Data?) {
        stored[entry.id] = entry
        if let screenshot { pictures[entry.id] = screenshot }
    }
    func screenshot(for id: String) -> Data? { pictures[id] }
    func remove(_ id: String) { stored[id] = nil; pictures[id] = nil }
}

// MARK: - The service

enum FeedbackOutcome: Equatable {
    case sent
    /// Kept on this device. `offline` is true for a connection problem.
    case queued(offline: Bool, message: String)
    case rateLimited
    case invalid(String)
    case notConfigured
}

@MainActor @Observable
final class FeedbackService {
    private let transport: FeedbackTransport?
    private let queue: FeedbackQueueStoring
    private let defaults: UserDefaults
    private let now: () -> Date

    /// The Send feedback sheet is open. Both windows present the sheet from this.
    var isPresenting = false
    private(set) var queuedCount = 0
    private(set) var isSending = false

    static let installIdKey = "feedbackInstallId"
    static let dayKey = "feedbackSendDay"
    static let countKey = "feedbackSendCount"

    init(transport: FeedbackTransport?, queue: FeedbackQueueStoring,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.queue = queue
        self.defaults = defaults
        self.now = now
        queuedCount = queue.entries().count
    }

    // MARK: Install id and the daily limit

    /// A random id for this install, made once. It limits duplicates and
    /// identifies nobody.
    var installId: String {
        if let existing = defaults.string(forKey: Self.installIdKey) { return existing }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: Self.installIdKey)
        return fresh
    }

    private func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now())
    }

    var sendsToday: Int {
        defaults.string(forKey: Self.dayKey) == today() ? defaults.integer(forKey: Self.countKey) : 0
    }

    var rateLimitReached: Bool { sendsToday >= FeedbackLimits.sendsPerDay }

    static let rateLimitMessage = "You've sent \(FeedbackLimits.sendsPerDay) pieces of feedback today. Please try again tomorrow."

    private func countThisSend() {
        defaults.set(today(), forKey: Self.dayKey)
        defaults.set(sendsToday + 1, forKey: Self.countKey)
    }

    // MARK: Sending

    func send(draft: FeedbackDraft, context: FeedbackContext) async -> FeedbackOutcome {
        if let problem = draft.problem { return .invalid(problem) }
        guard transport != nil else { return .notConfigured }
        if rateLimitReached { return .rateLimited }
        countThisSend()

        let payload = FeedbackPayloadBuilder.make(draft: draft, context: context)
        guard let row = try? JSONEncoder().encode(payload) else { return .invalid("Couldn't read that message.") }
        let entry = FeedbackQueueEntry(id: payload.id, row: row, hasScreenshot: draft.screenshot != nil, queuedAt: now())

        isSending = true
        defer { isSending = false }
        do {
            try await deliver(entry, screenshot: draft.screenshot)
            return .sent
        } catch {
            // Never lose the text: keep it and try again later.
            queue.save(entry, screenshot: draft.screenshot)
            queuedCount = queue.entries().count
            let offline = PlainError.isConnectionProblem(error) || (error as? FeedbackError).map {
                if case .temporary = $0 { return true } else { return false }
            } ?? false
            return .queued(offline: offline, message: PlainError.message(error, couldnt: "send your feedback"))
        }
    }

    /// Uploads the picture (once), then inserts the row.
    private func deliver(_ entry: FeedbackQueueEntry, screenshot: Data?) async throws {
        guard let transport else { throw FeedbackError.notConfigured }
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

    /// The same row with its screenshot path removed.
    private static func row(_ json: Data, withoutScreenshot: Bool) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return json }
        object["screenshot_path"] = nil
        return (try? JSONSerialization.data(withJSONObject: object)) ?? json
    }

    // MARK: Retrying

    /// Sends what is waiting, oldest first. Called at launch and when the
    /// network comes back. Stops at the first connection problem.
    func flushQueue() async {
        guard transport != nil else { return }
        for entry in queue.entries() {
            do {
                try await deliver(entry, screenshot: nil)
                queue.remove(entry.id)
            } catch {
                if PlainError.isConnectionProblem(error) { break }
                if let e = error as? FeedbackError, case .temporary = e { break }
                // Refused for now (the table may not exist yet): keep it, try the next.
                continue
            }
        }
        queuedCount = queue.entries().count
    }

    #if canImport(Network)
    @ObservationIgnored private var monitor: NWPathMonitor?

    /// Retries the queue each time the network becomes reachable.
    func startWatchingNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flushQueue() }
        }
        monitor.start(queue: DispatchQueue(label: "grasp.feedback.network"))
    }
    #endif
}

// MARK: - Screenshots

enum FeedbackImage {
    /// Scales an image to a 1600 px long edge and saves it as a JPEG under
    /// 500 KB, or nil if it can't be read.
    static func prepare(_ data: Data,
                        longEdge: Int = FeedbackLimits.screenshotLongEdge,
                        maxBytes: Int = FeedbackLimits.screenshotMaxBytes) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var edge = longEdge
        while edge >= 600 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            for quality in [0.8, 0.65, 0.5, 0.35] {
                if let jpeg = jpeg(image, quality: quality), jpeg.count <= maxBytes { return jpeg }
            }
            edge = Int(Double(edge) * 0.8)
        }
        return nil
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
