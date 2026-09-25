import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Read-only access to the parts of a zip -- all .pptx and .docx need,
/// since both are zips of XML parts.
///
/// ZIPFoundation does the reading wherever it builds. It doesn't build on
/// Windows (its zlib shim uses `#import`, which the Windows compiler reads
/// as a COM type-library import, and Windows ships no zlib anyway), so
/// there the reading goes through the `tar.exe` Windows has included since
/// Windows 10 1803 -- it's bsdtar, which reads zip archives as well as tarballs.
struct ZipReader {
    /// Every file entry's path inside the archive, `/`-separated.
    let paths: [String]

    #if canImport(ZIPFoundation)
    private let archive: Archive

    init?(url: URL) {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return nil }
        self.archive = archive
        paths = archive.filter { $0.type == .file }.map(\.path)
    }

    func data(at path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        guard (try? archive.extract(entry) { data.append($0) }) != nil else { return nil }
        return data
    }
    #elseif os(Windows)
    private let url: URL

    init?(url: URL) {
        self.url = url
        guard let listing = Self.tar(["-tf", url.path]) else { return nil }
        paths = String(decoding: listing, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasSuffix("/") }
    }

    func data(at path: String) -> Data? {
        guard paths.contains(path) else { return nil }
        return Self.tar(["-xOf", url.path, path])
    }

    /// Runs Windows' tar and returns what it wrote, or nil if it failed.
    private static func tar(_ arguments: [String]) -> Data? {
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: root + #"\System32\tar.exe"#)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read before waiting: a large part fills the pipe, and tar blocks
        // until someone drains it.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
    #else
    init?(url: URL) { nil }
    func data(at path: String) -> Data? { nil }
    #endif
}
