import Foundation

/// What running a program came to.
public struct CodeRunResult: Sendable, Equatable {
    public var compiled: Bool
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var exitCode: Int32

    public init(compiled: Bool, stdout: String = "", stderr: String = "", timedOut: Bool = false,
                exitCode: Int32 = 0) {
        self.compiled = compiled; self.stdout = stdout; self.stderr = stderr
        self.timedOut = timedOut; self.exitCode = exitCode
    }

    /// Compiled, finished in time, and exited cleanly.
    public var succeeded: Bool { compiled && !timedOut && exitCode == 0 }
}

/// Something that can compile and run a program. A protocol so the
/// question builder can be tested without a compiler, and so a device
/// with none (the iPhone, Windows) still builds.
public protocol CodeExecuting: Sendable {
    /// Whether this language can be run here at all.
    func canRun(_ language: CodeLanguage) -> Bool
    func run(_ source: String, language: CodeLanguage) async -> CodeRunResult
}

public enum CodeSafety {
    /// Calls and imports that have no place in a teaching example: running
    /// other programs, the network, deleting or writing files. Checked
    /// before anything is compiled, because the program was written by a
    /// model. Free-function calls only, so `list.remove(3)` is fine.
    private static let patterns: [(label: String, regex: NSRegularExpression)] = [
        ("a call that runs another program or opens a connection",
         #"(?<![\w.>:])(system|popen|fork|vfork|execv\w*|execl\w*|execp\w*|posix_spawn\w*|socket|connect|kill)\s*\("#),
        ("a call that changes files",
         #"(?<![\w.>:])(remove|unlink|rmdir|rename|fopen|freopen|open|signal|eval|exec)\s*\("#),
        ("file output or a system header",
         #"std::filesystem|<filesystem>|\bofstream\b|<unistd\.h>|<sys/|\b__asm|\basm\s*\("#),
        ("an import that reaches outside the program",
         #"^\s*(import|from)\s+(os|subprocess|socket|shutil|pathlib|ctypes|multiprocessing|urllib|http)\b|__import__"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.anchorsMatchLines])) }

    /// Whether the program waits for typed input, which a question can't
    /// give it: with nothing to read, what it prints is meaningless.
    public static func readsInput(_ source: String) -> Bool {
        let pattern = #"\bcin\b|\bscanf\s*\(|\bgetchar\s*\(|\bgetline\s*\(\s*cin|\binput\s*\(|sys\.stdin|\bstdin\b"#
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    /// What is wrong with `source`, nil when it's clean.
    public static func violation(in source: String) -> String? {
        let range = NSRange(location: 0, length: (source as NSString).length)
        return patterns.first { $0.regex.firstMatch(in: source, range: range) != nil }?.label
    }
}

#if os(macOS)
/// Compiles C++ with `clang++` and runs Python with the system `python3`,
/// each in a throwaway directory, with a time limit, capped output, and the
/// run itself inside `sandbox-exec` with no network and no writes outside
/// that directory.
public struct ProcessCodeExecutor: CodeExecuting {
    public var compileTimeout: TimeInterval
    public var runTimeout: TimeInterval
    static let outputLimit = 64 * 1024

    public init(compileTimeout: TimeInterval = 40, runTimeout: TimeInterval = 8) {
        self.compileTimeout = compileTimeout
        self.runTimeout = runTimeout
    }

    static let clang = "/usr/bin/clang++"
    static let python = "/usr/bin/python3"

    public func canRun(_ language: CodeLanguage) -> Bool {
        let tool = language == .cpp ? Self.clang : Self.python
        // /usr/bin shims exist even without developer tools installed;
        // asking for the developer directory tells the two apart.
        guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
        let probe = Self.launch("/usr/bin/xcode-select", ["-p"], timeout: 5)
        return probe.exitCode == 0
    }

    public func run(_ source: String, language: CodeLanguage) async -> CodeRunResult {
        if let token = CodeSafety.violation(in: source) {
            return CodeRunResult(compiled: false, stderr: "Not run: the program contains \(token)")
        }
        let (compileTimeout, runTimeout) = (self.compileTimeout, self.runTimeout)
        // On a thread of its own: compiling and running block for seconds,
        // and doing that on the shared async or dispatch pools starves
        // everything else waiting for a thread.
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Self.execute(source, language: language,
                                                            compileTimeout: compileTimeout, runTimeout: runTimeout))
            }
        }
    }

    private static func execute(_ source: String, language: CodeLanguage, compileTimeout: TimeInterval,
                                runTimeout: TimeInterval) -> CodeRunResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-code-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("main." + language.fileExtension)
                try source.write(to: file, atomically: true, encoding: .utf8)
                // The sandbox profile names the real path (no /var -> /private/var link).
                let sandboxDirectory = directory.resolvingSymlinksInPath().path

                var command: [String]
                switch language {
                case .cpp:
                    let binary = directory.appendingPathComponent("main.out").path
                    let compile = Self.launch(Self.clang, ["-std=c++17", "-O0", "-Wno-everything", "-Werror=uninitialized", "-Werror=sometimes-uninitialized", "-Werror=return-type", file.path, "-o", binary],
                                              timeout: compileTimeout, directory: directory.path)
                    guard compile.exitCode == 0, !compile.timedOut else {
                        return CodeRunResult(compiled: false, stderr: compile.stderr, timedOut: compile.timedOut,
                                             exitCode: compile.exitCode)
                    }
                    command = [binary]
                case .python:
                    command = [Self.python, "-B", file.path]
                }
                let profile = """
                (version 1)
                (allow default)
                (deny network*)
                (deny file-write* (require-not (require-any (subpath "\(sandboxDirectory)") \
                (literal "/dev/null") (literal "/dev/dtracehelper") (literal "/dev/tty"))))
                """
                let run = Self.launch("/usr/bin/sandbox-exec", ["-p", profile] + command,
                                      timeout: runTimeout, directory: directory.path)
                return CodeRunResult(compiled: true, stdout: run.stdout, stderr: run.stderr,
                                     timedOut: run.timedOut, exitCode: run.exitCode)
            }
        } catch {
            return CodeRunResult(compiled: false, stderr: "\(error)")
        }
    }

    struct Launched {
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = -1
        var timedOut = false
    }

    /// Runs a program to completion, killing it at `timeout`.
    static func launch(_ path: String, _ arguments: [String], timeout: TimeInterval,
                       directory: String? = nil) -> Launched {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        var result = Launched()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            result.stderr = "\(error)"
            return result
        }
        // Read while it runs, so a chatty program can't fill the pipe and
        // stall, and stop keeping output past the limit. Each pipe gets its
        // own thread: blocking reads on the shared dispatch pool starve
        // whatever else is running there.
        let outData = LockedData(), errData = LockedData()
        let readers = DispatchGroup()
        for (pipe, store) in [(out, outData), (err, errData)] {
            readers.enter()
            Thread.detachNewThread {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    store.append(chunk, limit: outputLimit)
                }
                readers.leave()
            }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            result.timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        // The process is gone, so each pipe reaches its end; give the
        // readers time to drain what is left.
        _ = readers.wait(timeout: .now() + 10)
        result.exitCode = process.terminationStatus
        result.stdout = String(decoding: outData.data, as: UTF8.self)
        result.stderr = String(decoding: errData.data, as: UTF8.self)
        return result
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ chunk: Data, limit: Int) {
            lock.lock(); defer { lock.unlock() }
            if storage.count < limit { storage.append(chunk.prefix(limit - storage.count)) }
        }
    }
}
#endif
