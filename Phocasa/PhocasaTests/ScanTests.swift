import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Scans driven through the view model, against a temp folder and a temp on-disk store (spec §B1–§B3).
@MainActor
final class ScanTests: XCTestCase {
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
            .appendingPathComponent("phocasa-20-scantests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        // The canonical path (`/private/var/…`), which is what the folder enumerator reports.
        // (`resolvingSymlinksInPath()` would strip `/private`.)
        let canonical = try XCTUnwrap(realpath(dir.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    private func makeContainer() throws -> ModelContainer {
        try makeContainer(storeURL: try makeTempDir("store").appendingPathComponent("scan.store"))
    }

    /// A container on the store at `storeURL`. A second one on the same file is what the app sees after a relaunch.
    private func makeContainer(storeURL: URL) throws -> ModelContainer {
        let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: config
        )
        containers.append(container)
        return container
    }

    /// A small real JPEG, optionally with a rating and keywords written by the app's own write path.
    @discardableResult
    private func makeJPEG(_ name: String, in dir: URL, rating: Int? = nil, keywords: [String] = []) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        if rating != nil || !keywords.isEmpty {
            MetadataService.shared.writeMetadata(rating: rating ?? 0, keywords: keywords, toImageAt: url.path)
        }
        return url
    }

    /// A library rooted at `photosDir` in a fresh on-disk store, opened like the app does at launch
    /// (`setModelContext`, which starts a rescan). Waits for that scan.
    private func openLibrary(at photosDir: URL, seed: (ModelContext) throws -> Void = { _ in })
        async throws -> (PhotoLibraryViewModel, ModelContext, ModelContainer)
    {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(PhotoLibrary(rootFolderPath: photosDir.path))
        try seed(context)
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        try await waitForScan(vm)
        return (vm, context, container)
    }

    private func waitForScan(_ vm: PhotoLibraryViewModel, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while vm.library.isScanning {
            if ContinuousClock.now > deadline {
                XCTFail("scan did not finish within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func rescan(_ vm: PhotoLibraryViewModel) async throws {
        vm.library.rescanCurrentLibrary()
        XCTAssertTrue(vm.library.isScanning, "rescanCurrentLibrary() must set isScanning before it returns")
        try await waitForScan(vm)
    }

    /// Every stored photo row, read through a separate context so nothing cached in the view model's
    /// context can hide a duplicate.
    private func storedPhotos(_ container: ModelContainer) throws -> [PhotoAsset] {
        try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
    }

    private func storedTags(_ container: ModelContainer) throws -> [Tag] {
        try ModelContext(container).fetch(FetchDescriptor<Tag>())
    }

    /// File names of the photos in the bin, as the store has them (a predicate, not the model property; see
    /// `StoredPhoto.fetchAllNow`).
    private func storedBinNames(_ container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.isDeleted }))
            .map(\.fileName).sorted()
    }

    /// Sets the file's creation date (the photo order's key), so new photos land among the existing ones.
    private func setCreated(_ url: URL, _ secondsSince1970: TimeInterval) throws {
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: secondsSince1970)],
                                              ofItemAtPath: url.path)
    }

    /// The library's in-memory state must equal what a full `loadExistingData()` of the same store gives, with the
    /// same filters, search, sort and missing set (task 10's oracle, plus the facts and the bin).
    private func assertMatchesFreshLoad(_ vm: PhotoLibraryViewModel, _ step: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let library = vm.library
        let oracle = LibraryStore()
        oracle.modelContext = library.modelContext
        oracle.sort = library.sort
        oracle.activeFilters = library.activeFilters
        oracle.viewingBin = library.viewingBin
        oracle.searchText = library.searchText
        oracle.missingPhotoIDs = library.missingPhotoIDs
        oracle.loadExistingData()
        func ids(_ photos: [PhotoAsset]) -> [UUID] { photos.map(\.id) }
        // A photo's `tags` have no stable order, so neither do the tag lines of its search key (search matches line by
        // line, so that order never matters): compare the key's lines as a set.
        func comparable(_ facts: [PhotoFacts]) -> [PhotoFacts] {
            facts.map { f in
                var lines = f.searchKey.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let name = lines.removeFirst()
                var copy = f
                copy.searchKey = ([name] + lines.sorted()).joined(separator: "\n")
                return copy
            }
        }
        XCTAssertEqual(ids(library.photos), ids(oracle.photos), "photos after \(step)", file: file, line: line)
        XCTAssertEqual(ids(library.allPhotos), ids(oracle.allPhotos), "allPhotos after \(step)", file: file, line: line)
        XCTAssertEqual(ids(library.binPhotos), ids(oracle.binPhotos), "binPhotos after \(step)", file: file, line: line)
        XCTAssertEqual(comparable(library.allFacts), comparable(oracle.allFacts), "allFacts after \(step)",
                       file: file, line: line)
        XCTAssertEqual(comparable(library.binFacts), comparable(oracle.binFacts), "binFacts after \(step)",
                       file: file, line: line)
        XCTAssertEqual(library.shownIDs, ids(library.photos), "shownIDs after \(step)", file: file, line: line)
        XCTAssertEqual(library.binCount, oracle.binCount, "binCount after \(step)", file: file, line: line)
        XCTAssertEqual(library.ratingCounts, oracle.ratingCounts, "ratingCounts after \(step)", file: file, line: line)
        XCTAssertEqual(library.tagCounts, oracle.tagCounts, "tagCounts after \(step)", file: file, line: line)
        XCTAssertEqual(library.categoryCounts, oracle.categoryCounts, "categoryCounts after \(step)", file: file, line: line)
        XCTAssertEqual(library.jpgCount, oracle.jpgCount, "jpgCount after \(step)", file: file, line: line)
        XCTAssertEqual(library.rawCount, oracle.rawCount, "rawCount after \(step)", file: file, line: line)
        XCTAssertEqual(library.libraryCounts, oracle.libraryCounts, "libraryCounts after \(step)", file: file, line: line)
        XCTAssertEqual(library.allTags.map(\.id), oracle.allTags.map(\.id), "allTags after \(step)", file: file, line: line)
        XCTAssertEqual(library.tagCategories, oracle.tagCategories, "tagCategories after \(step)", file: file, line: line)
        XCTAssertEqual(library.uncategorizedTags.map(\.id), oracle.uncategorizedTags.map(\.id),
                       "uncategorizedTags after \(step)", file: file, line: line)
        XCTAssertEqual(library.tagsByCategory.mapValues { $0.map(\.id) }, oracle.tagsByCategory.mapValues { $0.map(\.id) },
                       "tagsByCategory after \(step)", file: file, line: line)
        XCTAssertEqual(library.photos.indices.map { library.index(of: library.photos[$0].id) },
                       library.photos.indices.map { $0 }, "index(of:) after \(step)", file: file, line: line)
        XCTAssertEqual(library.currentLibrary?.id, oracle.currentLibrary?.id, "currentLibrary after \(step)",
                       file: file, line: line)
    }

    // MARK: - Import

    func testScanImportsRatingsAndKeywords() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("tagged.jpg", in: photos, rating: 3, keywords: ["cat:a", "b"])
        try makeJPEG("plain.jpg", in: photos)

        let (vm, _, container) = try await openLibrary(at: photos)

        XCTAssertEqual(vm.library.allPhotos.count, 2)
        let tagged = try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "tagged" })
        XCTAssertEqual(tagged.rating, 3)
        XCTAssertEqual(Set(tagged.tags.map(\.fullName)), ["cat:a", "b"])
        let plain = try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "plain" })
        XCTAssertEqual(plain.rating, 0)
        XCTAssertTrue(plain.tags.isEmpty)
        XCTAssertEqual(Set(try storedTags(container).map(\.fullName)), ["cat:a", "b"])
        XCTAssertEqual(vm.library.scanProgress, "Found 2 photos (2 new)")
    }

    func testNewPhotosReuseExistingTagsAndCreateEachNewTagOnce() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("one.jpg", in: photos, keywords: ["cat:a", "new:x"])
        try makeJPEG("two.jpg", in: photos, keywords: ["new:x", "cat:a", "cat:a"])
        var existing: Tag!

        let (vm, _, container) = try await openLibrary(at: photos) { context in
            existing = Tag(name: "a", category: "cat")
            context.insert(existing)
        }

        let tags = try storedTags(container)
        XCTAssertEqual(tags.map(\.fullName).sorted(), ["cat:a", "new:x"])
        XCTAssertEqual(tags.first { $0.fullName == "cat:a" }?.id, existing.id)
        for photo in vm.library.allPhotos {
            XCTAssertEqual(photo.tags.map(\.fullName).sorted(), ["cat:a", "new:x"], photo.fileName)
        }
        XCTAssertEqual(vm.library.tagCounts[existing.id], 2)
    }

    /// New photos without keywords go in through a background context. Later edits in the view model's context
    /// must all reach the store, including linking a tag whose `photos` that context has already loaded (a stale
    /// copy of that relationship is what would drop links saved elsewhere).
    func testPhotosAddedInBackgroundSurviveLaterEdits() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("tagged.jpg", in: photos, keywords: ["cat:a"])
        let (vm, _, container) = try await openLibrary(at: photos)
        let catA = try XCTUnwrap(vm.library.allTags.first { $0.fullName == "cat:a" })
        XCTAssertEqual(catA.photos.count, 1) // loads the inverse in the view model's context

        for i in 0..<3 { try makeJPEG("plain\(i).jpg", in: photos, rating: i == 0 ? 5 : nil) }
        try makeJPEG("tagged2.jpg", in: photos, keywords: ["cat:a"]) // links to the loaded tag
        try await rescan(vm)
        XCTAssertEqual(vm.library.lastScanReport?.inserted, 4)
        let plain0 = try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "plain0" })
        let plain1 = try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "plain1" })
        XCTAssertEqual(plain0.rating, 5)

        vm.library.addTag(name: "a", category: "cat", to: plain0)
        vm.library.setRating(2, for: plain1)
        vm.library.addTag(name: "b", category: "new", to: plain1)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(vm.library.tagCounts[catA.id], 3)
        let stored = try storedPhotos(container)
        XCTAssertEqual(stored.count, 5)
        let byName = Dictionary(uniqueKeysWithValues: stored.map { ($0.fileName, $0) })
        XCTAssertEqual(byName["plain0"]?.rating, 5)
        XCTAssertEqual(byName["plain0"]?.tags.map(\.fullName), ["cat:a"])
        XCTAssertEqual(byName["plain1"]?.rating, 2)
        XCTAssertEqual(byName["plain1"]?.tags.map(\.fullName), ["new:b"])
        XCTAssertEqual(byName["plain2"]?.tags.count, 0)
        XCTAssertEqual(byName["tagged"]?.tags.map(\.fullName), ["cat:a"])
        let storedCatA = try XCTUnwrap(try storedTags(container).first { $0.fullName == "cat:a" })
        XCTAssertEqual(Set(storedCatA.photos.map(\.fileName)), ["tagged", "tagged2", "plain0"])
    }

    // MARK: - Rescans

    func testRescanOfUnchangedLibraryDoesNotDirtyStore() async throws {
        let photos = try makeTempDir("photos")
        for i in 0..<5 { try makeJPEG("p\(i).jpg", in: photos, rating: 2, keywords: ["k:\(i % 2)"]) }
        let (vm, context, _) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.library.allPhotos.count, 5)
        XCTAssertFalse(context.hasChanges)
        let before = vm.library.allPhotos.map { ($0.persistentModelID, $0.jpgPath, $0.fileSize, $0.rating) }

        var pendingBeforeSave: Bool?
        vm.library.scanWillSave = { pendingBeforeSave = $0.hasChanges }
        try await rescan(vm)

        XCTAssertEqual(pendingBeforeSave, false, "an unchanged rescan must not touch any row")
        let report = try XCTUnwrap(vm.library.lastScanReport)
        XCTAssertEqual(report.discovered, 5)
        XCTAssertEqual(report.inserted, 0)
        XCTAssertEqual(report.updated, 0)
        XCTAssertFalse(report.reloaded, "nothing changed, so no reload")
        let after = vm.library.allPhotos.map { ($0.persistentModelID, $0.jpgPath, $0.fileSize, $0.rating) }
        XCTAssertEqual(after.map(\.0), before.map(\.0))
        XCTAssertEqual(after.map(\.1), before.map(\.1))
        XCTAssertEqual(after.map(\.2), before.map(\.2))
        XCTAssertEqual(after.map(\.3), before.map(\.3))
        XCTAssertEqual(vm.library.scanProgress, "Found 5 photos (0 new)")

        // Control: a real change is pending at the same point.
        try Data(repeating: 1, count: 10).write(to: photos.appendingPathComponent("p0.jpg"))
        try await rescan(vm)
        XCTAssertEqual(pendingBeforeSave, true)
        XCTAssertEqual(vm.library.lastScanReport?.updated, 1)
        XCTAssertEqual(vm.library.allPhotos.first { $0.fileName == "p0" }?.fileSize, 10)
    }

    func testLaunchShowsStoredPhotosWithoutCheckingFilesThenScanHidesMissingOnes() async throws {
        let photos = try makeTempDir("photos")
        let present = try makeJPEG("present.jpg", in: photos)
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(PhotoLibrary(rootFolderPath: photos.path))
        context.insert(PhotoAsset(fileName: "present", jpgPath: present.path, folderPath: photos.path,
                                  creationDate: Date(), fileSize: 1))
        context.insert(PhotoAsset(fileName: "gone", jpgPath: photos.appendingPathComponent("gone.jpg").path,
                                  folderPath: photos.path, creationDate: Date(), fileSize: 1))
        try context.save()

        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)

        // Straight from the store, trusting the last scan (no stat pass on the main actor)...
        XCTAssertEqual(Set(vm.library.allPhotos.map(\.fileName)), ["present", "gone"])
        XCTAssertTrue(vm.library.isScanning)
        // ...until the launch rescan has found which files are missing.
        try await waitForScan(vm)
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["present"])
        XCTAssertEqual(vm.library.lastScanReport?.missing, 1)
    }

    func testRefreshAvailabilityStillChecksEveryFile() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("a.jpg", in: photos)
        let b = try makeJPEG("b.jpg", in: photos)
        let (vm, _, _) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.library.allPhotos.count, 2)

        try FileManager.default.removeItem(at: b)
        vm.library.refreshAvailability()

        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["a"])
    }

    func testScanReportsMainActorTime() async throws {
        let photos = try makeTempDir("photos")
        for i in 0..<3 { try makeJPEG("p\(i).jpg", in: photos) }
        let (vm, _, _) = try await openLibrary(at: photos)

        let report = try XCTUnwrap(vm.library.lastScanReport)
        XCTAssertEqual(report.inserted, 3)
        XCTAssertFalse(report.reloaded, "new photos are added in memory")
        XCTAssertGreaterThan(report.mainActorTime, .zero)
    }

    func testOverlappingScansDoNotDuplicate() async throws {
        let photos = try makeTempDir("photos")
        for i in 0..<20 { try makeJPEG("p\(i).jpg", in: photos, rating: i % 5, keywords: ["k:\(i % 3)"]) }
        let container = try makeContainer()
        let context = container.mainContext
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context) // empty store: no library yet, so no scan
        context.insert(PhotoLibrary(rootFolderPath: photos.path))
        try context.save()
        vm.loadExistingData()

        vm.library.rescanCurrentLibrary()
        vm.library.rescanCurrentLibrary()
        vm.library.rescanCurrentLibrary()
        try await waitForScan(vm)

        let stored = try storedPhotos(container)
        XCTAssertEqual(stored.count, 20)
        XCTAssertEqual(Set(stored.map(\.fileName)).count, 20)
        XCTAssertEqual(try storedTags(container).count, 3)
        XCTAssertEqual(vm.library.allPhotos.count, 20)
    }

    func testScanToleratesExistingDuplicates() async throws {
        let photos = try makeTempDir("photos")
        let url = try makeJPEG("dup.jpg", in: photos)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)

        // Two rows for the same file, as overlapping scans used to leave behind. Both have a stale size.
        let (vm, _, container) = try await openLibrary(at: photos) { context in
            for _ in 0..<2 {
                context.insert(PhotoAsset(fileName: "dup", jpgPath: url.path, folderPath: photos.path,
                                          creationDate: Date(), fileSize: 1))
            }
        }

        let stored = try storedPhotos(container)
        XCTAssertEqual(stored.count, 2, "the scan neither inserts a third row nor deletes one")
        XCTAssertTrue(stored.contains { $0.fileSize == size }, "one of them is kept up to date")
        XCTAssertEqual(vm.library.scanProgress, "Found 1 photos (0 new)")

        try await rescan(vm) // and the next scan doesn't trap either
        XCTAssertEqual(try storedPhotos(container).count, 2)
    }

    func testFilesRemovedFromDiskAreHiddenAfterRescan() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("keep.jpg", in: photos)
        let gone = try makeJPEG("gone.jpg", in: photos)
        let (vm, _, _) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.library.allPhotos.count, 2)

        try FileManager.default.removeItem(at: gone)
        try await rescan(vm)

        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["keep"])
        XCTAssertEqual(vm.library.photos.map(\.fileName), ["keep"])
    }

    func testFileThatComesBackIsShownAgainWithoutDuplicate() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("keep.jpg", in: photos)
        let away = try makeJPEG("away.jpg", in: photos)
        let (vm, _, container) = try await openLibrary(at: photos)
        let original = try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "away" })
        vm.library.setRating(4, for: original)
        await MetadataWriter.shared.flush() // the write-back must not race the move below

        let parked = try makeTempDir("parked").appendingPathComponent("away.jpg")
        try FileManager.default.moveItem(at: away, to: parked)
        try await rescan(vm)
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["keep"])

        try FileManager.default.moveItem(at: parked, to: away)
        try await rescan(vm)

        XCTAssertEqual(try storedPhotos(container).count, 2)
        let back = try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "away" })
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.rating, 4)
    }

    func testRescanPicksUpChangedPairs() async throws {
        let photos = try makeTempDir("photos")
        let jpg = try makeJPEG("pair.jpg", in: photos)
        let raw = photos.appendingPathComponent("pair.arw")
        try Data("not a real raw".utf8).write(to: raw) // fake bytes; only the extension matters to the scanner
        let (vm, _, _) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.library.jpgCount, 1)
        XCTAssertEqual(vm.library.rawCount, 1)

        try FileManager.default.removeItem(at: jpg)
        try await rescan(vm)

        let photo = try XCTUnwrap(vm.library.allPhotos.first)
        XCTAssertNil(photo.jpgPath)
        XCTAssertEqual(photo.rawPath, raw.path)
        XCTAssertEqual(photo.fileSize, Int64(Data("not a real raw".utf8).count))
        XCTAssertEqual(vm.library.jpgCount, 0)
        XCTAssertEqual(vm.library.rawCount, 1)
        vm.library.applyFilter(.jpgOnly)
        XCTAssertTrue(vm.library.photos.isEmpty)
    }

    /// User decision (wave 2, #1): a scan leaves photos in the bin, even when it finds their files. (It used to put
    /// them back in the library, so "Move to Bin" didn't survive the launch rescan.)
    func testScanLeavesBinnedPhotoWhoseFileExistsInTheBin() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("binned.jpg", in: photos)
        try makeJPEG("kept.jpg", in: photos)
        let (vm, _, container) = try await openLibrary(at: photos)
        vm.deletePhoto(try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "binned" }))
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["kept"])
        XCTAssertEqual(vm.library.binCount, 1)

        try await rescan(vm)

        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["kept"])
        XCTAssertEqual(vm.library.binCount, 1)
        XCTAssertEqual(vm.library.binPhotos.map(\.fileName), ["binned"])
        XCTAssertEqual(try storedBinNames(container), ["binned"])
        XCTAssertEqual(vm.library.lastScanReport?.updated, 0, "nothing about the binned photo changed")
    }

    /// A binned photo's files are still tracked: the scan updates its paths and size, and it stays in the bin.
    func testBinnedPhotoWhoseFilesChangedStaysInTheBinWithNewPaths() async throws {
        let photos = try makeTempDir("photos")
        let jpg = try makeJPEG("pair.jpg", in: photos)
        let raw = photos.appendingPathComponent("pair.arw")
        try Data("not a real raw".utf8).write(to: raw)
        let (vm, _, container) = try await openLibrary(at: photos)
        vm.deletePhoto(try XCTUnwrap(vm.library.allPhotos.first))
        XCTAssertEqual(vm.library.binCount, 1)

        try FileManager.default.removeItem(at: jpg)
        try await rescan(vm)

        XCTAssertEqual(vm.library.lastScanReport?.updated, 1)
        XCTAssertTrue(vm.library.allPhotos.isEmpty)
        XCTAssertEqual(vm.library.binCount, 1)
        XCTAssertEqual(try storedBinNames(container), ["pair"], "still in the bin in the store")
        let stored = try XCTUnwrap(try storedPhotos(container).first)
        XCTAssertNil(stored.jpgPath)
        XCTAssertEqual(stored.rawPath, raw.path)
        XCTAssertEqual(stored.fileSize, Int64(Data("not a real raw".utf8).count))
        vm.library.applyFilter(.bin)
        XCTAssertEqual(vm.library.photos.map(\.fileName), ["pair"])
        XCTAssertNil(vm.library.photos.first?.jpgPath)
    }

    /// User decision (wave 2, #1): "Move to Bin" survives a relaunch, which opens the store again and rescans.
    func testMoveToBinSurvivesRelaunch() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("binned.jpg", in: photos)
        try makeJPEG("kept.jpg", in: photos)
        let storeURL = try makeTempDir("store").appendingPathComponent("scan.store")
        let first = try makeContainer(storeURL: storeURL).mainContext
        first.insert(PhotoLibrary(rootFolderPath: photos.path))
        try first.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(first)
        try await waitForScan(vm)
        vm.deletePhoto(try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "binned" }))

        // Relaunch: a new container on the same store, and a new view model with its launch rescan.
        let relaunched = try makeContainer(storeURL: storeURL)
        let vm2 = PhotoLibraryViewModel()
        vm2.setModelContext(relaunched.mainContext)
        await vm2.library.waitForScans()

        XCTAssertEqual(vm2.library.allPhotos.map(\.fileName), ["kept"])
        XCTAssertEqual(vm2.library.binCount, 1)
        XCTAssertEqual(vm2.library.binPhotos.map(\.fileName), ["binned"])
        XCTAssertEqual(try storedBinNames(relaunched), ["binned"])
    }

    func testPhotoOutsideScannedFolderStaysVisibleWhileItsFileExists() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("inside.jpg", in: photos)
        let elsewhere = try makeTempDir("oldroot")
        let outside = try makeJPEG("outside.jpg", in: elsewhere)
        let (vm, _, _) = try await openLibrary(at: photos) { context in
            context.insert(PhotoAsset(fileName: "outside", jpgPath: outside.path, folderPath: elsewhere.path,
                                      creationDate: Date(), fileSize: 1))
            context.insert(PhotoAsset(fileName: "vanished", jpgPath: elsewhere.appendingPathComponent("vanished.jpg").path,
                                      folderPath: elsewhere.path, creationDate: Date(), fileSize: 1))
        }

        XCTAssertEqual(Set(vm.library.allPhotos.map(\.fileName)), ["inside", "outside"])
    }

    func testScanOfMissingRootFolderHidesItsPhotos() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("a.jpg", in: photos)
        try makeJPEG("b.jpg", in: photos)
        let (vm, _, container) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.library.allPhotos.count, 2)

        try FileManager.default.removeItem(at: photos) // like an unplugged drive
        try await rescan(vm)

        XCTAssertTrue(vm.library.allPhotos.isEmpty)
        XCTAssertEqual(try storedPhotos(container).count, 2, "rows are kept, only hidden")
    }

    func testRescanRequestedDuringScanRunsAfterIt() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("first.jpg", in: photos)
        let (vm, _, container) = try await openLibrary(at: photos)

        vm.library.rescanCurrentLibrary()
        try makeJPEG("late.jpg", in: photos) // may or may not be seen by the running scan
        vm.library.rescanCurrentLibrary()              // but the queued one sees it
        try await waitForScan(vm)

        XCTAssertEqual(Set(vm.library.allPhotos.map(\.fileName)), ["first", "late"])
        XCTAssertEqual(try storedPhotos(container).count, 2)
    }

    /// `waitForScans()` returns once the launch rescan and every scan queued behind it are done: where work that
    /// should start after launch waits.
    func testWaitForScansWaitsForTheLaunchRescanAndQueuedScans() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("first.jpg", in: photos)
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(PhotoLibrary(rootFolderPath: photos.path))
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context) // starts the launch rescan
        XCTAssertTrue(vm.library.isScanning)
        try makeJPEG("late.jpg", in: photos)
        vm.library.rescanCurrentLibrary() // queued behind it

        await vm.library.waitForScans()

        XCTAssertFalse(vm.library.isScanning)
        XCTAssertEqual(Set(vm.library.allPhotos.map(\.fileName)), ["first", "late"])
    }

    // MARK: - Launch of a big library (background load)

    /// A library imported by a first launch (small, so it loads at once): tagged, rated, uncategorised and non-ASCII
    /// tags, a JPG+RAW pair, a RAW-only photo, distinct dates, one photo in the bin. Returns its folder and store, for
    /// a relaunch.
    private func importedLibrary() async throws -> (photos: URL, storeURL: URL) {
        let photos = try makeTempDir("photos")
        let files: [(String, Int?, [String])] = [
            ("a.jpg", 3, ["people:Ann", "Été"]), ("b.jpg", nil, ["places:home"]), ("c.jpg", nil, []),
            ("pair.jpg", 1, ["people:Bo"]), ("d.jpg", 5, ["people:Bo", "places:away"]), ("e.jpg", nil, []),
        ]
        for (day, file) in files.enumerated() {
            try setCreated(try makeJPEG(file.0, in: photos, rating: file.1, keywords: file.2), Double(day + 1) * 86_400)
        }
        for name in ["pair.arw", "rawonly.arw"] {
            let url = photos.appendingPathComponent(name)
            try Data("not a real raw".utf8).write(to: url)
            try setCreated(url, name == "pair.arw" ? 4 * 86_400 : 10 * 86_400)
        }
        let storeURL = try makeTempDir("store").appendingPathComponent("scan.store")
        let context = try makeContainer(storeURL: storeURL).mainContext
        context.insert(PhotoLibrary(rootFolderPath: photos.path))
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        try await waitForScan(vm)
        XCTAssertNil(vm.library.loading.lastBackgroundLoad, "a small library loads at once")
        XCTAssertEqual(vm.library.allPhotos.count, 7)
        vm.deletePhoto(try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "e" }))
        return (photos, storeURL)
    }

    /// Relaunches the store at `storeURL` as a big library: its load runs in the background, in pages of two rows.
    private func relaunchAsBigLibrary(_ storeURL: URL) throws -> PhotoLibraryViewModel {
        let vm = PhotoLibraryViewModel()
        vm.library.loading.backgroundLoadThreshold = 0
        vm.library.loading.pageSize = 2
        vm.setModelContext(try makeContainer(storeURL: storeURL).mainContext)
        return vm
    }

    func testRelaunchOfABigLibraryLoadsItInTheBackground() async throws {
        let (_, storeURL) = try await importedLibrary()

        let vm = try relaunchAsBigLibrary(storeURL)

        // setModelContext() returned without loading...
        XCTAssertTrue(vm.library.allPhotos.isEmpty)
        XCTAssertTrue(vm.library.photos.isEmpty)
        XCTAssertTrue(vm.library.isScanning, "the grid shows no empty-library message meanwhile")
        XCTAssertEqual(vm.library.scanProgress, "Loading library...")
        XCTAssertNotNil(vm.library.currentLibrary, "so a rescan requested now queues")
        // ...and the load, then the launch rescan, run behind it.
        await vm.library.waitForScans()
        let report = try XCTUnwrap(vm.library.loading.lastBackgroundLoad)
        XCTAssertTrue(report.applied)
        XCTAssertGreaterThanOrEqual(report.turns, 4, "a page of two rows per turn, then the apply")
        XCTAssertEqual(vm.library.lastScanReport?.discovered, 7, "the launch rescan ran after it")
        XCTAssertEqual(vm.library.lastScanReport?.updated, 0)
        XCTAssertEqual(vm.library.lastScanReport?.usedWalkReadAhead, true, "it walked the folder during the load")
        XCTAssertEqual(vm.library.lastScanReport?.usedRowsReadAhead, true, "and took the rows the load read")
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["rawonly", "d", "pair", "c", "b", "a"])
        XCTAssertEqual(vm.library.binPhotos.map(\.fileName), ["e"])
        assertMatchesFreshLoad(vm, "a relaunch that loaded in the background")
    }

    /// Every main-actor turn during the load sees either no library or the whole of it: never photos from one
    /// snapshot with counts from another, or a partial list.
    func testBackgroundLoadNeverShowsAHalfBuiltLibrary() async throws {
        let (_, storeURL) = try await importedLibrary()
        struct Sample: Equatable {
            var photos, allPhotos, allFacts, binPhotos, binCount, rated, tags, tagCounts, categories: Int
        }
        var samples: [Sample] = []
        var vm: PhotoLibraryViewModel!
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if let library = vm?.library {
                    samples.append(Sample(
                        photos: library.photos.count, allPhotos: library.allPhotos.count,
                        allFacts: library.allFacts.count, binPhotos: library.binPhotos.count, binCount: library.binCount,
                        rated: library.ratingCounts.values.reduce(0, +), tags: library.allTags.count,
                        tagCounts: library.tagCounts.count, categories: library.tagCategories.count))
                }
                await Task.yield()
            }
        }

        vm = try relaunchAsBigLibrary(storeURL)
        await vm.library.waitForScans()
        sampler.cancel()
        _ = await sampler.value

        let empty = Sample(photos: 0, allPhotos: 0, allFacts: 0, binPhotos: 0, binCount: 0, rated: 0, tags: 0,
                           tagCounts: 0, categories: 0)
        let whole = Sample(photos: 6, allPhotos: 6, allFacts: 6, binPhotos: 1, binCount: 1, rated: 6, tags: 5,
                           tagCounts: 5, categories: 2)
        XCTAssertGreaterThan(samples.count, 3)
        XCTAssertTrue(samples.contains(empty) && samples.contains(whole), "the sampler saw both sides of the load")
        XCTAssertEqual(samples.filter { $0 != empty && $0 != whole }, [], "half-built states")
    }

    /// A full load while the background load runs (from `refreshAvailability()`, say) is newer, so the background
    /// load is dropped rather than applied over it.
    func testFullLoadDuringTheBackgroundLoadWins() async throws {
        let (_, storeURL) = try await importedLibrary()
        let vm = try relaunchAsBigLibrary(storeURL)

        vm.loadExistingData()
        XCTAssertEqual(vm.library.allPhotos.count, 6)
        await vm.library.waitForScans()

        XCTAssertEqual(vm.library.loading.lastBackgroundLoad?.applied, false)
        XCTAssertEqual(vm.library.allPhotos.count, 6)
        assertMatchesFreshLoad(vm, "a full load during the background load")
    }

    /// The sort, filters and search can change while the library loads; the loaded library follows them.
    func testSortFilterAndSearchChangedDuringTheBackgroundLoad() async throws {
        let (_, storeURL) = try await importedLibrary()
        let vm = try relaunchAsBigLibrary(storeURL)

        vm.library.toggleSortOrder()
        vm.library.applyFilter(.jpgOnly)
        vm.library.searchText = "people"
        vm.library.applySearch()
        await vm.library.waitForScans()

        XCTAssertEqual(vm.library.loading.lastBackgroundLoad?.applied, true)
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["a", "b", "c", "pair", "d", "rawonly"])
        XCTAssertEqual(vm.library.photos.map(\.fileName), ["a", "pair", "d"])
        assertMatchesFreshLoad(vm, "sort, filter and search changed during the load")
    }

    /// The background load trusts the last scan, like the synchronous one: it shows photos whose files have gone,
    /// until the launch rescan hides them.
    func testBackgroundLoadShowsStoredPhotosThenTheRescanHidesMissingOnes() async throws {
        let (photos, storeURL) = try await importedLibrary()
        try FileManager.default.removeItem(at: photos.appendingPathComponent("c.jpg"))
        var namesWhenLoaded: Set<String>?
        let vm = PhotoLibraryViewModel()
        vm.library.loading.backgroundLoadThreshold = 0
        vm.library.loading.backgroundLoadDidApply = { namesWhenLoaded = Set(vm.library.allPhotos.map(\.fileName)) }
        vm.setModelContext(try makeContainer(storeURL: storeURL).mainContext)
        await vm.library.waitForScans()

        XCTAssertEqual(namesWhenLoaded, ["a", "b", "c", "pair", "d", "rawonly"])
        XCTAssertEqual(Set(vm.library.allPhotos.map(\.fileName)), ["a", "b", "pair", "d", "rawonly"])
        XCTAssertEqual(vm.library.lastScanReport?.missing, 1)
        assertMatchesFreshLoad(vm, "the launch rescan after a background load")
    }

    /// `waitForScans()` (task 33's after-launch hook) waits for the background load, the launch rescan and a scan
    /// queued behind them.
    func testWaitForScansWaitsForTheBackgroundLoadAndTheScansBehindIt() async throws {
        let (photos, storeURL) = try await importedLibrary()
        let vm = try relaunchAsBigLibrary(storeURL)
        try makeJPEG("late.jpg", in: photos)
        vm.library.rescanCurrentLibrary() // queued behind the load

        await vm.library.waitForScans()

        XCTAssertFalse(vm.library.isScanning)
        XCTAssertEqual(vm.library.loading.lastBackgroundLoad?.applied, true)
        XCTAssertTrue(vm.library.allPhotos.contains { $0.fileName == "late" })
        XCTAssertEqual(vm.library.allPhotos.count, 7)
        XCTAssertEqual(vm.library.lastScanReport?.usedWalkReadAhead, false,
                       "a scan requested after launch walks the folder again")
        assertMatchesFreshLoad(vm, "after waitForScans")
    }

    /// The launch rescan uses the rows the background load read only while they are still the store's.
    func testLaunchRescanReadsTheStoreAgainWhenItMayHaveChanged() async throws {
        let (_, storeURL) = try await importedLibrary()

        // Unsaved changes when the rescan starts (it saves them first).
        let vm = try relaunchAsBigLibrary(storeURL)
        vm.library.currentLibrary?.bookmarkData = Data([1])
        await vm.library.waitForScans()
        XCTAssertEqual(vm.library.lastScanReport?.usedWalkReadAhead, true)
        XCTAssertEqual(vm.library.lastScanReport?.usedRowsReadAhead, false)
        assertMatchesFreshLoad(vm, "unsaved changes at launch")

        // A full load after the background load read the store.
        let vm2 = try relaunchAsBigLibrary(storeURL)
        vm2.library.loading.backgroundLoadDidApply = { vm2.loadExistingData() }
        await vm2.library.waitForScans()
        XCTAssertEqual(vm2.library.lastScanReport?.usedRowsReadAhead, false)
        XCTAssertEqual(Set(vm2.library.allPhotos.map(\.fileName)), ["a", "b", "c", "pair", "d", "rawonly"])
    }

    /// "Move to Bin" survives a relaunch that loads in the background too.
    func testMoveToBinSurvivesARelaunchThatLoadsInTheBackground() async throws {
        let (_, storeURL) = try await importedLibrary()
        let vm = try relaunchAsBigLibrary(storeURL)
        await vm.library.waitForScans()

        XCTAssertEqual(vm.library.binPhotos.map(\.fileName), ["e"])
        XCTAssertFalse(vm.library.allPhotos.contains { $0.fileName == "e" })
    }

    // MARK: - Incremental updates after scans

    /// A library of six photos a day apart (days 1–6), two tagged and some rated, rescanned once loaded.
    private func openDatedLibrary() async throws -> (PhotoLibraryViewModel, URL, ModelContainer) {
        let photos = try makeTempDir("photos")
        for day in 1...6 {
            let url = try makeJPEG("old\(day).jpg", in: photos, rating: day % 3 == 0 ? 3 : nil,
                                   keywords: day % 2 == 0 ? ["people:ann"] : [])
            try setCreated(url, Double(day) * 86_400)
        }
        let (vm, _, container) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.library.allPhotos.count, 6)
        return (vm, photos, container)
    }

    /// A few new photos (the patch path): each goes where a reload would put it, with its tags and counts, and the
    /// library isn't reloaded.
    func testScanAddingAFewPhotosUpdatesTheLibraryLikeAFreshLoad() async throws {
        let (vm, photos, _) = try await openDatedLibrary()
        try setCreated(try makeJPEG("new-a.jpg", in: photos, rating: 3, keywords: ["people:ann"]), 2.5 * 86_400)
        try setCreated(try makeJPEG("new-b.jpg", in: photos, keywords: ["places:home", "loose"]), 9 * 86_400)
        try setCreated(try makeJPEG("new-c.jpg", in: photos), 0.5 * 86_400)

        try await rescan(vm)

        let report = try XCTUnwrap(vm.library.lastScanReport)
        XCTAssertEqual(report.inserted, 3)
        XCTAssertFalse(report.reloaded)
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName),
                       ["new-b", "old6", "old5", "old4", "old3", "new-a", "old2", "old1", "new-c"])
        XCTAssertEqual(vm.library.tagCategories.first, "people")
        XCTAssertTrue(vm.library.uncategorizedTags.map(\.name).contains("loose"))
        assertMatchesFreshLoad(vm, "a scan adding 3 photos")
    }

    /// Many new photos (the merge path), with a filter and search active and the sort reversed.
    func testScanAddingManyPhotosUpdatesTheLibraryLikeAFreshLoad() async throws {
        let (vm, photos, _) = try await openDatedLibrary()
        vm.library.toggleSortOrder()
        vm.library.applyFilter(.rated(3))
        vm.library.searchText = "new"
        vm.library.applySearch()
        for i in 0..<12 {
            let url = try makeJPEG("new\(i).jpg", in: photos, rating: i % 2 == 0 ? 3 : 1,
                                   keywords: i % 3 == 0 ? ["people:bo"] : [])
            try setCreated(url, Double(i) * 43_200)
        }

        try await rescan(vm)

        XCTAssertEqual(vm.library.lastScanReport?.inserted, 12)
        XCTAssertEqual(vm.library.lastScanReport?.reloaded, false)
        XCTAssertEqual(vm.library.photos.count, 6)
        assertMatchesFreshLoad(vm, "a scan adding 12 photos, filtered, oldest first")
        vm.library.searchText = ""
        vm.library.applyFilter(.all)
        assertMatchesFreshLoad(vm, "then clearing the filter and search")
    }

    /// Photos added while the bin is shown join the library, not the grid.
    func testScanAddingPhotosWhileTheBinIsShownKeepsShowingTheBin() async throws {
        let (vm, photos, _) = try await openDatedLibrary()
        vm.deletePhoto(try XCTUnwrap(vm.library.allPhotos.first))
        vm.library.applyFilter(.bin)
        for i in 0..<3 { try makeJPEG("new\(i).jpg", in: photos) }

        try await rescan(vm)

        XCTAssertEqual(vm.library.photos.map(\.fileName), ["old6"])
        assertMatchesFreshLoad(vm, "a scan while the bin is shown")
        vm.library.applyFilter(.all)
        XCTAssertEqual(vm.library.photos.count, 8)
        assertMatchesFreshLoad(vm, "back to the library")
    }

    /// Photos whose files go missing leave the library in memory, and come back the same way.
    func testPhotosGoingMissingAndComingBackUpdateTheLibraryInMemory() async throws {
        let (vm, photos, _) = try await openDatedLibrary()
        let parked = try makeTempDir("parked")
        for day in [2, 5] {
            try FileManager.default.moveItem(at: photos.appendingPathComponent("old\(day).jpg"),
                                             to: parked.appendingPathComponent("old\(day).jpg"))
        }

        try await rescan(vm)
        XCTAssertEqual(vm.library.lastScanReport?.missing, 2)
        XCTAssertEqual(vm.library.lastScanReport?.reloaded, false)
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["old6", "old4", "old3", "old1"])
        assertMatchesFreshLoad(vm, "two photos gone")

        for day in [2, 5] {
            try FileManager.default.moveItem(at: parked.appendingPathComponent("old\(day).jpg"),
                                             to: photos.appendingPathComponent("old\(day).jpg"))
        }
        try await rescan(vm)
        XCTAssertEqual(vm.library.lastScanReport?.missing, 0)
        XCTAssertEqual(vm.library.lastScanReport?.inserted, 0)
        XCTAssertEqual(vm.library.lastScanReport?.reloaded, false)
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["old6", "old5", "old4", "old3", "old2", "old1"])
        assertMatchesFreshLoad(vm, "both back")
    }

    /// A full load while a scan is inserting (here from the scan's own hook, after its inserts) already has the new
    /// photos, so the scan must not add them again.
    func testLoadDuringAScanDoesNotDuplicateItsNewPhotos() async throws {
        let (vm, photos, _) = try await openDatedLibrary()
        try makeJPEG("tagged.jpg", in: photos, keywords: ["people:cy"])
        try makeJPEG("plain.jpg", in: photos)
        vm.library.scanWillSave = { _ in vm.library.loadExistingData() }

        try await rescan(vm)

        XCTAssertEqual(vm.library.lastScanReport?.inserted, 2)
        XCTAssertEqual(vm.library.allPhotos.count, 8)
        XCTAssertEqual(Set(vm.library.allPhotos.map(\.id)).count, 8)
        vm.library.scanWillSave = nil
        assertMatchesFreshLoad(vm, "a load during the scan")
    }

    // MARK: - Scan plan (pure)

    private func found(_ name: String, folder: String = "/f", jpg: Bool = true, raw: Bool = false,
                       size: Int64 = 10, keywords: [String]? = nil) -> DiscoveredPhoto {
        DiscoveredPhoto(
            fileName: name, jpgPath: jpg ? "\(folder)/\(name).jpg" : nil, rawPath: raw ? "\(folder)/\(name).arw" : nil,
            folderPath: folder, fileSize: size, creationDate: nil,
            metadata: keywords.map { MetadataService.PhotoMetadata(rating: 0, keywords: $0) }
        )
    }

    private func stored(_ name: String, folder: String = "/f", jpg: Bool = true, raw: Bool = false,
                        size: Int64 = 10, inBin: Bool = false, id: UUID = UUID()) -> StoredPhoto {
        StoredPhoto(id: id, key: DiscoveredPhoto.key(folderPath: folder, fileName: name),
                    jpgPath: jpg ? "\(folder)/\(name).jpg" : nil, rawPath: raw ? "\(folder)/\(name).arw" : nil,
                    fileSize: size, isInBin: inBin)
    }

    func testPlanOfUnchangedLibraryIsEmptyAndStatsNothing() {
        var stats = 0
        let plan = ScanPlan(stored: [stored("a"), stored("b", raw: true)],
                            discovered: [found("a"), found("b", raw: true)],
                            fileExists: { _ in stats += 1; return true })
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.newPhotos.isEmpty)
        XCTAssertTrue(plan.missingIDs.isEmpty)
        XCTAssertEqual(plan.discoveredCount, 2)
        XCTAssertEqual(stats, 0)
    }

    func testPlanUpdatesChangedRowsOnly() {
        let changedSize = stored("size", size: 1)
        let lostJPG = stored("pair", raw: true)
        let plan = ScanPlan(
            stored: [stored("same"), changedSize, lostJPG],
            discovered: [found("same"), found("size", size: 99), found("pair", jpg: false, raw: true)]
        )
        XCTAssertEqual(plan.updates, [
            .init(id: changedSize.id, jpgPath: "/f/size.jpg", rawPath: nil, fileSize: 99),
            .init(id: lostJPG.id, jpgPath: nil, rawPath: "/f/pair.arw", fileSize: 10),
        ])
    }

    /// User decision (wave 2, #1): binned rows stay in the bin. A found one is updated only if its files changed.
    func testPlanLeavesBinnedRowsInTheBin() {
        let binnedFound = stored("found", inBin: true)
        let binnedChanged = stored("changed", inBin: true)
        let binnedGone = stored("gone", inBin: true)
        let plan = ScanPlan(stored: [binnedFound, binnedChanged, binnedGone],
                            discovered: [found("found"), found("changed", size: 99)],
                            fileExists: { _ in false })
        XCTAssertEqual(plan.updates, [
            .init(id: binnedChanged.id, jpgPath: "/f/changed.jpg", rawPath: nil, fileSize: 99),
        ])
        XCTAssertTrue(plan.newPhotos.isEmpty, "a binned photo's files are known, not new")
        XCTAssertTrue(plan.missingIDs.isEmpty, "the bin isn't checked for missing files, as before")
    }

    func testPlanKeepsEveryDuplicateRowUpToDateAndInsertsNothing() {
        let first = stored("dup", size: 1)
        let second = stored("dup", size: 2)
        let plan = ScanPlan(stored: [first, second], discovered: [found("dup", size: 3)])
        XCTAssertEqual(Set(plan.updates.map(\.id)), [first.id, second.id])
        XCTAssertTrue(plan.updates.allSatisfy { $0.fileSize == 3 })
        XCTAssertTrue(plan.newPhotos.isEmpty)
    }

    func testPlanMissingIDsAreUnfoundLibraryRowsWithNoFileLeft() {
        let gone = stored("gone", raw: true)
        let rawLeft = stored("rawleft", raw: true)
        let elsewhere = stored("elsewhere", folder: "/old")
        var checked: [String] = []
        let plan = ScanPlan(stored: [stored("here"), gone, rawLeft, elsewhere], discovered: [found("here")],
                            fileExists: { path in
                                checked.append(path)
                                return path == "/f/rawleft.arw" || path == "/old/elsewhere.jpg"
                            })
        XCTAssertEqual(plan.missingIDs, [gone.id])
        XCTAssertEqual(Set(checked), ["/f/gone.jpg", "/f/gone.arw", "/f/rawleft.jpg", "/f/rawleft.arw",
                                      "/old/elsewhere.jpg"])
    }

    /// Library rows that were missing and aren't any more (found, or their file exists again) are shown again; ones
    /// still missing, and binned ones, aren't.
    func testPlanFoundAgainAreLibraryRowsNoLongerMissing() {
        let found = stored("found")
        let fileBack = stored("elsewhere", folder: "/old")
        let stillGone = stored("gone")
        let binned = stored("binned", inBin: true)
        let plan = ScanPlan(stored: [found, fileBack, stillGone, binned],
                            discovered: [self.found("found"), self.found("binned")],
                            previouslyMissing: [found.id, fileBack.id, stillGone.id, binned.id],
                            fileExists: { $0 == "/old/elsewhere.jpg" })
        XCTAssertEqual(plan.missingIDs, [stillGone.id])
        XCTAssertEqual(plan.foundAgainIDs, [found.id, fileBack.id])
    }

    func testPlanNewPhotosAreTheUnknownKeysInDiscoveryOrder() {
        let plan = ScanPlan(stored: [stored("b")], discovered: [found("c"), found("b"), found("a")])
        XCTAssertEqual(plan.newPhotos.map(\.fileName), ["c", "a"])
    }

    /// The background context may only insert photos without relationships (see
    /// `ScanPlan.canInsertInBackground` for why a photo with tags must go through the view model's context).
    func testOnlyPhotosWithoutKeywordsAreInsertedInBackground() {
        XCTAssertTrue(ScanPlan.canInsertInBackground(found("unread")))
        XCTAssertTrue(ScanPlan.canInsertInBackground(found("none", keywords: [])))
        XCTAssertFalse(ScanPlan.canInsertInBackground(found("tagged", keywords: ["cat:a"])))
        XCTAssertFalse(ScanPlan.canInsertInBackground(found("plain", keywords: ["b"])))
    }

    func testBackgroundInsertSkipsPhotosWithKeywords() async throws {
        let container = try makeContainer()
        let inserted = await ScanPlan.insertInBackground(
            [found("a"), found("b", keywords: ["cat:x"]), found("c", keywords: [])], into: container)
        XCTAssertEqual(inserted.count, 2)
        XCTAssertEqual(Set(try storedPhotos(container).map(\.fileName)), ["a", "c"])
        XCTAssertEqual(Set(try storedPhotos(container).map(\.id)), Set(inserted), "it returns the saved rows' ids")
        XCTAssertTrue(try storedTags(container).isEmpty)
    }

    // MARK: - Tag parsing

    func testTagParseRoundTripsFullName() {
        XCTAssertTrue(Tag.parse(keyword: "cat:a") == ("cat", "a"))
        XCTAssertTrue(Tag.parse(keyword: "a") == ("", "a"))
        XCTAssertTrue(Tag.parse(keyword: "places:New York: Manhattan") == ("places", "New York: Manhattan"))
        XCTAssertTrue(Tag.parse(keyword: ":a:b") == ("", ":a:b"))
        XCTAssertTrue(Tag.parse(keyword: "a:") == ("", "a:"))

        for (category, name) in [("cat", "a"), ("", "plain"), ("people", "Ann Lee"), ("x", "a:b")] {
            let parsed = Tag.parse(keyword: Tag(name: name, category: category).fullName)
            XCTAssertEqual(parsed.category, category)
            XCTAssertEqual(parsed.name, name)
        }
        // The inverse holds for any keyword: parsing, then joining, gives the keyword back.
        for keyword in ["cat:a", "a", ":a", "a:", "::", "", "a::b", ":a:b", "a:b:", "é:ü", "a b:c d"] {
            let parsed = Tag.parse(keyword: keyword)
            XCTAssertEqual(Tag(name: parsed.name, category: parsed.category).fullName, keyword, keyword)
        }
    }
}
