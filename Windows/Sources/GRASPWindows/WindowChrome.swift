#if os(Windows)
import Foundation
import WinSDK

/// Paints the window's title bar in GRASP's canvas colours, so the system
/// caption doesn't sit white above a dark window. SwiftCrossUI doesn't expose
/// the title bar, so this sets DWM attributes on the window handle, found the
/// same way `WindowIcon` finds it. The native min/max/close buttons stay.
///
/// Attribute support by Windows version:
/// - Dark caption (`DWMWA_USE_IMMERSIVE_DARK_MODE`): 20 on Windows 10 20H1
///   (build 18985) and later and on Windows 11; 19 on Windows 10 1809 to 1909.
///   Both are tried, 20 first.
/// - Caption, text and border colour (34 to 36): Windows 11 (build 22000)
///   only. On Windows 10 they fail harmlessly and the dark caption stands.
nonisolated enum WindowChrome {
    private static let useImmersiveDarkModeBefore20H1: DWORD = 19
    private static let useImmersiveDarkMode: DWORD = 20
    private static let borderColor: DWORD = 34
    private static let captionColor: DWORD = 35
    private static let textColor: DWORD = 36

    private typealias SetAttribute = @convention(c) (HWND?, DWORD, UnsafeRawPointer?, DWORD) -> Int32

    static func apply(to window: HWND) {
        guard let setAttribute = loadSetAttribute() else { return }
        let dark = appsUseDarkTheme()

        func set(_ attribute: DWORD, _ value: UInt32) -> Bool {
            var v = value
            return withUnsafeBytes(of: &v) { setAttribute(window, attribute, $0.baseAddress, DWORD($0.count)) } == 0
        }
        // COLORREF is 0x00BBGGRR.
        func colorref(_ rgb: UInt32) -> UInt32 {
            ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
        }

        if !set(useImmersiveDarkMode, dark ? 1 : 0) {
            _ = set(useImmersiveDarkModeBefore20H1, dark ? 1 : 0)
        }
        // The canvas and cream text, matching GRASPColor.canvas / textPrimary.
        let canvas: UInt32 = dark ? 0x0E100F : 0xF7F4E3
        let text: UInt32 = dark ? 0xFFFCE1 : 0x14160F
        let border: UInt32 = dark ? 0x2C2E2A : 0xE2DDC4
        _ = set(captionColor, colorref(canvas))
        _ = set(textColor, colorref(text))
        _ = set(borderColor, colorref(border))
    }

    private static func loadSetAttribute() -> SetAttribute? {
        let module = "dwmapi.dll".withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
        guard let module, let proc = GetProcAddress(module, "DwmSetWindowAttribute") else { return nil }
        return unsafeBitCast(proc, to: SetAttribute.self)
    }

    /// The "Choose your default app mode" setting. Light when it can't be read.
    private static func appsUseDarkTheme() -> Bool {
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".withCString(encodedAs: UTF16.self) { path in
            "AppsUseLightTheme".withCString(encodedAs: UTF16.self) { name in
                RegGetValueW(HKEY_CURRENT_USER, path, name, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        return status == 0 && value == 0
    }
}
#endif
