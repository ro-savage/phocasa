import XCTest
import SwiftData
@testable import Phocasa

/// Deletes move files to the Trash on `FileTrasher`, off the main actor, and change the store afterwards (spec §G5).
/// Every test uses temp files and a trash that moves them into a temp folder: never the user's Trash.
@MainActor
final class FileTrasherTests: LibraryTestCase {

    /// The files trashed so far, recorded from the trasher's queue.
    private final class TrashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var count: Int { lock.withLock { urls.count } }
        var names: [String] { lock.withLock { urls.map(\.lastPathComponent) } }
        func append(_ url: URL) { lock.withLock { urls.append(url) } }
    }

    private var log: TrashLog!
    private var photosDir: URL!
    private var trashDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        log = TrashLog()
        photosDir = try makeTempDir()
        trashDir = try makeTempDir()
    }

    /// A trash that moves each file into `trashDir`, taking `delay` a file as a real `trashItem` can.
    private func useTestTrash(delay: TimeInterval = 0) {
        let log = self.log!
        let trashDir = self.trashDir!
        library.fileTrasher = FileTrasher { url in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
            log.append(url)
        }
    }

    /// A real (tiny) file in the photos folder.
    private func makeFile(_ name: String) throws -> String {
        let url = photosDir.appendingPathComponent(name)
        try Data([0xFF, 0xD8]).write(to: url)
        return url.path
    }

    /// A photo whose files are real temp files, saved once.
    @discardableResult
    private func insertPhoto(_ name: String, raw: Bool = false, sidecar: Bool = false,
                             inBin: Bool = false) throws -> PhotoAsset {
        let photo = PhotoAsset(fileName: name, jpgPath: try makeFile(name + ".jpg"),
                               rawPath: raw ? try makeFile(name + ".arw") : nil, folderPath: photosDir.path,
                               creationDate: Date(), fileSize: 2)
        if sidecar { _ = try makeFile(name + ".xmp") }
        photo.isInBin = inBin
        context.insert(photo)
        try context.save()
        return photo
    }

    private func filesLeft() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: photosDir.path))
    }

    // MARK: - Permanent delete

    /// Emptying a bin of 200 photos: the main actor runs other work while the files are trashed, the status bar shows
    /// the progress, and the store changes only once every file is in the Trash.
    func testTrashingTwoHundredFilesLeavesTheMainActorFree() async throws {
        let photos = try (0..<200).map { try insertPhoto("p\($0)", inBin: true) }
        library.loadExistingData()
        XCTAssertEqual(library.binCount, 200)
        useTestTrash(delay: 0.002)

        let deleting = Task { await library.deletePermanently(photos) }
        // Scheduled while the files are being trashed: it must run before the trashing ends.
        let midway = Task { @MainActor () -> (trashed: Int, progress: LibraryStore.TrashProgress?, binCount: Int) in
            while log.count == 0 { try? await Task.sleep(for: .milliseconds(1)) }
            return (log.count, library.trashProgress, library.binCount)
        }
        let seen = await midway.value
        await deleting.value

        XCTAssertLessThan(seen.trashed, 200, "a main-actor task ran while the files were being trashed")
        XCTAssertEqual(seen.progress?.total, 200, "more than 20 files: the status bar shows the progress")
        XCTAssertEqual(seen.binCount, 200, "the store changes after the files are in the Trash")
        XCTAssertEqual(log.count, 200)
        XCTAssertEqual(try filesLeft(), [])
        XCTAssertNil(library.trashProgress)
        XCTAssertEqual(library.binCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoAsset>()).count, 0)
    }

    func testPermanentDeleteTrashesJPGRAWAndSidecar() async throws {
        let photo = try insertPhoto("pair", raw: true, sidecar: true, inBin: true)
        _ = try makeFile("other.jpg")
        library.loadExistingData()
        useTestTrash()

        await library.deletePermanently([photo])

        XCTAssertEqual(Set(log.names), ["pair.jpg", "pair.arw", "pair.xmp"])
        XCTAssertEqual(try filesLeft(), ["other.jpg"])
        XCTAssertNil(library.trashProgress, "3 files: no progress shown")
        XCTAssertEqual(library.binCount, 0)
    }

    /// A second delete of photos whose delete is still running does nothing: they are deleted once.
    func testDeletingPhotosAlreadyBeingDeletedDoesNothing() async throws {
        let photos = try (0..<5).map { try insertPhoto("p\($0)", inBin: true) }
        library.loadExistingData()
        useTestTrash(delay: 0.01)

        let first = Task { await library.deletePermanently(photos) }
        let second = Task { await library.deletePermanently(photos) }
        await first.value
        await second.value

        XCTAssertEqual(log.count, 5, "each file trashed once")
        XCTAssertEqual(library.binCount, 0)
        XCTAssertTrue(library.photosBeingDeleted.isEmpty)
    }

    // MARK: - Files that can't be moved

    /// Makes the file at `path` locked (Finder's "Locked", the user-immutable flag), unlocked again at tear-down so the
    /// temp folder can be removed.
    private func lock(_ path: String) throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
    }

    /// A RAW that can't be moved keeps its sidecar: the `.xmp` holds its rating, keywords and edits, so it goes to the
    /// Trash only once the RAW has (it used to be trashed in the same batch, and left behind a RAW with nothing).
    func testAPermanentDeleteKeepsTheSidecarOfARAWThatCouldNotBeMoved() async throws {
        let stuck = try insertPhoto("stuck", raw: true, sidecar: true, inBin: true)
        let free = try insertPhoto("free", raw: true, sidecar: true, inBin: true)
        try lock(try XCTUnwrap(stuck.rawPath))
        library.loadExistingData()
        useTestTrash()

        await library.deletePermanently([stuck, free])

        XCTAssertEqual(Set(log.names), ["stuck.jpg", "free.jpg", "free.arw", "free.xmp"])
        XCTAssertEqual(try filesLeft(), ["stuck.arw", "stuck.xmp"], "the RAW that stayed keeps its sidecar")
        XCTAssertEqual(library.binPhotos.map(\.id), [stuck.id])
    }

    func testDeletingTheRAWsKeepsTheSidecarOfARAWThatCouldNotBeMoved() async throws {
        let stuck = try insertPhoto("stuck", raw: true, sidecar: true)
        let free = try insertPhoto("free", raw: true, sidecar: true)
        try lock(try XCTUnwrap(stuck.rawPath))
        library.loadExistingData()
        useTestTrash()

        await library.deleteFileType(of: [stuck, free], raw: true, jpg: false)

        XCTAssertEqual(Set(log.names), ["free.arw", "free.xmp"])
        XCTAssertEqual(try filesLeft(), ["stuck.jpg", "stuck.arw", "stuck.xmp", "free.jpg"])
        XCTAssertNotNil(stuck.rawPath, "the pair keeps the RAW it couldn't move")
        XCTAssertNil(free.rawPath)
    }

    /// Each file gets its own outcome: moved, already gone (its volume is there), on a volume that isn't mounted (it may
    /// well still be there), or there but not movable (locked, in a read-only folder), with the reason.
    func testTrasherReportsWhatHappenedToEachFile() async throws {
        let volumes = try makeTempDir()
        let drive = volumes.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let movable = drive.appendingPathComponent("a.jpg")
        try Data([1]).write(to: movable)
        let locked = drive.appendingPathComponent("locked.jpg")
        try Data([1]).write(to: locked)
        try lock(locked.path)
        let readOnlyFolder = drive.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyFolder, withIntermediateDirectories: true)
        let inReadOnly = readOnlyFolder.appendingPathComponent("b.jpg")
        try Data([1]).write(to: inReadOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyFolder.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyFolder.path)
        }
        let gone = drive.appendingPathComponent("gone.jpg")
        let unplugged = volumes.appendingPathComponent("Unplugged/c.jpg")
        let trashDir = self.trashDir!
        let trasher = FileTrasher(trashItem: { url in
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
        }, volumes: VolumeCheck(volumesDirectory: volumes.path))

        let outcomes = await trasher.trash([movable, locked, inReadOnly, gone, unplugged])

        XCTAssertEqual(outcomes.count, 5)
        XCTAssertEqual(outcomes.first, .trashed)
        guard case .failed(let reason) = outcomes[1] else { return XCTFail("locked: \(outcomes[1])") }
        XCTAssertFalse(reason.isEmpty)
        guard case .failed = outcomes[2] else { return XCTFail("read-only folder: \(outcomes[2])") }
        XCTAssertEqual(outcomes[3], .alreadyGone)
        XCTAssertEqual(outcomes[4], .volumeUnavailable(name: "Unplugged"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inReadOnly.path))
    }

    /// Emptying the bin with a locked file: that photo stays in the bin, in the store and in memory, the others go, and
    /// the owner is told how many couldn't be moved and why. (It used to be deleted from the store anyway, and the next
    /// scan brought it back as a new photo, out of the bin.)
    func testPermanentDeleteKeepsPhotosWhoseFilesCouldNotBeMoved() async throws {
        let kept = try insertPhoto("locked", inBin: true)
        let deleted = try insertPhoto("free", inBin: true)
        try lock(try XCTUnwrap(kept.jpgPath))
        library.loadExistingData()
        library.viewingBin = true
        library.refreshVisiblePhotos()
        useTestTrash()

        await library.deletePermanently([kept, deleted])

        XCTAssertEqual(log.names, ["free.jpg"])
        XCTAssertEqual(try filesLeft(), ["locked.jpg"])
        XCTAssertEqual(library.binPhotos.map(\.id), [kept.id])
        XCTAssertEqual(library.photos.map(\.id), [kept.id])
        XCTAssertEqual(library.binCount, 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
        XCTAssertEqual(rows.map(\.id), [kept.id])
        XCTAssertEqual(rows.first?.isInBin, true)
        let problem = try XCTUnwrap(library.deleteProblem)
        XCTAssertEqual(problem.photoCount, 1)
        XCTAssertEqual(problem.attemptedCount, 2)
        XCTAssertTrue(problem.message.contains("locked.jpg"), problem.message)
        XCTAssertTrue(library.photosBeingDeleted.isEmpty)
    }

    /// Emptying the bin while the drive is unplugged: nothing is deleted (the files may well still be there), and the
    /// owner is told the drive isn't connected. A file that is simply gone, on a volume that is there, counts as deleted.
    func testPermanentDeleteOfFilesOnADriveThatIsNotConnectedChangesNothing() async throws {
        let volumes = try makeTempDir()
        let offline = PhotoAsset(fileName: "away", jpgPath: volumes.appendingPathComponent("Photos/2024/away.jpg").path,
                                 folderPath: volumes.appendingPathComponent("Photos/2024").path,
                                 creationDate: Date(), fileSize: 2)
        offline.isInBin = true
        context.insert(offline)
        let vanished = PhotoAsset(fileName: "vanished", jpgPath: photosDir.appendingPathComponent("vanished.jpg").path,
                                  folderPath: photosDir.path, creationDate: Date(), fileSize: 2)
        vanished.isInBin = true
        context.insert(vanished)
        try context.save()
        library.loadExistingData()
        let log = self.log!
        library.fileTrasher = FileTrasher(trashItem: { log.append($0) },
                                          volumes: VolumeCheck(volumesDirectory: volumes.path))

        await library.deletePermanently([offline, vanished])

        XCTAssertEqual(log.count, 0, "nothing to move")
        XCTAssertEqual(library.binPhotos.map(\.id), [offline.id])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>()).map(\.id), [offline.id])
        let problem = try XCTUnwrap(library.deleteProblem)
        XCTAssertEqual(problem.photoCount, 1)
        XCTAssertTrue(problem.message.contains("“Photos” isn’t connected"), problem.message)
    }

    /// A pair whose JPG went to the Trash but whose RAW is locked stays in the bin as the RAW, so it never points at a
    /// file in the Trash.
    func testPermanentDeleteThatMovesPartOfAPairKeepsTheRest() async throws {
        let photo = try insertPhoto("pair", raw: true, inBin: true)
        try lock(try XCTUnwrap(photo.rawPath))
        library.loadExistingData()
        useTestTrash()

        await library.deletePermanently([photo])

        XCTAssertEqual(log.names, ["pair.jpg"])
        XCTAssertNil(photo.jpgPath)
        XCTAssertNotNil(photo.rawPath)
        XCTAssertEqual(library.binPhotos.map(\.id), [photo.id])
        XCTAssertEqual(library.binFacts.first?.hasJPG, false)
        XCTAssertEqual(library.deleteProblem?.photoCount, 1)
    }

    // MARK: - File-type delete

    /// A file-type delete whose RAW can't be moved leaves that pair as it was, and says so. (It used to clear `rawPath`
    /// regardless, and the next scan brought the RAW back.)
    func testFileTypeDeleteKeepsTheFileItCouldNotMove() async throws {
        let stuck = try insertPhoto("stuck", raw: true)
        let free = try insertPhoto("free", raw: true)
        try lock(try XCTUnwrap(stuck.rawPath))
        library.loadExistingData()
        useTestTrash()

        await library.deleteFileType(of: [stuck, free], raw: true, jpg: false)

        XCTAssertEqual(log.names, ["free.arw"])
        XCTAssertNotNil(stuck.rawPath)
        XCTAssertNil(free.rawPath)
        XCTAssertEqual(library.rawCount, 1)
        XCTAssertEqual(library.deleteProblem?.photoCount, 1)
        XCTAssertTrue(library.photosBeingDeleted.isEmpty)
    }

    func testFileTypeDeleteTrashesTheRAWAndItsSidecarThenKeepsTheJPG() async throws {
        let photo = try insertPhoto("pair", raw: true, sidecar: true)
        photo.hasRawEdits = true
        try context.save()
        library.loadExistingData()
        useTestTrash()

        await library.deleteFileType(of: [photo], raw: true, jpg: false)

        XCTAssertEqual(Set(log.names), ["pair.arw", "pair.xmp"])
        XCTAssertEqual(try filesLeft(), ["pair.jpg"])
        XCTAssertNil(photo.rawPath)
        XCTAssertFalse(photo.hasRawEdits)
        XCTAssertEqual(library.rawCount, 0)
        XCTAssertEqual(library.allPhotos.map(\.id), [photo.id])
    }

    /// The pair's `.xmp` is the RAW's sidecar, and goes with it, unless the JPG keeps its own rating and keywords there
    /// (a JPG that can't take them): then it stays with the JPG (REL-1 #5).
    func testFileTypeDeleteOfTheRAWKeepsASidecarTheJPGsValuesAreIn() async throws {
        let photo = try insertPhoto("pair", raw: true)
        let jpg = URL(fileURLWithPath: try XCTUnwrap(photo.jpgPath))
        XCTAssertEqual(MetadataService.shared.updateSidecar(
            of: jpg, MetadataService.SidecarUpdate(rating: 3, keywords: ["k"], overridesEmbedded: true)), .written)
        library.loadExistingData()
        useTestTrash()

        await library.deleteFileType(of: [photo], raw: true, jpg: false)

        XCTAssertEqual(log.names, ["pair.arw"])
        XCTAssertEqual(try filesLeft(), ["pair.jpg", "pair.xmp"])
    }

    func testFileTypeDeleteOfTheJPGKeepsTheRAW() async throws {
        let photo = try insertPhoto("pair", raw: true)
        library.loadExistingData()
        useTestTrash()

        await library.deleteFileType(of: [photo], raw: false, jpg: true)

        XCTAssertEqual(log.names, ["pair.jpg"])
        XCTAssertEqual(try filesLeft(), ["pair.arw"])
        XCTAssertNil(photo.jpgPath)
        XCTAssertNotNil(photo.rawPath)
    }
}
