#if os(Windows)
import Foundation
import WinSDK

/// Opens a web page in the default browser. ShellExecute rather than
/// SwiftCrossUI's `openURL`, which blocks the UI thread until WinRT's
/// launcher reports back.
nonisolated enum ExternalLink {
    static func open(_ url: URL) {
        _ = url.absoluteString.withCString(encodedAs: UTF16.self) { target in
            "open".withCString(encodedAs: UTF16.self) { verb in
                ShellExecuteW(nil, verb, target, nil, nil, SW_SHOWNORMAL)
            }
        }
    }
}
#endif
