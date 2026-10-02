import Foundation

/// Where AI work runs.
public enum AIMode: String, CaseIterable, Identifiable, Sendable {
    /// Ollama on a computer, Apple's on-device model on an iPhone.
    case local
    /// The cloud model only.
    case cloud
    /// The cloud model, dropping to local whenever it's rate-limited, out
    /// of quota or unreachable -- partway through a job too.
    case automatic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: return "Local"
        case .cloud: return "Cloud"
        case .automatic: return "Automatic"
        }
    }

    public var usesCloud: Bool { self != .local }
}

/// The one cloud provider GRASP supports. Its numbers are estimates: Google
/// no longer publishes fixed free-tier limits (AI Studio shows each
/// project's own), and they've changed several times.
public enum CloudProvider {
    public static let name = "Google Gemini"
    public static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
    public static let keyPageURL = URL(string: "https://aistudio.google.com/apikey")!
    public static let usagePageURL = URL(string: "https://aistudio.google.com/rate-limit")!
    /// Used until the live model list has been read once.
    public static let fallbackModel = "gemini-2.5-flash"
    /// Requests per minute the pacer keeps under.
    public static let requestsPerMinute = 10
    /// The daily request allowance quota warnings plan against.
    public static let estimatedRequestsPerDay = 250
    /// The free tier resets at midnight Pacific.
    public static let quotaTimeZone = TimeZone(identifier: "America/Los_Angeles")!

    /// Text models worth offering, best first: the newest Flash (fast and
    /// generous on the free tier), then Pro, then the rest. Image, audio,
    /// embedding and live models can't answer a lesson prompt.
    public static func chatModels(from ids: [String]) -> [String] {
        let excluded = ["image", "tts", "audio", "live", "embedding", "aqa", "imagen", "veo", "learnlm", "gemma"]
        let text = Set(ids.map { $0.replacingOccurrences(of: "models/", with: "") })
            .filter { id in id.hasPrefix("gemini") && !excluded.contains { id.contains($0) } }
        func rank(_ id: String) -> (Int, Double, Int, String) {
            let family = id.contains("flash") && !id.contains("lite") ? 0 : (id.contains("pro") ? 1 : 2)
            let version = Double(id.split(separator: "-").dropFirst().first ?? "") ?? 0
            let preview = id.contains("preview") || id.contains("exp") ? 1 : 0
            return (family, -version, preview, id)
        }
        return text.sorted { rank($0) < rank($1) }
    }
}

/// The student's AI choices. Machine-wide (`UserDefaults.standard`), like
/// the Ollama model: they describe this device, not one person's library.
public enum AIPreferences {
    public static let modeKey = "GRASP.aiMode"
    public static let cloudModelKey = "GRASP.cloudModel"
    /// Set once the student has accepted the free-tier data notice.
    public static let acceptedCloudNoticeKey = "GRASP.acceptedCloudNotice"

