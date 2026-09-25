import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Scans import ratings embedded in RAW files (user decision 2, kept from task 14). A regression test: a
/// generated TIFF named `.dng` stands in for a RAW file with embedded XMP.
@MainActor
final class MetadataEmbeddedRAWRatingTests: XCTestCase {
    private var dir: URL!
    private let service = MetadataService.shared

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-embedded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
    }

    /// A TIFF-based "RAW" file whose embedded XMP holds `xmp:Rating` (and keywords).
    @discardableResult
    private func makeRAWWithEmbeddedXMP(_ name: String, rating: Int, keywords: [String] = []) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let meta = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "\(rating)" as CFString))
        if !keywords.isEmpty {
            let subject = try XCTUnwrap(CGImageMetadataTagCreate(
                "http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString, "subject" as CFString,
                .arrayUnordered, keywords as CFArray))
            XCTAssertTrue(CGImageMetadataSetTagWithPath(meta, nil, "dc:subject" as CFString, subject))
        }
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(dest, try XCTUnwrap(ctx.makeImage()), meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testRAWOnlyFileWithAnEmbeddedRatingAndNoSidecarReadsIt() throws {
        let raw = try makeRAWWithEmbeddedXMP("IMG_0001.dng", rating: 4, keywords: ["people:ann"])
        XCTAssertTrue(FolderScanner.rawExtensions.contains(raw.pathExtension.lowercased()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.xmpSidecarURL.path))

        let read = service.readMetadata(from: raw.path)

        XCTAssertEqual(read.rating, 4)
        XCTAssertEqual(read.keywords, ["people:ann"])
    }

    func testANonZeroSidecarRatingStillWinsOverTheEmbeddedOne() throws {
        let raw = try makeRAWWithEmbeddedXMP("IMG_0002.dng", rating: 4)

        service.writeMetadata(rating: 0, keywords: [], toImageAt: raw.path)
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 4, "a zero in the sidecar doesn't hide the embedded rating")

        service.writeMetadata(rating: 2, keywords: [], toImageAt: raw.path)
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 2)
    }

    func testScanImportsTheEmbeddedRatingOfARAWOnlyPhoto() async throws {
        try makeRAWWithEmbeddedXMP("IMG_0003.dng", rating: 4)
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        context.insert(PhotoLibrary(rootFolderPath: dir.path))
        try context.save()
        vm.loadExistingData()

        vm.library.rescanCurrentLibrary()
        let deadline = Date().addingTimeInterval(10)
        while vm.library.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertFalse(vm.library.isScanning)
        let photo = try XCTUnwrap(vm.library.allPhotos.first)
        XCTAssertNil(photo.jpgPath)
        XCTAssertEqual(photo.rawPath.map { URL(fileURLWithPath: $0).lastPathComponent }, "IMG_0003.dng")
        XCTAssertEqual(photo.rating, 4)
        _ = container
    }
}
