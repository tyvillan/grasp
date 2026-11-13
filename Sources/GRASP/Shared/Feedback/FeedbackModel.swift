import Foundation

// Sending feedback to the maintainer's own Supabase project.
//
// This file is the whole of what leaves the device, and it is deliberately
// plain: strings, numbers and booleans handed in by the screens. It must never
// import or name anything from the library (notes, cards, questions, decks,
// courses) or from key storage. A test reads this file and `FeedbackService`
// for those words.

/// What kind of feedback it is.
enum FeedbackType: String, CaseIterable, Identifiable, Sendable {
    case bug, confusing, idea, love

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: return "Bug"
        case .confusing: return "Confusing"
        case .idea: return "Idea"
        case .love: return "Love it"
        }
    }
}

enum FeedbackLimits {
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
struct FeedbackDraft: Equatable, Sendable {
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
            if !mail.isEmpty, !FeedbackDraft.looksLikeEmail(mail) { return "That email doesn't look right. You can also leave it empty." }
        }
        if let screenshot, screenshot.count > FeedbackLimits.screenshotMaxBytes { return "That screenshot is too big." }
        return nil
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ")
    }
}

/// The facts about this install that travel with feedback. Every field is a
/// plain value the app hands in; none comes from the library.
struct FeedbackContext: Equatable, Sendable {
    var appVersion: String
    var build: String
    /// "mac" or "iphone".
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
            ("Platform", platform == "mac" ? "Mac" : "iPhone"),
            ("OS version", osVersion),
            ("Device", deviceModel),
            ("Screen you were on", screen),
            ("AI", aiMode == "cloud" ? "Cloud" : aiMode == "local" ? "Local" : "Off"),
            ("Install ID", installId),
        ]
    }
}

/// One feedback row, exactly as the `feedback` table takes it. The coding keys
/// are the column names, and a test pins the list.
struct FeedbackPayload: Codable, Equatable, Sendable {
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

    /// Every column the app may write.
    static var columnNames: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
}

enum FeedbackPayloadBuilder {
    /// Builds the row. Anonymous drops the name and email entirely.
    static func make(draft: FeedbackDraft, context: FeedbackContext, id: UUID = UUID()) -> FeedbackPayload {
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
enum FeedbackScreen: String, Sendable {
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
    case today = "Today"
    case courses = "Courses"
    case settings = "Settings"
    case search = "Search"

    /// The last screen the person was on in the main window. Set by the
    /// screens as they change; read when the sheet opens.
    @MainActor static var current: FeedbackScreen = .home
    /// Where the person is when no deck page is open (a tab on the iPhone).
    @MainActor static var base: FeedbackScreen = .home
}
