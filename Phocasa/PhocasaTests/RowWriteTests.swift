import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// The library's write queue (`LibraryStore+RowWrites`): changes show in memory at once and reach the store in chunks
/// sized by time; a second change during the chunks wins; quitting writes what's left; tag links change on the tag's
/// side and are what the store holds after a relaunch. On temp on-disk stores, with the queue made to write a few rows
/// per chunk so a small library takes several.
@MainActor
final class RowWriteTests: XCTestCase {
    private var tempDirs: [URL] = []
    private var containers: [ModelContainer] = []

    override func tearDown() async throws {
        containers.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    // MARK: - Helpers

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-rel3-rowwrites-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let canonical = try XCTUnwrap(realpath(dir.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    /// A container on the store at `storeURL`; a second one on the same file is what the app sees after a relaunch.
    private func makeContainer(_ storeURL: URL) throws -> ModelContainer {
        let container = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                           configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
        containers.append(container)
        return container
    }

    /// `count` photos (fake paths, no files) in a new temp store, loaded by a view model whose queue writes at most
    /// `chunk` rows at a time and writes at once only actions on at most `immediate` photos.
    private func makeLibrary(count: Int, chunk: Int = 7, immediate: Int = 4) throws
        -> (vm: PhotoLibraryViewModel, container: ModelContainer, storeURL: URL, photos: [PhotoAsset])
    {
        let storeURL = try makeTempDir("store").appendingPathComponent("rows.store")
        let container = try makeContainer(storeURL)
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<count {
            let photo = PhotoAsset(fileName: "p\(i)", jpgPath: "/fake/rows/p\(i).jpg", folderPath: "/fake/rows",
                                   creationDate: base.addingTimeInterval(Double(-i)), fileSize: 100)
            photo.rating = i % 3
            context.insert(photo)
        }
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.library.rowWrites.sizer.maximumRows = chunk
        vm.library.rowWrites.immediateLimit = immediate
        vm.library.rowWrites.pausesBetweenChunks = false
        vm.setModelContext(context)
        vm.loadExistingData()
        return (vm, container, storeURL, vm.library.allPhotos)
    }

    /// The rows as stored, through a context of their own.
    private func storedRatings(_ container: ModelContainer) throws -> [String: Int] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, $0.rating) })
    }

    private func storedTagNames(_ container: ModelContainer) throws -> [String: Set<String>] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, Set($0.tags.map(\.fullName))) })
    }

    /// A small real JPEG.
    private func makeJPEG(_ url: URL) throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: - Big changes: at once in memory, in chunks in the store

    func testABigRatingShowsAtOnceAndIsWrittenInChunks() async throws {
        let (vm, container, _, photos) = try makeLibrary(count: 60)
        var saves: [Int] = []
        vm.library.rowWrites.didWriteRows = { saves.append($0) }

        vm.selection.selectAll()
        vm.setRatingForSelection(5)

        XCTAssertEqual(vm.library.ratingCounts[5], 60, "the counts change at once")
        XCTAssertTrue(photos.allSatisfy { vm.library.rating(of: $0) == 5 }, "and what the cells show")
        XCTAssertEqual(try storedRatings(container).values.filter { $0 == 5 }.count, 0, "the store gets it in chunks")
        XCTAssertTrue(vm.library.hasPendingRowWrites)

        await vm.library.waitForRowWrites()

        XCTAssertEqual(Set(try storedRatings(container).values), [5])
        XCTAssertFalse(vm.library.hasPendingRowWrites)
        XCTAssertGreaterThan(saves.count, 5, "several chunks")
        XCTAssertTrue(saves.allSatisfy { $0 <= 7 }, "none bigger than a chunk: \(saves)")
        XCTAssertEqual(saves.reduce(0, +), 60)
        XCTAssertTrue(photos.allSatisfy { $0.rating == 5 })
    }

    func testASmallActionIsWrittenInTheTurnItIsMade() throws {
        let (vm, container, _, photos) = try makeLibrary(count: 20)
        vm.library.setRating(4, for: Array(photos.prefix(3)))
        XCTAssertFalse(vm.library.hasPendingRowWrites)
        let stored = try storedRatings(container)
        XCTAssertEqual(stored["p0"], 4)
        XCTAssertEqual(stored["p2"], 4)
    }

    /// A photo changed again while the first change is still being written keeps the newer value, in memory and in
    /// the store; so does one changed by a small action that's written at once.
    func testAChangeDuringTheChunksWins() async throws {
        let (vm, container, _, photos) = try makeLibrary(count: 60)
        vm.selection.selectAll()
        vm.setRatingForSelection(5)
        vm.library.setRating(1, for: photos[40])        // small: written now, ahead of the queue
        vm.library.setRating(2, for: Array(photos[10..<30])) // big: merges into the queue
        vm.library.addTag(name: "late", category: "t", to: Array(photos[20..<50]))
        vm.library.removeTag(try XCTUnwrap(vm.library.allTags.first), from: Array(photos[45..<50]))

        XCTAssertEqual(try storedRatings(container)["p40"], 1, "the small action is in the store already")
        await vm.library.waitForRowWrites()

        let stored = try storedRatings(container)
        for (i, photo) in photos.enumerated() {
            let expected = i == 40 ? 1 : (10..<30).contains(i) ? 2 : 5
            XCTAssertEqual(stored[photo.fileName], expected, photo.fileName)
            XCTAssertEqual(vm.library.rating(of: photo), expected)
        }
        let tags = try storedTagNames(container)
        for (i, photo) in photos.enumerated() {
            XCTAssertEqual(tags[photo.fileName], (20..<45).contains(i) ? ["t:late"] : [], photo.fileName)
        }
        XCTAssertEqual(vm.library.tagCounts[try XCTUnwrap(vm.library.allTags.first).id], 25)
    }

    /// Quitting writes what the queue still holds, in one go, so the store has every change before quit waits for the
    /// files' writes.
    func testQuittingWritesWhatIsStillQueued() throws {
        let (vm, container, _, _) = try makeLibrary(count: 50)
        vm.selection.selectAll()
        vm.setRatingForSelection(3)
        vm.addTagToSelection(name: "quit", category: "")
        XCTAssertTrue(vm.library.hasPendingRowWrites)

        PhotoLibraryViewModel.writePendingChangesBeforeQuit()

        XCTAssertFalse(vm.library.hasPendingRowWrites)
        XCTAssertEqual(Set(try storedRatings(container).values), [3])
        XCTAssertEqual(Set(try storedTagNames(container).values), [["quit"]])
    }

    /// A full load reads the store: it writes the queue first, so it loads the library as shown.
    func testAFullLoadWritesTheQueueFirst() throws {
        let (vm, container, _, _) = try makeLibrary(count: 40)
        vm.selection.selectAll()
        vm.setRatingForSelection(4)
        vm.loadExistingData()
        XCTAssertEqual(vm.library.ratingCounts[4], 40)
        XCTAssertEqual(Set(try storedRatings(container).values), [4])
    }

    /// A photo's files get its rating and keywords when its row is written, as the row holds them: a small action on a
    /// photo whose big change is still queued writes both values into its file, and the queue's later chunk doesn't
    /// write it back.
    func testFilesGetTheValuesTheRowHolds() async throws {
        let (vm, container, _, photos) = try makeLibrary(count: 40)
        let dir = try makeTempDir("files")
        let file = dir.appendingPathComponent("real.jpg")
        try makeJPEG(file)
        let photo = photos[30]
        photo.jpgPath = file.path
        try container.mainContext.save()

        vm.selection.selectAll()
        vm.setRatingForSelection(4)                                 // queued
        vm.library.addTag(name: "sea", category: "places", to: photo) // written now, with the queued rating
        XCTAssertEqual(try storedRatings(container)["p30"], 4)
        await MetadataWriter.shared.flush()
        var read = MetadataService.shared.readMetadata(from: file.path)
        XCTAssertEqual(read.rating, 4)
        XCTAssertEqual(read.keywords, ["places:sea"])

        await vm.library.waitForRowWrites()
        await MetadataWriter.shared.flush()
        read = MetadataService.shared.readMetadata(from: file.path)
        XCTAssertEqual(read.rating, 4)
        XCTAssertEqual(read.keywords, ["places:sea"], "the queue's own write of the photo didn't drop the tag")
    }

    /// The detail view reads the model: opening it on a photo whose change is queued writes that photo first.
    func testOpeningTheDetailViewWritesThePhotosQueuedChange() throws {
        let (vm, container, _, photos) = try makeLibrary(count: 40)
        vm.selection.selectAll()
        vm.setRatingForSelection(2)
        XCTAssertNotEqual(try storedRatings(container)["p33"], 2)
        vm.openDetail(for: photos[33])
        XCTAssertEqual(photos[33].rating, 2)
        XCTAssertEqual(try storedRatings(container)["p33"], 2)
    }

    // MARK: - Tag links on the tag's side

    /// Tagging and untagging many photos changes the tag's side once per chunk: the links the store holds after a
    /// relaunch are exactly those the library showed, from both sides.
    func testTagLinksAreWhatTheStoreHoldsAfterARelaunch() async throws {
        var (vm, container, storeURL, photos) = try makeLibrary(count: 80)
        vm.selection.selectedPhotos = Set(photos[0..<60].map(\.id))
        vm.addTagToSelection(name: "alice", category: "people")
        vm.library.addTag(name: "bob", category: "people", to: Array(photos[50..<80]))
        let alice = try XCTUnwrap(vm.library.allTags.first { $0.name == "alice" })
        vm.library.removeTag(alice, from: Array(photos[10..<25]))
        vm.library.addTag(name: "alice", category: "people", to: [photos[12], photos[70]])
        vm.library.addTag(name: "solo", category: "", to: [photos[3]])
        await vm.library.waitForRowWrites()

        var expected: [String: Set<String>] = [:]
        for (i, photo) in photos.enumerated() {
            var tags = Set<String>()
            if (0..<60).contains(i) && !(10..<25).contains(i) || i == 12 || i == 70 { tags.insert("people:alice") }
            if (50..<80).contains(i) { tags.insert("people:bob") }
            if i == 3 { tags.insert("solo") }
            expected[photo.fileName] = tags
            XCTAssertEqual(Set(vm.library.tags(of: photo).map(\.fullName)), tags, "in memory: \(photo.fileName)")
        }
        let aliceCount = expected.values.filter { $0.contains("people:alice") }.count
        XCTAssertEqual(vm.library.tagCounts[alice.id], aliceCount)

        // Relaunch: a new container on the same file.
        let names = photos.map(\.fileName)
        vm = PhotoLibraryViewModel()
        photos = []
        containers.removeAll()
        container = try makeContainer(storeURL)
        let fresh = ModelContext(container)
        let rows = try fresh.fetch(FetchDescriptor<PhotoAsset>())
        XCTAssertEqual(Set(rows.map(\.fileName)), Set(names))
        for row in rows {
            XCTAssertEqual(Set(row.tags.map(\.fullName)), expected[row.fileName], "photo side: \(row.fileName)")
        }
        let tags = try fresh.fetch(FetchDescriptor<Tag>())
        for tag in tags {
            let holders = Set(expected.filter { $0.value.contains(tag.fullName) }.keys)
            XCTAssertEqual(Set(tag.photos.map(\.fileName)), holders, "tag side: \(tag.fullName)")
        }
        XCTAssertEqual(Set(tags.map(\.fullName)), ["people:alice", "people:bob", "solo"])
    }

    /// Emptying a bin of tagged photos deletes their rows (and their links) in chunks; the library changes at once.
    func testEmptyingABigBinDeletesTheRowsAndTheirLinks() async throws {
        let (vm, container, _, photos) = try makeLibrary(count: 50)
        let trash = try makeTempDir("trash")
        vm.library.fileTrasher = FileTrasher { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
        vm.library.addTag(name: "gone", category: "t", to: Array(photos[0..<40]))
        await vm.library.waitForRowWrites()
        vm.selection.selectedPhotos = Set(photos[0..<45].map(\.id))
        vm.deleteSelected() // to the bin
        vm.library.applyFilter(.bin)
        vm.selection.selectAll()
        vm.deleteSelected() // asks
        XCTAssertEqual(vm.photosToDelete.count, 45)

        await vm.confirmPermanentDelete()?.value
        XCTAssertEqual(vm.library.binCount, 0, "the library changes at once")
        await vm.library.waitForRowWrites()

        let rows = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
        XCTAssertEqual(Set(rows.map(\.fileName)), Set(photos[45...].map(\.fileName)))
        let tag = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Tag>()).first)
        XCTAssertEqual(tag.photos.count, 0, "no link to a deleted row")
    }

    // MARK: - The chunk sizer

    /// The sizer against the costs measured at scale (`ScaleChecks.testTagCostAtLibraryScale`): a chunk takes
    /// `fixed + perRow × rows`. Its chunks settle near their target whatever the true per-row cost, follow a fixed part
    /// that grows as the chunks go (a tag that grows as it's written), and a chunk slowed by something else (a WAL
    /// checkpoint) doesn't shrink the ones after it to nothing (the first version's estimate made 3,755 chunks of a
    /// 150,000-photo tag, 52 minutes).
    func testTheSizerSettlesNearItsTargetAndShrugsOffASlowChunk() {
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        func cost(_ rows: Int, fixed: Double, perRow: Double) -> Duration {
            .microseconds(Int((fixed + perRow * Double(rows)) * 1000))
        }
        /// The sizer's chunk times over `chunks` chunks, with the fixed part growing by `growth` ms a row written.
        func run(_ sizer: inout WriteChunkSizer, chunks: Int, fixed: Double, perRow: Double,
                 growth: Double = 0) -> [Double] {
            var fixed = fixed
            var times: [Double] = []
            for _ in 0..<chunks {
                let rows = sizer.rows
                let took = cost(rows, fixed: fixed, perRow: perRow)
                sizer.record(rows: rows, took: took)
                times.append(ms(took))
                fixed += growth * Double(rows)
            }
            return times
        }
        // 150,000 photos loaded, ratings: 140 ms fixed, 0.1–0.25 ms a row.
        for perRow in [0.1, 0.25] {
            var sizer = WriteChunkSizer()
            XCTAssertEqual(sizer.rows, WriteChunkSizer.firstRows)
            let times = run(&sizer, chunks: 30, fixed: 140, perRow: perRow)
            XCTAssertTrue(times.allSatisfy { $0 < 260 }, "\(perRow) ms a row: no chunk runs long: \(times)")
            XCTAssertGreaterThan(times.last ?? 0, 160, "chunks of several hundred rows, not a few")
            XCTAssertGreaterThan(sizer.rows, 250)
        }
        // 10,000 loaded: 10 ms fixed, 0.15 ms a row: ~50 ms chunks.
        var small = WriteChunkSizer()
        let smallTimes = run(&small, chunks: 30, fixed: 10, perRow: 0.15)
        XCTAssertEqual(smallTimes.last ?? 0, 50, accuracy: 10)
        // A tag growing to 150,000 photos as it's written: 4 µs of fixed cost for each photo linked. Chunks follow the
        // growing fixed part, with a third of each for rows, so the whole tag takes tens of chunks, not thousands.
        var tag = WriteChunkSizer()
        var fixed = 140.0
        var written = 0
        var chunks = 0
        while written < 150_000 {
            let rows = min(tag.rows, 150_000 - written)
            tag.record(rows: rows, took: cost(rows, fixed: fixed, perRow: 0.17))
            written += rows
            fixed += 0.004 * Double(rows)
            chunks += 1
        }
        XCTAssertLessThan(chunks, 200, "\(chunks) chunks")
        XCTAssertLessThan(ms(tag.target), 1_200, "at most half as long again as the fixed part (740 ms at the end)")
        // One chunk slowed by 300 ms: the next ones keep their size (within a factor of two).
        var noisy = WriteChunkSizer()
        _ = run(&noisy, chunks: 20, fixed: 140, perRow: 0.1)
        let steady = noisy.rows
        noisy.record(rows: steady, took: cost(steady, fixed: 440, perRow: 0.1))
        _ = run(&noisy, chunks: 1, fixed: 140, perRow: 0.1)
        XCTAssertGreaterThan(noisy.rows, steady / 2)
        XCTAssertGreaterThanOrEqual(ms(noisy.perRow), 0.1, "rows never look cheaper than 0.1 ms")
        // A new batch starts small again, and chunks at most double.
        noisy.startBatch()
        XCTAssertEqual(noisy.rows, WriteChunkSizer.firstRows)
        noisy.record(rows: noisy.rows, took: cost(noisy.rows, fixed: 140, perRow: 0.1))
        XCTAssertEqual(noisy.rows, 2 * WriteChunkSizer.firstRows)
    }
}
