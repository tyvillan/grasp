import AppKit
import Foundation

/// Best-effort local setup actions for Ollama, for Settings' "Ollama Local
/// Server" section. There's no reliable way from user-land to tell "not
/// installed" apart from "installed somewhere unusual," so every path here
/// is "try it and move on" rather than surfacing a specific error --
/// `AppStore.refreshOllamaStatus()` run afterward is the actual source of
/// truth on whether it worked.
enum OllamaLauncher {
    static let downloadPageURL = URL(string: "https://ollama.com/download/mac")!
    private static let appBundlePath = "/Applications/Ollama.app"
    /// Common install locations for the bare CLI (Homebrew's two prefixes,
    /// then the system path), tried when the menu-bar app isn't present --
    /// a Homebrew-only install has no app bundle to launch.
    private static let cliCandidates = [
        "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/usr/bin/ollama",
    ]

    static func openDownloadPage() {
        NSWorkspace.shared.open(downloadPageURL)
    }

    /// Launching the menu-bar app is preferred when it's present: unlike
    /// the bare CLI daemon, it stays running in the background on its own
    /// (including across reboots, if the user enabled that), so it's the
    /// closer match to what "start the service" means to someone who
    /// installed it the normal way.
    static func startService() {
        if FileManager.default.fileExists(atPath: appBundlePath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: appBundlePath))
            return
        }
        guard let binary = cliCandidates.first(where: FileManager.default.fileExists(atPath:)) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
