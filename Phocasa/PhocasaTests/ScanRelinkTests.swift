import XCTest
import SwiftData
@testable import Phocasa

/// A photo's identity is its path (`folderPath/stem`). Moving a folder, renaming the library's folder, or its drive
/// mounting under another name used to give every photo a new row and leave the old one hidden for ever, with the work
/// that lives only in the store: a JPG edit, the bin, tags and ratings not written to the file yet. A scan now relinks
/// the old row to the files it finds (`ScanPlan.relinks`).
@MainActor
final class ScanRelinkTests: LibraryScanTestCase {
    private func move(_ from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
    }

    private func photo(_ name: String, in vm: PhotoLibraryViewModel) throws -> PhotoAsset {
        try XCTUnwrap((vm.library.allPhotos + vm.library.binPhotos).first { $0.fileName == name }, name)
    }

    // MARK: - A folder moved inside the library folder

    /// The folder moved in Finder after the photos were rated and tagged (their files' sizes changed with the writes,
    /// so the stored size is stale): the same rows, at the new paths, with their rating and tags.
    func testFolderMovedInsideTheLibraryFolderKeepsItsRows() async throws {
        let root = try makeTempDir("photos")
        let trip = try makeFolder(root.appendingPathComponent("Trip"))
        try makeJPEG("a.jpg", in: trip, taken: "2021:05:04 10:00:00")
        try makeJPEG("b.jpg", in: trip, taken: "2021:05:04 10:00:01")
        try makeJPEG("stays.jpg", in: root)
        let (vm, container) = try await openLibrary(folders: [root])
        let a = try photo("a", in: vm)
        let b = try photo("b", in: vm)
        vm.library.setRating(4, for: a)
        vm.library.addTag(name: "Ann", category: "people", to: b)
        await MetadataWriter.shared.flush() // the writes must not race the move

        try move(trip, to: root.appendingPathComponent("2021/Trip"))
        try await rescan(vm)

        XCTAssertEqual(try storedNames(container), ["a", "b", "stays"], "no new rows")
        XCTAssertEqual(vm.library.lastScanReport?.inserted, 0)
        XCTAssertEqual(vm.library.lastScanReport?.relinked, 2)
        XCTAssertEqual(try photo("a", in: vm).id, a.id)
        XCTAssertEqual(a.rating, 4)
        XCTAssertEqual(b.tags.map(\.fullName), ["people:Ann"])
        XCTAssertEqual(a.jpgPath, root.appendingPathComponent("2021/Trip/a.jpg").path)
        XCTAssertEqual(a.folderPath, root.appendingPathComponent("2021/Trip").path)
        XCTAssertEqual(a.fileSize, try FileManager.default.attributesOfItem(atPath: a.jpgPath!)[.size] as? Int64)
        XCTAssertEqual(names(vm.library.allPhotos), ["a", "b", "stays"])
        XCTAssertEqual(vm.library.scanProgress, "Found 3 photos (0 new, 2 moved)")
        assertMatchesFreshLoad(vm, "a folder moved inside the library folder")
    }

    /// A JPG edit lives only in the store: it stays with the moved photo.
    func testJPGEditOfAMovedPhotoIsKept() async throws {
        let root = try makeTempDir("photos")
        let day = try makeFolder(root.appendingPathComponent("Day 1"))
        try makeJPEG("edited.jpg", in: day)
        let (vm, _) = try await openLibrary(folders: [root])
        let edited = try photo("edited", in: vm)
        var parameters = EditParameters()
        parameters.exposure = 1.5
        edited.jpgEditParameters = parameters
        try XCTUnwrap(vm.library.modelContext).save()

        try move(day, to: root.appendingPathComponent("Holiday/Day 1"))
        try await rescan(vm)

        let moved = try photo("edited", in: vm)
        XCTAssertEqual(moved.id, edited.id)
        XCTAssertEqual(moved.jpgEditParameters?.exposure, 1.5)
        XCTAssertTrue(moved.hasAnyEdits)
    }

