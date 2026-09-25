import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Ratings and keywords go to both files of a JPG+RAW pair (user decision 4, task 23): the JPG's embedded XMP
/// and the RAW's `.xmp` sidecar. Driven through the view model, as the app does, on real files in a temp folder.
@MainActor
final class MetadataPairWriteTests: XCTestCase {
    private var dir: URL!
    private var container: ModelContainer?

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        await MetadataWriter.shared.flush()
        container = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func makeJPEG(_ name: String) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeFakeRAW(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("fake raw bytes".utf8).write(to: url)
        return url
    }

    private func makePair(_ stem: String, rawExtension: String = "ARW") throws -> (PhotoAsset, jpg: URL, raw: URL) {
        let jpg = try makeJPEG("\(stem).JPG")
        let raw = try makeFakeRAW("\(stem).\(rawExtension)")
        return (PhotoAsset(fileName: stem, jpgPath: jpg.path, rawPath: raw.path, folderPath: dir.path), jpg, raw)
    }

    private func makeViewModel(with photos: [PhotoAsset]) throws -> PhotoLibraryViewModel {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        self.container = container
        let context = ModelContext(container)
        for photo in photos { context.insert(photo) }
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        return vm
    }

    /// What the JPG itself holds, ignoring any sidecar next to it (`readMetadata` would merge that in).
    private func embedded(_ jpg: URL) throws -> (rating: Int?, keywords: [String]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        guard let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return (nil, []) }
        let rating = (CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?).flatMap { Int($0) }
        let subject = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString)
            .flatMap { CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] }?
            .compactMap { CGImageMetadataTagCopyValue($0) as? String } ?? []
        return (rating, subject)
    }

    /// What the sidecar holds (nil if there is none).
    private func sidecar(of raw: URL) throws -> MetadataService.PhotoMetadata? {
        guard FileManager.default.fileExists(atPath: raw.xmpSidecarURL.path) else { return nil }
        return MetadataService.shared.parseXMPSidecar(try String(contentsOf: raw.xmpSidecarURL, encoding: .utf8))
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: - Pairs write both files

    func testRatingAPairWritesBothFiles() async throws {
        let (photo, jpg, raw) = try makePair("DSC0001")
        let vm = try makeViewModel(with: [photo])

        vm.library.setRating(4, for: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(try embedded(jpg).rating, 4, "the JPG gets the rating, as before")
        XCTAssertEqual(try sidecar(of: raw)?.rating, 4, "and so does the RAW's sidecar")
        XCTAssertEqual(try listing(), ["DSC0001.ARW", "DSC0001.JPG", "DSC0001.xmp"])
    }

    func testTaggingAPairWritesKeywordsToBothFiles() async throws {
        let (photo, jpg, raw) = try makePair("DSC0002")
        let vm = try makeViewModel(with: [photo])

        vm.library.setRating(2, for: photo)
        vm.library.addTag(name: "ann", category: "people", to: photo)
        vm.library.addTag(name: "beach", category: "", to: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(Set(try embedded(jpg).keywords), ["people:ann", "beach"])
        XCTAssertEqual(Set(try XCTUnwrap(try sidecar(of: raw)).keywords), ["people:ann", "beach"],
                       "keywords travel with the rating, so the sidecar's never go stale")
        XCTAssertEqual(try sidecar(of: raw)?.rating, 2)

        let tag = try XCTUnwrap(photo.tags.first { $0.name == "beach" })
        vm.library.removeTag(tag, from: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(try embedded(jpg).keywords, ["people:ann"])
        XCTAssertEqual(try sidecar(of: raw)?.keywords, ["people:ann"])
    }

    func testBatchRatingOfPairsWritesEverySidecar() async throws {
        let pairs = try (0..<3).map { try makePair("BATCH_\($0)") }
        let vm = try makeViewModel(with: pairs.map(\.0))

        vm.selection.selectAll()
        vm.setRatingForSelection(5)
        await MetadataWriter.shared.flush()

        for (_, jpg, raw) in pairs {
            XCTAssertEqual(try embedded(jpg).rating, 5, jpg.lastPathComponent)
            XCTAssertEqual(try sidecar(of: raw)?.rating, 5, raw.lastPathComponent)
        }
    }

    func testRatingAPairKeepsItsRAWEdits() async throws {
        let (photo, jpg, raw) = try makePair("DSC0003", rawExtension: "CR3")
        MetadataService.shared.writeEditParameters(EditParameters(exposure: 0.7), forRAWAt: raw.path)
        photo.hasRawEdits = true
        let vm = try makeViewModel(with: [photo])

        vm.library.setRating(5, for: photo)
        vm.library.addTag(name: "x", category: "", to: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, 0.7)
        XCTAssertEqual(try sidecar(of: raw)?.rating, 5)
        XCTAssertEqual(try sidecar(of: raw)?.keywords, ["x"])
        XCTAssertEqual(try embedded(jpg).rating, 5)
        XCTAssertTrue(photo.hasRawEdits)
    }

    func testRatingAPairKeepsALightroomSidecarsDevelopSettings() async throws {
        let (photo, jpg, raw) = try makePair("DSC0004")
        try Data(SidecarFixtures.lightroom.utf8).write(to: raw.xmpSidecarURL)
        let before = SidecarFixtures.unrelated(try SidecarFixtures.properties(ofXMPAt: raw.xmpSidecarURL))
        let vm = try makeViewModel(with: [photo])

        vm.library.setRating(3, for: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(try sidecar(of: raw)?.rating, 3)
        XCTAssertEqual(try embedded(jpg).rating, 3)
        XCTAssertEqual(SidecarFixtures.unrelated(try SidecarFixtures.properties(ofXMPAt: raw.xmpSidecarURL)),
                       before)
    }

    func testPairReadsBackConsistentlyFromEitherFile() async throws {
        let (photo, jpg, raw) = try makePair("DSC0005")
        let vm = try makeViewModel(with: [photo])
        let service = MetadataService.shared

        vm.library.setRating(4, for: photo)
        vm.library.addTag(name: "ann", category: "people", to: photo)
        await MetadataWriter.shared.flush()

        for path in [jpg.path, raw.path] {
            XCTAssertEqual(service.readMetadata(from: path).rating, 4, path)
            XCTAssertEqual(service.readMetadata(from: path).keywords, ["people:ann"], path)
        }

        // Clearing both comes back as cleared from either file too.
        vm.library.setRating(0, for: photo)
        vm.library.removeTag(try XCTUnwrap(photo.tags.first), from: photo)
        await MetadataWriter.shared.flush()

        for path in [jpg.path, raw.path] {
            XCTAssertEqual(service.readMetadata(from: path).rating, 0, path)
            XCTAssertEqual(service.readMetadata(from: path).keywords, [], path)
        }
    }

    // MARK: - Single files write only themselves

    func testRatingARAWOnlyPhotoWritesOnlyItsSidecar() async throws {
        let raw = try makeFakeRAW("RAWONLY.NEF")
        let rawBytes = try Data(contentsOf: raw)
        let photo = PhotoAsset(fileName: "RAWONLY", rawPath: raw.path, folderPath: dir.path)
        let vm = try makeViewModel(with: [photo])

        vm.library.setRating(3, for: photo)
        vm.library.addTag(name: "k", category: "", to: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(try sidecar(of: raw)?.rating, 3)
        XCTAssertEqual(try sidecar(of: raw)?.keywords, ["k"])
        XCTAssertEqual(try Data(contentsOf: raw), rawBytes, "the RAW file itself is never written")
        XCTAssertEqual(try listing(), ["RAWONLY.NEF", "RAWONLY.xmp"])
    }

    func testRatingAJPGOnlyPhotoWritesOnlyTheJPG() async throws {
        let jpg = try makeJPEG("JPGONLY.jpg")
        let photo = PhotoAsset(fileName: "JPGONLY", jpgPath: jpg.path, folderPath: dir.path)
        let vm = try makeViewModel(with: [photo])

        vm.library.setRating(3, for: photo)
        vm.library.addTag(name: "k", category: "", to: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(try embedded(jpg).rating, 3)
        XCTAssertEqual(try embedded(jpg).keywords, ["k"])
        XCTAssertEqual(try listing(), ["JPGONLY.jpg"], "no sidecar is created for a JPG on its own")
    }
}
