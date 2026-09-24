import Foundation
import GRASPCore

/// Where GRASP keeps profiles and their databases on this device.
enum AppPaths {
    static func supportDirectory() -> URL {
        (try? GRASPDatabase.supportDirectory()) ?? FileManager.default.temporaryDirectory
    }
}
