import XCTest
import SwiftData
@testable import Phocasa

/// Every folder the owner opens stays a library folder (a `PhotoLibrary` row each), and a rescan scans each of them.
/// "Open Folder…" used to overwrite the one root: earlier folders' photos stayed shown but were never scanned again,
/// so their new files never appeared (REL-5).
@MainActor
final class LibraryFolderTests: LibraryScanTestCase {
    /// Opens `folder` as "Open Folder…" does, and waits for its scan.
    private func open(_ folder: URL, in vm: PhotoLibraryViewModel) async throws {
        vm.library.handleFolderSelected(url: folder)
        XCTAssertTrue(vm.library.isScanning || vm.library.modelContext == nil)
        try await waitForScan(vm)
    }

    /// An empty library in a fresh store, as a first launch shows it.
    private func emptyLibrary(storeURL: URL? = nil) throws -> (PhotoLibraryViewModel, ModelContainer) {
        let container = try makeContainer(storeURL: storeURL)
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(container.mainContext)
        return (vm, container)
    }

    private func folderPaths(_ vm: PhotoLibraryViewModel) -> [String] {
        vm.library.libraryFolders.map(\.rootFolderPath)
    }

    // MARK: - Several folders

    /// A second folder opened doesn't replace the first: both are library folders, and Rescan scans both (new files
    /// appear in each, deleted ones go), in the store and in memory.
    func testEveryFolderOpenedStaysALibraryFolderAndIsRescanned() async throws {
        let first = try makeTempDir("first")
        let second = try makeTempDir("second")
        try makeJPEG("a.jpg", in: first)
        let gone = try makeJPEG("gone.jpg", in: first, taken: "2021:05:04 11:00:00")
        try makeJPEG("b.jpg", in: second)
        let (vm, container) = try emptyLibrary()

        try await open(first, in: vm)
        try await open(second, in: vm)
        XCTAssertEqual(folderPaths(vm), [first.path, second.path].sorted())
        XCTAssertEqual(try storedFolderPaths(container), [first.path, second.path].sorted())
        XCTAssertEqual(names(vm.library.allPhotos), ["a", "b", "gone"])

        try makeJPEG("new-in-first.jpg", in: first, taken: "2022:01:01 00:00:00")
        try makeJPEG("new-in-second.jpg", in: second, taken: "2022:01:01 00:00:01")
        try FileManager.default.removeItem(at: gone)
        try await rescan(vm)

        XCTAssertEqual(names(vm.library.allPhotos), ["a", "b", "new-in-first", "new-in-second"])
        XCTAssertEqual(try storedNames(container), ["a", "b", "gone", "new-in-first", "new-in-second"])
        XCTAssertNotNil(vm.library.libraryFolders.first?.lastScanDate)
        XCTAssertTrue(vm.library.libraryFolders.allSatisfy { $0.lastScanDate != nil })
        assertMatchesFreshLoad(vm, "a rescan of two folders")
    }

    /// Rescan queues every folder, and one asked for while the queue runs still runs: no request is dropped (it used to
    /// be "the latest folder wins"). A folder asked for again while it waits is scanned once.
    func testTheScanQueueRunsEveryFolderAskedForOnce() async throws {
        let folders = try ["one", "two", "three"].map { try makeTempDir($0) }
        for (i, folder) in folders.enumerated() { try makeJPEG("p\(i).jpg", in: folder) }
        let (vm, _) = try await openLibrary(folders: folders)
        var scanned: [String] = []
        vm.library.scanWillSave = { [unowned vm] _ in
            scanned.append(vm.library.scanProgress)
        }

        vm.library.rescanCurrentLibrary()
        vm.library.rescan(vm.library.libraryFolders[0]) // already waiting: joins it
        try makeJPEG("late.jpg", in: folders[1])
        vm.library.rescan(try XCTUnwrap(vm.library.libraryFolders.first { $0.rootFolderPath == folders[1].path }))
        try await waitForScan(vm)

        XCTAssertEqual(scanned.count, 3, "each folder once: \(scanned)")
        XCTAssertTrue(vm.library.allPhotos.contains { $0.fileName == "late" })
        XCTAssertEqual(vm.library.allPhotos.count, 4)
    }

