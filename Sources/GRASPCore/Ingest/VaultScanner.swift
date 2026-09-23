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
    public var duplicatesSkipped = 0
    public var semesterCount = 0
    public var courseCount = 0
    public var errors: [String] = []

    // The synthesized memberwise init is only as public as the struct's
    // properties make it, which defaults to internal -- callers outside
    // GRASPCore (the app target's error-path fallbacks) need a real one.
    public init(
        filesScanned: Int = 0, filesUnchanged: Int = 0, filesImportedOrUpdated: Int = 0,
        filesSkippedAsset: Int = 0, filesSkippedEmpty: Int = 0, cardsCreated: Int = 0,
        duplicatesSkipped: Int = 0, semesterCount: Int = 0, courseCount: Int = 0, errors: [String] = []
    ) {
        self.filesScanned = filesScanned
        self.filesUnchanged = filesUnchanged
        self.filesImportedOrUpdated = filesImportedOrUpdated
        self.filesSkippedAsset = filesSkippedAsset
        self.filesSkippedEmpty = filesSkippedEmpty
        self.cardsCreated = cardsCreated
        self.duplicatesSkipped = duplicatesSkipped
        self.semesterCount = semesterCount
        self.courseCount = courseCount
        self.errors = errors
    }
}

/// Walks `<vaultRoot>/College/<Semester>/<Course>/[Lecture Notes/]*`, maps
/// folders to Semester/Course rows, filters asset sidecars and empty
/// stubs, cleans and reflows real notes (markdown directly,
/// PDF/docx/ipynb/pptx/image via their extractors), extracts deterministic
/// term/definition pairs, and writes everything into the store.
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
            let excludedFolders = Set(try ExcludedFolder.fetchAll(db).map(\.folderPath))
            for entry in topLevel.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let name = entry.lastPathComponent
                let range = NSRange(name.startIndex..., in: name)
                let isSemesterFolder = Self.semesterFolderRegex.firstMatch(in: name, range: range) != nil

                if isSemesterFolder {
                    try scanSemesterFolder(
                        entry, folderName: name, excludedFolders: excludedFolders, db: db, summary: &summary
                    )
                } else {
                    // A non-semester top-level directory (e.g. "Side
                    // Lectures") becomes its own pseudo-course with no
                    // semester -- it holds real substantive notes that
                    // don't fit the semester/course pattern.
                    try scanCourseFolder(
                        entry, semesterId: nil, courseNameOverride: name,
                        excludedFolders: excludedFolders, db: db, summary: &summary
                    )
                }
            }
            try Self.sweepMissingFiles(under: collegeRoot.path, db: db)
            summary.semesterCount = try Semester.fetchCount(db)
            summary.courseCount = try Course.fetchCount(db)
        }
        return summary
    }

    /// Notes that were in the vault and aren't any more.
    ///
    /// Identity is the file's path, and nothing used to notice a path
    /// disappearing: a renamed or deleted note kept its material and its
    /// cards forever, and the leftovers then blocked the renamed file's own
    /// cards as "duplicates". Now a note whose file is gone is retired --
    /// and when a note with exactly the same contents exists at a new path
    /// it was a rename, so its cards move over to it. For a real deletion
    /// only the untouched drafts go; anything approved or studied stays.
    ///
    /// A file iCloud has evicted to a placeholder is still there as far as
    /// this is concerned.
    static func sweepMissingFiles(under root: String, db: Database) throws {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let fm = FileManager.default
        func isPresent(_ path: String) -> Bool {
            if fm.fileExists(atPath: path) { return true }
            let url = URL(fileURLWithPath: path)
            let stub = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud").path
            return fm.fileExists(atPath: stub)
        }
        let live = try Material
            .filter(Column("deletedAt") == nil)
            .filter(Column("relativePath").like(prefix + "%"))
            .fetchAll(db)
        for var gone in live where !isPresent(gone.relativePath) {
            let renamedTo = try gone.contentHash.flatMap { hash in
                try Material
                    .filter(Column("contentHash") == hash)
                    .filter(Column("id") != gone.id)
                    .filter(Column("deletedAt") == nil)
                    .fetchAll(db)
                    .first { isPresent($0.relativePath) }
            }
            if let renamedTo {
                try db.execute(
                    sql: "UPDATE card SET materialId = ? WHERE materialId = ?",
                    arguments: [renamedTo.id, gone.id]
                )
            } else {
                try deleteReplaceableDrafts(materialId: gone.id, db: db)
            }
            gone.deletedAt = Date()
            gone.updatedAt = Date()
            try gone.update(db)
        }
    }

    private func scanSemesterFolder(
        _ semesterDir: URL, folderName: String, excludedFolders: Set<String>,
        db: Database, summary: inout ImportSummary
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
                fallbackSemesterFolderName: folderName, excludedFolders: excludedFolders, db: db, summary: &summary
            )
        }
    }

    private func scanCourseFolder(
        _ courseDir: URL, semesterId: String?, courseNameOverride: String?,
        fallbackSemesterFolderName: String = "", excludedFolders: Set<String>,
        db: Database, summary: inout ImportSummary
    ) throws {
        // Checked before anything else in this folder is even looked at --
        // no file walking, no `Material`/`Card` rows, no `findOrCreateCourse`
        // call. This is what makes excluding a folder different from
        // archiving a course: archiving still reuses the existing row on
        // rescan, but a course whose folder is excluded is never touched
        // at all, so it's also safe to have hard-deleted it beforehand.
        guard !excludedFolders.contains(courseDir.path) else { return }

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
        "pptx": .pptx, "png": .image, "jpg": .image, "jpeg": .image,
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
           existing.contentHash == contentHash, existing.deletedAt == nil {
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
            // Only a semester that was actually recognised. A top-level
            // folder whose first note merely had some tag created a
            // blank-named "unknown" semester and filed the course under it.
            if semSlug != "unknown", !semName.isEmpty {
                let semester = try findOrCreateSemester(slug: semSlug, name: semName, sortKey: semSortKey, db: db)
                semesterId = semester.id
            }
            let course = try findOrCreateCourse(
                name: courseName, folderPath: courseFolderPath, semesterId: semesterId,
                code: frontmatter.courseCode, db: db
            )
            resolvedCourseId = course.id
        }
        guard let courseId = resolvedCourseId else { return }

        try importNoteBody(
            fileURL: fileURL, relativePath: relativePath, contentHash: contentHash,
            frontmatter: frontmatter, rawBody: rawBody, courseId: courseId, db: db, summary: &summary
        )
    }

    /// PDF/docx/ipynb/pptx/image: no frontmatter to read, so semester
    /// resolution falls back to the folder name alone, and there is no
    /// asset-sidecar or empty-stub concept -- an extraction failure or
    /// empty result is its own distinct state instead.
    private func importBinaryMaterial(
        _ fileURL: URL, kind: MaterialKind, courseName: String, courseFolderPath: String,
        fallbackSemesterFolderName: String, resolvedCourseId: inout String?,
        db: Database, summary: inout ImportSummary
    ) throws {
        let data = try Data(contentsOf: fileURL)
        let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let relativePath = fileURL.path

        if let existing = try Material.filter(Column("relativePath") == relativePath).fetchOne(db),
           existing.contentHash == contentHash, existing.deletedAt == nil {
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

        try importBinaryBody(
            fileURL: fileURL, kind: kind, relativePath: relativePath, contentHash: contentHash,
            courseId: courseId, db: db, summary: &summary
        )
    }

    // MARK: - Manual import (files/folders picked by hand, not under the vault)

    /// The manual counterpart to `scan(vaultRoot:)`: imports files or
    /// whole folders the user picked by hand -- via a file picker, not
    /// necessarily anywhere near the vault -- directly into an
    /// already-known course. Every file runs through the exact same
    /// clean/reflow/parse pipeline a vault-discovered file does; the only
    /// difference is that the course is given rather than inferred from a
    /// `College/<Semester>/<Course>` folder position. This is what makes a
    /// manually-created course (no `folderPath`, nothing for the vault
    /// scan to ever find) actually usable, and lets any course pick up a
    /// one-off file -- a homework PDF, a scanned handout -- that never
    /// lived in Obsidian at all.
    public func importPaths(_ urls: [URL], intoCourse courseId: String) throws -> ImportSummary {
        var summary = ImportSummary()
        try database.queue.write { db in
            guard try Course.fetchOne(db, key: courseId) != nil else {
                summary.errors.append("Course no longer exists")
                return
            }
            for url in urls {
                try liftExclusions(matching: url, db: db)
                try importPathEntry(url, courseId: courseId, db: db, summary: &summary)
            }
            summary.semesterCount = try Semester.fetchCount(db)
            summary.courseCount = try Course.fetchCount(db)
        }
        return summary
    }

    /// A manual "Add Files or Folder…" is a deliberate choice to bring
    /// specific content back in, so it overrides an earlier exclusion
    /// rather than silently honoring it -- unlike `scan(vaultRoot:)`'s own
    /// automatic walk, which must never resurrect an excluded folder on
    /// its own. Matches an excluded folder that equals, contains, or sits
    /// inside `url`, so pointing this at the excluded folder itself, a
    /// file within it, or a parent folder that contains it all un-exclude
    /// it the same way.
    private func liftExclusions(matching url: URL, db: Database) throws {
        let path = url.path
        for excluded in try ExcludedFolder.fetchAll(db) {
            let folderPath = excluded.folderPath
            if folderPath == path || path.hasPrefix(folderPath + "/") || folderPath.hasPrefix(path + "/") {
                _ = try ExcludedFolder.deleteOne(db, key: folderPath)
            }
        }
    }

    /// `url` may be a single file or a folder -- a folder is walked
    /// recursively exactly like a vault course folder is, including the
    /// same ignored-directory list, so pointing this at a whole "Lecture
    /// Notes" folder behaves like pointing the vault scanner at one.
    private func importPathEntry(
        _ url: URL, courseId: String, db: Database, summary: inout ImportSummary
    ) throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else {
            try importSingleFile(url, courseId: courseId, db: db, summary: &summary)
            return
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            if let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory, isDir {
                if Self.ignoredDirectoryNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            try importSingleFile(fileURL, courseId: courseId, db: db, summary: &summary)
        }
    }

    private func importSingleFile(
        _ fileURL: URL, courseId: String, db: Database, summary: inout ImportSummary
    ) throws {
        let ext = fileURL.pathExtension.lowercased()
        guard let kind = Self.importableKinds[ext] else { return }
        summary.filesScanned += 1
        do {
            if kind == .markdown {
                let raw = try String(contentsOf: fileURL, encoding: .utf8)
                let contentHash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
                let relativePath = fileURL.path
                if let existing = try Material.filter(Column("relativePath") == relativePath).fetchOne(db),
                   existing.contentHash == contentHash, existing.deletedAt == nil {
                    summary.filesUnchanged += 1
                    return
                }
                let (frontmatter, rawBody) = FrontmatterParser.split(raw)
                try importNoteBody(
                    fileURL: fileURL, relativePath: relativePath, contentHash: contentHash,
                    frontmatter: frontmatter, rawBody: rawBody, courseId: courseId, db: db, summary: &summary
                )
            } else {
                let data = try Data(contentsOf: fileURL)
                let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let relativePath = fileURL.path
                if let existing = try Material.filter(Column("relativePath") == relativePath).fetchOne(db),
                   existing.contentHash == contentHash, existing.deletedAt == nil {
                    summary.filesUnchanged += 1
                    return
                }
                try importBinaryBody(
                    fileURL: fileURL, kind: kind, relativePath: relativePath, contentHash: contentHash,
                    courseId: courseId, db: db, summary: &summary
                )
            }
        } catch {
            summary.errors.append("\(fileURL.lastPathComponent): \(error)")
        }
    }

    // MARK: - Shared per-file tail (course already resolved)

    /// Builds/updates the `material` row for a markdown note and hands its
    /// body to the shared cleaning tail, once a course id is in hand --
    /// shared by the vault scan (which resolves the course from folder
    /// position) and manual import (which is handed the course directly).
    private func importNoteBody(
        fileURL: URL, relativePath: String, contentHash: String, frontmatter: Frontmatter,
        rawBody: String, courseId: String, db: Database, summary: inout ImportSummary
    ) throws {
        let fileName = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let parsedName = FilenameParsing.parse(fileNameWithoutExtension: fileName)

        var material = (try Material.filter(Column("relativePath") == relativePath).fetchOne(db))
            ?? Material(courseId: courseId, relativePath: relativePath, kind: .markdown, title: fileName)
        // A file that went missing and has come back.
        material.deletedAt = nil
        material.courseId = courseId
        material.contentHash = contentHash
        material.title = fileName
        material.topic = parsedName.topic
        // A unit taken straight from the filename ("Week 2", "Module 1")
        // beats inferring one from the topic text: it is stated rather than
        // guessed, and it is what the course itself is organised by.
        material.chapter = parsedName.unitLabel
            ?? parsedName.topic.flatMap { FilenameParsing.chapter(fromTopic: $0) }
        material.updatedAt = Date()

        if frontmatter.isAssetSidecar {
            material.extractionState = .skippedAsset
            try material.save(db)
            try Self.clearReplaceableContent(materialId: material.id, db: db)
            summary.filesSkippedAsset += 1
            summary.filesImportedOrUpdated += 1
            return
        }
        if TextCleaning.isEmptyStub(rawBody) {
            material.extractionState = .skippedEmpty
            try material.save(db)
            // A note emptied since its last import keeps no cards or search
            // text from what it used to say.
            try Self.clearReplaceableContent(materialId: material.id, db: db)
            summary.filesSkippedEmpty += 1
            summary.filesImportedOrUpdated += 1
            return
        }

        try finishImportingBody(
            &material, courseId: courseId, rawBody: rawBody,
            filenameDate: parsedName.dateFromFilename,
            hasLectureIdentity: parsedName.dateFromFilename != nil && parsedName.unitLabel != nil,
            db: db, summary: &summary
        )
    }

    /// The binary equivalent of `importNoteBody` -- extracts text by kind,
    /// then hands off to the same shared tail. No frontmatter, so no
    /// asset-sidecar or empty-stub concept; an extraction failure or empty
    /// result is its own distinct state instead.
    private func importBinaryBody(
        fileURL: URL, kind: MaterialKind, relativePath: String, contentHash: String,
        courseId: String, db: Database, summary: inout ImportSummary
    ) throws {
        let fileName = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let parsedName = FilenameParsing.parse(fileNameWithoutExtension: fileName)

        var material = (try Material.filter(Column("relativePath") == relativePath).fetchOne(db))
            ?? Material(courseId: courseId, relativePath: relativePath, kind: kind, title: fileName)
        // A file that went missing and has come back.
        material.deletedAt = nil
        material.courseId = courseId
        material.kind = kind
        material.contentHash = contentHash
        material.title = fileName
        material.topic = parsedName.topic
        material.chapter = parsedName.unitLabel
            ?? parsedName.topic.flatMap { FilenameParsing.chapter(fromTopic: $0) }
        material.updatedAt = Date()

        let extracted: String?
        switch kind {
        case .pdf: extracted = PDFExtractor.extractText(from: fileURL)
        case .docx: extracted = DocxExtractor.extractText(from: fileURL)
        case .ipynb: extracted = IpynbExtractor.extractText(from: fileURL)
        case .image: extracted = ImageExtractor.extractText(from: fileURL)
        case .pptx: extracted = PptxExtractor.extractText(from: fileURL)
        case .markdown: extracted = nil // never reached: markdown routes through importNote instead
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
            try Self.clearReplaceableContent(materialId: material.id, db: db)
            summary.filesImportedOrUpdated += 1
            return
        }

        try finishImportingBody(
            &material, courseId: courseId, rawBody: extracted,
            filenameDate: parsedName.dateFromFilename,
            hasLectureIdentity: parsedName.dateFromFilename != nil && parsedName.unitLabel != nil,
            db: db, summary: &summary
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

    /// Course-logistics documents: a syllabus, a course index, a schedule,
    /// a roadmap, a practice-tools page. They are worth importing -- they
    /// hold exam dates, grading weights and office hours, and should be
    /// searchable -- but they are not worth drilling, and the parser
    /// happily turns them into cards like "Test 1 / 20%" or "§1.4 / every
    /// 4th of the first 20". Detected from the filename alone, which is
    /// where the vault states a document's role: a leading underscore or
    /// `00_` prefix marks an index in this vault's convention.
    private static let referenceTitleMarkers = [
        "syllabus", "course index", "course-index", "schedule", "roadmap",
        "practice-tools", "practice tools", "assessments", "course-info",
    ]

    /// `hasLectureIdentity` is the escape hatch: a note stamped with a date
    /// *and* a unit is a specific class session, whatever words are in its
    /// topic. Without it, "2026-08-25_Module-01_First-Day-Syllabus-Overview"
    /// -- a real 419-word lecture -- gets thrown out for containing the
    /// word "syllabus", while the identical first-day lecture in another
    /// course is kept because its topic happens to say "Course-Mechanics".
    static func isReferenceDocument(title: String, hasLectureIdentity: Bool = false) -> Bool {
        if title.hasPrefix("_") || title.hasPrefix("00_") { return true }
        guard !hasLectureIdentity else { return false }
        let lower = title.lowercased()
        return referenceTitleMarkers.contains { lower.contains($0) }
    }

    /// Shared tail for every material kind once its plain-text body is in
    /// hand: clean, reflow, decide study-worthiness, persist the note text,
    /// and (re)parse deterministic cards.
    private func finishImportingBody(
        _ material: inout Material, courseId: String, rawBody: String, filenameDate: Date?,
        hasLectureIdentity: Bool = false, db: Database, summary: inout ImportSummary
    ) throws {
        let cleaned = TextCleaning.clean(rawBody)
        let (dateFromBody, bodyWithoutDate) = TextCleaning.extractDateLine(cleaned)
        let reflowed = Reflow.reflow(bodyWithoutDate)
        let wordCount = reflowed.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        let hasMath = reflowed.contains("\\(") || reflowed.contains("\\[")

        material.noteDate = dateFromBody ?? filenameDate
        material.isStudyWorthy = wordCount >= 30
            && wordCount <= Self.maxWordsForPairParsing
            && !Self.isReferenceDocument(
                title: material.title, hasLectureIdentity: hasLectureIdentity
            )
        material.extractionState = .ok
        material.importedAt = Date()
        try material.save(db)

        try NoteText(
            materialId: material.id, raw: rawBody, reflowed: reflowed,
            wordCount: wordCount, hasMath: hasMath
        ).save(db)

        // Clear previously-parsed cards for this material before re-parsing
        // -- but only untouched drafts. "Never reviewed" used to be the whole
        // test, which also swept away cards the student had approved, ones
        // the AI check had rewritten, ones partway up the Learn ladder, and
        // the deleted ones kept on purpose as tombstones: fixing one typo in
        // a note turned all of its approved cards back into fresh drafts and
        // brought deleted ones back.
        try Self.deleteReplaceableDrafts(materialId: material.id, db: db)

        if material.isStudyWorthy {
            let deck = try findOrCreateDeck(courseId: courseId, chapter: material.chapter, db: db)
            let pairs = PairParser.parse(reflowed)

            // Seeded from every card already in the deck -- deliberately
            // including soft-deleted ones, so a card the user explicitly
            // deleted stops resurrecting on every subsequent re-import
            // (the same fix already applied to deleted decks). Grown as
            // each new card is created, so two duplicate bullets inside
            // this same note also collapse, not just cross-note dupes.
            // And every card this note already has, wherever it sits: a card
            // moved to another deck, or deleted and so no longer in any deck
            // (a duplicate merge's loser), would otherwise be made again.
            let existingCards = try Card
                .filter(sql: "id IN (SELECT cardId FROM deckCard WHERE deckId = ?) OR materialId = ?",
                        arguments: [deck.id, material.id])
                .fetchAll(db)
            var duplicateIndex = DuplicateDetector.Index(existingCards)

            for pair in pairs {
                if duplicateIndex.matchId(front: pair.front, back: pair.back) != nil {
                    summary.duplicatesSkipped += 1
                    continue
                }
                let card = Card(
                    materialId: material.id, front: pair.front, back: pair.back,
                    hasMath: pair.back.contains("\\(") || pair.back.contains("\\["),
                    sourceLine: pair.sourceLine, origin: .parser, status: .draft
                )
                try card.save(db)
                try DeckCard(deckId: deck.id, cardId: card.id).save(db)
                duplicateIndex.insert(id: card.id, front: pair.front, back: pair.back)
                summary.cardsCreated += 1
            }
        }
        summary.filesImportedOrUpdated += 1
    }

    /// The parser's own untouched drafts for a note -- the only cards a
    /// re-import is allowed to replace. See `finishImportingBody`.
    static func deleteReplaceableDrafts(materialId: String, db: Database) throws {
        try Card
            .filter(Column("materialId") == materialId)
            .filter(Column("origin") == CardOrigin.parser.rawValue)
            .filter(Column("reps") == 0)
            .filter(Column("status") == CardStatus.draft.rawValue)
            .filter(Column("deletedAt") == nil)
            .filter(Column("isContextRefined") == false)
            .filter(sql: "id NOT IN (SELECT cardId FROM learnState)")
            .deleteAll(db)
    }

    private static func clearReplaceableContent(materialId: String, db: Database) throws {
        try deleteReplaceableDrafts(materialId: materialId, db: db)
        _ = try NoteText.deleteOne(db, key: materialId)
    }

    /// A freeform, hand-typed timeline (`AppStore.findOrCreateSemester(name:)`)
    /// only ever gets a placeholder `sortKey` -- a small sequential counter,
    /// not the real `year*10 + termOrder` scheme this scanner derives from
    /// an actual tag or folder name. Reconciled here whenever the slug
    /// already matches: without this, a timeline typed by hand before the
    /// vault ever imports that same term stays sorted by its placeholder
    /// forever, even after the real chronological position is known.
    private func findOrCreateSemester(slug: String, name: String, sortKey: Int, db: Database) throws -> Semester {
        if var existing = try Semester.filter(Column("slug") == slug).fetchOne(db) {
            if existing.sortKey != sortKey {
                existing.sortKey = sortKey
                try existing.update(db)
            }
            return existing
        }
        let semester = Semester(name: name, slug: slug, sortKey: sortKey)
        try semester.insert(db)
        return semester
    }

    /// An existing course picks up a code the first time one is seen, but
    /// a code already on the row is never overwritten -- the user can edit
    /// it by hand in the course sheet, and a re-import must not undo that.
    private func findOrCreateCourse(
        name: String, folderPath: String, semesterId: String?, code: String? = nil, db: Database
    ) throws -> Course {
        if var existing = try Course.filter(Column("folderPath") == folderPath).fetchOne(db) {
            if existing.code == nil, let code {
                existing.code = code
                existing.updatedAt = Date()
                try existing.update(db)
            }
            return existing
        }
        let course = Course(semesterId: semesterId, name: name, code: code, folderPath: folderPath)
        try course.insert(db)
        return course
    }

    private func findOrCreateDeck(courseId: String, chapter: String?, db: Database) throws -> Deck {
        let deckName = chapter ?? "General"
        // Excludes soft-deleted decks: without this, re-importing after a
        // user deletes a deck by hand would find and silently reuse that
        // same tombstoned row for new cards -- into a deck every query
        // already filters out everywhere else.
        if let existing = try Deck
            .filter(Column("courseId") == courseId)
            .filter(Column("name") == deckName)
            .filter(Column("deletedAt") == nil)
            .fetchOne(db) {
            return existing
        }
        let deck = Deck(courseId: courseId, name: deckName, chapter: chapter)
        try deck.insert(db)
        return deck
    }
}
