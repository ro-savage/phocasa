import Foundation
import SwiftData

@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    var name: String
    var category: String

    @Relationship var parent: Tag?
    @Relationship(deleteRule: .cascade, inverse: \Tag.parent) var children: [Tag] = []
    @Relationship(inverse: \PhotoAsset.tags) var photos: [PhotoAsset] = []

    var fullName: String {
        "\(category):\(name)"
    }

    init(name: String, category: String, parent: Tag? = nil) {
        self.id = UUID()
        self.name = name
        self.category = category
        self.parent = parent
        self.children = []
        self.photos = []
    }
}
