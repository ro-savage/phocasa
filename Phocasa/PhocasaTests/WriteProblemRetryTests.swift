import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// The status bar's Retry, through the library and the shared writer, on real files (REL-4 #1): a rating that couldn't
/// be written is reported, and Retry writes the photo's current value once the file can take it.
@MainActor
final class WriteProblemRetryTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        await MetadataWriter.shared.flush()
        if let dir {
            let fm = FileManager.default
            for url in (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try? fm.removeItem(at: dir)
        }
        dir = nil
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func item(_ path: String, _ rating: Int) -> MetadataWriteItem {
        MetadataWriteItem(path: path, rating: rating, keywords: [])
    }

    private func makeJPEG(_ name: String) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeViewModel(with photos: [PhotoAsset]) throws -> (PhotoLibraryViewModel, ModelContainer) {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        for photo in photos { context.insert(photo) }
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        return (vm, container)
    }

    /// The shared report (`MetadataWriteProblems.shared`), once it has heard the writer, filtered to `path`.
    private func sharedFailures(for path: String, until condition: ([MetadataWriteProblem]) -> Bool) async
        -> [MetadataWriteProblem] {
        let deadline = Date().addingTimeInterval(5)
        var failures: [MetadataWriteProblem] = []
        repeat {
            await MetadataWriter.shared.flush()
            await Task.yield()
            failures = MetadataWriteProblems.shared.report.failures.problems.filter { $0.path == path }
            if condition(failures) { break }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        return failures
    }

    func testARatingThatCantBeWrittenShowsInTheStatusBarReportAndRetryWritesTheCurrentValue() async throws {
        let jpg = try makeJPEG("ro.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: jpg.path)
        let photo = PhotoAsset(fileName: "ro", jpgPath: jpg.path, folderPath: dir.path, fileSize: 1)
        let (vm, container) = try makeViewModel(with: [photo])
        defer { _ = container }

        vm.library.setRating(2, for: photo)
        vm.library.setRating(4, for: photo)
        let failures = await sharedFailures(for: jpg.path) { !$0.isEmpty }
        XCTAssertEqual(failures.map(\.issue), [.readOnly(.file)])

        // Made writable, the Retry writes the photo's rating now: 4.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: jpg.path)
        await vm.retryWrites(failures).value
        let after = await sharedFailures(for: jpg.path) { $0.isEmpty }
        XCTAssertEqual(after, [])
        XCTAssertEqual(MetadataService.shared.readMetadata(from: jpg.path).rating, 4)
    }

    /// A problem whose photo is no longer in the library has nothing to retry: it's dismissed.
    func testRetryDismissesAProblemWhosePhotoIsGone() async throws {
        let gone = path("gone.jpg")
        MetadataWriter.shared.enqueue([item(gone, 3)])
        let failures = await sharedFailures(for: gone) { !$0.isEmpty }
        XCTAssertEqual(failures.map(\.issue), [.missing])

        let (vm, container) = try makeViewModel(with: [])
        defer { _ = container }
        await vm.retryWrites(failures).value
        let after = await sharedFailures(for: gone) { $0.isEmpty }
        XCTAssertEqual(after, [])
    }

    func testPhotosWithFilesAtFindsPairsAndBinnedPhotos() throws {
        let pair = PhotoAsset(fileName: "p", jpgPath: path("p.jpg"), rawPath: path("p.ARW"), folderPath: dir.path)
        let binned = PhotoAsset(fileName: "b", jpgPath: path("b.jpg"), folderPath: dir.path)
        binned.isInBin = true
        let other = PhotoAsset(fileName: "o", jpgPath: path("o.jpg"), folderPath: dir.path)
        let (vm, container) = try makeViewModel(with: [pair, binned, other])
        defer { _ = container }

        let found = vm.library.photos(withFilesAt: [path("p.ARW"), path("b.jpg"), path("nowhere.jpg")])
        XCTAssertEqual(Set(found.keys), [path("p.ARW"), path("b.jpg")])
        XCTAssertEqual(found[path("p.ARW")]?.id, pair.id)
        XCTAssertEqual(found[path("b.jpg")]?.id, binned.id)
    }
}
