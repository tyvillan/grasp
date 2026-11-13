import Foundation
import GRDB

/// The picture a question was read from (photo import). Stored as a small
/// JPEG in base64 so it rides the same sync as every other row: the app
/// compresses it (long edge about 1600 px) before it gets here. While its
/// question is a draft the picture is a draft too and never leaves the device.
public struct QuestionImage: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "questionImage"
    public var id: String
    public var courseId: String?
    public var jpegBase64: String
    public var width: Int
    public var height: Int
    /// "draft" until its question is approved, then "ready".
    public var status: String
    public var createdAt: Date
    public var deletedAt: Date?

    /// The JPEG bytes, or nil if the row is damaged.
    public var jpegData: Data? { Data(base64Encoded: jpegBase64) }
}

public enum QuestionImages {
    /// The largest picture kept, in bytes of JPEG. A phone photo compressed to
    /// 1600 px is typically 200 to 400 KB.
    public static let maxBytes = 900_000

    @discardableResult
    public static func save(jpeg: Data, width: Int, height: Int, courseId: String?, now: Date = Date(),
                            db: Database) throws -> QuestionImage {
        guard !jpeg.isEmpty else { throw QuestionBankError.invalid("That picture is empty.") }
        guard jpeg.count <= maxBytes else { throw QuestionBankError.invalid("That picture is too large to keep.") }
        let image = QuestionImage(id: UUID().uuidString, courseId: courseId, jpegBase64: jpeg.base64EncodedString(),
                                  width: width, height: height, status: "draft", createdAt: now, deletedAt: nil)
        try image.insert(db)
        return image
    }

    public static func image(_ id: String, db: Database) throws -> QuestionImage? {
        try QuestionImage.fetchOne(db, key: id).flatMap { $0.deletedAt == nil ? $0 : nil }
    }

    /// Lets the picture sync, once its question has been approved.
    public static func markReady(_ id: String, db: Database) throws {
        guard var image = try QuestionImage.fetchOne(db, key: id), image.status != "ready" else { return }
        image.status = "ready"
        try image.save(db)
    }

    /// Removes a picture nothing uses any more.
    public static func releaseIfUnused(_ id: String, now: Date = Date(), db: Database) throws {
        let uses = try TestQuestion.filter(Column("imageId") == id).filter(Column("deletedAt") == nil).fetchCount(db)
        guard uses == 0, var image = try QuestionImage.fetchOne(db, key: id), image.deletedAt == nil else { return }
        image.deletedAt = now
        try image.save(db)
    }
}