    /// A folder inside a library folder isn't another one: opening it scans the library folder. A folder above library
    /// folders takes their place, and their photos keep their rows (their paths are inside it).
    func testNestedFoldersAreOneLibraryFolder() async throws {
        let parent = try makeTempDir("parent")
        let inner = try makeFolder(parent.appendingPathComponent("2024"))
        let other = try makeFolder(parent.appendingPathComponent("2025"))
        try makeJPEG("a.jpg", in: inner)
        try makeJPEG("b.jpg", in: try makeFolder(inner.appendingPathComponent("June")), taken: "2024:06:01 00:00:00")
        try makeJPEG("c.jpg", in: other, taken: "2025:01:01 00:00:00")
        try makeJPEG("top.jpg", in: parent, taken: "2020:01:01 00:00:00")
        let (vm, container) = try emptyLibrary()

        try await open(inner, in: vm)
        try await open(inner.appendingPathComponent("June"), in: vm)
        XCTAssertEqual(folderPaths(vm), [inner.path], "a folder inside a library folder isn't a second one")
        try await open(other, in: vm)
        XCTAssertEqual(folderPaths(vm), [inner.path, other.path])
        let ids = Set(vm.library.allPhotos.map(\.id))
        XCTAssertEqual(ids.count, 3)

        try await open(parent, in: vm)

        XCTAssertEqual(folderPaths(vm), [parent.path], "it takes the place of the folders inside it")
        XCTAssertEqual(try storedFolderPaths(container), [parent.path])
        XCTAssertEqual(names(vm.library.allPhotos), ["a", "b", "c", "top"])
        XCTAssertTrue(ids.isSubset(of: Set(vm.library.allPhotos.map(\.id))), "the same rows")
        XCTAssertEqual(try storedPhotos(container).count, 4)
        assertMatchesFreshLoad(vm, "a folder opened above two library folders")
    }

    /// The folder list survives a relaunch, and the launch rescans each folder.
    func testTheFolderListSurvivesARelaunch() async throws {
        let first = try makeTempDir("first")
        let second = try makeTempDir("second")
        try makeJPEG("a.jpg", in: first)
        try makeJPEG("b.jpg", in: second)
        let storeURL = try makeStoreURL()
        let (vm, _) = try emptyLibrary(storeURL: storeURL)
        try await open(first, in: vm)
        try await open(second, in: vm)
        try makeJPEG("while-closed.jpg", in: first, taken: "2023:03:03 03:03:03")

        for big in [false, true] {
            let relaunched = PhotoLibraryViewModel()
            if big { relaunched.library.loading.backgroundLoadThreshold = 0 }
            relaunched.setModelContext(try makeContainer(storeURL: storeURL).mainContext)
            await relaunched.library.waitForScans()

            XCTAssertEqual(folderPaths(relaunched), [first.path, second.path].sorted(), "big: \(big)")
            XCTAssertEqual(names(relaunched.library.allPhotos), ["a", "b", "while-closed"], "big: \(big)")
            XCTAssertTrue(relaunched.library.libraryFolders.allSatisfy { $0.bookmarkData != nil })
        }
    }

    /// A library folder whose drive isn't connected is skipped, and says so (in the sidebar and the status bar), while
    /// the others are still scanned.
    func testAFolderOnADriveThatIsNotConnectedIsSkippedAndTheOthersScan() async throws {
        let volumes = try makeTempDir("volumes")
        let drive = try makeFolder(volumes.appendingPathComponent("Photo Drive"))
        let onDrive = try makeFolder(drive.appendingPathComponent("2024"))
        try makeJPEG("drive.jpg", in: onDrive)
        let local = try makeTempDir("local")
        try makeJPEG("local.jpg", in: local, taken: "2021:05:04 11:00:00")
        let (vm, container) = try await openLibrary(folders: [onDrive, local])
        vm.library.volumes = VolumeCheck(volumesDirectory: volumes.path)
        let unplugged = try makeTempDir("unplugged").appendingPathComponent("Photo Drive")

        try FileManager.default.moveItem(at: drive, to: unplugged)
        try makeJPEG("new.jpg", in: local, taken: "2021:05:04 12:00:00")
        try await rescan(vm)

        let driveFolder = try XCTUnwrap(vm.library.libraryFolders.first { $0.rootFolderPath == onDrive.path })
        let localFolder = try XCTUnwrap(vm.library.libraryFolders.first { $0.rootFolderPath == local.path })
        let notConnected = LibraryStore.ScanIssue.folderNotConnected(path: onDrive.path, volume: "Photo Drive")
        XCTAssertEqual(vm.library.folderIssues[driveFolder.id], notConnected)
        XCTAssertNil(vm.library.folderIssues[localFolder.id])
        XCTAssertEqual(vm.library.scanIssue, notConnected, "the status bar still says so after the other folder's scan")
        XCTAssertEqual(names(vm.library.allPhotos), ["local", "new"], "the drive's photos are hidden meanwhile")
        XCTAssertEqual(try storedPhotos(container).count, 3)

        try FileManager.default.moveItem(at: unplugged, to: drive)
        try await rescan(vm)

        XCTAssertNil(vm.library.scanIssue)
        XCTAssertTrue(vm.library.folderIssues.isEmpty)
        XCTAssertEqual(names(vm.library.allPhotos), ["drive", "local", "new"])
        assertMatchesFreshLoad(vm, "the drive back")
    }

