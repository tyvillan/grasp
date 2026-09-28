import Foundation

/// Where a Mac's iCloud file lives under iCloud for Windows. Notes are
/// stored by the path they were imported from, so a note imported on the
/// Mac carries a Mac path; the same file on a PC sits under `iCloudDrive`.
public enum ICloudPath {
    /// The part of `macPath` below iCloud Drive, as components, or nil when
    /// the file isn't in iCloud:
    /// - `…/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/a.md`
    ///   → `iCloud~md~obsidian/Vault/a.md` (Windows hides an app's `Documents`)
    /// - `…/Library/Mobile Documents/com~apple~CloudDocs/Notes/a.md` → `Notes/a.md`
    /// - `/Users/<name>/Desktop/a.pdf` → `Desktop/a.pdf` (Desktop & Documents in iCloud)
    public static func componentsInICloudDrive(macPath: String) -> [String]? {
        let parts = macPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "Users" else { return nil }
        let below = Array(parts.dropFirst(2))
        if below.count >= 3, below[0] == "Library", below[1] == "Mobile Documents" {
            let container = below[2]
            var rest = Array(below.dropFirst(3))
            if container == "com~apple~CloudDocs" { return rest.isEmpty ? nil : rest }
            if rest.first == "Documents" { rest.removeFirst() }
            return rest.isEmpty ? nil : [container] + rest
        }
        if below.count >= 2, below[0] == "Desktop" || below[0] == "Documents" {
            return below
        }
        return nil
    }

    /// `macPath` under `iCloudDrive` (iCloud for Windows' folder), or nil.
    public static func url(forMacPath macPath: String, iCloudDrive: URL) -> URL? {
        guard let components = componentsInICloudDrive(macPath: macPath) else { return nil }
        return components.reduce(iCloudDrive) { $0.appendingPathComponent($1) }
    }
}
