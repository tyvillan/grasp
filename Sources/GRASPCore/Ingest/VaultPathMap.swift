import Foundation
import GRDB

/// How a file's path on this machine maps to the path stored as its
/// identity. Notes, courses and excluded folders are keyed by full path,
/// and the Mac stores Mac paths. On a PC the same iCloud files sit under
/// iCloud for Windows' folder, so an import there stores the Mac's path for
/// any iCloud file and both machines update the same rows. `identity` (the
/// Mac, or a library with no Mac paths yet) stores paths as they are.
public struct VaultPathMap: Sendable, Equatable {
    /// `/Users/<name>` on the Mac; nil for `identity`.
    public let macHome: String?
    /// iCloud for Windows' folder, with forward slashes, e.g.
    /// `C:/Users/Tyler/iCloudDrive`.
    public let iCloudDrive: String

    public static let identity = VaultPathMap(macHome: nil, iCloudDrive: "")

    public init(macHome: String?, iCloudDrive: String) {
        self.macHome = macHome.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        self.iCloudDrive = Self.normalised(iCloudDrive)
    }

    public var isIdentity: Bool { macHome == nil }

    /// The Mac home that the library's paths were imported under, from any
    /// course folder or note with a `/Users/<name>/` path.
    public static func macHome(in db: Database) throws -> String? {
        let path = try String.fetchOne(db, sql: """
            SELECT folderPath FROM course WHERE folderPath LIKE '/Users/%'
            UNION ALL SELECT relativePath FROM material WHERE relativePath LIKE '/Users/%'
            LIMIT 1
            """)
        guard let parts = path?.split(separator: "/", omittingEmptySubsequences: true), parts.count >= 2 else {
            return nil
        }
        return "/\(parts[0])/\(parts[1])"
    }

    /// The identity to store for a path on this machine.
    public func stored(forLocal path: String) -> String {
        guard let macHome, let rest = componentsUnderDrive(path) else { return path }
        let mobile = macHome + "/Library/Mobile Documents"
        guard let first = rest.first else { return mobile + "/com~apple~CloudDocs" }
        if first == "Desktop" || first == "Documents" {
            return ([macHome] + rest).joined(separator: "/")
        }
        if first.contains("~") {
            return ([mobile, first, "Documents"] + rest.dropFirst()).joined(separator: "/")
        }
        return ([mobile, "com~apple~CloudDocs"] + rest).joined(separator: "/")
    }

    /// Where a stored path's file is on this machine.
    public func local(forStored path: String) -> String {
        guard let macHome, path == macHome || path.hasPrefix(macHome + "/"),
              let components = ICloudPath.componentsInICloudDrive(macPath: path)
        else { return path }
        return ([iCloudDrive] + components).joined(separator: "/")
    }

    private func componentsUnderDrive(_ path: String) -> [String]? {
        let drive = iCloudDrive.lowercased()
        let local = Self.normalised(path)
        guard !drive.isEmpty else { return nil }
        let lower = local.lowercased()
        if lower == drive { return [] }
        guard lower.hasPrefix(drive + "/") else { return nil }
        return local.dropFirst(drive.count + 1).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Forward slashes, no trailing slash, and no `/` before a drive letter
    /// (`/C:/x` → `C:/x`).
    static func normalised(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        if p.count >= 3, p.first == "/", p.dropFirst().dropFirst().first == ":" { p.removeFirst() }
        while p.count > 1, p.hasSuffix("/"), !p.hasSuffix(":/") { p.removeLast() }
        return p
    }
}
