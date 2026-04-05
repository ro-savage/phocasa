import XCTest
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
