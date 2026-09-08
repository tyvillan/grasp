import Foundation
import GRDB

// MARK: - Core records
//
// TEXT UUID primary keys throughout (never INTEGER autoincrement) so rows
// have a stable identity that survives a future export/sync without a
// migration -- cheap optionality, no functional cost today.

public struct Semester: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "semester"
    public var id: String
    public var name: String
    public var slug: String       // e.g. "spring-2026" -- the authority for ordering
    public var sortKey: Int       // derived from slug, NOT folder name (folder names lie)
    public var startsOn: Date?
    public var endsOn: Date?

    public init(id: String = UUID().uuidString, name: String, slug: String, sortKey: Int,
                startsOn: Date? = nil, endsOn: Date? = nil) {
        self.id = id; self.name = name; self.slug = slug; self.sortKey = sortKey
        self.startsOn = startsOn; self.endsOn = endsOn
    }
}

public struct Course: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "course"
    public var id: String
    public var semesterId: String?
    public var name: String
    public var code: String?
    public var colorHex: String?
    public var folderPath: String?   // nil for manually-created courses with no vault folder
    public var sortIndex: Int
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, semesterId: String?, name: String, code: String? = nil,
                colorHex: String? = nil, folderPath: String? = nil, sortIndex: Int = 0,
                isArchived: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.semesterId = semesterId; self.name = name; self.code = code
        self.colorHex = colorHex; self.folderPath = folderPath; self.sortIndex = sortIndex
        self.isArchived = isArchived; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum MaterialKind: String, Codable, Sendable {
    case markdown, pdf, docx, pptx, ipynb, image
}

public enum ExtractionState: String, Codable, Sendable {
    case pending, ok, skippedAsset, skippedEmpty, noTextLayer, unsupported, failed
}

public struct Material: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "material"
    public var id: String
    public var courseId: String
    public var relativePath: String   // relative to the vault root; identity key
    public var kind: MaterialKind
    public var contentHash: String?
    public var title: String
    public var noteDate: Date?
    public var topic: String?
    public var chapter: String?
    public var extractionState: ExtractionState
    public var isStudyWorthy: Bool
    public var importedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, courseId: String, relativePath: String,
                kind: MaterialKind, contentHash: String? = nil, title: String,
                noteDate: Date? = nil, topic: String? = nil, chapter: String? = nil,
                extractionState: ExtractionState = .pending, isStudyWorthy: Bool = true,
                importedAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
                deletedAt: Date? = nil) {
        self.id = id; self.courseId = courseId; self.relativePath = relativePath; self.kind = kind
        self.contentHash = contentHash; self.title = title; self.noteDate = noteDate
        self.topic = topic; self.chapter = chapter; self.extractionState = extractionState
        self.isStudyWorthy = isStudyWorthy; self.importedAt = importedAt
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

public struct NoteText: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "noteText"
    public var materialId: String
    public var raw: String
    public var reflowed: String
    public var wordCount: Int
    public var hasMath: Bool

    public init(materialId: String, raw: String, reflowed: String, wordCount: Int, hasMath: Bool) {
        self.materialId = materialId; self.raw = raw; self.reflowed = reflowed
        self.wordCount = wordCount; self.hasMath = hasMath
    }
}

public struct Deck: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "deck"
    public var id: String
    public var courseId: String
    public var name: String
    public var chapter: String?
    public var origin: String   // "auto" | "manual"
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, courseId: String, name: String, chapter: String? = nil,
                origin: String = "auto", sortIndex: Int = 0, createdAt: Date = Date(),
                updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.courseId = courseId; self.name = name; self.chapter = chapter
        self.origin = origin; self.sortIndex = sortIndex
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

public enum CardOrigin: String, Codable, Sendable {
    case parser, ollama, manual
}

public enum CardStatus: String, Codable, Sendable {
    case draft, active, suspended
}

public struct Card: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "card"
    public var id: String
    public var materialId: String?
    public var front: String
    public var back: String
    public var hasMath: Bool
    public var imagePath: String?
    public var sourceLine: Int?
    public var origin: CardOrigin
    public var status: CardStatus
    // FSRS state, inline (see schema comment)
    public var due: Date
    public var stability: Double
    public var difficulty: Double
    public var elapsedDays: Double
    public var scheduledDays: Double
    public var reps: Int
    public var lapses: Int
    public var schedulerState: Int
    public var lastReview: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String = UUID().uuidString, materialId: String?, front: String, back: String,
                hasMath: Bool = false, imagePath: String? = nil, sourceLine: Int? = nil,
                origin: CardOrigin, status: CardStatus = .draft, due: Date = Date(),
                stability: Double = 0, difficulty: Double = 0, elapsedDays: Double = 0,
                scheduledDays: Double = 0, reps: Int = 0, lapses: Int = 0, schedulerState: Int = 0,
                lastReview: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
                deletedAt: Date? = nil) {
        self.id = id; self.materialId = materialId; self.front = front; self.back = back
        self.hasMath = hasMath; self.imagePath = imagePath; self.sourceLine = sourceLine
        self.origin = origin; self.status = status; self.due = due; self.stability = stability
        self.difficulty = difficulty; self.elapsedDays = elapsedDays; self.scheduledDays = scheduledDays
        self.reps = reps; self.lapses = lapses; self.schedulerState = schedulerState
        self.lastReview = lastReview; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct DeckCard: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "deckCard"
    public var deckId: String
    public var cardId: String
    public var sortIndex: Int

    public init(deckId: String, cardId: String, sortIndex: Int = 0) {
        self.deckId = deckId; self.cardId = cardId; self.sortIndex = sortIndex
    }
}