    /// A photo moved from one library folder into another keeps its row: the scan of the folder it's in now finds the
    /// row the other folder's scan found missing.
    func testAPhotoMovedBetweenLibraryFoldersKeepsItsRow() async throws {
        let first = try makeTempDir("first")
        let second = try makeTempDir("second")
        let moving = try makeJPEG("moving.jpg", in: first)
        try makeJPEG("b.jpg", in: second, taken: "2020:02:02 00:00:00")
        let (vm, container) = try await openLibrary(folders: [first, second])
        let photo = try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "moving" })
        vm.library.setRating(3, for: photo)
        await MetadataWriter.shared.flush()

        try FileManager.default.moveItem(at: moving, to: second.appendingPathComponent("moving.jpg"))
        try await rescan(vm)

        XCTAssertEqual(try storedPhotos(container).count, 2)
        XCTAssertEqual(photo.jpgPath, second.appendingPathComponent("moving.jpg").path)
        XCTAssertEqual(photo.rating, 3)
        XCTAssertEqual(names(vm.library.allPhotos), ["b", "moving"])
        assertMatchesFreshLoad(vm, "a photo moved between library folders")
    }

    // MARK: - Removing a folder

    /// Files a test might trash go into a temp folder, never the user's Trash.
    private func useTempTrash(_ vm: PhotoLibraryViewModel) throws {
        let trash = try makeTempDir("trash")
        vm.library.fileTrasher = FileTrasher { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
    }

    /// "Remove from Library…" takes the folder's photos (in the library, the bin, or missing) out of the store and
    /// memory, and the folder out of the list, and leaves every file as it was. The other folders are untouched.
    func testRemovingAFolderRemovesItsRowsAndNoFiles() async throws {
        let removed = try makeTempDir("removed")
        let kept = try makeTempDir("kept")
        let a = try makeJPEG("a.jpg", in: removed, rating: 2)
        let binned = try makeJPEG("binned.jpg", in: removed, taken: "2021:05:04 11:00:00")
        let raw = try makeRAW("binned.arw", in: removed)
        let gone = try makeJPEG("gone.jpg", in: removed, taken: "2021:05:04 12:00:00")
        try makeJPEG("k.jpg", in: kept, taken: "2021:05:04 13:00:00", keywords: ["people:Ann"])
        let (vm, container) = try await openLibrary(folders: [removed, kept])
        try useTempTrash(vm)
        vm.deletePhoto(try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "binned" }))
        try FileManager.default.removeItem(at: gone)
        try await rescan(vm) // "gone" is hidden as missing now
        XCTAssertEqual(vm.library.missingPhotoIDs.count, 1)
        let files = [a, binned, raw]
        let bytes = try files.map { try Data(contentsOf: $0) }
        let folder = try XCTUnwrap(vm.library.libraryFolders.first { $0.rootFolderPath == removed.path })
        vm.selection.selectedPhotos = Set(vm.library.allPhotos.map(\.id))

        vm.requestFolderRemoval(folder)
        let deadline = ContinuousClock.now + .seconds(10)
        while vm.pendingFolderRemoval == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let request = try XCTUnwrap(vm.pendingFolderRemoval)
        XCTAssertEqual(request.photoCount, 3, "the library's, the bin's and the missing one")
        await vm.confirmFolderRemoval(request)?.value
        await vm.library.waitForScans()

        XCTAssertEqual(folderPaths(vm), [kept.path])
        XCTAssertEqual(try storedFolderPaths(container), [kept.path])
        XCTAssertEqual(try storedNames(container), ["k"])
        XCTAssertEqual(names(vm.library.allPhotos), ["k"])
        XCTAssertTrue(vm.library.binPhotos.isEmpty)
        XCTAssertTrue(vm.library.missingPhotoIDs.isEmpty)
        XCTAssertEqual(vm.selection.selectedPhotos, Set(vm.library.allPhotos.map(\.id)), "the removed photos deselected")
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, bytes, "no file changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.appendingPathComponent("a.xmp").path))
        XCTAssertEqual(vm.library.tagCounts.values.reduce(0, +), 1)
        assertMatchesFreshLoad(vm, "a folder removed")

        // Its photos come back, as new photos, if it's opened again.
        try await open(removed, in: vm)
        XCTAssertEqual(names(vm.library.allPhotos), ["a", "binned", "k"])
    }

    /// A store holding a library folder inside another (opening folders never leaves one, but a store could): a rescan
    /// scans the outer one only, and removing the inner one leaves its photos, which are the outer one's too.
    func testAFolderInsideAnotherInTheStoreIsScannedOnceAndItsRemovalKeepsThePhotos() async throws {
        let root = try makeTempDir("root")
        let inner = try makeFolder(root.appendingPathComponent("inner"))
        try makeJPEG("a.jpg", in: inner)
        let (vm, container) = try await openLibrary(folders: [root, inner, inner])
        XCTAssertEqual(vm.library.libraryFolders.count, 3)
        var scans = 0
        vm.library.scanWillSave = { _ in scans += 1 }

        try await rescan(vm)
        XCTAssertEqual(scans, 1, "the outer folder only")

        let innerFolder = try XCTUnwrap(vm.library.libraryFolders.last)
        XCTAssertEqual(innerFolder.rootFolderPath, inner.path)
        _ = await vm.library.removeLibraryFolder(innerFolder)?.value
        await vm.library.waitForScans()

        XCTAssertEqual(try storedFolderPaths(container), [root.path, inner.path])
        XCTAssertEqual(try storedNames(container), ["a"], "the photos stay with the other folders")
        XCTAssertEqual(names(vm.library.allPhotos), ["a"])
    }

    /// Never while a scan runs: the removal isn't started, and nothing changes.
    func testAFolderIsNotRemovedWhileAScanRuns() async throws {
        let folder = try makeTempDir("photos")
        try makeJPEG("a.jpg", in: folder)
        let (vm, container) = try await openLibrary(folders: [folder])
        let library = try XCTUnwrap(vm.library.libraryFolders.first)

        vm.library.rescanCurrentLibrary()
        XCTAssertFalse(vm.library.canRemoveLibraryFolders)
        XCTAssertNil(vm.library.removeLibraryFolder(library))
        try await waitForScan(vm)

        XCTAssertEqual(folderPaths(vm), [folder.path])
        XCTAssertEqual(try storedNames(container), ["a"])
        XCTAssertTrue(vm.library.canRemoveLibraryFolders)
    }

    /// The detail view showing one of the folder's photos closes first: it must not go on showing (or saving an edit
    /// of) a removed photo.
    func testRemovingAFolderClosesTheDetailViewOnOneOfItsPhotos() async throws {
        let removed = try makeTempDir("removed")
        let kept = try makeTempDir("kept")
        try makeJPEG("a.jpg", in: removed)
        try makeJPEG("k.jpg", in: kept, taken: "2021:05:04 13:00:00")
        let (vm, _) = try await openLibrary(folders: [removed, kept])
        let a = try XCTUnwrap(vm.library.allPhotos.first { $0.fileName == "a" })
        vm.openDetail(for: a)
        XCTAssertTrue(vm.showingDetail)
        let folder = try XCTUnwrap(vm.library.libraryFolders.first { $0.rootFolderPath == removed.path })

        let request = FolderRemoval(folder: folder, name: "removed", path: removed.path, photoCount: 1)
        await vm.confirmFolderRemoval(request)?.value

        XCTAssertFalse(vm.showingDetail)
        XCTAssertNil(vm.selectedDetailPhoto)
        XCTAssertFalse(vm.selection.selectedPhotos.contains(a.id))
        XCTAssertEqual(names(vm.library.allPhotos), ["k"])
    }
}
