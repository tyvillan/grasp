#if os(Windows)
import Foundation
import WinSDK

/// Gives a GUI launch somewhere to write. Linked as a GUI program (see
/// grasp.ps1) and started from a shortcut, GRASP has no stdout or stderr,
/// and a write to a missing stream fail-fasts in ucrtbase. SwiftCrossUI
/// logs at startup, and the Swift runtime prints crash reports, so both go
/// to `GRASPWindows.log` in the library folder instead. Called by
/// `Launcher` before SwiftCrossUI starts.
enum ConsoleOutput {
    /// Makes the C runtime report a bad argument as a failed call instead
    /// of killing the app. Started from a shortcut, SwiftCrossUI's console
    /// setup passes the runtime an invalid argument on launch, and the
    /// default handler fail-fasts (0xc0000409 in ucrtbase) before a window
    /// ever appears. With this the call just fails and GRASP carries on,
    /// which is what that console setup expects anyway.
    static func tolerateInvalidParameters() {
        _set_invalid_parameter_handler { _, _, _, _, _ in }
    }

    static func redirectIfDetached() {
        guard !hasUsableHandle(STD_OUTPUT_HANDLE) || !hasUsableHandle(STD_ERROR_HANDLE) else { return }
        guard let folder = try? Library.supportDirectory() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("GRASPWindows.log").path
        var reopened: UnsafeMutablePointer<FILE>?
        guard freopen_s(&reopened, path, "w", stdout) == 0,
              freopen_s(&reopened, path, "a", stderr) == 0 else { return }
        setvbuf(stdout, nil, _IOLBF, 1024)
        // Unbuffered, so the last words before a crash reach the file.
        setvbuf(stderr, nil, _IONBF, 0)
        // Win32-level writers (the Swift runtime's crash reports) read the
        // process's standard handles rather than the C streams.
        SetStdHandle(STD_OUTPUT_HANDLE, HANDLE(bitPattern: _get_osfhandle(_fileno(stdout))))
        SetStdHandle(STD_ERROR_HANDLE, HANDLE(bitPattern: _get_osfhandle(_fileno(stderr))))
    }

    /// Whether the standard handle exists. INVALID_HANDLE_VALUE (-1) is a
    /// macro Swift doesn't import, hence the bit pattern.
    private static func hasUsableHandle(_ which: DWORD) -> Bool {
        guard let handle = GetStdHandle(which) else { return false }
        return Int(bitPattern: handle) != -1
    }
}
#endif
