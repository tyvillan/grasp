import Foundation

/// Which Gemini model a request uses and which it walks to next when that
/// one is overloaded or out of quota. One place, so the app and the timing
/// harness cannot pick differently.
///
/// - A model the student pinned in Settings is used alone: no walking.
/// - Otherwise the primary is "the best model" remembered from the last
///   connection check (the first of `CloudProvider.chatModels`), or the
///   built-in fallback if there never was a check. It does not refresh by
///   itself: the list is only read again when the student presses Test
///   connection, so a stale list keeps being used.
/// - The alternates are the rest of that remembered list, in order.
/// - On a request, `GeminiTransport` tries the primary, then each alternate
///   in turn for overload, a used-up daily quota, or a model the key does not
///   offer. A model that failed is skipped for a while.
public struct CloudModelSelection: Equatable, Sendable {
    public var primary: String
    public var alternates: [String]
    /// Where the answer came from, for output: "pinned", "remembered",
    /// "built-in" or "live list".
    public var source: String

    public init(primary: String, alternates: [String], source: String) {
        self.primary = primary; self.alternates = alternates; self.source = source
    }

    static let pinnedKey = AIPreferences.cloudModelKey
    static let bestKey = "GRASP.cloudBestModel"
    static let listKey = "GRASP.cloudModelList"

    /// What the app uses, from its preferences (the standard defaults in the
    /// app; another domain's, to read what the app would do).
    public static func read(from defaults: UserDefaults) -> CloudModelSelection {
        let pinned = defaults.string(forKey: pinnedKey) ?? ""
        let list = defaults.stringArray(forKey: listKey) ?? []
        if !pinned.isEmpty {
            return CloudModelSelection(primary: pinned, alternates: [], source: "pinned")
        }
        if let best = defaults.string(forKey: bestKey), !best.isEmpty {
            return CloudModelSelection(primary: best, alternates: rest(of: list, besides: best), source: "remembered")
        }
        let fallback = CloudProvider.fallbackModel
        return CloudModelSelection(primary: fallback, alternates: rest(of: list, besides: fallback), source: "built-in")
    }

    /// What a fresh connection check would make it: the best of a live list.
    public static func fromLiveList(_ ids: [String]) -> CloudModelSelection {
        let models = CloudProvider.chatModels(from: ids)
        guard let best = models.first else {
            return CloudModelSelection(primary: CloudProvider.fallbackModel, alternates: [], source: "built-in")
        }
        return CloudModelSelection(primary: best, alternates: rest(of: models, besides: best), source: "live list")
    }

    /// The rest of the list, in the order the picker shows it.
    static func rest(of known: [String], besides primary: String) -> [String] {
        (known.isEmpty ? [CloudProvider.fallbackModel] : known).filter { $0 != primary }
    }
}
