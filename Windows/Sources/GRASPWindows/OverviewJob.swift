import Foundation
import GRASPCore
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A run writing overviews for some notes with the local model, one note at
/// a time, like the Mac's overview AI job. Owned by `Library`, so it keeps
/// going (with its Stop button) when you switch decks and come back.
@Observable
final class OverviewJob {
    /// Which course's notes this run is for -- one run at a time per course.
    let courseId: String?
    private(set) var headline: String
    /// 0...1 across the whole run.
    private(set) var fraction = 0.0
    private(set) var isFinished = false
    /// Set when a run ends with notes it couldn't write, naming them.
    private(set) var failure: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(courseId: String?, headline: String) {
        self.courseId = courseId
        self.headline = headline
    }

    func stop() {
        task?.cancel()
    }

    /// Writes each note in turn, reloading the library after each so the
    /// lesson appears as soon as it's done.
    func run(_ notes: [(materialId: String, title: String)], library: Library) {
        task = Task { [weak self] in
            guard let self else { return }
            let generator = await CardGenerators.select()
            guard await generator.isAvailable, let ollama = generator as? OllamaGenerator else {
                failure = "Ollama isn't running, so nothing could be written. Settings shows its status."
                isFinished = true
                return
            }
            // Loads the model onto the graphics card before the first real
            // request. Cold, the load (over a minute here) ran inside the
            // lesson-plan call, which Ollama then failed with a 500 -- the
            // run carried on, but without its plan.
            headline = "Loading \(ollama.modelName) onto the graphics card…"
            await Self.warm(ollama)
            var failed: [String] = []
            var wroteAny = false
            for (index, note) in notes.enumerated() {
                if Task.isCancelled { break }
                headline = notes.count == 1
                    ? "Writing overview · \(note.title)"
                    : "Writing overview \(index + 1) of \(notes.count) · \(note.title)"
                let base = Double(index) / Double(notes.count)
                let share = 1.0 / Double(notes.count)
                let progress = AIProgress { [weak self] snapshot in
                    Task { @MainActor in self?.fraction = base + share * snapshot.fraction }
                }
                let outcome = await AIProgress.$current.withValue(progress) {
                    await OverviewWriter.write(materialId: note.materialId, force: true,
                                               using: generator, database: library.database)
                }
                switch outcome {
                case .written:
                    wroteAny = true
                    library.overviewsChanged()
                case .empty, .unavailable:
                    failed.append(note.title)
                case .unchanged, .tooShort, .tooLong, .cancelled:
                    break
                }
                fraction = Double(index + 1) / Double(notes.count)
            }
            if !Task.isCancelled, !failed.isEmpty {
                failure = Self.explain(failed: failed, wroteAny: wroteAny)
            }
            isFinished = true
        }
    }

    /// Asks Ollama to load the model and keep it loaded for the run: a
    /// generate request with no prompt does only that.
    private static func warm(_ generator: OllamaGenerator) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": generator.modelName, "keep_alive": "15m"])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Names the notes, because "2 notes failed" in a deck of eight leaves
    /// you hunting for which two.
    private static func explain(failed names: [String], wroteAny: Bool) -> String {
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        case 3...4: list = names.dropLast().joined(separator: ", ") + ", and " + names.last!
        default: list = "\(names.count) notes"
        }
        return "\(list) couldn't be written" + (wroteAny ? "; the rest were." : ".")
            + " The model either came back with nothing usable or stopped responding -- check that Ollama is running."
    }
}
