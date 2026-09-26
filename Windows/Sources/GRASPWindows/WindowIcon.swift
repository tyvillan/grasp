#if os(Windows)
import Foundation
import WinSDK

/// Puts GRASP's icon on its window. The icon is embedded in the exe
/// (Windows\Resources\GRASP.rc, linked by grasp.ps1), which is enough for
/// Explorer and shortcuts, but WinUI gives each window its own generic
/// icon, and that's what the title bar and taskbar show. SwiftCrossUI
/// doesn't expose the window, so this finds it by process and sets the
/// icon through Win32 once it appears.
nonisolated enum WindowIcon {
    static func applyWhenWindowAppears() {
        Thread.detachNewThread {
            // The window shows within a second or two of launch; give up after 20 s.
            for _ in 0..<80 {
                if let window = mainWindow() {
                    apply(to: window)
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    private static func apply(to window: HWND) {
        let module = GetModuleHandleW(nil)
        // Resource id 1, as GRASP.rc names it (MAKEINTRESOURCE(1)).
        let id = UnsafePointer<WCHAR>(bitPattern: 1)
        for (kind, metric) in [(ICON_BIG, SM_CXICON), (ICON_SMALL, SM_CXSMICON)] {
            let size = GetSystemMetrics(metric)
            guard let icon = LoadImageW(module, id, UINT(IMAGE_ICON), size, size, UINT(LR_DEFAULTCOLOR)) else { continue }
            SendMessageW(window, UINT(WM_SETICON), WPARAM(kind), LPARAM(Int(bitPattern: icon)))
        }
    }

    /// This process's visible top-level window, if it's up yet.
    private static func mainWindow() -> HWND? {
        final class Search { var found: HWND? }
        let search = Search()
        withExtendedLifetime(search) {
            _ = EnumWindows({ window, context in
                guard let window else { return true }
                var owner: DWORD = 0
                GetWindowThreadProcessId(window, &owner)
                guard owner == GetCurrentProcessId(), IsWindowVisible(window),
                      GetWindow(window, UINT(GW_OWNER)) == nil else { return true }
                Unmanaged<Search>.fromOpaque(UnsafeRawPointer(bitPattern: Int(context))!)
                    .takeUnretainedValue().found = window
                return false
            }, LPARAM(Int(bitPattern: Unmanaged.passUnretained(search).toOpaque())))
        }
        return search.found
    }
}
#endif