    public static var mode: AIMode {
        get { UserDefaults.standard.string(forKey: modeKey).flatMap(AIMode.init(rawValue:)) ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Empty means "the best model on the live list".
    public static var cloudModel: String {
        get { UserDefaults.standard.string(forKey: cloudModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: cloudModelKey) }
    }

    static let bestCloudModelKey = "GRASP.cloudBestModel"
    static let cachedCloudModelsKey = "GRASP.cloudModelList"

    /// The key's usable models from the last check, best first -- what
    /// the next-best model is when the best one is overloaded.
    public static var cachedCloudModels: [String] {
        get { UserDefaults.standard.stringArray(forKey: cachedCloudModelsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: cachedCloudModelsKey) }
    }

    /// Models to try, in order, if the chosen one is overloaded. Empty when
    /// the student pinned a model: they asked for that one.
    public static func alternateCloudModels(besides primary: String) -> [String] {
        guard cloudModel.isEmpty else { return [] }
        return alternates(from: cachedCloudModels, besides: primary)
    }

    /// The rest of the list, in the order the picker shows it.
    static func alternates(from known: [String], besides primary: String) -> [String] {
        (known.isEmpty ? [CloudProvider.fallbackModel] : known).filter { $0 != primary }
    }

    /// The best model the key's live list offered, remembered so a request
    /// doesn't have to list models first.
    public static var bestKnownCloudModel: String? {
        get { UserDefaults.standard.string(forKey: bestCloudModelKey) }
        set { UserDefaults.standard.set(newValue, forKey: bestCloudModelKey) }
    }

    /// The model requests actually use.
    public static var resolvedCloudModel: String {
        let chosen = cloudModel
        if !chosen.isEmpty { return chosen }
        return bestKnownCloudModel ?? CloudProvider.fallbackModel
    }

    public static var hasAcceptedCloudNotice: Bool {
        get { UserDefaults.standard.bool(forKey: acceptedCloudNoticeKey) }
        set { UserDefaults.standard.set(newValue, forKey: acceptedCloudNoticeKey) }
    }
}

/// What the cloud model has been doing today: requests sent, whether it's
/// paused, and the last time a job fell back to the local model. Shown in
/// the AI settings and used to warn before a job that won't fit.
public final class CloudUsage: @unchecked Sendable {
    public static let shared = CloudUsage()
    /// Posted (on whatever thread) after any change, for UI to re-read.
    public static let didChange = Notification.Name("GRASP.CloudUsage.didChange")

    // Everything the UI reads is kept in memory, behind `lock`, and written
    // to `defaults` on a separate queue -- never while the lock is held. A
    // `UserDefaults` write notifies SwiftUI on the writing thread, and
    // SwiftUI's handler waits for the main thread; with the lock held, the
    // main thread (drawing Settings, reading this class) waited on the lock
    // in turn, and the whole app froze mid-job.
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let persistQueue = DispatchQueue(label: "com.tyvillan.grasp.cloudusage")

    private var countDay: String?
    private var count = 0
    private var paused: Date?
    private var fallback: String?
    private var transportError: String?
    private var avoidedModels: [String: (until: Date, reason: String)] = [:]
    private var usedModel: String?

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        // Read now, while nothing else can hold the lock or be writing.
        paused = defaults.object(forKey: Self.pausedUntilKey) as? Date
        fallback = defaults.string(forKey: Self.lastFallbackKey)
        let day = Self.quotaDay(of: now())
        countDay = day
        count = defaults.integer(forKey: Self.usageKey(day))
    }

    /// The quota day a moment falls in, as "yyyy-MM-dd" in Pacific time.
    static func quotaDay(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = CloudProvider.quotaTimeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The next midnight Pacific after `date`, when the quota resets.
    static func nextReset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = CloudProvider.quotaTimeZone
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    private static func usageKey(_ day: String) -> String { "GRASP.cloudUsage.\(day)" }
    private static let pausedUntilKey = "GRASP.cloudPausedUntil"
    private static let lastFallbackKey = "GRASP.cloudLastFallback"

    /// Rolls the counter over when the quota day changes. Called before
    /// taking the lock: it reads `UserDefaults`, and a defaults write in
    /// flight on another thread is delivering change notifications whose
    /// observers want this lock -- holding it across a read could wait on
    /// that write forever.
    private func rollOverDay() {
        let day = Self.quotaDay(of: now())
        lock.lock()
        let current = countDay
        lock.unlock()
        guard current != day else { return }
        let stored = defaults.integer(forKey: Self.usageKey(day))
        lock.lock()
        if countDay != day {
            countDay = day
            count = stored
        }
        lock.unlock()
    }

    /// `UserDefaults` is thread-safe but only declared `Sendable` on Apple's
    /// Foundation; this lets the same code build against swift-corelibs.
    private struct DefaultsBox: @unchecked Sendable { let defaults: UserDefaults }

    private func persist(_ write: @escaping @Sendable (UserDefaults) -> Void) {
        let box = DefaultsBox(defaults: defaults)
        persistQueue.async { write(box.defaults) }
    }

    public var requestsToday: Int {
        rollOverDay()
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Requests left today, by the estimate; never negative.
    public var estimatedRemainingToday: Int {
        max(0, CloudProvider.estimatedRequestsPerDay - requestsToday)
    }

    func recordRequest() {
        rollOverDay()
        lock.lock()
        count += 1
        let (key, value) = (Self.usageKey(countDay ?? ""), count)
        lock.unlock()
        persist { $0.set(value, forKey: key) }
        notify()
    }

    /// Non-nil while the cloud model is out of quota: until the reset.
    public var pausedUntil: Date? {
        rollOverDay()
        lock.lock(); defer { lock.unlock() }
        guard let until = paused, until > now() else { return nil }
        return until
    }

    func pauseForQuota() {
        rollOverDay()
        lock.lock()
        let until = Self.nextReset(after: now())
        paused = until
        // The provider says it's used up, whatever the local count thought.
        count = max(count, CloudProvider.estimatedRequestsPerDay)
        let (key, value) = (Self.usageKey(countDay ?? ""), count)
        lock.unlock()
        persist {
            $0.set(until, forKey: Self.pausedUntilKey)
            $0.set(value, forKey: key)
        }
        notify()
    }

    /// Cleared when the student changes the key or tests it successfully.
    public func clearPause() {
        rollOverDay()
        lock.lock()
        paused = nil
        lock.unlock()
        persist { $0.removeObject(forKey: Self.pausedUntilKey) }
        notify()
    }

    /// The most recent fallback, in a sentence, e.g. "Gemini's free limit
    /// for today is used up, so this ran on qwen3.5:9b."
    public var lastFallback: String? {
        rollOverDay()
        lock.lock(); defer { lock.unlock() }
        return fallback
    }

    func recordFallback(_ message: String) {
        rollOverDay()
        lock.lock()
        fallback = message
        lock.unlock()
        persist { $0.set(message, forKey: Self.lastFallbackKey) }
        notify()
    }

    /// The last way a request failed to go through, in words, or nil after
    /// one succeeds. Shown beside "Can't reach Google" so the cause isn't
    /// a guess.
    public var lastTransportError: String? {
        lock.lock(); defer { lock.unlock() }
        return transportError
    }

    public func recordTransportError(_ detail: String?) {
        lock.lock()
        let changed = transportError != detail
        transportError = detail
        lock.unlock()
        if changed { notify() }
    }

    /// Whether a model was recently overloaded and should be skipped.
    func isAvoided(_ model: String) -> Bool {
        skipNote(for: model) != nil
    }

    /// Why a model is being skipped right now ("overloaded"), or nil.
    public func skipNote(for model: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = avoidedModels[model] else { return nil }
        if entry.until <= now() { avoidedModels[model] = nil; return nil }
        return entry.reason
    }

    /// Skips a model for a while after it kept failing, so the next call
    /// goes straight to one that works instead of waiting it out again.
    func avoid(_ model: String, for seconds: TimeInterval = 600, reason: String = "unavailable") {
        lock.lock()
        avoidedModels[model] = (now().addingTimeInterval(seconds), reason)
        lock.unlock()
        notify()
    }

    /// The model that answered most recently -- what the model menu shows
    /// as in use, which differs from the best model while that one is
    /// being skipped.
    public var lastUsedModel: String? {
        lock.lock(); defer { lock.unlock() }
        return usedModel
    }

    func recordModelUsed(_ model: String) {
        lock.lock()
        let changed = usedModel != model
        usedModel = model
        lock.unlock()
        if changed { notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Before a big job: whether today's estimated allowance covers it.
public enum AIQuotaEstimate {
    /// Roughly 13 calls per note: a plan, about five sections, a review of
    /// each, and the repetition check (see `OverviewComposer`).
    public static func overviewRequests(notes: Int) -> Int { notes * 13 }
    /// One call per batch of fifteen cards.
    public static func refineRequests(cards: Int) -> Int { (cards + 14) / 15 }
    /// One call per card.
    public static func contextCheckRequests(cards: Int) -> Int { cards }

    /// A warning when `needed` won't fit in what's left today, else nil.
    public static func warning(needed: Int, mode: AIMode, usage: CloudUsage = .shared) -> String? {
        guard mode.usesCloud else { return nil }
        let left = usage.pausedUntil == nil ? usage.estimatedRemainingToday : 0
        guard needed > left else { return nil }
        let rest = mode == .automatic
            ? "GRASP will finish the rest on your local model."
            : "Once it runs out, the rest won't be written until the limit resets at midnight Pacific."
        if left == 0 {
            return "Gemini's free limit for today looks used up. " + rest
        }
        return "This needs about \(needed) requests and about \(left) of today's free \(CloudProvider.name) "
            + "requests are left. " + rest
    }
}