    /// A photo in the bin that moves stays in the bin (a scan never takes a photo out of it), at its new paths.
    func testBinnedPhotoThatMovedStaysInTheBin() async throws {
        let root = try makeTempDir("photos")
        let old = try makeFolder(root.appendingPathComponent("Old"))
        try makeJPEG("binned.jpg", in: old)
        try makeRAW("binned.arw", in: old)
        try makeJPEG("kept.jpg", in: old, taken: "2021:05:04 11:00:00")
        let (vm, container) = try await openLibrary(folders: [root])
        vm.deletePhoto(try photo("binned", in: vm))
        XCTAssertEqual(vm.library.binPhotos.map(\.fileName), ["binned"])

        try move(old, to: root.appendingPathComponent("New"))
        try await rescan(vm)

        XCTAssertEqual(try storedNames(container), ["binned", "kept"])
        XCTAssertEqual(try storedBinNames(container), ["binned"])
        XCTAssertEqual(vm.library.binPhotos.map(\.fileName), ["binned"])
        XCTAssertEqual(vm.library.allPhotos.map(\.fileName), ["kept"])
        let binned = try photo("binned", in: vm)
        XCTAssertEqual(binned.rawPath, root.appendingPathComponent("New/binned.arw").path)
        XCTAssertEqual(binned.jpgPath, root.appendingPathComponent("New/binned.jpg").path)
        assertMatchesFreshLoad(vm, "a binned photo moved")
        vm.library.applyFilter(.bin)
        assertMatchesFreshLoad(vm, "the bin shown")
    }

    /// A folder moved out of the library folder (its photos hidden as missing) and later moved back in somewhere else:
    /// the hidden rows come back, relinked, rather than new rows beside them.
    func testHiddenPhotosThatComeBackElsewhereAreRelinkedAndShownAgain() async throws {
        let root = try makeTempDir("photos")
        let trip = try makeFolder(root.appendingPathComponent("Trip"))
        try makeJPEG("a.jpg", in: trip, taken: "2020:01:01 09:00:00")
        try makeJPEG("b.jpg", in: trip, taken: "2020:01:01 09:00:01")
        let (vm, container) = try await openLibrary(folders: [root])
        let a = try photo("a", in: vm)
        vm.library.setRating(5, for: a)
        await MetadataWriter.shared.flush()
        let parked = try makeTempDir("parked").appendingPathComponent("Trip")

        try move(trip, to: parked)
        try await rescan(vm)
        XCTAssertTrue(vm.library.allPhotos.isEmpty, "hidden while their files are elsewhere")

        try move(parked, to: root.appendingPathComponent("Sorted/Trip"))
        try await rescan(vm)

        XCTAssertEqual(try storedNames(container), ["a", "b"])
        XCTAssertEqual(names(vm.library.allPhotos), ["a", "b"])
        XCTAssertEqual(try photo("a", in: vm).id, a.id)
        XCTAssertEqual(a.rating, 5)
        XCTAssertTrue(vm.library.missingPhotoIDs.isEmpty)
        assertMatchesFreshLoad(vm, "hidden photos back elsewhere")
    }

    // MARK: - The library folder itself moved

    /// The library's folder renamed in Finder: its bookmark finds it, and every photo keeps its row, matched by its path
    /// inside the folder (even lookalikes, and photos without a capture date, which the content match can't tell apart).
    func testRenamedLibraryFolderIsFollowedAndItsPhotosKeepTheirRows() async throws {
        let parent = try makeTempDir("parent")
        let root = try makeFolder(parent.appendingPathComponent("Pictures"))
        for folder in ["100CANON", "101CANON"] {
            let dir = try makeFolder(root.appendingPathComponent("DCIM/\(folder)"))
            try makeJPEG("IMG_0001.jpg", in: dir, taken: "2019:07:07 07:07:07") // lookalikes
        }
        try makeJPEG("undated.jpg", in: root, taken: nil)
        let (vm, container) = try await openLibrary(folders: [root], bookmarks: true)
        XCTAssertEqual(vm.library.allPhotos.count, 3)
        let ids = Set(vm.library.allPhotos.map(\.id))
        let undated = try photo("undated", in: vm)
        vm.library.setRating(2, for: undated)
        await MetadataWriter.shared.flush()

        let renamed = parent.appendingPathComponent("Photos")
        try FileManager.default.moveItem(at: root, to: renamed)
        try await rescan(vm)

        XCTAssertNil(vm.library.scanIssue)
        XCTAssertEqual(try storedPhotos(container).count, 3, "no new rows")
        XCTAssertEqual(Set(vm.library.allPhotos.map(\.id)), ids)
        XCTAssertEqual(vm.library.lastScanReport?.relinked, 3)
        XCTAssertEqual(undated.rating, 2)
        XCTAssertEqual(undated.jpgPath, renamed.appendingPathComponent("undated.jpg").path)
        XCTAssertEqual(try storedFolderPaths(container), [renamed.path], "the library folder follows it")
        assertMatchesFreshLoad(vm, "the library folder renamed")

        var pendingBeforeSave: Bool?
        vm.library.scanWillSave = { pendingBeforeSave = $0.hasChanges }
        try await rescan(vm)
        XCTAssertEqual(pendingBeforeSave, false, "the next, unchanged rescan writes nothing")
        XCTAssertEqual(vm.library.lastScanReport?.relinked, 0)
        XCTAssertEqual(vm.library.lastScanReport?.updated, 0)
    }

