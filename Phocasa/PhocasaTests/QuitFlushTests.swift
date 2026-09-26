import XCTest
import ImageIO
import UniformTypeIdentifiers
import SwiftData
@testable import Phocasa

/// Quitting waits for the metadata writes still queued (ratings, keywords, RAW edits) to reach the files, for at most
/// 5 s (task 30, step 8). Nothing here asks the real app to terminate.
@MainActor
final class QuitFlushTests: XCTestCase {

    func testFlushThatFinishesInTimeReportsDone() async {
        let done = await AppDelegate.flushPendingWrites(timeout: .seconds(5)) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(done)
    }

    /// A flush that doesn't finish (a stuck write, say) holds quit up for the timeout only.
    func testFlushThatHangsGivesUpAfterTheTimeout() async {
        let start = ContinuousClock.now
        let done = await AppDelegate.flushPendingWrites(timeout: .milliseconds(200)) {
            try? await Task.sleep(for: .seconds(30))
        }
        let waited = ContinuousClock.now - start
        XCTAssertFalse(done)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(190))
        XCTAssertLessThan(waited, .seconds(3), "quit isn't held up for the whole flush")
    }

    /// The terminate reply comes only after the flush.
    func testReplyComesAfterTheFlush() async {
        var events: [String] = []
        let replied = expectation(description: "reply")
        AppDelegate.replyAfterFlushing(timeout: .seconds(5), flush: {
            try? await Task.sleep(for: .milliseconds(50))
            await MainActor.run { events.append("flushed") }
        }, reply: {
            events.append("reply")
            replied.fulfill()
        })
        XCTAssertEqual(events, [], "the reply waits for the flush")
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(events, ["flushed", "reply"])
    }

    /// The real writer: a rating enqueued just before quitting is in the file once the quit flush returns.
    func testQuitFlushWaitsForTheMetadataWriter() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-30-quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.resolvingSymlinksInPath().appendingPathComponent("quit.jpg")
        try writeJPEG(to: url)

        MetadataWriter.shared.enqueue([MetadataWriteItem(path: url.path, rating: 4, keywords: ["quit:test"])])
        let done = await AppDelegate.flushPendingWrites(timeout: AppDelegate.quitFlushTimeout)

        XCTAssertTrue(done)
        let metadata = MetadataService.shared.readMetadata(from: url.path)
        XCTAssertEqual(metadata.rating, 4)
        XCTAssertEqual(metadata.keywords, ["quit:test"])
    }

    /// Bug test (REL-1 #7): a session saved only on close, navigate or Escape, so an edit still open at ⌘Q was lost.
    /// Quitting (`AppDelegate.applicationShouldTerminate`) ends every open session with a save before the flush, so a
    /// RAW edit's sidecar write is among the writes quit waits for.
    func testQuitSavesOpenEditSessionsBeforeTheFlush() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-rel1-quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let raw = dir.appendingPathComponent("quit.ARW") // a RAW edit only needs the sidecar's path
        let jpg = dir.appendingPathComponent("other.jpg")
        let rawPhoto = PhotoAsset(fileName: "quit", rawPath: raw.path, folderPath: dir.path, creationDate: Date())
        let jpgPhoto = PhotoAsset(fileName: "other", jpgPath: jpg.path, folderPath: dir.path, creationDate: Date())
        context.insert(rawPhoto)
        context.insert(jpgPhoto)
        try context.save()
        func editing(_ photo: PhotoAsset, isRAW: Bool) -> PhotoLibraryViewModel {
            let viewModel = PhotoLibraryViewModel()
            viewModel.setModelContext(context)
            viewModel.openDetail(for: photo)
            viewModel.startEditing(photo: photo, isRAW: isRAW)
            viewModel.editSession?.parameters.exposure = 0.7
            return viewModel
        }
        let rawWindow = editing(rawPhoto, isRAW: true)
        let jpgWindow = editing(jpgPhoto, isRAW: false)

        PhotoLibraryViewModel.saveEditsBeforeQuit()
        let done = await AppDelegate.flushPendingWrites(timeout: AppDelegate.quitFlushTimeout)

        XCTAssertTrue(done)
        XCTAssertFalse(rawWindow.isEditing)
        XCTAssertFalse(jpgWindow.isEditing)
        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, 0.7)
        XCTAssertEqual(jpgPhoto.jpgEditParameters?.exposure, 0.7)
    }

    private func writeJPEG(to url: URL) throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
