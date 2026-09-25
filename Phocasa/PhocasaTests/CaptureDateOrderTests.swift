import XCTest
import SwiftData
@testable import Phocasa

/// The grid is ordered by capture date, falling back to the file creation date, in both directions, including after
/// bin moves and restores (user decision, wave 2 #6). `LibrarySort` is the only definition of that order.
@MainActor
final class CaptureDateOrderTests: LibraryTestCase {

    /// Inserts and saves a photo with a capture date and a file creation date (seconds since 1970; either may be nil).
    @discardableResult
    private func insert(_ name: String, captured: TimeInterval?, created: TimeInterval?) -> PhotoAsset {
        let photo = PhotoAsset(fileName: name, jpgPath: "/fake/\(name).jpg", folderPath: "/fake",
                               creationDate: created.map(date), fileSize: 1000)
        photo.captureDate = captured.map(date)
        photo.captureDateChecked = true
        context.insert(photo)
        try? context.save()
        return photo
    }

    private func names(_ photos: [PhotoAsset]) -> [String] { photos.map(\.fileName) }

    /// A second store loaded fresh from the same context, in `library`'s order: the oracle for in-memory changes.
    private func freshLoad() -> LibraryStore {
        let fresh = LibraryStore()
        fresh.sort = library.sort
        fresh.modelContext = context
        fresh.loadExistingData()
        return fresh
    }

    private func assertMatchesFreshLoad(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let fresh = freshLoad()
        XCTAssertEqual(names(library.allPhotos), names(fresh.allPhotos), "library after \(step)", file: file, line: line)
        XCTAssertEqual(names(library.binPhotos), names(fresh.binPhotos), "bin after \(step)", file: file, line: line)
        XCTAssertEqual(library.allFacts.map(\.id), ids(library.allPhotos), "facts stay aligned after \(step)", file: file, line: line)
        XCTAssertEqual(library.binFacts.map(\.id), ids(library.binPhotos), "bin facts stay aligned after \(step)", file: file, line: line)
    }

    // MARK: - The key

    func testKeyIsTheCaptureDateFallingBackToTheCreationDate() {
        XCTAssertEqual(LibrarySort.key(captureDate: date(10), creationDate: date(20)).date, date(10))
        XCTAssertEqual(LibrarySort.key(captureDate: nil, creationDate: date(20)).date, date(20))
        XCTAssertEqual(LibrarySort.key(captureDate: nil, creationDate: nil).date, .distantPast)
        let photo = insert("p", captured: 10, created: 20)
        XCTAssertEqual(LibrarySort.key(of: photo), date(10))
        photo.captureDate = nil
        XCTAssertEqual(LibrarySort.key(of: photo), date(20))
    }

    // MARK: - Fetch order

    func testPhotosAreShownInCaptureOrderNotCreationOrder() {
        insert("a", captured: 1000, created: 4000)
        insert("b", captured: 2000, created: 3000)
        insert("c", captured: 3000, created: 2000)
        insert("d", captured: 4000, created: 1000)
        library.loadExistingData()
        XCTAssertEqual(names(library.photos), ["d", "c", "b", "a"], "newest capture first")

        library.toggleSortOrder()
        XCTAssertEqual(names(library.photos), ["a", "b", "c", "d"], "toggling reverses")
        library.loadExistingData()
        XCTAssertEqual(names(library.photos), ["a", "b", "c", "d"], "a fresh fetch agrees with the toggle")
    }

    func testPhotosWithoutACaptureDateFallBackToTheirCreationDate() {
        insert("x", captured: 2500, created: 100)
        insert("u1", captured: nil, created: 3500)
        insert("u2", captured: nil, created: 1500)
        insert("y", captured: 500, created: 5000)
        insert("n", captured: nil, created: nil)
        library.loadExistingData()
        XCTAssertEqual(names(library.photos), ["u1", "x", "u2", "y", "n"], "undated photos sort by creation date, nil oldest")

        library.toggleSortOrder()
        XCTAssertEqual(names(library.photos), ["n", "y", "u2", "x", "u1"])
        library.loadExistingData()
        XCTAssertEqual(names(library.photos), ["n", "y", "u2", "x", "u1"])
    }