    /// A drive that comes back as `/Volumes/Photos 1` (macOS adds the number when the name is taken): its bookmark finds
    /// it on Rescan, and the photos keep their rows.
    func testDriveMountedUnderAnotherNameIsFollowedOnRescan() async throws {
        let volumes = try makeTempDir("volumes")
        let drive = try makeFolder(volumes.appendingPathComponent("Photo Drive"))
        let root = try makeFolder(drive.appendingPathComponent("2024"))
        try makeJPEG("a.jpg", in: root)
        try makeRAW("a.arw", in: root)
        let (vm, container) = try await openLibrary(folders: [root], bookmarks: true)
        vm.library.volumes = VolumeCheck(volumesDirectory: volumes.path)
        let a = try photo("a", in: vm)

        let remounted = volumes.appendingPathComponent("Photo Drive 1")
        try FileManager.default.moveItem(at: drive, to: remounted)
        try await rescan(vm)

        XCTAssertNil(vm.library.scanIssue)
        XCTAssertEqual(try storedPhotos(container).count, 1)
        XCTAssertEqual(try photo("a", in: vm).id, a.id)
        XCTAssertEqual(a.rawPath, remounted.appendingPathComponent("2024/a.arw").path)
        XCTAssertEqual(try storedFolderPaths(container), [remounted.appendingPathComponent("2024").path])
    }

    /// The same, when the library's bookmark can't find the drive: it says the drive isn't connected, and choosing the
    /// folder at its new mount with Open Folder moves the library folder there, keeping every row.
    func testDriveMountedUnderAnotherNameIsFoundWhenTheFolderIsOpenedThere() async throws {
        let volumes = try makeTempDir("volumes")
        let drive = try makeFolder(volumes.appendingPathComponent("Photo Drive"))
        let root = try makeFolder(drive.appendingPathComponent("2024"))
        try makeJPEG("a.jpg", in: root)
        try makeJPEG("b.jpg", in: root, taken: nil)
        let (vm, container) = try await openLibrary(folders: [root], bookmarks: false)
        vm.library.volumes = VolumeCheck(volumesDirectory: volumes.path)
        let ids = Set(vm.library.allPhotos.map(\.id))

        let remounted = volumes.appendingPathComponent("Photo Drive 1")
        try FileManager.default.moveItem(at: drive, to: remounted)
        try await rescan(vm)
        XCTAssertEqual(vm.library.scanIssue, .folderNotConnected(path: root.path, volume: "Photo Drive"))

        vm.library.handleFolderSelected(url: remounted.appendingPathComponent("2024"))
        try await waitForScan(vm)

        XCTAssertNil(vm.library.scanIssue)
        XCTAssertEqual(try storedPhotos(container).count, 2, "no new rows")
        XCTAssertEqual(Set(vm.library.allPhotos.map(\.id)), ids)
        XCTAssertEqual(try storedFolderPaths(container), [remounted.appendingPathComponent("2024").path],
                       "the same library folder, at the new mount")
        assertMatchesFreshLoad(vm, "the drive's folder opened at its new mount")
    }

