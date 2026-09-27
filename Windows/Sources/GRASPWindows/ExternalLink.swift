#if os(Windows)
import Foundation
import WinSDK

/// Opens a web page in the default browser. ShellExecute rather than
/// SwiftCrossUI's `openURL`, which blocks the UI thread until WinRT's
/// launcher reports back.
nonisolated enum ExternalLink {
    static func open(_ url: URL) {
        shellExecute(url.absoluteString, parameters: nil)
    }

    /// Opens a file in its default app, like double-clicking it.
    static func openFile(_ url: URL) {
        shellExecute(url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path, parameters: nil)
    }

    /// Opens File Explorer with the file selected (the Mac's "Show in Finder").
    static func showInExplorer(_ url: URL) {
        let path = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        shellExecute("explorer.exe", parameters: "/select,\"\(path)\"")
    }

    private static func shellExecute(_ target: String, parameters: String?) {
        _ = target.withCString(encodedAs: UTF16.self) { file in
            "open".withCString(encodedAs: UTF16.self) { verb in
                if let parameters {
                    return parameters.withCString(encodedAs: UTF16.self) {
                        ShellExecuteW(nil, verb, file, $0, nil, SW_SHOWNORMAL)
                    }
                }
                return ShellExecuteW(nil, verb, file, nil, nil, SW_SHOWNORMAL)
            }
        }
    }
}

/// The Windows clipboard, for "Copy Path" and "Copy Lesson".
nonisolated enum Clipboard {
    static func copy(_ text: String) {
        let utf16 = Array(text.utf16) + [0]
        let bytes = utf16.count * MemoryLayout<UInt16>.size
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        // The clipboard takes ownership of the memory once it's set.
        guard let handle = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)), let pointer = GlobalLock(handle) else { return }
        utf16.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(handle)
        // CF_UNICODETEXT is 13; the macro doesn't import.
        _ = SetClipboardData(13, handle)
    }
}
#endif
