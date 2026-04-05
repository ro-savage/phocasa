import Foundation
import SwiftData

@Model
final class PhotoLibrary {
    @Attribute(.unique) var id: UUID
    var rootFolderPath: String
    var bookmarkData: Data?
    var lastScanDate: Date?

    init(rootFolderPath: String, bookmarkData: Data? = nil) {
        self.id = UUID()
        self.rootFolderPath = rootFolderPath
        self.bookmarkData = bookmarkData
        self.lastScanDate = nil
    }
}
