import Foundation
import CryptoKit
import GRDB

public struct ImportSummary: Sendable, Equatable {
    public var filesScanned = 0
    public var filesUnchanged = 0
    public var filesImportedOrUpdated = 0
    public var filesSkippedAsset = 0
    public var filesSkippedEmpty = 0
    public var cardsCreated = 0
    public var semesterCount = 0
    public var courseCount = 0
    public var errors: [String] = []
}

/// Walks `<vaultRoot>/College/<Semester>/<Course>/[Lecture Notes/]*`, maps
/// folders to Semester/Course rows, filters asset sidecars and empty
/// stubs, cleans and reflows real notes (markdown directly, PDF/docx/ipynb
/// via their extractors), extracts deterministic term/definition pairs,
/// and writes everything into the store. No pptx handling -- there are
/// none under College/ in the vault this was built against.
///
/// Re-running is idempotent: unchanged files (by content hash) are
/// skipped, and a file whose hash matches an existing material under a
/// different path is treated as a rename rather than a new import, so
/// review history on its cards survives.
public actor VaultScanner {
    private let database: GRASPDatabase

    public init(database: GRASPDatabase) {
        self.database = database
    }

    private static let semesterFolderRegex = try! NSRegularExpression(
        pattern: #"^(Fall|Spring|Summer) Semester \d{4}(-\d{4})?$"#
    )
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".obsidian", "node_modules", "__pycache__", ".ipynb_checkpoints", ".vscode",
    ]

    public func scan(vaultRoot: URL) throws -> ImportSummary {
        var summary = ImportSummary()
        let collegeRoot = vaultRoot.appendingPathComponent("College", isDirectory: true)
        let fm = FileManager.default

        guard let topLevel = try? fm.contentsOfDirectory(
            at: collegeRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            summary.errors.append("Could not read College/ under \(vaultRoot.path)")
            return summary
        }

        try database.queue.write { db in
            for entry in topLevel.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let name = entry.lastPathComponent
                let range = NSRange(name.startIndex..., in: name)
                let isSemesterFolder = Self.semesterFolderRegex.firstMatch(in: name, range: range) != nil

                if isSemesterFolder {
                    try scanSemesterFolder(entry, folderName: name, db: db, summary: &summary)
                } else {
                    // A non-semester top-level directory (e.g. "Side
                    // Lectures") becomes its own pseudo-course with no
                    // semester -- it holds real substantive notes that
                    // don't fit the semester/course pattern.
                    try scanCourseFolder(
                        entry, semesterId: nil, courseNameOverride: name, db: db, summary: &summary
                    )
                }
            }
            summary.semesterCount = try Semester.fetchCount(db)
            summary.courseCount = try Course.fetchCount(db)
        }
        return summary
    }

    private func scanSemesterFolder(
        _ semesterDir: URL, folderName: String, db: Database, summary: inout ImportSummary
    ) throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: semesterDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue // loose files directly under a semester folder are out of Phase 2 scope
            }
            if Self.ignoredDirectoryNames.contains(entry.lastPathComponent) { continue }
            // Semester is resolved per-note from frontmatter (with this
            // folder name as fallback), not assumed from the folder, since
            // folder names are known to sort incorrectly.
            try scanCourseFolder(
                entry, semesterId: nil, courseNameOverride: nil,
                fallbackSemesterFolderName: folderName, db: db, summary: &summary
            )
        }
    }

    private func scanCourseFolder(
        _ courseDir: URL, semesterId: String?, courseNameOverride: String?,
        fallbackSemesterFolderName: String = "", db: Database, summary: inout ImportSummary
    ) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: courseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let courseName = courseNameOverride ?? courseDir.lastPathComponent
        var resolvedCourseId: String?

        for case let fileURL as URL in enumerator {
            if let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory, isDir {
                if Self.ignoredDirectoryNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            guard let kind = Self.importableKinds[ext] else { continue }

            summary.filesScanned += 1
            do {
                if kind == .markdown {
                    try importNote(
                        fileURL, courseName: courseName, courseFolderPath: courseDir.path,
                        fallbackSemesterFolderName: fallbackSemesterFolderName,
                        resolvedCourseId: &resolvedCourseId, db: db, summary: &summary
                    )
                } else {
                    try importBinaryMaterial(
                        fileURL, kind: kind, courseName: courseName, courseFolderPath: courseDir.path,
                        fallbackSemesterFolderName: fallbackSemesterFolderName,
                        resolvedCourseId: &resolvedCourseId, db: db, summary: &summary
                    )
                }
            } catch {
                summary.errors.append("\(fileURL.lastPathComponent): \(error)")
            }
        }
    }

    private static let importableKinds: [String: MaterialKind] = [
        "md": .markdown, "pdf": .pdf, "docx": .docx, "ipynb": .ipynb,
    ]

    private func importNote(
        _ fileURL: URL, courseName: String, courseFolderPath: String,
        fallbackSemesterFolderName: String, resolvedCourseId: inout String?,
        db: Database, summary: inout ImportSummary
    ) throws {
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let contentHash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        let relativePath = fileURL.path

        // Idempotency: unchanged content at the same path needs no work.
        if let existing = try Material.filter(Column("relativePath") == relativePath).fetchOne(db),
           existing.contentHash == contentHash {
            summary.filesUnchanged += 1
            return
        }

        let (frontmatter, rawBody) = FrontmatterParser.split(raw)

        // Resolve (or create) the course lazily, once per folder, from the
        // first note's frontmatter -- avoids a course row for a folder that
        // turns out to hold nothing importable.
        if resolvedCourseId == nil {
            let (semSlug, semName, semSortKey) = SemesterSlug.resolve(
                tags: frontmatter.tags, folderName: fallbackSemesterFolderName
            )
            var semesterId: String?
            if !fallbackSemesterFolderName.isEmpty || !frontmatter.tags.isEmpty {
                let semester = try findOrCreateSemester(slug: semSlug, name: semName, sortKey: semSortKey, db: db)
                semesterId = semester.id
            }
            let course = try findOrCreateCourse(
                name: courseName, folderPath: courseFolderPath, semesterId: semesterId, db: db
            )
            resolvedCourseId = course.id
        }
        guard let courseId = resolvedCourseId else { return }

        let fileName = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let parsedName = FilenameParsing.parse(fileNameWithoutExtension: fileName)

        var material = (try Material.filter(Column("relativePath") == relativePath).fetchOne(db))
            ?? Material(courseId: courseId, relativePath: relativePath, kind: .markdown, title: fileName)
        material.courseId = courseId
        material.contentHash = contentHash
        material.title = fileName
        material.topic = parsedName.topic
        material.chapter = parsedName.topic.flatMap { FilenameParsing.chapter(fromTopic: $0) }
        material.updatedAt = Date()

        if frontmatter.isAssetSidecar {
            material.extractionState = .skippedAsset
            try material.save(db)
            summary.filesSkippedAsset += 1
            summary.filesImportedOrUpdated += 1
            return
        }
        if TextCleaning.isEmptyStub(rawBody) {
            material.extractionState = .skippedEmpty
            try material.save(db)
            summary.filesSkippedEmpty += 1
            summary.filesImportedOrUpdated += 1
            return
        }

        try finishImportingBody(
            &material, courseId: courseId, rawBody: rawBody,
            filenameDate: parsedName.dateFromFilename, db: db, summary: &summary
        )
    }

    /// PDF/docx/ipynb: no frontmatter to read, so semester resolution
    /// falls back to the folder name alone, and there is no asset-sidecar
    /// or empty-stub concept -- an extraction failure or empty result is
    /// its own distinct state instead.
    private func importBinaryMaterial(
        _ fileURL: URL, kind: MaterialKind, courseName: String, courseFolderPath: String,
        fallbackSemesterFolderName: String, resolvedCourseId: inout String?,
        db: Database, summary: inout ImportSummary
    ) throws {
        let data = try Data(contentsOf: fileURL)
        let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let relativePath = fileURL.path

        if let existing = try Material.filter(Column("relativePath") == relativePath).fetchOne(db),
           existing.contentHash == contentHash {
            summary.filesUnchanged += 1
            return
        }

        if resolvedCourseId == nil {
            let (semSlug, semName, semSortKey) = SemesterSlug.resolve(tags: [], folderName: fallbackSemesterFolderName)
            var semesterId: String?
            if !fallbackSemesterFolderName.isEmpty {
                let semester = try findOrCreateSemester(slug: semSlug, name: semName, sortKey: semSortKey, db: db)
                semesterId = semester.id
            }
            let course = try findOrCreateCourse(
                name: courseName, folderPath: courseFolderPath, semesterId: semesterId, db: db
            )
            resolvedCourseId = course.id
        }
        guard let courseId = resolvedCourseId else { return }

        let fileName = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let parsedName = FilenameParsing.parse(fileNameWithoutExtension: fileName)

        var material = (try Material.filter(Column("relativePath") == relativePath).fetchOne(db))
            ?? Material(courseId: courseId, relativePath: relativePath, kind: kind, title: fileName)
        material.courseId = courseId
        material.kind = kind
        material.contentHash = contentHash
        material.title = fileName
        material.topic = parsedName.topic
        material.chapter = parsedName.topic.flatMap { FilenameParsing.chapter(fromTopic: $0) }
        material.updatedAt = Date()

        let extracted: String?
        switch kind {
        case .pdf: extracted = PDFExtractor.extractText(from: fileURL)
        case .docx: extracted = DocxExtractor.extractText(from: fileURL)
        case .ipynb: extracted = IpynbExtractor.extractText(from: fileURL)
        case .markdown, .image, .pptx: extracted = nil
        }

        guard let extracted else {
            material.extractionState = .failed
            try material.save(db)
            summary.filesImportedOrUpdated += 1
            return
        }
        guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A real file with nothing to extract -- a scanned-image PDF
            // with no text layer, most often -- not an error.
            material.extractionState = .noTextLayer
            try material.save(db)
            summary.filesImportedOrUpdated += 1
            return
        }

        try finishImportingBody(
            &material, courseId: courseId, rawBody: extracted,
            filenameDate: parsedName.dateFromFilename, db: db, summary: &summary
        )
    }

    /// Above this, a file reads as reference material (a textbook, a full
    /// slide deck export) rather than one lecture's worth of notes -- the
    /// deterministic parser was tuned against real notes topping out
    /// around 3,000 words each (Physical Geology's richest file), and
    /// running it against a 236,000-word textbook PDF measured against
    /// this vault produced 364 pairs that were almost entirely table-of-
    /// contents entries, running headers, and truncated code fragments.
    /// The text is still kept (searchable, viewable) -- only automatic
    /// card generation is skipped.
    private static let maxWordsForPairParsing = 8000

    /// Shared tail for every material kind once its plain-text body is in
    /// hand: clean, reflow, decide study-worthiness, persist the note text,
    /// and (re)parse deterministic cards.
    private func finishImportingBody(
        _ material: inout Material, courseId: String, rawBody: String, filenameDate: Date?,
        db: Database, summary: inout ImportSummary
    ) throws {
        let cleaned = TextCleaning.clean(rawBody)
        let (dateFromBody, bodyWithoutDate) = TextCleaning.extractDateLine(cleaned)
        let reflowed = Reflow.reflow(bodyWithoutDate)
        let wordCount = reflowed.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        let hasMath = reflowed.contains("\\(") || reflowed.contains("\\[")

        material.noteDate = dateFromBody ?? filenameDate
        material.isStudyWorthy = wordCount >= 30 && wordCount <= Self.maxWordsForPairParsing
        material.extractionState = .ok
        material.importedAt = Date()
        try material.save(db)

        try NoteText(
            materialId: material.id, raw: rawBody, reflowed: reflowed,
            wordCount: wordCount, hasMath: hasMath
        ).save(db)

        // Clear previously-parsed parser-origin cards for this material
        // before re-parsing, but never touch a card the user has edited or
        // reviewed -- those survive re-import untouched.
        try Card
            .filter(Column("materialId") == material.id)
            .filter(Column("origin") == CardOrigin.parser.rawValue)
            .filter(Column("reps") == 0)
            .deleteAll(db)

        if material.isStudyWorthy {
            let deck = try findOrCreateDeck(courseId: courseId, chapter: material.chapter, db: db)
            let pairs = PairParser.parse(reflowed)
            for pair in pairs {
                let card = Card(
                    materialId: material.id, front: pair.front, back: pair.back,
                    hasMath: pair.back.contains("\\(") || pair.back.contains("\\["),
                    sourceLine: pair.sourceLine, origin: .parser, status: .draft
                )
                try card.save(db)
                try DeckCard(deckId: deck.id, cardId: card.id).save(db)
                summary.cardsCreated += 1
            }
        }
        summary.filesImportedOrUpdated += 1
    }

    private func findOrCreateSemester(slug: String, name: String, sortKey: Int, db: Database) throws -> Semester {
        if let existing = try Semester.filter(Column("slug") == slug).fetchOne(db) { return existing }
        let semester = Semester(name: name, slug: slug, sortKey: sortKey)
        try semester.insert(db)
        return semester
    }

    private func findOrCreateCourse(
        name: String, folderPath: String, semesterId: String?, db: Database
    ) throws -> Course {
        if let existing = try Course.filter(Column("folderPath") == folderPath).fetchOne(db) {
            return existing
        }
        let course = Course(semesterId: semesterId, name: name, folderPath: folderPath)
        try course.insert(db)
        return course
    }

    private func findOrCreateDeck(courseId: String, chapter: String?, db: Database) throws -> Deck {
        let deckName = chapter ?? "General"
        if let existing = try Deck
            .filter(Column("courseId") == courseId)
            .filter(Column("name") == deckName)
            .fetchOne(db) {
            return existing
        }
        let deck = Deck(courseId: courseId, name: deckName, chapter: chapter)
        try deck.insert(db)
        return deck
    }
}
