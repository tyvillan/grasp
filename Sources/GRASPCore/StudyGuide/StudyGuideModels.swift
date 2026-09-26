import Foundation
import GRDB

/// One imported exam study guide: the parsed document, the file it came
/// from, and the exam it prepares for. Several guides can point at the same
/// exam (a professor's and a student's own), and the exam page reads them
/// together.
public struct StudyGuide: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "studyGuide"
    public var id: String
    public var courseId: String
    /// The exam this guide is for. Linked automatically on import (see
    /// `StudyGuideMatcher.exam`) and changeable by hand; nil when the course
    /// has no exam yet.
    public var examEventId: String?
    /// The imported file. Unique: re-importing the same file updates its
    /// guide rather than making a second.
    public var materialId: String?
    public var title: String
    /// A `StudyGuideDocument`, encoded by `StudyGuideCoding`.
    public var bodyJSON: String
    public var bodySchemaVersion: Int
    /// The `Material.contentHash` the body was parsed from.
    public var sourceContentHash: String?
    /// "rules" today; a model's name once an AI fallback parses a guide the
    /// rules can't.
    public var parser: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, courseId: String, examEventId: String? = nil,
                materialId: String? = nil, title: String, bodyJSON: String,
                bodySchemaVersion: Int = StudyGuideDocument.schemaVersion,
                sourceContentHash: String? = nil, parser: String = "rules",
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.courseId = courseId; self.examEventId = examEventId
        self.materialId = materialId; self.title = title; self.bodyJSON = bodyJSON
        self.bodySchemaVersion = bodySchemaVersion; self.sourceContentHash = sourceContentHash
        self.parser = parser; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// nil for a body from a newer build, or a corrupt one.
    public func document() -> StudyGuideDocument? {
        guard bodySchemaVersion <= StudyGuideDocument.schemaVersion else { return nil }
        return StudyGuideCoding.decode(bodyJSON)
    }
}

/// Which lecture deck a guide's part covers. Filled by
/// `StudyGuideMatcher.decks` when the guide is imported; `isManual` rows are
/// the student's own corrections, which a re-import never replaces.
public struct StudyGuidePartDeck: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "studyGuidePartDeck"
    public var guideId: String
    /// Index into `StudyGuideDocument.parts`.
    public var partIndex: Int
    public var deckId: String
    public var isManual: Bool

    public init(guideId: String, partIndex: Int, deckId: String, isManual: Bool = false) {
        self.guideId = guideId; self.partIndex = partIndex; self.deckId = deckId
        self.isManual = isManual
    }
}

public enum SkillConfidence: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case canDoCold, shaky, cantYet
}

/// How sure the student is of one "you should be able to" skill.
public struct SkillRating: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "skillRating"
    public var guideId: String
    /// `StudyGuideDocument.skillId(part:skill:)`.
    public var skillId: String
    public var rating: SkillConfidence
    public var ratedAt: Date

    public init(guideId: String, skillId: String, rating: SkillConfidence, ratedAt: Date = Date()) {
        self.guideId = guideId; self.skillId = skillId; self.rating = rating; self.ratedAt = ratedAt
    }
}

extension StudyGuideDocument {
    /// Stable while the guide's text is: skills are addressed by position,
    /// like `RenderedSection` ids.
    public static func skillId(part: Int, skill: Int) -> String { "p\(part)s\(skill)" }
}
