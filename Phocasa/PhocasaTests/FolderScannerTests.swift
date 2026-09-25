import XCTest
import ImageIO
import os
import UniformTypeIdentifiers
@testable import Phocasa

final class FolderScannerTests: XCTestCase {

    // MARK: - Extension Classification

    func testStandardExtensionsContainExpectedFormats() {
        for ext in ["jpg", "jpeg", "png", "tiff", "tif", "heic", "heif"] {
            XCTAssertTrue(FolderScanner.standardExtensions.contains(ext), "\(ext) should be standard")
        }
    }

    func testRawExtensionsContainExpectedFormats() {
        for ext in ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef"] {
            XCTAssertTrue(FolderScanner.rawExtensions.contains(ext), "\(ext) should be RAW")
        }
    }

    func testStandardAndRawDoNotOverlap() {
        let overlap = FolderScanner.standardExtensions.intersection(FolderScanner.rawExtensions)
        XCTAssertTrue(overlap.isEmpty, "Standard and RAW extensions should not overlap: \(overlap)")
    }

    func testAllExtensionsIsUnion() {
        XCTAssertEqual(
            FolderScanner.allExtensions,
            FolderScanner.standardExtensions.union(FolderScanner.rawExtensions)
        )
    }

    func testRawDoesNotContainStandard() {
        XCTAssertFalse(FolderScanner.rawExtensions.contains("jpg"))
        XCTAssertFalse(FolderScanner.rawExtensions.contains("png"))
    }

    func testStandardDoesNotContainRaw() {
        XCTAssertFalse(FolderScanner.standardExtensions.contains("cr2"))
        XCTAssertFalse(FolderScanner.standardExtensions.contains("nef"))
    }

    // MARK: - Scanning

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func testScanEmptyDirectory() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }

        let scanner = FolderScanner()
        let results = await scanner.scan(folderURL: dir)
        XCTAssertTrue(results.isEmpty)
    }

    func testScanFindsSingleJPG() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }

        try Data("fake".utf8).write(to: dir.appendingPathComponent("photo1.jpg"))

        let scanner = FolderScanner()
        let results = await scanner.scan(folderURL: dir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.fileName, "photo1")
        XCTAssertNotNil(results.first?.jpgPath)
        XCTAssertNil(results.first?.rawPath)
    }

    func testScanPairsJPGAndRAW() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }

        try Data("jpg".utf8).write(to: dir.appendingPathComponent("sunset.jpg"))
        try Data("raw".utf8).write(to: dir.appendingPathComponent("sunset.cr2"))

        let scanner = FolderScanner()
        let results = await scanner.scan(folderURL: dir)

        XCTAssertEqual(results.count, 1, "JPG+RAW pair should produce 1 entry")
        let photo = results.first!
        XCTAssertEqual(photo.fileName, "sunset")
        XCTAssertNotNil(photo.jpgPath)
        XCTAssertNotNil(photo.rawPath)
    }

    func testScanMultiplePhotos() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }

        try Data("a".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("b.jpg"))
        try Data("c".utf8).write(to: dir.appendingPathComponent("c.nef"))

        let scanner = FolderScanner()
        let results = await scanner.scan(folderURL: dir)

        XCTAssertEqual(results.count, 3)
    }

    func testScanSkipsHiddenFiles() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }

        try Data("visible".utf8).write(to: dir.appendingPathComponent("visible.jpg"))
        try Data("hidden".utf8).write(to: dir.appendingPathComponent(".hidden.jpg"))

        let scanner = FolderScanner()
        let results = await scanner.scan(folderURL: dir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.fileName, "visible")
    }

    func testScanSkipsNonPhotoFiles() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }

        try Data("photo".utf8).write(to: dir.appendingPathComponent("photo.jpg"))
        try Data("text".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("doc".utf8).write(to: dir.appendingPathComponent("readme.md"))
        try Data("pdf".utf8).write(to: dir.appendingPathComponent("manual.pdf"))

        let scanner = FolderScanner()
        let results = await scanner.scan(folderURL: dir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.fileName, "photo")
    }

    func testScanRecursesSubdirectories() async throws {
        let dir = try makeTempDir()
        let subDir = dir.appendingPathComponent("vacation")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { cleanUp(dir) }

        try Data("root".utf8).write(to: dir.appendingPathComponent("root.jpg"))
        try Data("sub".utf8).write(to: subDir.appendingPathComponent("sub.jpg"))

        let scanner = FolderScanner()
        let results = await scanner.scan(folderURL: dir)

        XCTAssertEqual(results.count, 2)
        let names = Set(results.map(\.fileName))
        XCTAssertEqual(names, ["root", "sub"])
    }

    func testDiscoveredPhotoKeyIsFolderPathAndStem() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("frame.jpg"))

        let found = await FolderScanner().scan(folderURL: dir)
        let photo = try XCTUnwrap(found.first)

        XCTAssertEqual(photo.key, "\(photo.folderPath)/frame")
        XCTAssertEqual(photo.key, DiscoveredPhoto.key(folderPath: photo.folderPath, fileName: photo.fileName))
    }

    func testScanWithoutKnownKeysReadsNoMetadata() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        try makeJPEG(at: dir.appendingPathComponent("rated.jpg"), rating: 3)

        let results = await FolderScanner().scan(folderURL: dir)

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.metadata, "scan(folderURL:) only walks the folder")
    }

    func testKnownKeysSkipTheMetadataReadAndNewKeysGetIt() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        try makeJPEG(at: dir.appendingPathComponent("known.jpg"), rating: 2, keywords: ["cat:a"])
        try makeJPEG(at: dir.appendingPathComponent("new.jpg"), rating: 4, keywords: ["cat:b", "plain"])
        try Data("raw".utf8).write(to: dir.appendingPathComponent("new.cr2")) // the JPG of a pair is read
        let scanner = FolderScanner()
        let walked = await scanner.scan(folderURL: dir)
        let knownKey = try XCTUnwrap(walked.first { $0.fileName == "known" }).key

        let results = await scanner.scan(folderURL: dir, knownKeys: [knownKey])

        XCTAssertEqual(results.count, 2)
        let known = try XCTUnwrap(results.first { $0.fileName == "known" })
        XCTAssertNil(known.metadata)
        let new = try XCTUnwrap(results.first { $0.fileName == "new" })
        XCTAssertNotNil(new.rawPath)
        XCTAssertEqual(new.metadata?.rating, 4)
        XCTAssertEqual(new.metadata?.keywords.sorted(), ["cat:b", "plain"])
    }

    func testReadMetadataForManyFilesKeepsOrderAndReportsProgress() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        // More than two work items of 64, so the reads really run concurrently.
        for i in 0..<150 {
            try makeJPEG(at: dir.appendingPathComponent(String(format: "p%03d.jpg", i)), rating: i % 6)
        }
        let scanner = FolderScanner()
        let discovered = await scanner.scan(folderURL: dir)
        let reports = OSAllocatedUnfairLock(initialState: [(done: Int, total: Int)]())

        let results = await scanner.readMetadata(for: discovered) { done, total in
            reports.withLock { $0.append((done, total)) }
        }

        XCTAssertEqual(results.map(\.key), discovered.map(\.key), "same photos, same order")
        for photo in results {
            let index = try XCTUnwrap(Int(photo.fileName.dropFirst()))
            XCTAssertEqual(photo.metadata?.rating, index % 6, photo.fileName)
        }
        let progress = reports.withLock { $0 }
        XCTAssertEqual(progress.count, 3, "one report per work item of 64")
        XCTAssertEqual(progress.map(\.done).max(), 150)
        XCTAssertTrue(progress.allSatisfy { $0.total == 150 })
    }

    /// A small real JPEG, with a rating and keywords written by the app's own write path.
    private func makeJPEG(at url: URL, rating: Int, keywords: [String] = []) throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        MetadataService.shared.writeMetadata(rating: rating, keywords: keywords, toImageAt: url.path)
    }

    func testScanAggregatesFileSize() async throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }

        let jpgData = Data(repeating: 0x42, count: 1000)
        let rawData = Data(repeating: 0x43, count: 5000)
        try jpgData.write(to: dir.appendingPathComponent("photo.jpg"))
        try rawData.write(to: dir.appendingPathComponent("photo.cr2"))

        let scanner = FolderScanner()
        let results = await scanner.scan(folderURL: dir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.fileSize, 6000)
    }
}