    // MARK: - What isn't relinked

    /// Two photos that look the same (same name, size and capture date), both moved: which row is which can't be told,
    /// so neither is relinked. They're new photos, and the old rows stay hidden (nothing is guessed).
    func testLookalikesThatBothMovedAreNotRelinked() async throws {
        let root = try makeTempDir("photos")
        for folder in ["A", "B"] {
            try makeJPEG("x.jpg", in: try makeFolder(root.appendingPathComponent(folder)), taken: "2022:02:02 02:02:02")
        }
        let (vm, container) = try await openLibrary(folders: [root])
        let old = Set(vm.library.allPhotos.map(\.id))
        XCTAssertEqual(old.count, 2)

        try move(root.appendingPathComponent("A"), to: root.appendingPathComponent("C"))
        try move(root.appendingPathComponent("B"), to: root.appendingPathComponent("D"))
        try await rescan(vm)

        XCTAssertEqual(vm.library.lastScanReport?.relinked, 0)
        XCTAssertEqual(vm.library.lastScanReport?.inserted, 2)
        XCTAssertEqual(try storedPhotos(container).count, 4)
        XCTAssertTrue(Set(vm.library.allPhotos.map(\.id)).isDisjoint(with: old), "the old rows stay hidden")
        XCTAssertEqual(vm.library.missingPhotoIDs, old)
    }

    /// One photo moved and also copied: two new photos match its row, so it isn't relinked to either.
    func testMovedPhotoWithACopyIsNotRelinked() async throws {
        let root = try makeTempDir("photos")
        let a = try makeFolder(root.appendingPathComponent("A"))
        try makeJPEG("x.jpg", in: a)
        let (vm, _) = try await openLibrary(folders: [root])
        let original = try photo("x", in: vm)

        try FileManager.default.copyItem(at: a, to: root.appendingPathComponent("Copy"))
        try move(a, to: root.appendingPathComponent("Moved"))
        try await rescan(vm)

        XCTAssertEqual(vm.library.lastScanReport?.relinked, 0)
        XCTAssertEqual(vm.library.allPhotos.count, 2)
        XCTAssertFalse(vm.library.allPhotos.contains { $0.id == original.id })
    }

    /// A photo whose files are still there isn't another photo's old row, even with the same name and capture date: a
    /// copy is a photo of its own.
    func testACopyBesideTheOriginalIsANewPhoto() async throws {
        let root = try makeTempDir("photos")
        let a = try makeFolder(root.appendingPathComponent("A"))
        try makeJPEG("x.jpg", in: a)
        let (vm, container) = try await openLibrary(folders: [root])
        let original = try photo("x", in: vm)

        try FileManager.default.copyItem(at: a, to: root.appendingPathComponent("B"))
        try await rescan(vm)

        XCTAssertEqual(vm.library.lastScanReport?.relinked, 0)
        XCTAssertEqual(try storedPhotos(container).count, 2)
        XCTAssertEqual(original.jpgPath, a.appendingPathComponent("x.jpg").path)
    }

    // MARK: - The plan (pure)

    private func found(_ name: String, folder: String, jpg: Bool = true, raw: Bool = false, size: Int64 = 10,
                       taken: Date? = nil, created: Date? = nil, read: Bool = true) -> DiscoveredPhoto {
        DiscoveredPhoto(
            fileName: name, jpgPath: jpg ? "\(folder)/\(name).jpg" : nil, rawPath: raw ? "\(folder)/\(name).arw" : nil,
            folderPath: folder, fileSize: size, creationDate: created,
            metadata: read ? MetadataService.PhotoMetadata(rating: 0, keywords: [], captureDate: taken) : nil
        )
    }

    private func stored(_ name: String, folder: String, jpg: Bool = true, raw: Bool = false, size: Int64 = 10,
                        inBin: Bool = false, taken: Date? = nil, created: Date? = nil) -> StoredPhoto {
        StoredPhoto(id: UUID(), key: DiscoveredPhoto.key(folderPath: folder, fileName: name),
                    jpgPath: jpg ? "\(folder)/\(name).jpg" : nil, rawPath: raw ? "\(folder)/\(name).arw" : nil,
                    fileSize: size, isInBin: inBin, captureDate: taken, creationDate: created)
    }

