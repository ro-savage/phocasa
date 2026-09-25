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

    // MARK: - File-type delete

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
