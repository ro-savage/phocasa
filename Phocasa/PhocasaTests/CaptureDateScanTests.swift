import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Shared setup for tests that scan real files into a temp on-disk store.
@MainActor
class CaptureDateStoreTestCase: XCTestCase {
    private var tempDirs: [URL] = []
    private var containers: [ModelContainer] = []

    override func tearDown() async throws {
        containers.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    /// A temp folder, as the canonical path the folder enumerator reports (`/private/var/…`).
    func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-33-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let canonical = try XCTUnwrap(realpath(dir.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    func makeContainer() throws -> ModelContainer {
        let storeDir = try makeTempDir("store")
        let config = ModelConfiguration(url: storeDir.appendingPathComponent("capture.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: config
        )
        containers.append(container)
        return container
    }

    func waitForScan(_ vm: PhotoLibraryViewModel, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while vm.library.isScanning {
            if ContinuousClock.now > deadline { return XCTFail("scan did not finish within \(timeout)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Every stored photo row by file name, read through a separate context.
    func storedPhotos(_ container: ModelContainer) throws -> [String: PhotoAsset] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
        return Dictionary(rows.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func names(_ photos: [PhotoAsset]) -> [String] { photos.map(\.fileName) }

    /// A local capture time (`yyyy:MM:dd HH:mm:ss`) as a date.
    func local(_ exif: String) -> Date { CaptureDate.parse(exif)! }
}

/// A scan stores the capture date it reads with each new photo's metadata, at both insert sites.
@MainActor
final class CaptureDateScanTests: CaptureDateStoreTestCase {

    func testScanStoresCaptureDatesAndShowsTheLibraryInCaptureOrder() async throws {
        let dir = try makeTempDir("photos")
        // Written in this order, so creation order is the reverse of capture order (apart from "none").
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("none.jpg"), exifDate: nil)
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("new.jpg"), exifDate: "2020:05:01 10:00:00")
        // With keywords, so it's inserted on the main context; the others go in through a background context.
        MetadataService.shared.writeMetadata(rating: 2, keywords: ["cat:a"], toImageAt: dir.appendingPathComponent("new.jpg").path)
        try CaptureDateFixtures.writeImage(at: dir.appendingPathComponent("raw.dng"), type: .tiff,
                                           exif: [kCGImagePropertyExifDateTimeOriginal: "2017:03:03 03:03:03"])
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("mid.jpg"), exifDate: "2015:05:01 10:00:00",
                                          subseconds: "5", offset: "+02:00")
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("old.jpg"), exifDate: "2010:05:01 10:00:00")

        let container = try makeContainer()
        let context = container.mainContext
        context.insert(PhotoLibrary(rootFolderPath: dir.path))
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        try await waitForScan(vm)

        XCTAssertEqual(names(vm.library.photos), ["none", "new", "raw", "mid", "old"],
                       "capture order; the photo without one sorts by its (recent) creation date")

        let stored = try storedPhotos(container)
        XCTAssertEqual(stored["new"]?.captureDate, local("2020:05:01 10:00:00"))
        XCTAssertEqual(stored["new"]?.tags.map(\.fullName), ["cat:a"], "the main-context insert")
        XCTAssertEqual(stored["raw"]?.captureDate, local("2017:03:03 03:03:03"), "a RAW-only photo reads its RAW")
        XCTAssertNil(stored["raw"]?.jpgPath)
        XCTAssertEqual(try XCTUnwrap(stored["mid"]?.captureDate).timeIntervalSince1970,
                       CaptureDateFixtures.utc(2015, 5, 1, 8, 0, 0).timeIntervalSince1970 + 0.5, accuracy: 1e-6)
        XCTAssertEqual(stored["old"]?.captureDate, local("2010:05:01 10:00:00"))
        XCTAssertNil(stored["none"]?.captureDate)
        for (name, photo) in stored {
            XCTAssertTrue(photo.captureDateChecked, "\(name): the scan read its file")
        }

        vm.library.toggleSortOrder()
        XCTAssertEqual(names(vm.library.photos), ["old", "mid", "raw", "new", "none"])
    }

    func testRescanFindsNewPhotosInCaptureOrderAmongExistingOnes() async throws {
        let dir = try makeTempDir("photos")
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("a.jpg"), exifDate: "2012:01:01 00:00:00")
        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("c.jpg"), exifDate: "2014:01:01 00:00:00")
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(PhotoLibrary(rootFolderPath: dir.path))
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        try await waitForScan(vm)
        XCTAssertEqual(names(vm.library.photos), ["c", "a"])

        try CaptureDateFixtures.writeJPEG(at: dir.appendingPathComponent("b.jpg"), exifDate: "2013:01:01 00:00:00")
        vm.library.rescanCurrentLibrary()
        try await waitForScan(vm)
        XCTAssertEqual(names(vm.library.photos), ["c", "b", "a"], "the new photo goes by its capture date, not its new file")
    }
}