    private let noon = Date(timeIntervalSince1970: 1_600_000_000)

    /// The library folder moved: new photos are the rows at the same paths inside the old folder, whatever their
    /// dates or sizes, and those rows aren't missing. Rows whose files are still there aren't relinked.
    func testPlanRelinksByPathInsideAMovedLibraryFolder() {
        let a = stored("IMG_1", folder: "/Volumes/Photos/2024/100", raw: true)
        let b = stored("IMG_1", folder: "/Volumes/Photos/2024/101", size: 99)
        let stillThere = stored("kept", folder: "/Volumes/Photos/2024")
        var plan = ScanPlan(
            stored: [a, b, stillThere],
            discovered: [found("IMG_1", folder: "/Volumes/Photos 1/2024/100", raw: true, read: false),
                         found("IMG_1", folder: "/Volumes/Photos 1/2024/101", size: 12, read: false),
                         found("kept", folder: "/Volumes/Photos 1/2024", read: false)],
            previouslyMissing: [b.id], root: "/Volumes/Photos 1/2024", movedFrom: "/Volumes/Photos/2024",
            fileExists: { $0.hasPrefix("/Volumes/Photos/2024/kept") })
        XCTAssertEqual(Set(plan.relinks.map(\.id)), [a.id, b.id])
        XCTAssertEqual(plan.relinks.first { $0.id == a.id },
                       ScanPlan.Relink(id: a.id, to: found("IMG_1", folder: "/Volumes/Photos 1/2024/100", raw: true)))
        XCTAssertEqual(plan.newPhotos.map(\.folderPath), ["/Volumes/Photos 1/2024"], "kept's row still has its file")
        XCTAssertTrue(plan.missingIDs.isEmpty)
        XCTAssertEqual(plan.foundAgainIDs, [b.id], "a hidden row relinked is shown again")
        plan.relinkMovedPhotos(fileExists: { _ in false })
        XCTAssertEqual(plan.relinks.count, 2, "nothing more to match")
    }

    /// A photo found elsewhere is a stored row whose files are gone when the file names and the capture date agree;
    /// the size needn't (a rating written into the file changes it).
    func testPlanRelinksByFilesAndCaptureDate() {
        let row = stored("trip", folder: "/r/Old", raw: true, size: 100, taken: noon)
        let otherDate = stored("other", folder: "/r/Old", taken: noon)
        var plan = ScanPlan(stored: [row, otherDate],
                            discovered: [found("trip", folder: "/r/New", raw: true, size: 140, taken: noon),
                                         found("other", folder: "/r/New", taken: noon.addingTimeInterval(1))],
                            root: "/r", fileExists: { _ in false })
        XCTAssertEqual(plan.missingIDs, [row.id, otherDate.id])
        plan.relinkMovedPhotos(fileExists: { _ in false })
        XCTAssertEqual(plan.relinks, [ScanPlan.Relink(id: row.id, to: found("trip", folder: "/r/New", raw: true,
                                                                              size: 140))])
        XCTAssertEqual(plan.newPhotos.map(\.fileName), ["other"], "a different capture date is another photo")
        XCTAssertEqual(plan.missingIDs, [otherDate.id])
    }

    /// The file names must agree: a JPG+RAW pair isn't its JPG alone, nor a file with another extension.
    func testPlanRelinksOnlyTheSameFileNames() {
        let pair = stored("p", folder: "/r/Old", raw: true, taken: noon)
        let jpeg = stored("q", folder: "/r/Old", taken: noon)
        var plan = ScanPlan(stored: [pair, jpeg],
                            discovered: [found("p", folder: "/r/New", taken: noon),
                                         DiscoveredPhoto(fileName: "q", jpgPath: "/r/New/q.jpeg", rawPath: nil,
                                                         folderPath: "/r/New", fileSize: 10, creationDate: nil,
                                                         metadata: .init(rating: 0, keywords: [], captureDate: noon))],
                            root: "/r", fileExists: { _ in false })
        plan.relinkMovedPhotos(fileExists: { _ in false })
        XCTAssertTrue(plan.relinks.isEmpty)
        XCTAssertEqual(plan.newPhotos.count, 2)
    }

