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

    @Relationship var tags: [Tag] = []

    var displayPath: String {
        jpgPath ?? rawPath ?? ""
    }

    var hasRawPair: Bool {
        jpgPath != nil && rawPath != nil
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
        self.tags = []
    }
}
