#if os(Windows)
import Foundation
import WinSDK

/// Keyboard shortcuts for the screen that wants them -- flashcards use the
/// Mac's Space, 1, 2, arrows, E and S. SwiftCrossUI only reports Enter in a
/// text field, so this watches the UI thread's own key messages with a
/// thread-local `WH_GETMESSAGE` hook (never other apps' keys) and hands
/// them to whichever handler is set. A handler returning true swallows the
/// key.
///
/// Only one screen at a time sets a handler, and it clears it when it goes
/// away or opens a sheet with text fields, so typing is never hijacked.
enum KeyCommands {
    enum Key: Equatable {
        case space, left, right, escape, enter
        case character(Character)
    }

    /// Runs on the UI thread, inside the message loop.
    nonisolated(unsafe) static var handler: ((Key) -> Bool)?
    /// Who set `handler`, so a screen going away clears only its own (the
    /// next screen may already have set one).
    nonisolated(unsafe) static var owner: String?

    static func set(owner: String, _ handler: @escaping (Key) -> Bool) {
        self.owner = owner
        self.handler = handler
    }

    static func clear(owner: String) {
        guard self.owner == owner else { return }
        self.owner = nil
        handler = nil
    }
    nonisolated(unsafe) private static var hook: HHOOK?

    /// The sheets on screen, innermost last, each with what Return does
    /// (its one yellow button). While any sheet is up the screen's handler
    /// gets no keys. Escape is WinUI's own: the dialog closes itself.
    struct SheetReturn {
        let id: String
        let confirm: () -> Void
        /// A sheet with a multi-line text box: plain Return types a new
        /// line there, so Ctrl+Return confirms instead.
        let multiline: Bool
    }
    nonisolated(unsafe) static var sheets: [SheetReturn] = []

    static func pushSheet(_ sheet: SheetReturn) {
        sheets.removeAll { $0.id == sheet.id }
        sheets.append(sheet)
    }

    static func popSheet(_ id: String) {
        sheets.removeAll { $0.id == id }
    }

    /// Return in the innermost sheet: true when it was taken.
    private static func sheetKey(_ vk: Int32) -> Bool? {
        guard let top = sheets.last else { return nil }
        guard vk == VK_RETURN else { return false }
        let ctrl = GetKeyState(VK_CONTROL) < 0
        guard ctrl || !top.multiline else { return false }
        top.confirm()
        return true
    }

    /// Installed once, when the window first appears.
    static func install() {
        guard hook == nil else { return }
        hook = SetWindowsHookExW(WH_GETMESSAGE, { code, wParam, lParam in
            if code >= 0, wParam == WPARAM(PM_REMOVE),
               let message = UnsafeMutablePointer<MSG>(bitPattern: Int(lParam)) {
                let kind = message.pointee.message
                // Only key messages carry a key code here; others' wParam can
                // be any pointer-sized value, which a checked Int32(...)
                // traps on (it crashed the app seconds after launch).
                let vk = Int32(truncatingIfNeeded: message.pointee.wParam)
                if kind == UINT(WM_KEYDOWN) {
                    if let taken = KeyCommands.sheetKey(vk) {
                        // A sheet is up: Return confirms it, every other key goes
                        // to the sheet's own controls, never the screen behind.
                        if taken { KeyCommands.swallow(message, vk) }
                    } else if let handler = KeyCommands.handler, let key = KeyCommands.key(forVirtualKey: vk), handler(key) {
                        // Swallowed: the control with focus never sees it.
                        KeyCommands.swallow(message, vk)
                    }
                } else if kind == UINT(WM_KEYUP) || kind == UINT(WM_CHAR),
                          // WM_CHAR carries the character: a lower-case letter
                          // maps back to its key; Return, Space and digits are
                          // the same number either way.
                          KeyCommands.swallowed.contains(kind == UINT(WM_CHAR) && (97...122).contains(vk) ? vk - 32 : vk) {
                    // The rest of a key we took. WinUI buttons act on the
                    // key-up of Return and Space, so letting it through
                    // pressed whatever had focus: after a click on a choice
                    // row (which can't take focus) that was the course's
                    // "⋯" menu, and Return in Test opened it.
                    if kind == UINT(WM_KEYUP) { KeyCommands.swallowed.remove(vk) }
                    message.pointee.message = UINT(WM_NULL)
                }
            }
            return CallNextHookEx(nil, code, wParam, lParam)
        }, nil, GetCurrentThreadId())
    }

    /// Keys whose key-down was taken, so their key-up and character are
    /// taken too.
    nonisolated(unsafe) static var swallowed: Set<Int32> = []

    static func swallow(_ message: UnsafeMutablePointer<MSG>, _ vk: Int32) {
        message.pointee.message = UINT(WM_NULL)
        swallowed.insert(vk)
    }

    private static func key(forVirtualKey vk: Int32) -> Key? {
        switch vk {
        case VK_SPACE: return .space
        case VK_LEFT: return .left
        case VK_RIGHT: return .right
        case VK_ESCAPE: return .escape
        case VK_RETURN: return .enter
        case 0x30...0x39: return .character(Character(Unicode.Scalar(UInt8(vk))))          // 0-9
        case 0x41...0x5A: return .character(Character(Unicode.Scalar(UInt8(vk + 0x20))))   // A-Z, as a-z
        case 0x61...0x69: return .character(Character(String(vk - 0x60)))                  // number pad 1-9
        default: return nil
        }
    }
}
#endif
