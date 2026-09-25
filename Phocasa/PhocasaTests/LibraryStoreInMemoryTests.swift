import XCTest
import SwiftData
@testable import Phocasa

/// `LibraryStore`'s in-memory library: mutations patch the lists, the grid and the counts without a reload. Moved from
/// `ViewModelTests` (task 30) with every assertion; the checks against a fresh load stay there.
final class LibraryStoreInMemoryTests: LibraryTestCase {

    func testPhotosDidChangePicksUpDirectModelChanges() {
        let raw = PhotoAsset(fileName: "raw", rawPath: "/fake/raw.arw", folderPath: "/fake", creationDate: date(2000))
        context.insert(raw)
        let jpg = insertPhoto(name: "jpg", creationDate: date(1000))
        library.loadExistingData()
        library.applyFilter(.jpgOnly)
        XCTAssertEqual(ids(library.photos), [jpg.id])
        XCTAssertEqual(library.jpgCount, 1)

        // As an export that writes a JPG next to a RAW-only photo does.
        raw.jpgPath = "/fake/raw-raw-edit.jpg"
        library.photosDidChange([raw])

        XCTAssertEqual(ids(library.photos), [raw.id, jpg.id])
        XCTAssertEqual(library.jpgCount, 2)
    }

    func testSetRatingUpdatesFilterAndCountsInMemory() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 3, creationDate: date(2000))
        insertPhoto(name: "c", rating: 5, creationDate: date(1000))
        library.loadExistingData()
        library.applyFilter(.rated(3))
        XCTAssertEqual(library.ratingCounts, [3: 2, 5: 1])

        library.setRating(4, for: a)

        XCTAssertEqual(ids(library.photos), [b.id])
        XCTAssertEqual(library.ratingCounts, [3: 1, 4: 1, 5: 1])
    }

    func testFacetCountsWithActiveFilter() {
        let a = insertPhoto(name: "a", rating: 3)
        let b = insertPhoto(name: "b", rating: 5)
        library.loadExistingData()
        library.addTag(name: "alice", category: "people", to: a)
        library.addTag(name: "alice", category: "people", to: b)
        let alice = a.tags[0]

        library.applyFilter(.rated(3))

        XCTAssertEqual(library.ratingCounts, [3: 1, 5: 1], "rating counts ignore the rating filter")
        XCTAssertEqual(library.tagCounts, [alice.id: 1], "tag counts only cover 3-star photos")
        XCTAssertEqual(library.categoryCounts, ["people": 1])
        XCTAssertEqual(library.jpgCount, 1)
    }

    func testAddAndRemoveTagUpdateTagListsCountsAndFiltersInMemory() {
        let a = insertPhoto(name: "a", creationDate: date(2000))
        let b = insertPhoto(name: "b", creationDate: date(1000))
        library.loadExistingData()

        library.addTag(name: "bob", category: "people", to: a)
        let bob = a.tags[0]
        XCTAssertEqual(library.tagsByCategory["people"]?.map(\.name), ["bob"])
        XCTAssertEqual(library.tagCategories, ["people"])
        XCTAssertEqual(library.tagCounts, [bob.id: 1])
        XCTAssertEqual(library.categoryCounts, ["people": 1])

        library.addTag(name: "alice", category: "people", to: b)
        library.addTag(name: "zed", category: "", to: a)
        XCTAssertEqual(library.tagsByCategory["people"]?.map(\.name), ["alice", "bob"])
        XCTAssertEqual(library.uncategorizedTags.map(\.name), ["zed"])
        XCTAssertEqual(library.allTags.map(\.name), ["zed", "alice", "bob"])
        XCTAssertEqual(library.categoryCounts, ["people": 2])

        library.applyFilter(.tag(bob.id))
        XCTAssertEqual(ids(library.photos), [a.id])
        library.applyFilter(.tagCategory("people"))
        XCTAssertEqual(ids(library.photos), [a.id, b.id])

        library.removeTag(bob, from: a)
        XCTAssertEqual(ids(library.photos), [b.id])
        XCTAssertNil(library.tagCounts[bob.id])
        XCTAssertEqual(library.categoryCounts, ["people": 1])
    }

    func testSearchFindsTagAddedInMemory() {
        let a = insertPhoto(name: "IMG_1")
        insertPhoto(name: "IMG_2")
        library.loadExistingData()
        library.addTag(name: "Sunset", category: "Time", to: a)

        library.searchText = "sunset"
        library.applyCurrentFilter()
        XCTAssertEqual(ids(library.photos), [a.id])

        library.searchText = "time"
        library.applyCurrentFilter()
        XCTAssertEqual(ids(library.photos), [a.id])
    }

    func testSearchAppliesInBinView() {
        insertPhoto(name: "sunset", isDeleted: true)
        insertPhoto(name: "forest", isDeleted: true)
        library.loadExistingData()
        library.searchText = "sun"

        library.applyFilter(.bin)

        XCTAssertEqual(library.photos.map(\.fileName), ["sunset"])
    }

    func testSearchSuggestions() {
        let a = insertPhoto(name: "a")
        library.loadExistingData()
        library.addTag(name: "Sundown", category: "time", to: a)
        library.addTag(name: "sunrise", category: "time", to: a)
        library.addTag(name: "beach", category: "sunny places", to: a)

        // Matching categories first (in sidebar order), then matching tag names (in `allTags` order).
        library.searchText = "SUN"
        XCTAssertEqual(library.searchSuggestions, ["sunny places", "Sundown", "sunrise"])

        library.searchText = "tim"
        XCTAssertEqual(library.searchSuggestions, ["time"])

        library.searchText = ""
        XCTAssertEqual(library.searchSuggestions, [])
    }

    func testToggleSortOrderReversesInMemory() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 1, creationDate: date(2000))
        let c = insertPhoto(name: "c", rating: 3, creationDate: date(1000))
        library.loadExistingData()

        library.toggleSortOrder()
        XCTAssertEqual(ids(library.photos), [c.id, b.id, a.id])

        library.applyFilter(.rated(3))
        XCTAssertEqual(ids(library.photos), [c.id, a.id])

        library.toggleSortOrder()
        XCTAssertEqual(ids(library.photos), [a.id, c.id])

        // A later full load uses the same order.
        library.toggleSortOrder()
        library.loadExistingData()
        XCTAssertEqual(ids(library.photos), [c.id, a.id])
    }

    func testLoadExistingDataKeepsActiveFiltersAndSearch() {
        insertPhoto(name: "sunset", rating: 3, creationDate: date(3000))
        insertPhoto(name: "forest", rating: 3, creationDate: date(2000))
        insertPhoto(name: "sunrise", rating: 5, creationDate: date(1000))
        library.loadExistingData()
        library.applyFilter(.rated(3))
        library.searchText = "sun"
        library.applyCurrentFilter()

        insertPhoto(name: "sundown", rating: 3, creationDate: date(500))
        library.loadExistingData()

        XCTAssertEqual(library.photos.map(\.fileName), ["sunset", "sundown"])
    }

    func testIndexOfTracksFiltering() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 1, creationDate: date(2000))
        let c = insertPhoto(name: "c", rating: 3, creationDate: date(1000))
        library.loadExistingData()
        XCTAssertEqual(library.index(of: a.id), 0)
        XCTAssertEqual(library.index(of: b.id), 1)
        XCTAssertEqual(library.index(of: c.id), 2)

        library.applyFilter(.rated(3))
        XCTAssertEqual(library.index(of: a.id), 0)
        XCTAssertNil(library.index(of: b.id))
        XCTAssertEqual(library.index(of: c.id), 1)

        library.toggleSortOrder()
        XCTAssertEqual(library.index(of: c.id), 0)
        XCTAssertEqual(library.index(of: a.id), 1)

        library.applyFilter(.all)
        XCTAssertEqual(library.index(of: b.id), 1)
        XCTAssertNil(library.index(of: UUID()))
    }
}
