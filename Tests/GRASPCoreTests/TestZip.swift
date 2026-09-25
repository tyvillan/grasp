import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Writes a small zip at test time -- .pptx and .docx tests build their
/// archives here rather than checking in binary fixtures. ZIPFoundation
/// where it builds; on Windows, the system's tar.exe (bsdtar), the same
/// tool `ZipReader` reads with there.
enum TestZip {
    struct Failure: Error {}

    static func write(_ entries: [String: String], to url: URL) throws {
        #if canImport(ZIPFoundation)
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for (path, text) in entries {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        #elseif os(Windows)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (path, text) in entries {
            let file = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Not atomically: an atomic write swaps a temp file into place,
            // and on Windows that swap fails with a sharing violation if
            // anything (the indexer, Defender) has just opened the file.
            try Data(text.utf8).write(to: file)
        }
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: root + #"\System32\tar.exe"#)
        // --format=zip rather than -a: -a picks the format from the suffix,
        // and .pptx/.docx aren't suffixes it knows.
        process.arguments = ["--format=zip", "-cf", url.path, "-C", staging.path] + entries.keys.sorted()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure() }
        #else
        throw Failure()
        #endif
    }
}
