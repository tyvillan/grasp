import Foundation
import SwiftCrossUI

/// The entry point: makes a shortcut launch safe before SwiftCrossUI
/// starts, then runs the app.
///
/// This has to run first. Started from a shortcut, a GUI program has no
/// console, and SwiftCrossUI's WinUI backend sets up the console in
/// `earlySetup()`, before `GRASPWindowsApp.init()`. There it hands the C
/// runtime an invalid argument, which by default kills the app on launch
/// (0xc0000409 in ucrtbase), and it logs to a stderr that doesn't exist.
@main
enum Launcher {
    static func main() {
        #if os(Windows)
        ConsoleOutput.tolerateInvalidParameters()
        // Before the log redirect, which would truncate the open window's log.
        if SignInLink.handOffIfLink() { return }
        ConsoleOutput.redirectIfDetached()
        SignInLink.claim()
        #endif
        GRASPWindowsApp.main()
    }
}
