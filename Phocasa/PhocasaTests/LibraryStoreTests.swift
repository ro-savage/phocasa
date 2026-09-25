import XCTest
import SwiftData
@testable import Phocasa

/// `LibraryStore` on its own: loading, counts, filters, search, sort, rating and tags, and the in-memory library.
/// Moved from `ViewModelTests` (task 30) with every assertion; flows that also touch the selection or the detail view
/// stay there.
final class LibraryStoreTests: LibraryTestCase {

    // MARK: - Loading

    func testLoadExistingData() {
        insertPhoto(name: "photo1")
        insertPhoto(name: "photo2")
        insertPhoto(name: "deleted", isDeleted: true)

        library.loadExistingData()

        XCTAssertEqual(library.allPhotos.count, 2)
        XCTAssertEqual(library.binCount, 1)
    }

    func testLoadSetsPhotosArray() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")

        library.loadExistingData()

        XCTAssertEqual(library.photos.count, 2)
    }

    func testLoadBinViewShowsDeletedPhotos() {
        insertPhoto(name: "active")
        insertPhoto(name: "binned", isDeleted: true)

        library.viewingBin = true
        library.loadExistingData()

        XCTAssertEqual(library.photos.count, 1)
        XCTAssertEqual(library.photos.first?.fileName, "binned")
    }

    // MARK: - Rating Counts

    func testRatingCountsComputed() {
        insertPhoto(name: "a", rating: 0)
        insertPhoto(name: "b", rating: 3)
        insertPhoto(name: "c", rating: 3)
        insertPhoto(name: "d", rating: 5)

        library.loadExistingData()

        XCTAssertEqual(library.ratingCounts[0], 1)
        XCTAssertEqual(library.ratingCounts[3], 2)
        XCTAssertEqual(library.ratingCounts[5], 1)
        XCTAssertNil(library.ratingCounts[1])
        XCTAssertNil(library.ratingCounts[2])
    }

    func testRatingCountsEmptyLibrary() {
        library.loadExistingData()
        XCTAssertTrue(library.ratingCounts.isEmpty)
    }

    // MARK: - Filtering

    func testFilterAll() {
        insertPhoto(name: "a", rating: 1)
        insertPhoto(name: "b", rating: 3)
        library.loadExistingData()

        library.applyFilter(.all)

        XCTAssertEqual(library.photos.count, 2)
    }

    func testFilterByRating() {
        insertPhoto(name: "a", rating: 1)
        insertPhoto(name: "b", rating: 3)
        insertPhoto(name: "c", rating: 3)
        library.loadExistingData()

        library.applyFilter(.rated(3))

        XCTAssertEqual(library.photos.count, 2)
        XCTAssertTrue(library.photos.allSatisfy { $0.rating == 3 })
    }

    func testFilterUnrated() {
        insertPhoto(name: "a", rating: 0)
        insertPhoto(name: "b", rating: 3)
        library.loadExistingData()

        library.applyFilter(.unrated)

        XCTAssertEqual(library.photos.count, 1)
        XCTAssertEqual(library.photos.first?.rating, 0)
    }

    func testFilterBin() {
        insertPhoto(name: "a")
        insertPhoto(name: "b", isDeleted: true)
        insertPhoto(name: "c", isDeleted: true)
        library.loadExistingData()

        library.applyFilter(.bin)

        XCTAssertTrue(library.viewingBin)
        XCTAssertEqual(library.photos.count, 2)
    }

    func testFilterBinDoesNotShowActivePhotos() {
        insertPhoto(name: "active")
        insertPhoto(name: "binned", isDeleted: true)
        library.loadExistingData()

        library.applyFilter(.bin)

        XCTAssertEqual(library.photos.count, 1)
        XCTAssertEqual(library.photos.first?.fileName, "binned")
    }

    // MARK: - In-memory contract

    /// The store is read by `loadExistingData()` (and by scans). UI interactions work on the in-memory
    /// state; in the app every store change goes through the view model, so nothing is lost.
    func testFilterChangesDoNotRefetch() {
        insertPhoto(name: "loaded")
        library.loadExistingData()

        let late = insertPhoto(name: "late")
        library.applyFilter(.all)
        XCTAssertFalse(library.photos.contains { $0.id == late.id })

        library.loadExistingData()
        XCTAssertTrue(library.photos.contains { $0.id == late.id })
    }

    // MARK: - Rating

    func testSetRating() {
        let photo = insertPhoto(name: "a")
        library.loadExistingData()

        library.setRating(4, for: photo)

        XCTAssertEqual(photo.rating, 4)
    }

    // MARK: - File Availability

    func testRefreshAvailabilityHidesPhotosWithMissingFiles() throws {
        let dir = try makeTempDir()
        let presentPath = dir.appendingPathComponent("present.jpg").path
        FileManager.default.createFile(atPath: presentPath, contents: Data())

        let present = insertPhoto(name: "present")
        present.jpgPath = presentPath
        let gone = insertPhoto(name: "gone")
        gone.jpgPath = dir.appendingPathComponent("gone.jpg").path
        try context.save()

        library.refreshAvailability()

        XCTAssertEqual(library.allPhotos.map(\.id), [present.id])
    }

    // MARK: - Sort

    func testToggleSortOrder() {
        XCTAssertTrue(library.sortNewestFirst)
        library.toggleSortOrder()
        XCTAssertFalse(library.sortNewestFirst)
        library.toggleSortOrder()
        XCTAssertTrue(library.sortNewestFirst)
    }

    // MARK: - Tags

    func testFindOrCreateTag() {
        let tag = library.findOrCreateTag(name: "sunset", category: "time", in: context)
        XCTAssertEqual(tag.name, "sunset")
        XCTAssertEqual(tag.category, "time")

        // Finding again should return the same tag
        let same = library.findOrCreateTag(name: "sunset", category: "time", in: context)
        XCTAssertEqual(tag.id, same.id)
    }

    func testAddTag() {
        let photo = insertPhoto(name: "a")
        library.loadExistingData()

        library.addTag(name: "sunset", category: "time", to: photo)

        XCTAssertEqual(photo.tags.count, 1)
        XCTAssertEqual(photo.tags.first?.name, "sunset")
        XCTAssertEqual(photo.tags.first?.category, "time")
    }

    func testAddDuplicateTag() {
        let photo = insertPhoto(name: "a")
        library.loadExistingData()

        library.addTag(name: "sunset", category: "time", to: photo)
        library.addTag(name: "sunset", category: "time", to: photo)

        XCTAssertEqual(photo.tags.count, 1, "Duplicate tags should not be added")
    }

    func testRemoveTag() {
        let photo = insertPhoto(name: "a")
        library.loadExistingData()

        library.addTag(name: "sunset", category: "time", to: photo)
        let tag = photo.tags.first!

        library.removeTag(tag, from: photo)

        XCTAssertTrue(photo.tags.isEmpty)
    }

    // MARK: - Search

    func testSearchByFilename() {
        insertPhoto(name: "sunset_beach")
        insertPhoto(name: "mountain_view")
        library.loadExistingData()
        library.searchText = "sunset"

        library.applyCurrentFilter()

        XCTAssertEqual(library.photos.count, 1)
        XCTAssertEqual(library.photos.first?.fileName, "sunset_beach")
    }

    func testSearchCaseInsensitive() {
        insertPhoto(name: "Sunset_Beach")
        library.loadExistingData()
        library.searchText = "sunset"

        library.applyCurrentFilter()

        XCTAssertEqual(library.photos.count, 1)
    }

    func testSearchClearedRestoresAll() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")
        library.loadExistingData()
        library.searchText = "a"
        library.applyCurrentFilter()
        XCTAssertEqual(library.photos.count, 1)

        library.searchText = ""
        library.applyCurrentFilter()
        XCTAssertEqual(library.photos.count, 2)
    }

    // MARK: - File Type Filter

    func testFilterJPGOnly() {
        insertPhoto(name: "jpg_only")
        let rawOnly = PhotoAsset(fileName: "raw_only", rawPath: "/fake/raw_only.cr3",
                                 folderPath: "/fake", creationDate: Date(), fileSize: 1000)
        context.insert(rawOnly)
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        library.loadExistingData()

        library.applyFilter(.jpgOnly)

        XCTAssertEqual(library.photos.count, 2, "Should show jpg_only and paired (both have jpgPath)")
        XCTAssertTrue(library.photos.allSatisfy { $0.jpgPath != nil })
    }

    func testFilterRAWOnly() {
        insertPhoto(name: "jpg_only")
        let rawOnly = PhotoAsset(fileName: "raw_only", rawPath: "/fake/raw_only.cr3",
                                 folderPath: "/fake", creationDate: Date(), fileSize: 1000)
        context.insert(rawOnly)
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        library.loadExistingData()

        library.applyFilter(.rawOnly)

        XCTAssertEqual(library.photos.count, 2, "Should show raw_only and paired (both have rawPath)")
        XCTAssertTrue(library.photos.allSatisfy { $0.rawPath != nil })
    }

    func testFileTypeCountsComputed() {
        insertPhoto(name: "jpg_only")
        let rawOnly = PhotoAsset(fileName: "raw_only", rawPath: "/fake/raw_only.cr3",
                                 folderPath: "/fake", creationDate: Date(), fileSize: 1000)
        context.insert(rawOnly)
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        library.loadExistingData()

        XCTAssertEqual(library.jpgCount, 2, "jpg_only + paired")
        XCTAssertEqual(library.rawCount, 2, "raw_only + paired")
    }

    // MARK: - Multi-Filter

    func testMultiFilterAutoCombinesDifferentCategories() {
        let a = insertPhoto(name: "a", rating: 3)
        a.rawPath = "/fake/a.cr3"
        insertPhoto(name: "b", rating: 3)
        // b has no rawPath
        let c = insertPhoto(name: "c", rating: 5)
        c.rawPath = "/fake/c.cr3"
        try? context.save()
        library.loadExistingData()

        // Click rating 3
        library.applyFilter(.rated(3))
        XCTAssertEqual(library.photos.count, 2, "a and b are rated 3")

        // Click RAW only — should auto-combine (different category)
        library.applyFilter(.rawOnly)
        XCTAssertEqual(library.photos.count, 1, "Only a is rated 3 AND has RAW")
        XCTAssertEqual(library.photos.first?.fileName, "a")
        XCTAssertEqual(library.activeFilters.count, 2)
    }

    func testMultiFilterReplacesWithinCategory() {
        insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", rating: 4)
        insertPhoto(name: "c", rating: 5)
        library.loadExistingData()

        library.applyFilter(.rated(3))
        XCTAssertEqual(library.photos.count, 1)

        // Click 4-star — should replace 3-star (same category)
        library.applyFilter(.rated(4))
        XCTAssertEqual(library.photos.count, 1)
        XCTAssertEqual(library.photos.first?.rating, 4)
        XCTAssertEqual(library.activeFilters.count, 1)
    }

    func testMultiFilterShiftToggle() {
        insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", rating: 4)
        insertPhoto(name: "c", rating: 5)
        library.loadExistingData()

        library.applyFilter(.rated(3))
        XCTAssertEqual(library.photos.count, 1)

        // Shift-click 4-star — should add (now showing 3 AND 4)
        library.applyFilter(.rated(4), isShiftHeld: true)
        XCTAssertEqual(library.photos.count, 2)
        XCTAssertTrue(library.activeFilters.contains(.rated(3)))
        XCTAssertTrue(library.activeFilters.contains(.rated(4)))

        // Shift-click 3-star again — should remove it
        library.applyFilter(.rated(3), isShiftHeld: true)
        XCTAssertEqual(library.photos.count, 1)
        XCTAssertEqual(library.photos.first?.rating, 4)
    }

    func testClearFiltersWithAll() {
        insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", rating: 5)
        library.loadExistingData()

        library.applyFilter(.rated(3))
        XCTAssertEqual(library.photos.count, 1)

        library.applyFilter(.all)
        XCTAssertTrue(library.activeFilters.isEmpty)
        XCTAssertEqual(library.photos.count, 2)
    }

    func testBinFilterIsExclusive() {
        insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", isDeleted: true)
        library.loadExistingData()

        library.applyFilter(.rated(3))
        library.applyFilter(.bin)

        XCTAssertTrue(library.viewingBin)
        XCTAssertEqual(library.activeFilters, [.bin])
        XCTAssertEqual(library.photos.count, 1)
        XCTAssertEqual(library.photos.first?.fileName, "b")
    }

    // MARK: - Smart Delete (File Type)

    func testHasFileTypeFilter() {
        XCTAssertFalse(library.hasFileTypeFilter)

        library.applyFilter(.rawOnly)
        XCTAssertTrue(library.hasFileTypeFilter)

        library.applyFilter(.all)
        XCTAssertFalse(library.hasFileTypeFilter)
    }
}