    func testBurstShotsWithOneCaptureSecondAreOrderedByCreationDate() {
        insert("b1", captured: 1000, created: 10)
        insert("b2", captured: 1000, created: 20)
        insert("b3", captured: 1000, created: 30)
        insert("later", captured: 2000, created: 5)
        insert("undated", captured: nil, created: 1000) // same key as the burst: its creation date breaks the tie
        library.loadExistingData()
        XCTAssertEqual(names(library.photos), ["later", "undated", "b3", "b2", "b1"])
        library.toggleSortOrder()
        XCTAssertEqual(names(library.photos), ["b1", "b2", "b3", "undated", "later"])
    }

    /// The fetch, `insertionIndex` and `merge` agree on one order, with dated, undated and tied photos, both ways.
    func testFetchInsertionAndMergeAgreeWithMixedDates() {
        var photos: [PhotoAsset] = []
        let seeds: [(TimeInterval?, TimeInterval?)] = [
            (3000, 10), (nil, 3500), (1000, 20), (nil, 500), (3000, 40), (2000, nil), (nil, nil), (5000, 1), (nil, 2500),
        ]
        for (i, seed) in seeds.enumerated() { photos.append(insert("p\(i)", captured: seed.0, created: seed.1)) }
        let facts = photos.map { PhotoFacts($0) }
        for newestFirst in [true, false] {
            let sort = LibrarySort(newestFirst: newestFirst)
            let fetched = sort.fetch(where: #Predicate<PhotoAsset> { _ in true }, in: context)
            let keys = fetched.map(LibrarySort.sortKey(of:))
            for i in 1..<keys.count {
                XCTAssertTrue(sort.precedes(keys[i - 1], keys[i]), "newestFirst \(newestFirst): \(names(fetched))")
            }

            var inserted: [PhotoAsset] = []
            for photo in photos { inserted.insert(photo, at: sort.insertionIndex(for: photo, in: inserted)) }
            XCTAssertEqual(names(inserted), names(fetched), "insertion, newestFirst \(newestFirst)")

            var base: [PhotoAsset] = []
            for photo in photos.prefix(4) { base.insert(photo, at: sort.insertionIndex(for: photo, in: base)) }
            let baseFacts = base.map { photo in facts[photos.firstIndex { $0 === photo }!] }
            let incoming = (4..<photos.count).map { (photo: photos[$0], facts: facts[$0]) }
            let (merged, mergedFacts) = sort.merge(incoming, into: base, baseFacts)
            XCTAssertEqual(names(merged), names(fetched), "merge, newestFirst \(newestFirst)")
            XCTAssertEqual(mergedFacts.map(\.id), ids(merged))
        }
    }

    /// Each fetch result is in order however the dated and undated photos interleave.
    func testFetchInterleavesLongRunsOfDatedAndUndatedPhotos() {
        // 60 dated and 40 undated photos, keys spread over the same range.
        for i in 0..<100 {
            let key = TimeInterval((i * 37) % 100) * 100
            if i % 5 < 3 {
                insert("d\(i)", captured: key, created: 50_000 - key)
            } else {
                insert("u\(i)", captured: nil, created: key + 50)
            }
        }
        for newestFirst in [true, false] {
            let sort = LibrarySort(newestFirst: newestFirst)
            let keys = sort.fetch(where: #Predicate<PhotoAsset> { _ in true }, in: context).map(LibrarySort.sortKey(of:))
            XCTAssertEqual(keys.count, 100)
            for i in 1..<keys.count {
                XCTAssertTrue(sort.precedes(keys[i - 1], keys[i]), "newestFirst \(newestFirst) at \(i)")
            }
        }
    }

    /// A few undated photos among many dated ones (a library after the backfill), and a few dated photos among many
    /// undated ones (during it): the small run is merged in by binary search, in both directions.
    func testFetchMergesASmallRunIntoALargeOne() {
        for (label, datedCount) in [("few undated", 47), ("few dated", 3)] {
            for photo in (try? context.fetch(FetchDescriptor<PhotoAsset>())) ?? [] { context.delete(photo) }
            try? context.save()
            var photos: [PhotoAsset] = []
            for i in 0..<50 {
                let key = TimeInterval((i * 29) % 50) * 100 + 7
                photos.append(i < datedCount
                    ? insert("d\(i)", captured: key, created: 90_000 - key)
                    : insert("u\(i)", captured: nil, created: key + 50))
            }
            for newestFirst in [true, false] {
                let sort = LibrarySort(newestFirst: newestFirst)
                let fetched = sort.fetch(where: #Predicate<PhotoAsset> { _ in true }, in: context)
                var inserted: [PhotoAsset] = []
                for photo in photos { inserted.insert(photo, at: sort.insertionIndex(for: photo, in: inserted)) }
                XCTAssertEqual(names(fetched), names(inserted), "\(label), newestFirst \(newestFirst)")
            }
        }
    }

    // MARK: - Bin

    func testMovingToTheBinAndRestoringKeepCaptureOrder() {
        insert("a", captured: 1000, created: 4000)
        let b = insert("b", captured: 2000, created: 3000)
        insert("c", captured: 3000, created: 2000)
        let d = insert("d", captured: 4000, created: 1000)
        insert("e", captured: nil, created: 2500)
        library.loadExistingData()
        XCTAssertEqual(names(library.photos), ["d", "c", "e", "b", "a"])

        library.moveToBin([b, d])
        XCTAssertEqual(names(library.photos), ["c", "e", "a"])
        XCTAssertEqual(names(library.binPhotos), ["d", "b"], "the bin is in capture order too")
        assertMatchesFreshLoad("moving to the bin")

        library.restoreFromBin([b])
        XCTAssertEqual(names(library.photos), ["c", "e", "b", "a"])
        library.restoreFromBin([d])
        XCTAssertEqual(names(library.photos), ["d", "c", "e", "b", "a"])
        assertMatchesFreshLoad("restoring")
    }

    func testBurstShotRestoredFromTheBinGoesBackToItsPlace() {
        insert("b1", captured: 1000, created: 10)
        let b2 = insert("b2", captured: 1000, created: 20)
        insert("b3", captured: 1000, created: 30)
        library.loadExistingData()
        library.moveToBin([b2])
        library.restoreFromBin([b2])
        XCTAssertEqual(names(library.photos), ["b3", "b2", "b1"], "not after the other frames of its burst")
        assertMatchesFreshLoad("restoring a burst frame")
    }

    func testManyPhotosMovedAndRestoredTogetherKeepCaptureOrder() {
        var photos: [PhotoAsset] = []
        for i in 0..<30 {
            let captured: TimeInterval? = i % 4 == 0 ? nil : TimeInterval((i * 7) % 30) * 100
            photos.append(insert("p\(i)", captured: captured, created: TimeInterval(3000 - i * 10)))
        }
        library.loadExistingData()
        let moving = stride(from: 0, to: 30, by: 2).map { photos[$0] } // more than `patchLimit`: merged
        library.moveToBin(moving)
        assertMatchesFreshLoad("moving 15 photos to the bin")
        library.toggleSortOrder()
        assertMatchesFreshLoad("toggling with a full bin")
        library.restoreFromBin(moving)
        assertMatchesFreshLoad("restoring 15 photos")
    }

    /// Task 10's oracle, with capture dates: random bin moves, restores, toggles and ratings keep the in-memory library
    /// equal to a fresh load.
    func testRandomisedInteractionsKeepCaptureOrder() {
        var rng = SystemRandomNumberGenerator()
        var photos: [PhotoAsset] = []
        for i in 0..<40 {
            let captured: TimeInterval? = i % 3 == 0 ? nil : TimeInterval(Int.random(in: 0..<15, using: &rng)) * 100
            photos.append(insert("p\(i)", captured: captured, created: TimeInterval(10_000 - i * 37)))
        }
        library.loadExistingData()
        for step in 0..<60 {
            let inLibrary = library.allPhotos
            let inBin = library.binPhotos
            switch Int.random(in: 0..<5, using: &rng) {
            case 0 where !inLibrary.isEmpty:
                library.moveToBin([inLibrary.randomElement(using: &rng)!])
            case 1 where inLibrary.count > 10:
                library.moveToBin(Array(inLibrary.shuffled(using: &rng).prefix(10)))
            case 2 where !inBin.isEmpty:
                library.restoreFromBin(Array(inBin.shuffled(using: &rng).prefix(Int.random(in: 1...10, using: &rng))))
            case 3:
                library.toggleSortOrder()
            default:
                // Rate only library photos: saving a change to a binned row takes it out of the bin in the store until
                // task 31's rename (spec §H5), which would make the fresh load differ for another reason.
                if let photo = inLibrary.randomElement(using: &rng) {
                    library.setRating(Int.random(in: 0...5, using: &rng), for: photo)
                }
            }
            assertMatchesFreshLoad("step \(step)")
        }
    }
}
