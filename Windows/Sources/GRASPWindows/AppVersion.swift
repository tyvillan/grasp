import Foundation

/// The Windows app's version, kept here and nowhere else. Settings > About
/// and Send feedback both read it. Raise `number` when a build goes out;
/// the Mac's version is separate and set in its own project.
enum AppVersion {
    static let number = "0.1.0"

    /// The build: the day the running exe was built ("20261116").
    static let build: String = {
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let date = (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date) ?? nil
        guard let date else { return "unknown" }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }()

    /// "Version 0.1.0 (build 20261116)".
    static var display: String { "Version \(number) (build \(build))" }
}
