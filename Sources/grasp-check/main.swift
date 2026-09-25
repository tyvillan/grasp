import Foundation
import GRDB
import GRASPCore

// `swift run grasp-check`: does GRASP's core work on this machine?
//
// Built for Windows first, where there's no GRASP app yet to try things in.
// Each step exercises one part of the core the app will stand on --
// the database, importing notes, the study scheduler, the overview maths,
// the local AI connection -- and prints what happened. The last line says
// whether everything passed; the exit code says the same for scripts.

var failures = 0

@MainActor func step(_ name: String, _ body: @MainActor () async throws -> String) async {
    do {
        let detail = try await body()
        print("  ✓ \(name)" + (detail.isEmpty ? "" : " -- \(detail)"))
    } catch {
        failures += 1
        print("  ✗ \(name) -- \(error)")
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

#if os(Windows)
let platform = "Windows"
#elseif os(macOS)
let platform = "macOS"
#elseif os(Linux)
let platform = "Linux"
#else
let platform = "another platform"
#endif

print("GRASP core check on \(platform)\n")

let workspace = FileManager.default.temporaryDirectory
    .appendingPathComponent("grasp-check-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: workspace) }

var database: GRASPDatabase!

await step("Create a library database") {
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    database = try GRASPDatabase(path: workspace.appendingPathComponent("library.sqlite"))
    let tables = try await database.queue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    guard tables.contains("card"), tables.contains("noteOverview"), tables.contains("syncOutbox") else {
        throw CheckFailure("missing tables; found \(tables.sorted())")
    }
    return "\(tables.count) tables, every migration applied"
}

await step("Find the app's data folder") {
    try GRASPDatabase.supportDirectory().path
}

let lecture = SampleVault.lecture

await step("Import a note") {
    let vault = try SampleVault.write(to: workspace.appendingPathComponent("vault", isDirectory: true))
    let summary = try await VaultScanner(database: database).scan(vaultRoot: vault)
    guard summary.errors.isEmpty else { throw CheckFailure(summary.errors.joined(separator: "; ")) }
    guard summary.cardsCreated > 0 else { throw CheckFailure("no cards made from \(summary.filesScanned) file(s)") }
    return "\(summary.filesScanned) file, \(summary.courseCount) course, \(summary.cardsCreated) cards"
}

await step("Schedule a review") {
    let now = Date()
    let first = FSRS.schedule(FSRS.Snapshot(stability: 0, difficulty: 0, reps: 0, lapses: 0, state: .new, lastReview: nil),
                              grade: .good, now: now)
    guard first.due > now else { throw CheckFailure("due date isn't in the future") }
    return "next review in \(Int(first.due.timeIntervalSince(now) / 60)) minutes"
}

await step("Row-reduce the lecture's matrix") {
    guard let walk = NoteMatrices.walkthroughs(in: lecture).first else { throw CheckFailure("no matrix found") }
    let end = walk.start.walk(walk.steps).states.last!
    guard walk.matchesNoteResult, end.isReducedEchelon else { throw CheckFailure("steps don't reach the note's result") }
    return "\(walk.steps.count) steps from the note, free variables x\(end.variableKinds!.free.map { String($0 + 1) }.joined(separator: ", x"))"
}

await step("Draw math notation") {
    let pretty = MathNotation.prettify("a11x1 + a12x2 = b1 in R3")
    guard pretty == "a₁₁x₁ + a₁₂x₂ = b₁ in ℝ³" else { throw CheckFailure("got \(pretty)") }
    return pretty
}

await step("Hash note contents") {
    // Content hashes decide when a note changed; this runs through
    // swift-crypto off Apple platforms.
    let count = try await database.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM material WHERE contentHash IS NOT NULL") ?? 0
    }
    guard count > 0 else { throw CheckFailure("imported note has no content hash") }
    return "ok"
}

await step("Record changes for sync") {
    let pending = try await database.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOutbox") ?? 0
    }
    return "\(pending) change(s) waiting (sync is off until you sign in, so 0 is expected)"
}

await step("Look for a local AI model") {
    let generator = await CardGenerators.select()
    switch generator {
    case let ollama as OllamaGenerator: return "Ollama is running, using \(ollama.modelName)"
    case is NoGenerator: return "none found -- install Ollama for AI features (optional for this check)"
    default: return String(describing: type(of: generator))
    }
}

print(failures == 0
      ? "\nEverything passed. GRASP's core works on \(platform)."
      : "\n\(failures) check(s) failed. Copy everything above and send it over.")
exit(failures == 0 ? 0 : 1)
