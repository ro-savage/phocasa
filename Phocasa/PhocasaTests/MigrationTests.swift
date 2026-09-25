import XCTest
import SwiftData
@testable import Phocasa

/// Phocasa's SwiftData models as they were before task 31 (`main` at 1d91126), frozen: the format every existing
/// library is stored in. Never change these. The class names match the live models, so the entity names match.
enum PhocasaSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self] }

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

    @Model
    final class Tag {
        @Attribute(.unique) var id: UUID
        var name: String
        var category: String

        @Relationship var parent: Tag?
        @Relationship(deleteRule: .cascade, inverse: \Tag.parent) var children: [Tag] = []
        @Relationship(inverse: \PhotoAsset.tags) var photos: [PhotoAsset] = []

        init(name: String, category: String = "", parent: Tag? = nil) {
            self.id = UUID()
            self.name = name
            self.category = category
            self.parent = parent
            self.children = []
            self.photos = []
        }
    }

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

    @Model
    final class EditPreset {
        @Attribute(.unique) var id: UUID
        var name: String
        var parametersData: Data
        var createdDate: Date

        init(name: String, parametersData: Data) {
            self.id = UUID()
            self.name = name
            self.parametersData = parametersData
            self.createdDate = Date()
        }
    }
}

/// A library stored in the V1 format opens with the app's current models with every value kept (spec §H4, §H5).
/// Temp stores only: these tests never touch the user's library.
@MainActor
final class MigrationTests: XCTestCase {

    /// A photo row's stored values, to compare before and after the migration.
    private struct PhotoValues: Equatable {
        let id: UUID
        let fileName: String
        let jpgPath: String?
        let rawPath: String?
        let rating: Int
        let creationDate: Date?
        let fileSize: Int64
        let folderPath: String
        let inBin: Bool
        let jpgEditParametersData: Data?
        let hasRawEdits: Bool
        let tagIDs: Set<UUID>
    }

