import XCTest
import SwiftData
import ImageIO
import CryptoKit
@testable import Phocasa

/// Round trips on a real camera RAW (and its JPG, if one sits next to it). Skipped unless `PHOCASA_TEST_RAW`
/// (pass `TEST_RUNNER_PHOCASA_TEST_RAW`) names a RAW file. That file is only read: the test copies it, and its JPG,
/// into its own temp folder and writes only to the copies.
@MainActor
final class MetadataRealFileTests: XCTestCase {
    private var dir: URL!
    private var raw: URL!
    private var jpg: URL?
    private var container: ModelContainer?

    override func setUp() async throws {
        guard let source = ProcessInfo.processInfo.environment["PHOCASA_TEST_RAW"], !source.isEmpty else {
            throw XCTSkip("set PHOCASA_TEST_RAW to a RAW file (a copy) to run the real-file round trips")
        }
        let sourceURL = URL(fileURLWithPath: source)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-realfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
        raw = dir.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: raw)
        for ext in ["JPG", "jpg", "jpeg", "JPEG"] {
            let candidate = sourceURL.deletingPathExtension().appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let copy = dir.appendingPathComponent(candidate.lastPathComponent)
                try FileManager.default.copyItem(at: candidate, to: copy)
                jpg = copy
                break
            }
        }
    }

    override func tearDown() async throws {
        await MetadataWriter.shared.flush()
        container = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func embeddedRating(_ url: URL) throws -> Int? {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        return meta.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:Rating" as CFString) as String? }
            .flatMap { Int($0) }
    }

    func testRAWOnlyRatingAndKeywordsGoToTheSidecarAndLeaveTheRAWUntouched() throws {
        if let jpg { try FileManager.default.removeItem(at: jpg) }
        let before = try digest(raw)

        MetadataService.shared.writeMetadata(rating: 4, keywords: ["people:ann", "beach"], toImageAt: raw.path)
        MetadataService.shared.writeEditParameters(EditParameters(exposure: 0.4), forRAWAt: raw.path)
        MetadataService.shared.writeMetadata(rating: 5, keywords: ["beach"], toImageAt: raw.path)

        let read = MetadataService.shared.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, 5)
        XCTAssertEqual(read.keywords, ["beach"])
        XCTAssertEqual(read.editParameters?.exposure, 0.4)
        XCTAssertEqual(try digest(raw), before, "the RAW file itself is never written")
    }

    func testLightroomSidecarNextToARealRAWKeepsItsDevelopSettings() throws {
        try Data(SidecarFixtures.lightroom.utf8).write(to: raw.xmpSidecarURL)
        let unrelated = SidecarFixtures.unrelated(try SidecarFixtures.properties(ofXMPAt: raw.xmpSidecarURL))

        MetadataService.shared.writeMetadata(rating: 1, keywords: ["k"], toImageAt: raw.path)
        MetadataService.shared.writeEditParameters(EditParameters(exposure: -1), forRAWAt: raw.path)
        MetadataService.shared.clearEditParameters(forRAWAt: raw.path)

        XCTAssertEqual(SidecarFixtures.unrelated(try SidecarFixtures.properties(ofXMPAt: raw.xmpSidecarURL)), unrelated)
        XCTAssertEqual(MetadataService.shared.readMetadata(from: raw.path).rating, 1)
    }

    func testRatingARealCameraJPGChangesOnlyItsXMP() throws {
        let jpg = try XCTUnwrap(jpg, "needs the RAW's JPG next to it")
        let before = try Data(contentsOf: jpg)
        let beforeProps = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(before as CFData, nil)), 0, nil) as? [String: Any])

        MetadataService.shared.writeMetadata(rating: 4, keywords: ["people:ann", "beach"], toImageAt: jpg.path)
        MetadataService.shared.writeMetadata(rating: 2, keywords: ["beach"], toImageAt: jpg.path)

        let after = try Data(contentsOf: jpg)
        typealias T = MetadataJPEGPreservationTests
        let xmpID = "http://ns.adobe.com/xap/1.0/"
        let (oldSegments, oldSOS) = T.header(before), (newSegments, newSOS) = T.header(after)
        XCTAssertEqual(newSegments.filter { $0.id != xmpID }, oldSegments.filter { $0.id != xmpID },
                       "Exif (with the MakerNote), MPF and every other segment stay byte-identical")
        XCTAssertEqual(after[newSOS...], before[oldSOS...], "image data and the appended preview are copied as is")
        if let oldPreview = T.mpfSecondImage(before) {
            let newPreview = try XCTUnwrap(T.mpfSecondImage(after))
            XCTAssertEqual(after[newPreview], before[oldPreview], "the MPF entry still points at the preview")
        }
        let afterProps = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(after as CFData, nil)), 0, nil) as? [String: Any])
        XCTAssertEqual(Set(afterProps.keys), Set(beforeProps.keys).union(["{IPTC}"]),
                       "no ImageIO dictionary (such as the MakerNote's {PictureStyle}) disappears")
        XCTAssertEqual(try embeddedRating(jpg), 2)
        XCTAssertEqual(MetadataService.shared.readMetadata(from: jpg.path).keywords, ["beach"])
    }

    func testRatingARealPairWritesTheJPGAndTheSidecar() async throws {
        let jpg = try XCTUnwrap(jpg, "needs the RAW's JPG next to it")
        let rawBefore = try digest(raw)
        let photo = PhotoAsset(fileName: raw.deletingPathExtension().lastPathComponent,
                               jpgPath: jpg.path, rawPath: raw.path, folderPath: dir.path)
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        self.container = container
        let context = ModelContext(container)
        context.insert(photo)
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)

        vm.library.setRating(3, for: photo)
        vm.library.addTag(name: "ann", category: "people", to: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(try embeddedRating(jpg), 3)
        let sidecar = MetadataService.sidecarContents(try Data(contentsOf: raw.xmpSidecarURL))
        XCTAssertEqual(sidecar.rating, 3)
        XCTAssertEqual(sidecar.keywords, ["people:ann"])
        for path in [jpg.path, raw.path] {
            XCTAssertEqual(MetadataService.shared.readMetadata(from: path).rating, 3, path)
            XCTAssertEqual(MetadataService.shared.readMetadata(from: path).keywords, ["people:ann"], path)
        }
        XCTAssertEqual(try digest(raw), rawBefore)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary), "the JPG still decodes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("phocasa-tmp") }, [])
    }
}
