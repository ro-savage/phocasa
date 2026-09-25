import XCTest
import SwiftData
@testable import Phocasa

/// `LibrarySort` is the only definition of photo order, so its parts must agree with each other: the store's fetch,
/// `precedes`, the insertion index, the merge and the toggle all give the same order, undated photos included.
@MainActor
final class LibrarySortTests: LibraryTestCase {

    /// Photos with distinct dates, one undated, inserted in a scrambled order.
    @discardableResult
    private func seedScrambled() -> [PhotoAsset] {
        var photos: [PhotoAsset] = []
        for seconds in [3000.0, 1000, 5000, 2000, 4000] {
            photos.append(insertPhoto(name: "p\(Int(seconds))", creationDate: date(seconds)))
        }
        let undated = PhotoAsset(fileName: "undated", jpgPath: "/fake/undated.jpg", folderPath: "/fake", creationDate: nil)
        context.insert(undated)
        try? context.save()
        photos.append(undated)
        return photos
    }

    private func fetchLibrary(_ sort: LibrarySort) -> [PhotoAsset] {
        sort.fetch(where: #Predicate { !$0.isDeleted }, in: context)
    }

    func testMissingDateSortsAsOldest() {
        XCTAssertEqual(LibrarySort.key(creationDate: nil), .distantPast)
        XCTAssertTrue(LibrarySort(newestFirst: true).precedes(date(1), LibrarySort.key(creationDate: nil)))
        XCTAssertTrue(LibrarySort(newestFirst: false).precedes(LibrarySort.key(creationDate: nil), date(1)))
    }

    func testFetchOrderAgreesWithPrecedes() {
        seedScrambled()
        for newestFirst in [true, false] {
            let sort = LibrarySort(newestFirst: newestFirst)
            let keys = fetchLibrary(sort).map(LibrarySort.key(of:))
            XCTAssertEqual(keys.count, 6)
            for i in 1..<keys.count {
                XCTAssertTrue(sort.precedes(keys[i - 1], keys[i]), "newestFirst \(newestFirst): \(keys)")
            }
            XCTAssertEqual(newestFirst ? keys.last : keys.first, .distantPast, "the undated photo is the oldest")
        }
    }

    func testInsertionIndexRebuildsTheFetchOrder() {
        let photos = seedScrambled()
        for newestFirst in [true, false] {
            let sort = LibrarySort(newestFirst: newestFirst)
            var list: [PhotoAsset] = []
            for photo in photos {
                list.insert(photo, at: sort.insertionIndex(for: photo, in: list))
            }
            XCTAssertEqual(ids(list), ids(fetchLibrary(sort)), "newestFirst \(newestFirst)")
        }
    }

    func testInsertionIndexGoesAfterEqualKeys() {
        let first = insertPhoto(name: "first", creationDate: date(1000))
        let twin = insertPhoto(name: "twin", creationDate: date(1000))
        let sort = LibrarySort()
        XCTAssertEqual(sort.insertionIndex(for: twin, in: [first]), 1)
    }

    func testMergeMatchesInsertingOneByOne() {
        let photos = seedScrambled()
        let facts = photos.map { PhotoFacts($0) }
        for newestFirst in [true, false] {
            let sort = LibrarySort(newestFirst: newestFirst)
            // Start from three photos in order, then merge the other three in one pass.
            var base: [PhotoAsset] = []
            for photo in photos.prefix(3) { base.insert(photo, at: sort.insertionIndex(for: photo, in: base)) }
            let baseFacts = base.map { photo in facts[photos.firstIndex { $0 === photo }!] }
            let incoming = (3..<6).map { (photo: photos[$0], facts: facts[$0]) }

            let (merged, mergedFacts) = sort.merge(incoming, into: base, baseFacts)

            XCTAssertEqual(ids(merged), ids(fetchLibrary(sort)), "newestFirst \(newestFirst)")
            XCTAssertEqual(mergedFacts.map(\.id), ids(merged), "facts stay next to their photos")
        }
    }

    func testToggleThenReorderGivesTheOtherDirection() {
        seedScrambled()
        var sort = LibrarySort()
        var list = fetchLibrary(sort)
        sort.toggle()
        LibrarySort.reorderAfterToggle(&list)
        XCTAssertFalse(sort.newestFirst)
        XCTAssertEqual(ids(list), ids(fetchLibrary(sort)))
    }
}