    /// A row stored without a capture date (not read yet, or the file has none) needs the same size and file creation
    /// date instead.
    func testPlanRelinksARowWithoutACaptureDateBySizeAndCreationDate() {
        let undated = stored("scan", folder: "/r/Old", size: 50, created: noon)
        let neverRead = stored("old", folder: "/r/Old", size: 60, created: noon)
        let resized = stored("resized", folder: "/r/Old", size: 70, created: noon)
        let noDates = stored("nodates", folder: "/r/Old", size: 80)
        var plan = ScanPlan(stored: [undated, neverRead, resized, noDates],
                            discovered: [found("scan", folder: "/r/New", size: 50, created: noon),
                                         found("old", folder: "/r/New", size: 60, taken: noon, created: noon),
                                         found("resized", folder: "/r/New", size: 71, created: noon),
                                         found("nodates", folder: "/r/New", size: 80)],
                            root: "/r", fileExists: { _ in false })
        plan.relinkMovedPhotos(fileExists: { _ in false })
        XCTAssertEqual(Set(plan.relinks.map(\.id)), [undated.id, neverRead.id])
        XCTAssertEqual(plan.newPhotos.map(\.fileName).sorted(), ["nodates", "resized"])
    }

    /// Only one-to-one matches relink: two missing rows for one new photo, or two new photos for one row, relink
    /// nothing. A lookalike whose files are still there doesn't count.
    func testPlanDoesNotRelinkAmbiguousMatches() {
        let twinA = stored("x", folder: "/r/A", taken: noon)
        let twinB = stored("x", folder: "/r/B", taken: noon)
        let single = stored("y", folder: "/r/A", taken: noon)
        let original = stored("z", folder: "/r/A", taken: noon)
        let movedCopy = stored("z", folder: "/r/B", taken: noon)
        var plan = ScanPlan(stored: [twinA, twinB, single, original, movedCopy],
                            discovered: [found("x", folder: "/r/C", taken: noon),
                                         found("y", folder: "/r/C", taken: noon),
                                         found("y", folder: "/r/D", taken: noon),
                                         found("z", folder: "/r/A", taken: noon),
                                         found("z", folder: "/r/C", taken: noon)],
                            root: "/r", fileExists: { $0 == "/r/A/z.jpg" })
        plan.relinkMovedPhotos(fileExists: { $0 == "/r/A/z.jpg" })
        XCTAssertEqual(plan.relinks.map(\.id), [movedCopy.id], "z's original is still there, so C's z is B's")
        XCTAssertEqual(plan.newPhotos.map(\.folderPath).sorted(), ["/r/C", "/r/C", "/r/D"])
        XCTAssertEqual(plan.missingIDs, [twinA.id, twinB.id, single.id])
    }

    /// Rows anywhere can be the moved photo: in the bin (it stays there), under another library folder, or hidden.
    func testPlanRelinksRowsInTheBinAndUnderOtherLibraryFolders() {
        let binned = stored("b", folder: "/other/Old", inBin: true, taken: noon)
        let hidden = stored("h", folder: "/other/Old", taken: noon)
        var plan = ScanPlan(stored: [binned, hidden],
                            discovered: [found("b", folder: "/r/New", taken: noon),
                                         found("h", folder: "/r/New", taken: noon)],
                            previouslyMissing: [hidden.id], root: "/r", otherRoots: ["/other"],
                            fileExists: { _ in false })
        XCTAssertEqual(plan.missingSet(after: [hidden.id]), [hidden.id], "another folder's rows aren't checked")
        plan.relinkMovedPhotos(fileExists: { _ in false })
        XCTAssertEqual(Set(plan.relinks.map(\.id)), [binned.id, hidden.id])
        XCTAssertEqual(plan.foundAgainIDs, [hidden.id], "not the binned one: the bin keeps it")
        XCTAssertEqual(plan.missingSet(after: [hidden.id]), [])
    }

