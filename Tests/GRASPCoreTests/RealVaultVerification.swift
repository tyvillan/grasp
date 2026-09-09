import Testing
import Foundation
import GRDB
@testable import GRASPCore

/// One-off verification against Tyler's real Obsidian vault, not a fixture
/// test -- confirms the scanner's counts match what was measured with the
/// Python prototype before any Swift was written. Not meant to run on any
/// other machine; delete or gate behind an env var if this ever needs to
/// run in a shared CI environment.
///
/// Known, deliberate exclusions verified against the corpus: 2 loose files
/// sitting directly under a semester folder rather than inside a course
/// subfolder (a schedule doc, an audit doc -- neither is lecture content),
/// and 1 Jupyter `.ipynb_checkpoints` artifact excluded by the ignore list.
@Suite("RealVaultVerification")
struct RealVaultVerificationTests {
    static let vaultRoot = URL(fileURLWithPath:
        "/Users/tyvillan/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault")

    @Test("scans the real vault and reports counts")
    func scansRealVault() async throws {
        guard FileManager.default.fileExists(atPath: Self.vaultRoot.path) else {
            Issue.record("Real vault not present on this machine -- skipping")
            return
        }
        let db = try GRASPDatabase.inMemory()
        let scanner = VaultScanner(database: db)
        let summary = try await scanner.scan(vaultRoot: Self.vaultRoot)

        print("""

        === Real vault scan ===
        files scanned:            \(summary.filesScanned)
        files imported/updated:   \(summary.filesImportedOrUpdated)
        skipped (asset sidecar):  \(summary.filesSkippedAsset)
        skipped (empty stub):     \(summary.filesSkippedEmpty)
        cards created:            \(summary.cardsCreated)
        semesters:                \(summary.semesterCount)
        courses:                  \(summary.courseCount)
        errors:                   \(summary.errors.count)
        """)
        if !summary.errors.isEmpty {
            print("first errors: \(summary.errors.prefix(5))")
        }

        try await db.queue.read { dbConn in
            let courses = try Course.fetchAll(dbConn)
            for course in courses.sorted(by: { $0.name < $1.name }) {
                let materialCount = try Material.filter(Column("courseId") == course.id).fetchCount(dbConn)
                let cardCount = try Card
                    .filter(sql: "materialId IN (SELECT id FROM material WHERE courseId = ?)", arguments: [course.id])
                    .fetchCount(dbConn)
                print("  \(course.name): \(materialCount) files, \(cardCount) cards")
            }
        }

        #expect(summary.filesScanned > 0)
        #expect(summary.errors.isEmpty)
        // Deterministic pairs. Physical Geology (232) still matches the
        // validated Python prototype measurement exactly -- it is pure
        // markdown, untouched by binary extraction. The overall floor
        // accounts for PDF/docx/ipynb extraction adding real cards to
        // American History, Calculus 2, Intro to Python, and others that
        // had none when only markdown was parsed.
        #expect(summary.cardsCreated > 600)
        // 5 semesters, not 4: Club Baseball's PDF certificates (skipped
        // entirely before binary extraction existed) now create a course
        // under the current semester, which didn't exist as a row before.
        #expect(summary.semesterCount == 5)
        // 20, not 15: Fall 2026-2027 gained five real courses (Intro to
        // Software Design, Introduction to Anthropology, Matrix Theory,
        // Microeconomic Principles, Systems Programming with C++). Those
        // notes use a different convention from every earlier semester --
        // nested 01_Lectures/02_Readings folders and
        // "YYYY-MM-DD_Unit-NN_Topic" filenames -- and are written prose
        // rather than slide dumps, which is what the bold-term and
        // heading/quote shapes in `PairParser` were added for.
        #expect(summary.courseCount == 20)
    }
}
