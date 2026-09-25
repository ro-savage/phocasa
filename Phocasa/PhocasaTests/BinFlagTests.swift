import XCTest
import SwiftData
@testable import Phocasa

/// The bin flag as stored. It used to be `PhotoAsset.isDeleted`, which collided with SwiftData's own
/// `PersistentModel.isDeleted` (spec §H5): the property read `false` after a save, and saving any later change to a
/// binned row wrote the flag back as `false`, so a photo rated in the bin came back into the library at the next
/// reload or launch (task 30's probe). Each test here failed with `isDeleted`; `isInBin` fixes them (task 31).
@MainActor
final class BinFlagTests: LibraryTestCase {

    /// Ids of the binned photos as stored, read through a fresh context on the same container.
    private func storedBinIDs(in container: ModelContainer) -> Set<UUID> {
        let fresh = ModelContext(container)
        let rows = (try? fresh.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.isInBin }))) ?? []
        return Set(rows.map(\.id))
    }

    // MARK: - Later saves keep the flag

    /// Rating a photo in the bin (its stars are clickable in the bin view) keeps it in the bin.
    func testRatingAPhotoInTheBinKeepsItInTheBin() {
        let binned = insertPhoto(name: "binned")
        let other = insertPhoto(name: "other")
        library.loadExistingData()
        library.moveToBin([binned])
        XCTAssertEqual(storedBinIDs(in: container), [binned.id], "precondition: moveToBin stores the flag")

        library.setRating(4, for: binned)
        try? context.save()

        XCTAssertEqual(storedBinIDs(in: container), [binned.id], "a fresh context still finds the photo in the bin")
        library.loadExistingData()
        XCTAssertEqual(ids(library.binPhotos), [binned.id])
        XCTAssertEqual(ids(library.allPhotos), [other.id])
        XCTAssertEqual(library.binCount, 1)
        XCTAssertEqual(binned.rating, 4)
    }

    /// The same for a rating of several photos at once (the selection-wide path).
    func testRatingSeveralPhotosInTheBinKeepsThemInTheBin() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        library.loadExistingData()
        library.moveToBin([a, b])
        XCTAssertEqual(storedBinIDs(in: container), [a.id, b.id], "precondition")

        library.setRating(2, for: [a, b])

        XCTAssertEqual(storedBinIDs(in: container), [a.id, b.id])
        library.loadExistingData()
        XCTAssertEqual(library.binCount, 2)
        XCTAssertTrue(library.allPhotos.isEmpty)
    }

    /// A photo already in the bin when the library loads (binned in an earlier session), rated twice: each rating is
    /// its own save.
    func testRatingAPhotoBinnedEarlierTwiceKeepsItInTheBin() {
        let binned = insertPhoto(name: "binned", isInBin: true)
        library.loadExistingData()
        XCTAssertEqual(ids(library.binPhotos), [binned.id], "precondition")

        library.setRating(2, for: binned)
        library.setRating(3, for: binned)

        XCTAssertEqual(storedBinIDs(in: container), [binned.id])
        library.loadExistingData()
        XCTAssertEqual(ids(library.binPhotos), [binned.id])
        XCTAssertTrue(library.allPhotos.isEmpty)
    }

    /// Tagging a photo in the bin keeps it in the bin.
    func testTaggingAPhotoInTheBinKeepsItInTheBin() {
        let binned = insertPhoto(name: "binned")
        library.loadExistingData()
        library.moveToBin([binned])

        library.addTag(name: "sea", category: "place", to: binned)

        XCTAssertEqual(storedBinIDs(in: container), [binned.id])
        library.loadExistingData()
        XCTAssertEqual(ids(library.binPhotos), [binned.id])
        XCTAssertTrue(library.allPhotos.isEmpty)
    }

    /// A row inserted in the bin, then changed and saved again, stays in the bin.
    func testChangingARowInsertedInTheBinKeepsTheFlag() throws {
        let binned = insertPhoto(name: "binned", isInBin: true)
        binned.fileSize = 2000
        try context.save()

        XCTAssertEqual(storedBinIDs(in: container), [binned.id])
    }

    /// After a relaunch (a new container on the same store file), a photo rated in the bin is still in the bin.
    func testPhotoRatedInTheBinIsStillInTheBinAfterARelaunch() throws {
        let url = try makeTempDir().appendingPathComponent("library.store")
        var binnedID: UUID?
        do {
            let container = try Self.makeContainer(at: url)
            let context = ModelContext(container)
            let library = LibraryStore()
            library.open(context)
            let photo = PhotoAsset(fileName: "binned", jpgPath: "/fake/binned.jpg", folderPath: "/fake",
                                   creationDate: Date(), fileSize: 1000)
            context.insert(photo)
            try context.save()
            library.loadExistingData()
            library.moveToBin([photo])
            library.setRating(5, for: photo)
            binnedID = photo.id
        }

        let container = try Self.makeContainer(at: url)
        let library = LibraryStore()
        library.open(ModelContext(container))
        XCTAssertEqual(ids(library.binPhotos), [try XCTUnwrap(binnedID)])
        XCTAssertTrue(library.allPhotos.isEmpty)
        XCTAssertEqual(library.binPhotos.first?.rating, 5)
    }

    // MARK: - Reading the flag

    /// The property reads what was stored straight after a save, with no refetch (results/10.md, deviation 12).
    func testFlagReadsCorrectlyStraightAfterASave() throws {
        let photo = insertPhoto(name: "a")
        photo.isInBin = true
        try context.save()
        XCTAssertTrue(photo.isInBin, "read straight after the save")

        photo.rating = 3
        try context.save()
        XCTAssertTrue(photo.isInBin, "read after a later save of another field")
    }

    /// `moveToBin` and `restoreFromBin` leave the property matching the store.
    func testMoveToBinAndRestoreSetTheProperty() {
        let photo = insertPhoto(name: "a")
        library.loadExistingData()

        library.moveToBin([photo])
        XCTAssertTrue(photo.isInBin)
        XCTAssertEqual(storedBinIDs(in: container), [photo.id])

        library.restoreFromBin([photo])
        XCTAssertFalse(photo.isInBin)
        XCTAssertEqual(storedBinIDs(in: container), [])
    }

    // MARK: - Helpers

    private static func makeContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
    }
}