    private var storeURL: URL!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaTests-Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        storeURL = dir.appendingPathComponent("default.store")
    }

    // MARK: - Containers

    private func makeV1Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: PhocasaSchemaV1.self)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
    }

    /// The app's current models, opened the way `PhocasaApp` opens the real store.
    private func makeCurrentContainer() throws -> ModelContainer {
        let schema = Schema([Phocasa.PhotoAsset.self, Phocasa.Tag.self, Phocasa.PhotoLibrary.self,
                             Phocasa.EditPreset.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
    }

    // MARK: - V1 → current

    func testV1StoreMigratesWithoutDataLoss() throws {
        var edit = EditParameters()
        edit.exposure = 1.5
        edit.cropRect = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        let editData = try JSONEncoder().encode(edit)
        let presetParameters = EditParameters(exposure: -0.5, contrast: 20)
        let presetData = try JSONEncoder().encode(presetParameters)
        let bookmark = Data((0..<64).map { UInt8($0) })
        let scanDate = Date(timeIntervalSince1970: 1_700_000_000)

        var expectedPhotos: [PhotoValues] = []
        var expectedTags: [UUID: (name: String, category: String)] = [:]
        var libraryID: UUID?
        var presetID: UUID?
        var presetCreated: Date?

        // 1. A V1 store with a binned photo, a rated and tagged one, and an edited one (and every other field set).
        do {
            let container = try makeV1Container()
            let context = ModelContext(container)

            let place = PhocasaSchemaV1.Tag(name: "sea", category: "place")
            let child = PhocasaSchemaV1.Tag(name: "beach", category: "place", parent: place)
            let person = PhocasaSchemaV1.Tag(name: "ann", category: "people")
            for tag in [place, child, person] { context.insert(tag) }

            let binned = PhocasaSchemaV1.PhotoAsset(
                fileName: "binned", jpgPath: "/photos/binned.jpg", folderPath: "/photos",
                creationDate: Date(timeIntervalSince1970: 1_000), fileSize: 1_234)
            binned.isDeleted = true
            binned.rating = 1

            let rated = PhocasaSchemaV1.PhotoAsset(
                fileName: "rated", jpgPath: "/photos/rated.jpg", rawPath: "/photos/rated.arw", folderPath: "/photos",
                creationDate: Date(timeIntervalSince1970: 2_000), fileSize: 25_000_000)
            rated.rating = 4
            rated.hasRawEdits = true

            let edited = PhocasaSchemaV1.PhotoAsset(
                fileName: "edited", rawPath: "/photos/sub/edited.cr3", folderPath: "/photos/sub",
                creationDate: nil, fileSize: 9)
            edited.jpgEditParametersData = editData
            edited.thumbnailData = Data(repeating: 0xAB, count: 256 * 1024) // large enough for external storage

            for photo in [binned, rated, edited] { context.insert(photo) }
            rated.tags = [child, person]

            let library = PhocasaSchemaV1.PhotoLibrary(rootFolderPath: "/photos", bookmarkData: bookmark)
            library.lastScanDate = scanDate
            context.insert(library)

            let preset = PhocasaSchemaV1.EditPreset(name: "Warm", parametersData: presetData)
            context.insert(preset)

            try context.save()

            let v1Photos: [PhocasaSchemaV1.PhotoAsset] = [binned, rated, edited]
            expectedPhotos = v1Photos.map { (photo: PhocasaSchemaV1.PhotoAsset) -> PhotoValues in
                PhotoValues(id: photo.id, fileName: photo.fileName, jpgPath: photo.jpgPath, rawPath: photo.rawPath,
                            rating: photo.rating, creationDate: photo.creationDate, fileSize: photo.fileSize,
                            folderPath: photo.folderPath, inBin: photo === binned,
                            jpgEditParametersData: photo.jpgEditParametersData, hasRawEdits: photo.hasRawEdits,
                            tagIDs: Set(photo.tags.map(\.id)))
            }
            for tag in [place, child, person] { expectedTags[tag.id] = (tag.name, tag.category) }
            libraryID = library.id
            presetID = preset.id
            presetCreated = preset.createdDate

            // Sanity check of the V1 store itself, through a fresh context.
            let fresh = ModelContext(container)
            let v1Binned = try fresh.fetch(FetchDescriptor<PhocasaSchemaV1.PhotoAsset>(
                predicate: #Predicate { $0.isDeleted }))
            XCTAssertEqual(v1Binned.map(\.id), [binned.id], "precondition: the V1 store holds the bin flag")
        }

        // 2. The same file, opened with the app's current models.
        let container = try makeCurrentContainer()
        let context = ModelContext(container)

        let photos = try context.fetch(FetchDescriptor<Phocasa.PhotoAsset>())
        let actual = photos.map { (photo: Phocasa.PhotoAsset) -> PhotoValues in
            PhotoValues(id: photo.id, fileName: photo.fileName, jpgPath: photo.jpgPath, rawPath: photo.rawPath,
                        rating: photo.rating, creationDate: photo.creationDate, fileSize: photo.fileSize,
                        folderPath: photo.folderPath, inBin: photo.isInBin,
                        jpgEditParametersData: photo.jpgEditParametersData, hasRawEdits: photo.hasRawEdits,
                        tagIDs: Set(photo.tags.map(\.id)))
        }
        XCTAssertEqual(actual.count, 3)
        for expected in expectedPhotos {
            XCTAssertEqual(actual.first { $0.id == expected.id }, expected, "photo \(expected.fileName)")
        }

        // The bin flag carried over from `isDeleted`, in the store's own evaluation too.
        let binnedNow = try context.fetch(FetchDescriptor<Phocasa.PhotoAsset>(predicate: #Predicate { $0.isInBin }))
        XCTAssertEqual(binnedNow.map(\.fileName), ["binned"])
        let libraryNow = try context.fetch(FetchDescriptor<Phocasa.PhotoAsset>(predicate: #Predicate { !$0.isInBin }))
        XCTAssertEqual(Set(libraryNow.map(\.fileName)), ["rated", "edited"])

        // Edit parameters decode.
        let edited = try XCTUnwrap(photos.first { $0.fileName == "edited" })
        XCTAssertEqual(edited.jpgEditParameters, edit)
        XCTAssertTrue(edited.hasAnyEdits)

        // Tags: every row survives (the child tag becomes a plain tag), and the photo ↔ tag links are intact both ways.
        let tags = try context.fetch(FetchDescriptor<Phocasa.Tag>())
        XCTAssertEqual(tags.count, 3)
        for tag in tags {
            XCTAssertEqual(expectedTags[tag.id]?.name, tag.name)
            XCTAssertEqual(expectedTags[tag.id]?.category, tag.category)
        }
        let rated = try XCTUnwrap(photos.first { $0.fileName == "rated" })
        XCTAssertEqual(Set(rated.tags.map(\.fullName)), ["place:beach", "people:ann"])
        XCTAssertEqual(tags.first { $0.name == "beach" }?.photos.map(\.id), [rated.id])
        XCTAssertEqual(tags.first { $0.name == "ann" }?.photos.map(\.id), [rated.id])
        XCTAssertEqual(tags.first { $0.name == "sea" }?.photos.count, 0)

        // The library and the preset survive.
        let libraries = try context.fetch(FetchDescriptor<Phocasa.PhotoLibrary>())
        XCTAssertEqual(libraries.count, 1)
        XCTAssertEqual(libraries.first?.id, libraryID)
        XCTAssertEqual(libraries.first?.rootFolderPath, "/photos")
        XCTAssertEqual(libraries.first?.bookmarkData, bookmark)
        XCTAssertEqual(libraries.first?.lastScanDate, scanDate)

        let presets = try context.fetch(FetchDescriptor<Phocasa.EditPreset>())
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets.first?.id, presetID)
        XCTAssertEqual(presets.first?.name, "Warm")
        XCTAssertEqual(presets.first?.createdDate, presetCreated)
        XCTAssertEqual(presets.first?.parameters, presetParameters)
    }

    /// Many rows: each one's bin flag carries over, not just the first's.
    func testEveryRowsBinFlagCarriesOver() throws {
        var binnedIDs = Set<UUID>()
        var allIDs = Set<UUID>()
        do {
            let context = ModelContext(try makeV1Container())
            for i in 0..<60 {
                let photo = PhocasaSchemaV1.PhotoAsset(fileName: "p\(i)", jpgPath: "/p/p\(i).jpg", folderPath: "/p",
                                                       creationDate: Date(timeIntervalSince1970: Double(i)))
                photo.isDeleted = i % 3 == 0
                photo.rating = i % 6
                context.insert(photo)
                allIDs.insert(photo.id)
                if photo.isDeleted { binnedIDs.insert(photo.id) }
            }
            try context.save()
        }

        let context = ModelContext(try makeCurrentContainer())
        let photos = try context.fetch(FetchDescriptor<Phocasa.PhotoAsset>())
        XCTAssertEqual(Set(photos.map(\.id)), allIDs)
        XCTAssertEqual(Set(photos.filter(\.isInBin).map(\.id)), binnedIDs)
        let binned = try context.fetch(FetchDescriptor<Phocasa.PhotoAsset>(predicate: #Predicate { $0.isInBin }))
        XCTAssertEqual(Set(binned.map(\.id)), binnedIDs)
        for photo in photos {
            XCTAssertEqual(photo.rating, Int(photo.fileName.dropFirst())! % 6)
        }
    }

    /// After the migration the app loads the library as before, and a photo from the old bin, rated in the new
    /// build, is still in the bin at the next launch (the bug the rename fixes, on a migrated store).
    func testMigratedLibraryLoadsAndKeepsTheBinAcrossLaterSaves() throws {
        var binnedID: UUID?
        do {
            let context = ModelContext(try makeV1Container())
            let binned = PhocasaSchemaV1.PhotoAsset(fileName: "binned", jpgPath: "/p/binned.jpg", folderPath: "/p",
                                                    creationDate: Date(timeIntervalSince1970: 1))
            binned.isDeleted = true
            let kept = PhocasaSchemaV1.PhotoAsset(fileName: "kept", jpgPath: "/p/kept.jpg", folderPath: "/p",
                                                  creationDate: Date(timeIntervalSince1970: 2))
            context.insert(binned)
            context.insert(kept)
            try context.save()
            binnedID = binned.id
        }

        do {
            let library = LibraryStore()
            library.open(ModelContext(try makeCurrentContainer()))
            XCTAssertEqual(library.binPhotos.map(\.id), [try XCTUnwrap(binnedID)])
            XCTAssertEqual(library.allPhotos.map(\.fileName), ["kept"])

            let binned = try XCTUnwrap(library.binPhotos.first)
            library.setRating(3, for: binned)
            library.setRating(5, for: binned)
            XCTAssertTrue(binned.isInBin, "read straight after the saves")
        }

        let library = LibraryStore()
        library.open(ModelContext(try makeCurrentContainer()))
        XCTAssertEqual(library.binPhotos.map(\.id), [try XCTUnwrap(binnedID)])
        XCTAssertEqual(library.binPhotos.first?.rating, 5)
        XCTAssertEqual(library.allPhotos.map(\.fileName), ["kept"])
    }
}
