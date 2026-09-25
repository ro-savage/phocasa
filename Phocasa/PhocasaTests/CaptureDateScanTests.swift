import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Shared setup for tests that scan real files into a temp on-disk store.
@MainActor
class CaptureDateStoreTestCase: XCTestCase {
    private var tempDirs: [URL] = []
    private var containers: [ModelContainer] = []

    override func tearDown() async throws {
        containers.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    /// A temp folder, as the canonical path the folder enumerator reports (`/private/var/…`).
    func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-33-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let canonical = try XCTUnwrap(realpath(dir.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    func makeContainer() throws -> ModelContainer {
        let storeDir = try makeTempDir("store")
        let config = ModelConfiguration(url: storeDir.appendingPathComponent("capture.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: config
        )
        containers.append(container)
        return container
    }

    func waitForScan(_ vm: PhotoLibraryViewModel, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while vm.library.isScanning {
            if ContinuousClock.now > deadline { return XCTFail("scan did not finish within \(timeout)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Every stored photo row by file name, read through a separate context.
    func storedPhotos(_ container: ModelContainer) throws -> [String: PhotoAsset] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
        return Dictionary(rows.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func names(_ photos: [PhotoAsset]) -> [String] { photos.map(\.fileName) }

    /// A local capture time (`yyyy:MM:dd HH:mm:ss`) as a date.
    func local(_ exif: String) -> Date { CaptureDate.parse(exif)! }
}

/// Libraries stored before capture dates were read get them after launch (`CaptureDateBackfill`).
@MainActor
final class CaptureDateBackfillTests: CaptureDateStoreTestCase {
    @MainActor final class Log {
        var entries: [String] = []
        var grids: [[String]] = []
    }

    /// Inserts a row as an older version of the app stored it: no capture date, not checked.
    @discardableResult
    func insertOldRow(_ name: String, jpg: URL?, raw: URL? = nil, created: TimeInterval, in context: ModelContext) -> PhotoAsset {
        let photo = PhotoAsset(fileName: name, jpgPath: jpg?.path, rawPath: raw?.path,
                               folderPath: (jpg ?? raw)!.deletingLastPathComponent().path,
                               creationDate: Date(timeIntervalSince1970: created), fileSize: 100)
        context.insert(photo)
        return photo
    }

    /// Four dated JPEGs whose creation dates run the other way, one undated JPEG and one missing file, stored as an
    /// older version left them, in a library rooted at the folder.
    private func makeOldLibrary() throws -> (dir: URL, container: ModelContainer) {
        let dir = try makeTempDir("old")
        let container = try makeContainer()
        let context = container.mainContext
        for (i, name) in ["a", "b", "c", "d"].enumerated() {
            let url = dir.appendingPathComponent("\(name).jpg")
            try CaptureDateFixtures.writeJPEG(at: url, exifDate: "201\(i):06:01 12:00:00")
            insertOldRow(name, jpg: url, created: TimeInterval(4000 - i * 1000), in: context)
        }
        let undated = dir.appendingPathComponent("undated.jpg")
        try CaptureDateFixtures.writeJPEG(at: undated, exifDate: nil)
        insertOldRow("undated", jpg: undated, created: 2_000_000_000, in: context) // 2033: newer than every capture
        insertOldRow("missing", jpg: dir.appendingPathComponent("missing.jpg"), created: 100, in: context)
        context.insert(PhotoLibrary(rootFolderPath: dir.path))
        try context.save()
        return (dir, container)
    }

    func testExistingRowsGetCaptureDatesAfterLaunchAndTheOrderUpdatesOnce() async throws {
        let (_, container) = try makeOldLibrary()
        let vm = PhotoLibraryViewModel()
        XCTAssertEqual(vm.library.captureDates.startDelay, .seconds(2), "the app waits a little after the launch scans")
        vm.library.captureDates.startDelay = .milliseconds(10)
        vm.setModelContext(container.mainContext)
        XCTAssertEqual(names(vm.library.photos), ["undated", "a", "b", "c", "d", "missing"], "creation order at first")
        var versionWhileWriting: Int?
        vm.library.captureDates.didApplyChunk = { [unowned vm] _ in versionWhileWriting = vm.library.libraryVersion }
        try await waitForScan(vm)
        await vm.library.captureDates.task?.value

        XCTAssertEqual(names(vm.library.photos), ["undated", "d", "c", "b", "a"], "capture order, after the launch rescan hid the missing photo")
        XCTAssertEqual(vm.library.libraryVersion, try XCTUnwrap(versionWhileWriting) + 1, "the library is re-ordered once, at the end")
        let report = try XCTUnwrap(vm.library.captureDates.lastReport)
        XCTAssertEqual(report.candidates, 6)
        XCTAssertEqual(report.datesWritten, 4)
        XCTAssertEqual(report.undated, 1)
        XCTAssertEqual(report.unreadable, 1)
        XCTAssertTrue(report.reordered)

        let stored = try storedPhotos(container)
        XCTAssertEqual(stored["a"]?.captureDate, local("2010:06:01 12:00:00"))
        XCTAssertEqual(stored["d"]?.captureDate, local("2013:06:01 12:00:00"))
        XCTAssertNil(stored["undated"]?.captureDate)
        XCTAssertNil(stored["missing"]?.captureDate)

        // The next launch reads only the files still without a date, and writes nothing.
        let next = PhotoLibraryViewModel()
        next.library.captureDates.startDelay = .milliseconds(10)
        next.setModelContext(ModelContext(container))
        try await waitForScan(next)
        await next.library.captureDates.task?.value
        let nextReport = try XCTUnwrap(next.library.captureDates.lastReport)
        XCTAssertEqual(nextReport.candidates, 2, "the undated and the missing file")
        XCTAssertEqual(nextReport.datesWritten, 0)
        XCTAssertTrue(nextReport.chunkMainActorTimes.isEmpty, "nothing to write")
        XCTAssertFalse(nextReport.reordered)
        XCTAssertEqual(names(next.library.photos), ["undated", "d", "c", "b", "a"], "a fresh launch fetches capture order")
    }

    func testALibraryReleasedBeforeTheDelayEndsDoesNoBackfill() async throws {
        let (_, container) = try makeOldLibrary()
        weak var released: LibraryStore?
        do {
            let vm = PhotoLibraryViewModel()
            vm.library.captureDates.startDelay = .milliseconds(50)
            vm.setModelContext(container.mainContext)
            try await waitForScan(vm)
            released = vm.library
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(released, "the waiting backfill doesn't keep the library alive")
        XCTAssertNil(try storedPhotos(container)["a"]?.captureDate, "and doesn't run")
    }

    /// A context doesn't keep its container alive, and reading `modelContext.container` once the container is gone
    /// traps. A library that outlives its container skips the after-launch backfill instead of crashing. (Found when
    /// tasks 32 and 33 merged: test hooks that captured their own view model kept its library alive past tearDown.)
    func testALibraryThatOutlivesItsContainerDoesNoBackfill() async throws {
        let library = LibraryStore()
        library.captureDates.startDelay = .milliseconds(50)
        weak var released: ModelContainer?
        do {
            let container = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                               configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            released = container
            library.open(container.mainContext)
            library.backfillCaptureDatesAfterScans()
        }
        XCTAssertNil(released, "only the library's context is left")
        await library.captureDates.task?.value
        XCTAssertNil(library.captureDates.lastReport, "the backfill gave up without touching the store")
        XCTAssertNil(library.captureDates.task)
    }

    func testRowsWhoseFilesWereEmptyAreNotRead() async throws {
        let dir = try makeTempDir("empty")
        let container = try makeContainer()
        let empty = dir.appendingPathComponent("empty.jpg")
        FileManager.default.createFile(atPath: empty.path, contents: nil)
        insertOldRow("empty", jpg: empty, created: 1, in: container.mainContext).fileSize = 0
        let dated = dir.appendingPathComponent("dated.jpg")
        try CaptureDateFixtures.writeJPEG(at: dated, exifDate: "2001:01:01 01:01:01")
        insertOldRow("dated", jpg: dated, created: 2, in: container.mainContext)
        try container.mainContext.save()
        let library = LibraryStore()
        library.open(container.mainContext)

        let report = await library.backfillCaptureDates()
        XCTAssertEqual(report.candidates, 1, "the empty file (size 0 at the last scan) isn't a candidate")
        XCTAssertEqual(report.datesWritten, 1)
    }

    /// A store with `count` dated JPEGs whose creation order is the reverse of their capture order, opened without a
    /// launch rescan or backfill.
    private func openStore(count: Int, maxChunkRows: Int) throws -> (LibraryStore, ModelContainer) {
        let dir = try makeTempDir("chunks")
        let container = try makeContainer()
        for i in 0..<count {
            let url = dir.appendingPathComponent(String(format: "p%02d.jpg", i))
            try CaptureDateFixtures.writeJPEG(at: url, exifDate: String(format: "2000:01:01 00:00:%02d", i))
            insertOldRow(String(format: "p%02d", i), jpg: url, created: TimeInterval(10_000 - i), in: container.mainContext)
        }
        try container.mainContext.save()
        let library = LibraryStore()
        library.captureDates.maxChunkRows = maxChunkRows
        library.open(container.mainContext)
        return (library, container)
    }

    func testWritesAreChunkedOtherMainActorWorkRunsBetweenThemAndTheOrderChangesOnlyAtTheEnd() async throws {
        let (library, _) = try openStore(count: 10, maxChunkRows: 2)
        let creationOrder = names(library.photos)
        XCTAssertEqual(creationOrder.first, "p00")
        let log = Log()
        library.captureDates.didApplyChunk = { [unowned library] chunk in
            log.entries.append("chunk \(chunk)")
            log.grids.append(self.names(library.photos))
            if chunk == 0 { DispatchQueue.main.async { MainActor.assumeIsolated { log.entries.append("other work") } } }
        }

        let report = await library.backfillCaptureDates()

        XCTAssertEqual(report.chunkMainActorTimes.count, 5, "10 rows, 2 per chunk")
        XCTAssertEqual(log.entries.first, "chunk 0")
        XCTAssertLessThan(try XCTUnwrap(log.entries.firstIndex(of: "other work")),
                          try XCTUnwrap(log.entries.firstIndex(of: "chunk 4")),
                          "main-queue work queued during the backfill runs before it ends: \(log.entries)")
        XCTAssertEqual(log.grids.count, 5)
        XCTAssertTrue(log.grids.allSatisfy { $0 == creationOrder }, "the grid keeps its order until the end")
        XCTAssertEqual(names(library.photos), creationOrder.reversed(), "then shows capture order")
        XCTAssertEqual(report.datesWritten, 10)
    }

    func testChangesMadeDuringTheBackfillAreKept() async throws {
        let (library, container) = try openStore(count: 12, maxChunkRows: 3)
        let rated = try XCTUnwrap(library.photos.first { $0.fileName == "p03" })
        let binned = try XCTUnwrap(library.photos.first { $0.fileName == "p07" })
        library.captureDates.didApplyChunk = { [unowned library] chunk in
            if chunk == 0 { library.setRating(4, for: rated) }
            // After the last write (a later write to a binned row would take it out of the bin in the store until
            // task 31's rename), but before the re-order.
            if chunk == 3 { library.moveToBin([binned]) }
        }
        await library.backfillCaptureDates()

        XCTAssertEqual(try storedPhotos(container)["p03"]?.rating, 4)
        XCTAssertEqual(names(library.binPhotos), ["p07"])
        XCTAssertEqual(names(library.allPhotos), (0..<12).filter { $0 != 7 }.reversed().map { String(format: "p%02d", $0) })
        let fresh = LibraryStore()
        fresh.modelContext = container.mainContext
        fresh.loadExistingData()
        XCTAssertEqual(names(fresh.allPhotos), names(library.allPhotos), "in memory matches a fresh load")
    }

    func testBinnedRowsStayBinnedAcrossTheBackfill() async throws {
        let (library, container) = try openStore(count: 6, maxChunkRows: 64)
        let toBin = library.photos.filter { ["p01", "p04"].contains($0.fileName) }
        library.moveToBin(toBin)
        XCTAssertEqual(names(library.binPhotos), ["p01", "p04"], "creation order before the backfill")

        await library.backfillCaptureDates()
        XCTAssertEqual(names(library.binPhotos), ["p04", "p01"], "the bin is in capture order too")

        // Before task 31's rename, saving a change to a binned row can write its bin flag back as false (spec §H5):
        // a probe lost it when the row was rated, or written directly after `moveToBin`, but not when it was fetched
        // by id first, as each backfill chunk does. So this holds on both sides of the rename.
        let fresh = LibraryStore()
        fresh.modelContext = ModelContext(container)
        fresh.loadExistingData()
        XCTAssertEqual(names(fresh.binPhotos), ["p04", "p01"], "the store still has them in the bin")
    }

    func testAPairWhoseJPGIsGoneIsReadFromItsRAW() async throws {
        let dir = try makeTempDir("pair")
        let container = try makeContainer()
        let raw = dir.appendingPathComponent("pair.dng")
        try CaptureDateFixtures.writeImage(at: raw, type: .tiff, exif: [kCGImagePropertyExifDateTimeOriginal: "2019:09:09 09:09:09"])
        insertOldRow("pair", jpg: dir.appendingPathComponent("pair.jpg"), raw: raw, created: 1, in: container.mainContext)
        try container.mainContext.save()
        let library = LibraryStore()
        library.open(container.mainContext)

        await library.backfillCaptureDates()
        XCTAssertEqual(try storedPhotos(container)["pair"]?.captureDate, local("2019:09:09 09:09:09"))
    }

    func testNothingToDoWritesNothing() async throws {
        let (library, container) = try openStore(count: 3, maxChunkRows: 64)
        await library.backfillCaptureDates()
        let version = library.libraryVersion
        var chunks = 0
        library.captureDates.didApplyChunk = { _ in chunks += 1 }

        let report = await library.backfillCaptureDates()
        XCTAssertEqual(report.candidates, 0)
        XCTAssertEqual(chunks, 0)
        XCTAssertTrue(report.chunkMainActorTimes.isEmpty)
        XCTAssertFalse(report.reordered)
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertEqual(library.libraryVersion, version)
    }
}

/// A scan stores the capture date it reads with each new photo's metadata, at both insert sites.
@MainActor
final class CaptureDateScanTests: CaptureDateStoreTestCase {

    func testScanStoresCaptureDatesAndShowsTheLibraryInCaptureOrder() async throws {
        let dir = try makeTempDir("photos")
        // Written in this order, so creation order is the reverse of capture order (apart from "none").
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("none.jpg"), exifDate: nil)
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("new.jpg"), exifDate: "2020:05:01 10:00:00")
        // With keywords, so it's inserted on the main context; the others go in through a background context.
        MetadataService.shared.writeMetadata(rating: 2, keywords: ["cat:a"], toImageAt: dir.appendingPathComponent("new.jpg").path)
        try CaptureDateFixtures.writeImage(at: dir.appendingPathComponent("raw.dng"), type: .tiff,
                                           exif: [kCGImagePropertyExifDateTimeOriginal: "2017:03:03 03:03:03"])
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("mid.jpg"), exifDate: "2015:05:01 10:00:00",
                                          subseconds: "5", offset: "+02:00")
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("old.jpg"), exifDate: "2010:05:01 10:00:00")

        let container = try makeContainer()
        let context = container.mainContext
        context.insert(PhotoLibrary(rootFolderPath: dir.path))
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        try await waitForScan(vm)

        XCTAssertEqual(names(vm.library.photos), ["none", "new", "raw", "mid", "old"],
                       "capture order; the photo without one sorts by its (recent) creation date")

        let stored = try storedPhotos(container)
        XCTAssertEqual(stored["new"]?.captureDate, local("2020:05:01 10:00:00"))
        XCTAssertEqual(stored["new"]?.tags.map(\.fullName), ["cat:a"], "the main-context insert")
        XCTAssertEqual(stored["raw"]?.captureDate, local("2017:03:03 03:03:03"), "a RAW-only photo reads its RAW")
        XCTAssertNil(stored["raw"]?.jpgPath)
        XCTAssertEqual(try XCTUnwrap(stored["mid"]?.captureDate).timeIntervalSince1970,
                       CaptureDateFixtures.utc(2015, 5, 1, 8, 0, 0).timeIntervalSince1970 + 0.5, accuracy: 1e-6)
        XCTAssertEqual(stored["old"]?.captureDate, local("2010:05:01 10:00:00"))
        XCTAssertNil(stored["none"]?.captureDate)

        vm.library.toggleSortOrder()
        XCTAssertEqual(names(vm.library.photos), ["old", "mid", "raw", "new", "none"])
    }

    func testRescanFindsNewPhotosInCaptureOrderAmongExistingOnes() async throws {
        let dir = try makeTempDir("photos")
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("a.jpg"), exifDate: "2012:01:01 00:00:00")
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("c.jpg"), exifDate: "2014:01:01 00:00:00")
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(PhotoLibrary(rootFolderPath: dir.path))
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        try await waitForScan(vm)
        XCTAssertEqual(names(vm.library.photos), ["c", "a"])

        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("b.jpg"), exifDate: "2013:01:01 00:00:00")
        vm.library.rescanCurrentLibrary()
        try await waitForScan(vm)
        XCTAssertEqual(names(vm.library.photos), ["c", "b", "a"], "the new photo goes by its capture date, not its new file")
    }
}
