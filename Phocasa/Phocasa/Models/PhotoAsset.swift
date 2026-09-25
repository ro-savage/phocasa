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
    var folderPath: String
    /// In the bin. Renamed from `isDeleted`, which collided with SwiftData's own `isDeleted` (spec §H5);
    /// `originalName` migrates existing stores.
    @Attribute(originalName: "isDeleted") var isInBin: Bool

    // Edit parameters stored as JSON
    @Attribute(.externalStorage) var jpgEditParametersData: Data?
    var hasRawEdits: Bool = false

    @Relationship var tags: [Tag] = []

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
        self.folderPath = folderPath
        self.isInBin = false
        self.jpgEditParametersData = nil
        self.hasRawEdits = false
        self.tags = []
    }
}
