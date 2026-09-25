import XCTest
import SwiftData
@testable import Phocasa

/// Shared setup for tests that drive a `LibraryStore` over a fresh in-memory store, with the same helpers as
/// `ViewModelTests`, so the tests moved out of it (task 30) read as they did there.
@MainActor
class LibraryTestCase: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    var library: LibraryStore!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: config
        )
        context = ModelContext(container)
        library = LibraryStore()
        library.open(context)
    }

    override func tearDown() async throws {
        library = nil
        context = nil
        container = nil
    }

    // MARK: - Helpers

    @discardableResult
    func insertPhoto(
        name: String,
        rating: Int = 0,
        isInBin: Bool = false,
        creationDate: Date? = nil
    ) -> PhotoAsset {
        let photo = PhotoAsset(
            fileName: name,
            jpgPath: "/fake/\(name).jpg",
            folderPath: "/fake",
            creationDate: creationDate ?? Date(),
            fileSize: 1000
        )
        photo.rating = rating
        photo.isInBin = isInBin
        context.insert(photo)
        try? context.save()
        return photo
    }

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func ids(_ photos: [PhotoAsset]) -> [UUID] { photos.map(\.id) }
}
