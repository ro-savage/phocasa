import Foundation
import SwiftData

@Model
final class EditPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var parametersData: Data
    var createdDate: Date

    var parameters: EditParameters {
        get {
            (try? JSONDecoder().decode(EditParameters.self, from: parametersData)) ?? EditParameters()
        }
        set {
            parametersData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    init(name: String, parameters: EditParameters) {
        self.id = UUID()
        self.name = name
        self.parametersData = (try? JSONEncoder().encode(parameters)) ?? Data()
        self.createdDate = Date()
    }
}
