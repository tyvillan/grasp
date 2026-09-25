import Foundation
import GRASPCore
import GRDB
import Observation

/// One deck as the sidebar lists it.
struct DeckRow: Identifiable, Hashable {
    let id: String
    let courseName: String
    let name: String
    let total: Int
    let due: Int
    let drafts: Int
}

/// The signed-in profile's library: what the screens show, and the
/// actions they take on it. The Windows counterpart of the Mac app's
/// `AppStore`, kept thin -- the study logic itself is GRASPCore's `Study`.
@Observable
final class Library {
    let database: GRASPDatabase
    private(set) var decks: [DeckRow] = []
    /// The result of the last import, or why it failed.
    var status: String?
    private(set) var isImporting = false

    init() throws {
        let support = try Self.supportDirectory()
        var profiles = try ProfileStore.loadOrMigrate(supportDirectory: support)
        // No profile picker or sign-in yet: a fresh install gets one profile.
        if profiles.isEmpty {
            profiles = [Profile(name: "Me")]
            try ProfileStore.save(profiles, supportDirectory: support)
        }
        database = try GRASPDatabase(path: profiles[0].databaseURL(supportDirectory: support))
        reload()
    }

    /// Where the library lives. `GRASP_SUPPORT_DIR` overrides it -- on a
    /// Mac, trying this app would otherwise open the real Mac app's
    /// library, which uses the same folder.
    static func supportDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["GRASP_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return try GRASPDatabase.supportDirectory()
    }

    func reload() {
        let now = Date()
        decks = (try? database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT deck.id, deck.name, course.name AS courseName,
                       COUNT(card.id) AS total,
                       COALESCE(SUM(CASE WHEN card.status = 'active' AND card.due <= ? THEN 1 ELSE 0 END), 0) AS due,
                       COALESCE(SUM(CASE WHEN card.status = 'draft' THEN 1 ELSE 0 END), 0) AS drafts
                FROM deck
                JOIN course ON course.id = deck.courseId
                LEFT JOIN deckCard ON deckCard.deckId = deck.id
                LEFT JOIN card ON card.id = deckCard.cardId
                     AND card.deletedAt IS NULL AND card.status != 'suspended'
                WHERE deck.deletedAt IS NULL AND course.isArchived = 0
                GROUP BY deck.id
                ORDER BY course.name, deck.sortIndex, deck.name
                """, arguments: [now])
            .map { row in
                DeckRow(id: row["id"], courseName: row["courseName"], name: row["name"],
                        total: row["total"], due: row["due"], drafts: row["drafts"])
            }
        }) ?? []
    }

    // MARK: - Importing

    /// Imports a notes folder laid out as `College/<semester>/<course>/`.
    func importVault(at root: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let summary = try await VaultScanner(database: database).scan(vaultRoot: root)
            if summary.courseCount == 0 {
                status = "No courses found. GRASP looks for College\\<semester>\\<course> folders inside \(root.lastPathComponent)."
            } else {
                status = "Imported \(summary.filesImportedOrUpdated) note(s) from \(summary.courseCount) course(s): "
                    + "\(summary.cardsCreated) new card(s)."
                    + (summary.errors.first.map { " First problem: \($0)" } ?? "")
            }
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
        reload()
    }

    /// Imports the built-in one-lecture Matrix Theory vault.
    func importSample() async {
        do {
            let root = try Self.supportDirectory().appendingPathComponent("Sample Notes", isDirectory: true)
            await importVault(at: try SampleVault.write(to: root))
        } catch {
            status = "Couldn't write the sample notes: \(error.localizedDescription)"
        }
    }

    // MARK: - Studying

    func dueCards(inDeck deckId: String) -> [Card] {
        (try? database.queue.read { try Study.dueCards(inDecks: [deckId], db: $0) }) ?? []
    }

    func approveDrafts(inDeck deckId: String) {
        try? database.queue.write { try Study.approveDrafts(inDecks: [deckId], db: $0) }
        reload()
    }

    func grade(_ card: Card, _ grade: FSRS.Grade) {
        try? database.queue.write { try Study.grade(card.id, grade: grade, source: "flashcards", db: $0) }
        reload()
    }

    // MARK: - Figures

    /// The first row reduction in this deck's notes, walked step by step.
    func rowReduction(inDeck deckId: String) -> RowReductionSteps? {
        try? database.queue.read { db in
            for material in try OverviewQueries.materials(forDecks: [deckId], db: db) {
                guard let note = try NoteText.fetchOne(db, key: material.id) else { continue }
                for text in [note.raw, note.reflowed] {
                    if let walk = NoteMatrices.walkthroughs(in: text).first {
                        let walked = walk.start.walk(walk.steps)
                        return RowReductionSteps(states: walked.states, steps: walked.steps,
                                                 fromNote: walk.stepsFromNote)
                    }
                }
            }
            return nil
        }
    }
}

/// A row reduction ready to draw: `states[0]` is the starting matrix and
/// `steps[i]` turns `states[i]` into `states[i + 1]`.
struct RowReductionSteps {
    let states: [RationalMatrix]
    let steps: [RowOperation]
    let fromNote: Bool
}
