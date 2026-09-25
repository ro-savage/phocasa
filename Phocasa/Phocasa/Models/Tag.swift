import Foundation
import SwiftData

@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    var name: String
    var category: String

    @Relationship(inverse: \PhotoAsset.tags) var photos: [PhotoAsset] = []

    var fullName: String {
        category.isEmpty ? name : "\(category):\(name)"
    }

    init(name: String, category: String = "") {
        self.id = UUID()
        self.name = name
        self.category = category
        self.photos = []
    }
}
