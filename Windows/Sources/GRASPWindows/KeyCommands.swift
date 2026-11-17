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
               let message = UnsafeMutablePointer<MSG>(bitPattern: Int(lParam)),
               message.pointee.message == UINT(WM_KEYDOWN) {
                let vk = Int32(message.pointee.wParam)
                if let taken = KeyCommands.sheetKey(vk) {
                    // A sheet is up: Return confirms it, every other key goes
                    // to the sheet's own controls, never the screen behind.
                    if taken { message.pointee.message = UINT(WM_NULL) }
                } else if let handler = KeyCommands.handler, let key = KeyCommands.key(forVirtualKey: vk), handler(key) {
                    // Swallowed: the control with focus never sees it.
                    message.pointee.message = UINT(WM_NULL)
                }
            }
            return CallNextHookEx(nil, code, wParam, lParam)
        }, nil, GetCurrentThreadId())
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
