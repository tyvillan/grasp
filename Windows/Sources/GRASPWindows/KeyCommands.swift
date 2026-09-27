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
    nonisolated(unsafe) private static var hook: HHOOK?

    /// Installed once, when the window first appears.
    static func install() {
        guard hook == nil else { return }
        hook = SetWindowsHookExW(WH_GETMESSAGE, { code, wParam, lParam in
            if code >= 0, wParam == WPARAM(PM_REMOVE),
               let message = UnsafeMutablePointer<MSG>(bitPattern: Int(lParam)),
               message.pointee.message == UINT(WM_KEYDOWN), let handler = KeyCommands.handler,
               let key = KeyCommands.key(forVirtualKey: Int32(message.pointee.wParam)),
               handler(key) {
                // Swallowed: the control with focus never sees it.
                message.pointee.message = UINT(WM_NULL)
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
