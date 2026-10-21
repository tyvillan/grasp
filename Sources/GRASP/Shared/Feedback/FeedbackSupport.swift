import Foundation
import GRASPCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension FeedbackService {
    /// The one service for this install: the real server unless a debug run
    /// asks for a stand-in, and a queue beside the app's own data.
    static let shared: FeedbackService = {
        let folder = ((try? GRASPDatabase.supportDirectory()) ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("FeedbackQueue", isDirectory: true)
        var transport: FeedbackTransport? = SupabaseFeedbackTransport()
        #if DEBUG
        if let mode = StubHooks.value("GRASP_STUB_FEEDBACK") {
            transport = StubFeedbackTransport(mode: mode == "offline" ? .offline : mode == "reject" ? .reject(403) : .ok)
        }
        #endif
        let service = FeedbackService(transport: transport, queue: FileFeedbackQueue(folder: folder))
        #if DEBUG
        // A debug run can start clean, or from the limit already reached.
        if StubHooks.value("GRASP_FEEDBACK_STATE") == "fresh" {
            for key in [FeedbackService.dayKey, FeedbackService.countKey, FeedbackAsks.optedOutKey,
                        FeedbackAsks.firstTestShownKey, FeedbackAsks.weekShownKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if StubHooks.value("GRASP_FEEDBACK_STATE") == "ratelimit" {
            UserDefaults.standard.set(service.todayString(), forKey: FeedbackService.dayKey)
            UserDefaults.standard.set(FeedbackLimits.sendsPerDay, forKey: FeedbackService.countKey)
        }
        #endif
        return service
    }()

    func todayString() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

extension FeedbackAsks {
    static let shared = FeedbackAsks()
}

extension FeedbackContext {
    /// The facts about this install, with the screen and AI setting handed in.
    @MainActor
    static func current(screen: FeedbackScreen, aiMode: String, installId: String) -> FeedbackContext {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let platform = "mac"
        let osName = "macOS"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let model = String(cString: bytes)
        #else
        let platform = "iphone"
        let osName = "iOS"
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        #endif
        return FeedbackContext(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            platform: platform,
            osVersion: "\(osName) \(os.majorVersion).\(os.minorVersion)",
            deviceModel: model.isEmpty ? "unknown" : model,
            screen: screen.rawValue,
            aiMode: aiMode,
            installId: installId
        )
    }
}

extension AppStore {
    /// Called when a profile opens: starts the seven days for the soft asks (and
    /// skips them for a library that already has content), and sends anything
    /// that was waiting.
    func startFeedback() {
        FeedbackAsks.shared.recordLaunch(libraryHasData: libraryHasCoursesOrCards)
        let service = FeedbackService.shared
        service.startWatchingNetwork()
        Task { await service.flushQueue() }
        #if DEBUG
        if let ask = FeedbackDebug.ask { FeedbackAsks.shared.forceShow(ask) }
        if FeedbackDebug.opensSheet { service.isPresenting = true }
        #endif
    }

    /// "cloud", "local" or "off", from the AI setting and whether a model is
    /// ready. Reads the cached status only, never key storage.
    var feedbackAIMode: String {
        guard isGeneratorAvailable else { return "off" }
        return aiMode == .local ? "local" : "cloud"
    }

    /// The facts that go with feedback, as of now.
    func feedbackContext() -> FeedbackContext {
        .current(screen: FeedbackScreen.current, aiMode: feedbackAIMode, installId: FeedbackService.shared.installId)
    }
}

#if os(macOS)
enum FeedbackLauncher {
    /// Opens the Send feedback sheet in the main window. From the Settings
    /// window it closes Settings first, the way Replay tutorial does.
    static func open() {
        for window in NSApp.windows where window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true {
            window.performClose(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let main = mainWindow() { main.makeKeyAndOrderFront(nil) }
        FeedbackService.shared.isPresenting = true
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") != true }
    }

    /// The app's own window as a picture, drawn by the app itself, so no
    /// screen recording permission is involved.
    static func captureMainWindow() -> Data? {
        guard let view = mainWindow()?.contentView?.superview ?? mainWindow()?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return FeedbackImage.prepare(png)
    }

    /// True when something is presented as a sheet over the main window.
    static var isSheetShowing: Bool { mainWindow()?.attachedSheet != nil || NSApp.modalWindow != nil }
}
#else
enum FeedbackLauncher {
    /// True when something is presented over the app (a sheet or a full-screen cover).
    static var isSheetShowing: Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return false }
        while let next = top.presentedViewController { top = next }
        return top !== scene.keyWindow?.rootViewController
    }
}
#endif
