#if os(Windows)
import Foundation
import WinSDK

/// The `grasp://auth-callback` link Google sign-in comes back with.
///
/// Windows opens a `grasp://` link by starting a second GRASPWindows.exe
/// with the link as its argument. That copy hands the link to the window
/// that's already open (through a small file in the library folder, which
/// the waiting sign-in picks up) and quits before SwiftCrossUI starts.
///
/// Not SwiftCrossUI's own URL-scheme support: it delivers the link to the
/// running window on a background thread, which crashes it in libdispatch
/// about 15 seconds later, and leaves the second copy hanging.
nonisolated enum SignInLink {
    /// Held by the everyday window for as long as it's open, so a link
    /// launch knows there's someone to hand over to.
    private static let runningMarker = "Local\\GRASPWindows.Running"

    /// Test copies run under other exe names and must not take `grasp://`
    /// (or the running marker) over from the everyday window.
    static var isEverydayExe: Bool {
        ["graspwindows", "graspwindows.exe"].contains(ProcessInfo.processInfo.processName.lowercased())
    }

    // MARK: - The launch carrying a link

    /// Called first thing by `Launcher`. True when this launch only brought
    /// a link for the open window and should quit now. With no window open,
    /// GRASP just starts normally: a sign-in the app wasn't waiting for has
    /// nothing to finish.
    static func handOffIfLink() -> Bool {
        guard let link = CommandLine.arguments.dropFirst().first(where: { $0.lowercased().hasPrefix("grasp:") }),
              isRunning(),
              let inbox = inboxURL()
        else { return false }
        try? Data(link.utf8).write(to: inbox)
        bringWindowForward()
        return true
    }

    private static func isRunning() -> Bool {
        guard let handle = runningMarker.withCString(encodedAs: UTF16.self, { OpenMutexW(DWORD(SYNCHRONIZE), false, $0) })
        else { return false }
        CloseHandle(handle)
        return true
    }

    private static func bringWindowForward() {
        guard let window = "GRASP".withCString(encodedAs: UTF16.self, { FindWindowW(nil, $0) }) else { return }
        if IsIconic(window) { ShowWindow(window, SW_RESTORE) }
        SetForegroundWindow(window)
    }

    // MARK: - The open window

    /// Marks this window as the one links go to, and points `grasp://` at
    /// this exe (per user, no admin needed). Rewritten each launch, so the
    /// link follows the exe if it moves.
    static func claim() {
        guard isEverydayExe else { return }
        // Deliberately never closed: the marker lasts as long as the process.
        _ = runningMarker.withCString(encodedAs: UTF16.self) { CreateMutexW(nil, false, $0) }
        registerScheme()
    }

    /// The link a launch handed over, if one is waiting. Taking it removes it.
    static func take() -> URL? {
        guard let inbox = inboxURL(), let data = try? Data(contentsOf: inbox) else { return nil }
        try? FileManager.default.removeItem(at: inbox)
        return String(data: data, encoding: .utf8).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Clears a link left over from an earlier, abandoned sign-in.
    static func discard() {
        guard let inbox = inboxURL() else { return }
        try? FileManager.default.removeItem(at: inbox)
    }

    private static func inboxURL() -> URL? {
        (try? Library.supportDirectory())?.appendingPathComponent("sign-in-link.txt")
    }

    // MARK: - Registry

    private static func registerScheme() {
        var buffer = [WCHAR](repeating: 0, count: 1024)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard length > 0 else { return }
        let exe = String(decoding: buffer[0..<Int(length)], as: UTF16.self)

        let root = "Software\\Classes\\grasp"
        // Replaces whatever was there, including a registration an older
        // build made through the Windows App SDK.
        _ = root.withCString(encodedAs: UTF16.self) { RegDeleteTreeW(currentUser, $0) }
        setValue(root, nil, "URL:GRASP")
        setValue(root, "URL Protocol", "")
        setValue(root + "\\DefaultIcon", nil, "\"\(exe)\",0")
        setValue(root + "\\shell\\open\\command", nil, "\"\(exe)\" \"%1\"")
    }

    /// HKEY_CURRENT_USER, a macro Swift doesn't import: (HKEY)(LONG)0x80000001,
    /// sign-extended.
    private static var currentUser: HKEY? {
        HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001)))
    }

    private static func setValue(_ key: String, _ name: String?, _ value: String) {
        var data = Array(value.utf16) + [0]
        let bytes = DWORD(data.count * MemoryLayout<WCHAR>.size)
        key.withCString(encodedAs: UTF16.self) { key in
            data.withUnsafeMutableBytes { raw in
                if let name {
                    _ = name.withCString(encodedAs: UTF16.self) {
                        RegSetKeyValueW(currentUser, key, $0, DWORD(REG_SZ), raw.baseAddress, bytes)
                    }
                } else {
                    _ = RegSetKeyValueW(currentUser, key, nil, DWORD(REG_SZ), raw.baseAddress, bytes)
                }
            }
        }
    }
}
#endif