    /// A scan checks only its own library folder's rows (and rows under no library folder): the other folders' rows
    /// aren't statted, and stay missing or not as they were. An unchanged rescan stats nothing.
    func testPlanChecksOnlyItsOwnFoldersRows() {
        let here = stored("here", folder: "/r")
        let goneHere = stored("gone", folder: "/r/sub")
        let other = stored("other", folder: "/s")
        let otherHidden = stored("otherHidden", folder: "/s/x")
        let orphan = stored("orphan", folder: "/old")
        var statted: [String] = []
        let plan = ScanPlan(stored: [here, goneHere, other, otherHidden, orphan],
                            discovered: [found("here", folder: "/r")],
                            previouslyMissing: [otherHidden.id], root: "/r", otherRoots: ["/s"],
                            fileExists: { statted.append($0); return false })
        XCTAssertEqual(Set(statted), ["/r/sub/gone.jpg", "/old/orphan.jpg"])
        XCTAssertEqual(plan.missingIDs, [goneHere.id, orphan.id])
        XCTAssertTrue(plan.foundAgainIDs.isEmpty)
        XCTAssertEqual(plan.missingSet(after: [otherHidden.id]), [goneHere.id, orphan.id, otherHidden.id])

        statted = []
        var unchanged = ScanPlan(stored: [here, other], discovered: [found("here", folder: "/r")], root: "/r",
                                 otherRoots: ["/s"], fileExists: { statted.append($0); return true })
        unchanged.relinkMovedPhotos(fileExists: { statted.append($0); return true })
        XCTAssertEqual(statted, [])
        XCTAssertTrue(unchanged.updates.isEmpty && unchanged.relinks.isEmpty && unchanged.newPhotos.isEmpty)
    }

    /// The volume names macOS gives a drive whose name is taken.
    func testSameFolderOnARenamedVolume() {
        let volumes = VolumeCheck(volumesDirectory: "/Volumes")
        XCTAssertTrue(volumes.isSameFolderOnRenamedVolume("/Volumes/Photos 1/2024", as: "/Volumes/Photos/2024"))
        XCTAssertTrue(volumes.isSameFolderOnRenamedVolume("/Volumes/Photos/2024", as: "/Volumes/Photos 2/2024"))
        XCTAssertTrue(volumes.isSameFolderOnRenamedVolume("/Volumes/Photos 1", as: "/Volumes/Photos"))
        XCTAssertFalse(volumes.isSameFolderOnRenamedVolume("/Volumes/Photos/2024", as: "/Volumes/Photos/2024"))
        XCTAssertFalse(volumes.isSameFolderOnRenamedVolume("/Volumes/Photos 1/2023", as: "/Volumes/Photos/2024"))
        XCTAssertFalse(volumes.isSameFolderOnRenamedVolume("/Volumes/Backup/2024", as: "/Volumes/Photos/2024"))
        XCTAssertFalse(volumes.isSameFolderOnRenamedVolume("/Volumes/Photos 1a/2024", as: "/Volumes/Photos/2024"))
        XCTAssertFalse(volumes.isSameFolderOnRenamedVolume("/Users/me/2024", as: "/Volumes/Photos/2024"))
    }

    // MARK: - New photos

    /// A RAW whose sidecar holds a saved Phocasa edit (from another library, or a row that couldn't be relinked) is
    /// marked edited when it's added, so the detail view shows the edit.
    func testNewRAWWithASavedEditInItsSidecarIsMarkedEdited() async throws {
        let root = try makeTempDir("photos")
        let raw = try makeRAW("edited.arw", in: root)
        try makeRAW("plain.arw", in: root)
        var parameters = EditParameters()
        parameters.contrast = 20
        MetadataService.shared.writeSidecar(rating: 0, keywords: [], for: raw, editParameters: parameters)
        try makeJPEG("pair.jpg", in: root)
        let pairRAW = try makeRAW("pair.arw", in: root)
        MetadataService.shared.writeSidecar(rating: 0, keywords: [], for: pairRAW, editParameters: parameters)

        let (vm, _) = try await openLibrary(folders: [root])

        XCTAssertTrue(try photo("edited", in: vm).hasRawEdits)
        XCTAssertTrue(try photo("pair", in: vm).hasRawEdits)
        XCTAssertFalse(try photo("plain", in: vm).hasRawEdits)
    }
}
