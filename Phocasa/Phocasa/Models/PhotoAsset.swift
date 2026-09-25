import Foundation
import SwiftData

@Model
final class PhotoAsset {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var jpgPath: String?
    var rawPath: String?
    var rating: Int
    var creationDate: Date?
    var fileSize: Int64
    @Attribute(.externalStorage) var thumbnailData: Data?
    var folderPath: String
    var isDeleted: Bool

    // Edit parameters stored as JSON
    @Attribute(.externalStorage) var jpgEditParametersData: Data?
    var hasRawEdits: Bool = false

    @Relationship var tags: [Tag] = []

    /// When the photo was taken (EXIF `DateTimeOriginal`, see `CaptureDate`). The grid is ordered by it, falling back
    /// to `creationDate` (`LibrarySort`). Set from the scan's metadata read for new photos, and by the backfill after
    /// launch for rows stored before capture dates were read (`CaptureDateBackfill`).
    var captureDate: Date? = nil
    /// Whether the file's capture date has been read, so a nil `captureDate` means the file has none and the backfill
    /// doesn't read it again on every launch. Stays false while the file can't be read (it is tried again).
    var captureDateChecked: Bool = false

    var displayPath: String {
        jpgPath ?? rawPath ?? ""
    }

    var hasRawPair: Bool {
        jpgPath != nil && rawPath != nil
    }

    var hasAnyEdits: Bool {
        jpgEditParametersData != nil || hasRawEdits
    }

    var jpgEditParameters: EditParameters? {
        get {
            guard let data = jpgEditParametersData else { return nil }
            return try? JSONDecoder().decode(EditParameters.self, from: data)
        }
        set {
            jpgEditParametersData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    init(fileName: String, jpgPath: String? = nil, rawPath: String? = nil,
         folderPath: String, creationDate: Date? = nil, fileSize: Int64 = 0) {
        self.id = UUID()
        self.fileName = fileName
        self.jpgPath = jpgPath
        self.rawPath = rawPath
        self.rating = 0
        self.creationDate = creationDate
        self.fileSize = fileSize
        self.thumbnailData = nil
        self.folderPath = folderPath
        self.isDeleted = false
        self.jpgEditParametersData = nil
        self.hasRawEdits = false
        self.tags = []
    }
}
