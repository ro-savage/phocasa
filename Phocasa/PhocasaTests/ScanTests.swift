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
        let storeDir = try makeTempDir("store")
        let config = ModelConfiguration(url: storeDir.appendingPathComponent("scan.store"), cloudKitDatabase: .none)
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
        while vm.isScanning {
            if ContinuousClock.now > deadline {
                XCTFail("scan did not finish within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func rescan(_ vm: PhotoLibraryViewModel) async throws {
        vm.rescanCurrentLibrary()
        XCTAssertTrue(vm.isScanning, "rescanCurrentLibrary() must set isScanning before it returns")
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

    // MARK: - Import

    func testScanImportsRatingsAndKeywords() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("tagged.jpg", in: photos, rating: 3, keywords: ["cat:a", "b"])
        try makeJPEG("plain.jpg", in: photos)

        let (vm, _, container) = try await openLibrary(at: photos)

        XCTAssertEqual(vm.allPhotos.count, 2)
        let tagged = try XCTUnwrap(vm.allPhotos.first { $0.fileName == "tagged" })
        XCTAssertEqual(tagged.rating, 3)
        XCTAssertEqual(Set(tagged.tags.map(\.fullName)), ["cat:a", "b"])
        let plain = try XCTUnwrap(vm.allPhotos.first { $0.fileName == "plain" })
        XCTAssertEqual(plain.rating, 0)
        XCTAssertTrue(plain.tags.isEmpty)
        XCTAssertEqual(Set(try storedTags(container).map(\.fullName)), ["cat:a", "b"])
        XCTAssertEqual(vm.scanProgress, "Found 2 photos (2 new)")
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
        for photo in vm.allPhotos {
            XCTAssertEqual(photo.tags.map(\.fullName).sorted(), ["cat:a", "new:x"], photo.fileName)
        }
        XCTAssertEqual(vm.tagCounts[existing.id], 2)
    }

    /// New photos without keywords go in through a background context. Later edits in the view model's context
    /// must all reach the store, including linking a tag whose `photos` that context has already loaded (a stale
    /// copy of that relationship is what would drop links saved elsewhere).
    func testPhotosAddedInBackgroundSurviveLaterEdits() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("tagged.jpg", in: photos, keywords: ["cat:a"])
        let (vm, _, container) = try await openLibrary(at: photos)
        let catA = try XCTUnwrap(vm.allTags.first { $0.fullName == "cat:a" })
        XCTAssertEqual(catA.photos.count, 1) // loads the inverse in the view model's context

        for i in 0..<3 { try makeJPEG("plain\(i).jpg", in: photos, rating: i == 0 ? 5 : nil) }
        try makeJPEG("tagged2.jpg", in: photos, keywords: ["cat:a"]) // links to the loaded tag
        try await rescan(vm)
        XCTAssertEqual(vm.lastScanReport?.inserted, 4)
        let plain0 = try XCTUnwrap(vm.allPhotos.first { $0.fileName == "plain0" })
        let plain1 = try XCTUnwrap(vm.allPhotos.first { $0.fileName == "plain1" })
        XCTAssertEqual(plain0.rating, 5)

        vm.addTag(name: "a", category: "cat", to: plain0)
        vm.setRating(2, for: plain1)
        vm.addTag(name: "b", category: "new", to: plain1)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(vm.tagCounts[catA.id], 3)
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
        XCTAssertEqual(vm.allPhotos.count, 5)
        XCTAssertFalse(context.hasChanges)
        let before = vm.allPhotos.map { ($0.persistentModelID, $0.jpgPath, $0.fileSize, $0.rating) }

        var pendingBeforeSave: Bool?
        vm.scanWillSave = { pendingBeforeSave = $0.hasChanges }
        try await rescan(vm)

        XCTAssertEqual(pendingBeforeSave, false, "an unchanged rescan must not touch any row")
        let report = try XCTUnwrap(vm.lastScanReport)
        XCTAssertEqual(report.discovered, 5)
        XCTAssertEqual(report.inserted, 0)
        XCTAssertEqual(report.updated, 0)
        XCTAssertFalse(report.reloaded, "nothing changed, so no reload")
        let after = vm.allPhotos.map { ($0.persistentModelID, $0.jpgPath, $0.fileSize, $0.rating) }
        XCTAssertEqual(after.map(\.0), before.map(\.0))
        XCTAssertEqual(after.map(\.1), before.map(\.1))
        XCTAssertEqual(after.map(\.2), before.map(\.2))
        XCTAssertEqual(after.map(\.3), before.map(\.3))
        XCTAssertEqual(vm.scanProgress, "Found 5 photos (0 new)")

        // Control: a real change is pending at the same point.
        try Data(repeating: 1, count: 10).write(to: photos.appendingPathComponent("p0.jpg"))
        try await rescan(vm)
        XCTAssertEqual(pendingBeforeSave, true)
        XCTAssertEqual(vm.lastScanReport?.updated, 1)
        XCTAssertEqual(vm.allPhotos.first { $0.fileName == "p0" }?.fileSize, 10)
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
        XCTAssertEqual(Set(vm.allPhotos.map(\.fileName)), ["present", "gone"])
        XCTAssertTrue(vm.isScanning)
        // ...until the launch rescan has found which files are missing.
        try await waitForScan(vm)
        XCTAssertEqual(vm.allPhotos.map(\.fileName), ["present"])
        XCTAssertEqual(vm.lastScanReport?.missing, 1)
    }

    func testRefreshAvailabilityStillChecksEveryFile() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("a.jpg", in: photos)
        let b = try makeJPEG("b.jpg", in: photos)
        let (vm, _, _) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.allPhotos.count, 2)

        try FileManager.default.removeItem(at: b)
        vm.refreshAvailability()

        XCTAssertEqual(vm.allPhotos.map(\.fileName), ["a"])
    }

    func testScanReportsMainActorTime() async throws {
        let photos = try makeTempDir("photos")
        for i in 0..<3 { try makeJPEG("p\(i).jpg", in: photos) }
        let (vm, _, _) = try await openLibrary(at: photos)

        let report = try XCTUnwrap(vm.lastScanReport)
        XCTAssertEqual(report.inserted, 3)
        XCTAssertTrue(report.reloaded)
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

        vm.rescanCurrentLibrary()
        vm.rescanCurrentLibrary()
        vm.rescanCurrentLibrary()
        try await waitForScan(vm)

        let stored = try storedPhotos(container)
        XCTAssertEqual(stored.count, 20)
        XCTAssertEqual(Set(stored.map(\.fileName)).count, 20)
        XCTAssertEqual(try storedTags(container).count, 3)
        XCTAssertEqual(vm.allPhotos.count, 20)
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
        XCTAssertEqual(vm.scanProgress, "Found 1 photos (0 new)")

        try await rescan(vm) // and the next scan doesn't trap either
        XCTAssertEqual(try storedPhotos(container).count, 2)
    }

    func testFilesRemovedFromDiskAreHiddenAfterRescan() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("keep.jpg", in: photos)
        let gone = try makeJPEG("gone.jpg", in: photos)
        let (vm, _, _) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.allPhotos.count, 2)

        try FileManager.default.removeItem(at: gone)
        try await rescan(vm)

        XCTAssertEqual(vm.allPhotos.map(\.fileName), ["keep"])
        XCTAssertEqual(vm.photos.map(\.fileName), ["keep"])
    }

    func testFileThatComesBackIsShownAgainWithoutDuplicate() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("keep.jpg", in: photos)
        let away = try makeJPEG("away.jpg", in: photos)
        let (vm, _, container) = try await openLibrary(at: photos)
        let original = try XCTUnwrap(vm.allPhotos.first { $0.fileName == "away" })
        vm.setRating(4, for: original)
        await MetadataWriter.shared.flush() // the write-back must not race the move below

        let parked = try makeTempDir("parked").appendingPathComponent("away.jpg")
        try FileManager.default.moveItem(at: away, to: parked)
        try await rescan(vm)
        XCTAssertEqual(vm.allPhotos.map(\.fileName), ["keep"])

        try FileManager.default.moveItem(at: parked, to: away)
        try await rescan(vm)

        XCTAssertEqual(try storedPhotos(container).count, 2)
        let back = try XCTUnwrap(vm.allPhotos.first { $0.fileName == "away" })
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.rating, 4)
    }

    func testRescanPicksUpChangedPairs() async throws {
        let photos = try makeTempDir("photos")
        let jpg = try makeJPEG("pair.jpg", in: photos)
        let raw = photos.appendingPathComponent("pair.arw")
        try Data("not a real raw".utf8).write(to: raw) // fake bytes; only the extension matters to the scanner
        let (vm, _, _) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.jpgCount, 1)
        XCTAssertEqual(vm.rawCount, 1)

        try FileManager.default.removeItem(at: jpg)
        try await rescan(vm)

        let photo = try XCTUnwrap(vm.allPhotos.first)
        XCTAssertNil(photo.jpgPath)
        XCTAssertEqual(photo.rawPath, raw.path)
        XCTAssertEqual(photo.fileSize, Int64(Data("not a real raw".utf8).count))
        XCTAssertEqual(vm.jpgCount, 0)
        XCTAssertEqual(vm.rawCount, 1)
        vm.applyFilter(.jpgOnly)
        XCTAssertTrue(vm.photos.isEmpty)
    }

    /// Existing behaviour, kept: a scan puts photos whose files it finds back into the library, bin
    /// included. (Listed under "Decisions for the user" in results/20.md.)
    func testScanRestoresBinnedPhotoWhoseFileExists() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("binned.jpg", in: photos)
        let (vm, _, _) = try await openLibrary(at: photos)
        vm.deletePhoto(try XCTUnwrap(vm.allPhotos.first))
        XCTAssertTrue(vm.allPhotos.isEmpty)
        XCTAssertEqual(vm.binCount, 1)

        try await rescan(vm)

        XCTAssertEqual(vm.allPhotos.map(\.fileName), ["binned"])
        XCTAssertEqual(vm.binCount, 0)
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

        XCTAssertEqual(Set(vm.allPhotos.map(\.fileName)), ["inside", "outside"])
    }

    func testScanOfMissingRootFolderHidesItsPhotos() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("a.jpg", in: photos)
        try makeJPEG("b.jpg", in: photos)
        let (vm, _, container) = try await openLibrary(at: photos)
        XCTAssertEqual(vm.allPhotos.count, 2)

        try FileManager.default.removeItem(at: photos) // like an unplugged drive
        try await rescan(vm)

        XCTAssertTrue(vm.allPhotos.isEmpty)
        XCTAssertEqual(try storedPhotos(container).count, 2, "rows are kept, only hidden")
    }

    func testRescanRequestedDuringScanRunsAfterIt() async throws {
        let photos = try makeTempDir("photos")
        try makeJPEG("first.jpg", in: photos)
        let (vm, _, container) = try await openLibrary(at: photos)

        vm.rescanCurrentLibrary()
        try makeJPEG("late.jpg", in: photos) // may or may not be seen by the running scan
        vm.rescanCurrentLibrary()              // but the queued one sees it
        try await waitForScan(vm)

        XCTAssertEqual(Set(vm.allPhotos.map(\.fileName)), ["first", "late"])
        XCTAssertEqual(try storedPhotos(container).count, 2)
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
            .init(id: changedSize.id, jpgPath: "/f/size.jpg", rawPath: nil, fileSize: 99, restoresFromBin: false),
            .init(id: lostJPG.id, jpgPath: nil, rawPath: "/f/pair.arw", fileSize: 10, restoresFromBin: false),
        ])
    }

    func testPlanRestoresBinnedRowsItFindsAndLeavesOthersInTheBin() {
        let binnedFound = stored("found", inBin: true)
        let binnedGone = stored("gone", inBin: true)
        let plan = ScanPlan(stored: [binnedFound, binnedGone], discovered: [found("found")],
                            fileExists: { _ in false })
        XCTAssertEqual(plan.updates.map(\.id), [binnedFound.id])
        XCTAssertEqual(plan.updates.first?.restoresFromBin, true)
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
        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(Set(try storedPhotos(container).map(\.fileName)), ["a", "c"])
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