/// One graded study event. Written by every study mode (flashcards, Learn,
/// tests), not just flashcards -- `source` distinguishes them, and every
/// grade updates the same FSRS scheduler state on `card` regardless of
/// which mode produced it, so studying in one mode still schedules the
/// card correctly for the others.
public struct Review: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "review"
    public var id: String
    public var cardId: String
    public var reviewedAt: Date
    public var grade: Int   // 1 again .. 4 easy
    public var source: String   // flashcards | learn | test | cram | manual
    public var elapsedMS: Int?
    public var dueBefore: Date?
    public var dueAfter: Date
    public var stabilityAfter: Double?
    public var difficultyAfter: Double?
    public var schedulerVersion: String

    public init(id: String = UUID().uuidString, cardId: String, reviewedAt: Date, grade: Int, source: String,
                elapsedMS: Int? = nil, dueBefore: Date? = nil, dueAfter: Date,
                stabilityAfter: Double? = nil, difficultyAfter: Double? = nil, schedulerVersion: String) {
        self.id = id; self.cardId = cardId; self.reviewedAt = reviewedAt; self.grade = grade
        self.source = source; self.elapsedMS = elapsedMS; self.dueBefore = dueBefore; self.dueAfter = dueAfter
        self.stabilityAfter = stabilityAfter; self.difficultyAfter = difficultyAfter
        self.schedulerVersion = schedulerVersion
    }
}

/// Learn mode's own per-card progress -- deliberately separate from the
/// FSRS `schedule` fields on `Card`: Learn drills initial acquisition
/// (new -> recognition -> recall -> mastered) while FSRS handles ongoing
/// long-term retention. A card can be "mastered" in Learn and still show
/// up in flashcards on its normal spaced schedule.
public struct LearnState: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "learnState"
    public var cardId: String
    public var level: Int   // 0 new, 1 recognition, 2 recall, 3 mastered
    public var consecutiveCorrect: Int
    public var lastSeenAt: Date?

    public init(cardId: String, level: Int = 0, consecutiveCorrect: Int = 0, lastSeenAt: Date? = nil) {
        self.cardId = cardId; self.level = level
        self.consecutiveCorrect = consecutiveCorrect; self.lastSeenAt = lastSeenAt
    }
}

public struct TestAttempt: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "testAttempt"
    public var id: String
    public var deckId: String?
    public var configJSON: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var scoreNumerator: Int?
    public var scoreDenominator: Int?

    public init(id: String = UUID().uuidString, deckId: String?, configJSON: String, startedAt: Date = Date(),
                finishedAt: Date? = nil, scoreNumerator: Int? = nil, scoreDenominator: Int? = nil) {
        self.id = id; self.deckId = deckId; self.configJSON = configJSON; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.scoreNumerator = scoreNumerator; self.scoreDenominator = scoreDenominator
    }
}

public struct TestItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "testItem"
    public var id: String
    public var attemptId: String
    public var cardId: String?
    public var ordinal: Int
    public var questionType: String
    public var promptText: String
    public var choicesJSON: String?
    public var correctAnswer: String?
    public var givenAnswer: String?
    public var isCorrect: Bool?

    public init(id: String = UUID().uuidString, attemptId: String, cardId: String?, ordinal: Int,
                questionType: String, promptText: String, choicesJSON: String? = nil,
                correctAnswer: String? = nil, givenAnswer: String? = nil, isCorrect: Bool? = nil) {
        self.id = id; self.attemptId = attemptId; self.cardId = cardId; self.ordinal = ordinal
        self.questionType = questionType; self.promptText = promptText; self.choicesJSON = choicesJSON
        self.correctAnswer = correctAnswer; self.givenAnswer = givenAnswer; self.isCorrect = isCorrect
    }
}

/// Drives FSRS interval capping and due-queue reordering as the date
/// approaches -- the one scheduling feature a plain SRS implementation
/// lacks: "study for retention" and "study for a specific exam on a
/// specific date" are different problems.
public struct Exam: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "exam"
    public var id: String
    public var courseId: String
    public var name: String
    public var examDate: Date

    public init(id: String = UUID().uuidString, courseId: String, name: String, examDate: Date) {
        self.id = id; self.courseId = courseId; self.name = name; self.examDate = examDate
    }
}

public struct ImportRun: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "importRun"
    public var id: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var filesScanned: Int?
    public var filesChanged: Int?
    public var filesSkippedAsset: Int?
    public var filesSkippedEmpty: Int?
    public var cardsCreated: Int?
    public var errorsJSON: String?

    public init(id: String = UUID().uuidString, startedAt: Date = Date(), finishedAt: Date? = nil,
                filesScanned: Int? = nil, filesChanged: Int? = nil, filesSkippedAsset: Int? = nil,
                filesSkippedEmpty: Int? = nil, cardsCreated: Int? = nil, errorsJSON: String? = nil) {
        self.id = id; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.filesScanned = filesScanned; self.filesChanged = filesChanged
        self.filesSkippedAsset = filesSkippedAsset; self.filesSkippedEmpty = filesSkippedEmpty
        self.cardsCreated = cardsCreated; self.errorsJSON = errorsJSON
    }
}
