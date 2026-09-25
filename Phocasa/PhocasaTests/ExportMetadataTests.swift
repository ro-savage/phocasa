// Exports and baked edits keep the photo's original metadata (post-wave-3 task A; the user's rule, CLAUDE.md
// "Metadata"). Each export path runs through the view model on a hand-built camera-style JPEG (`RichJPEG`) and, for
// RAW exports, a TIFF with metadata of its own in the photo's RAW slot: `CIRAWFilter` renders a `.tif` (not one
// named `.ARW` or `.dng`, which the test host's RAW decoder rejects). The gated real-file tests use a camera RAW.

import XCTest
import ImageIO
import UniformTypeIdentifiers
import SwiftData
@testable import Phocasa

@MainActor
final class ExportMetadataTests: XCTestCase {
    private var dir: URL!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var viewModels: [PhotoLibraryViewModel] = []

    private nonisolated static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("phocasa-A-ExportMetadataTests-\(UUID().uuidString)", isDirectory: true)

    override class func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    override func setUp() async throws {
        dir = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(url: dir.appendingPathComponent("test.store"))
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDown() async throws {
        for viewModel in viewModels { viewModel.stopEditing(save: false) }
        viewModels = []
        await MetadataWriter.shared.flush()
        weak let store = container
        context = nil
        container = nil
        for _ in 0..<100 where store != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private static let keywords = ["people:ann", "beach"]

    private func makeViewModel() -> PhotoLibraryViewModel {
        let viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
        viewModels.append(viewModel)
        return viewModel
    }

    /// A photo rated 4 and tagged with `keywords`, saved.
    private func insertPhoto(jpg: URL? = nil, raw: URL? = nil) throws -> PhotoAsset {
        let photo = PhotoAsset(fileName: (jpg ?? raw)!.lastPathComponent, jpgPath: jpg?.path, rawPath: raw?.path,
                               folderPath: dir.path, creationDate: Date())
        context.insert(photo)
        photo.rating = 4
        for keyword in Self.keywords {
            let (category, name) = Tag.parse(keyword: keyword)
            let tag = Tag(name: name, category: category)
            context.insert(tag)
            photo.tags.append(tag)
        }
        try context.save()
        return photo
    }

    /// A TIFF standing in for a camera RAW (`name` ends in `.tif`): stored 240×160 with orientation 6, like the rich
    /// JPEG, and metadata of its own, so a test can tell which file an export took its metadata from.
    private func writeFakeRAW(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let jpeg = try RichJPEG.encodedPixels(width: 240, height: 160)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "RawCam", kCGImagePropertyTIFFModel: "Raw Model",
                kCGImagePropertyTIFFArtist: "Raw Artist", kCGImagePropertyTIFFCopyright: "(c) Raw",
                kCGImagePropertyTIFFOrientation: 6,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2023:07:08 09:10:11",
                kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
                kCGImagePropertyExifFNumber: 4.0, kCGImagePropertyExifExposureTime: 0.01,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifLensModel: "RAW Lens 35mm",
                kCGImagePropertyExifBodySerialNumber: "RAW-999",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 11.0,
            ],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Starts editing `photo`, sets an exposure change and waits for its preview.
    private func startEditing(_ viewModel: PhotoLibraryViewModel, _ photo: PhotoAsset, isRAW: Bool) async throws {
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)
        viewModel.startEditing(photo: photo, isRAW: isRAW)
        let session = try XCTUnwrap(viewModel.editSession)
        session.parameters.exposure = 0.5
        _ = try await eventually(10, "the preview renders") { session.previewImage }
    }

    /// Waits for the export to land (the detail view is told to reload) and for its metadata writes.
    private func waitForExport(_ viewModel: PhotoLibraryViewModel, from version: Int) async throws {
        _ = try await eventually(20, "the export finishes") { viewModel.editedFilesVersion != version ? true : nil }
        await MetadataWriter.shared.flush()
    }

    private func waitFor<T>(_ seconds: Double = 5, _ body: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if let value = body() { return value }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return body()
    }

    struct Timeout: Error {}

    private func eventually<T>(_ seconds: Double = 5, _ message: String = "timed out",
                               file: StaticString = #filePath, line: UInt = #line,
                               _ body: () -> T?) async throws -> T {
        if let value = await waitFor(seconds, body) { return value }
        XCTFail(message, file: file, line: line)
        throw Timeout()
    }

    private func readBack(_ url: URL) -> MetadataService.PhotoMetadata {
        MetadataService.shared.readMetadata(from: url.path)
    }

    // MARK: - The three exports

    func testApplyingEditsPermanentlyKeepsTheJPGsMetadata() async throws {
        let rich = try RichJPEG.make()
        let url = dir.appendingPathComponent("cam.jpg")
        try rich.data.write(to: url)
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: url)
        try await startEditing(viewModel, photo, isRAW: false)
        let version = viewModel.editedFilesVersion

        viewModel.exportJPGPermanent()

        try await waitForExport(viewModel, from: version)
        let output = try Data(contentsOf: url)
        XCTAssertNotEqual(output, rich.data, "the edit was baked")
        KeptMetadata.assertKeeps(original: rich.data, output: output, pixelSize: CGSize(width: 160, height: 240),
                                 rating: 4, keywords: Self.keywords, readBack: readBack(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.xmpSidecarURL.path),
                       "rating and keywords are in the file itself")
    }

    func testReplacingTheExistingJPGKeepsTheCameraJPGsMetadata() async throws {
        let rich = try RichJPEG.make()
        let jpg = dir.appendingPathComponent("DSC0001.jpg")
        try rich.data.write(to: jpg)
        let raw = try writeFakeRAW("DSC0001.tif")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: jpg, raw: raw)
        try await startEditing(viewModel, photo, isRAW: true)
        let version = viewModel.editedFilesVersion

        viewModel.exportRAWToJPG(replaceExisting: true)

        try await waitForExport(viewModel, from: version)
        XCTAssertEqual(photo.jpgPath, jpg.path)
        let output = try Data(contentsOf: jpg)
        KeptMetadata.assertKeeps(original: rich.data, output: output, pixelSize: CGSize(width: 160, height: 240),
                                 rating: 4, keywords: Self.keywords, readBack: readBack(jpg))
        let tiff = KeptMetadata.properties(output)["{TIFF}"] as? [String: Any]
        XCTAssertEqual(tiff?["Make"] as? String, "TestCam", "the metadata is the JPG's, not the RAW's")
    }

    func testARAWEditAsANewFileCarriesThePairedJPGsMetadata() async throws {
        let rich = try RichJPEG.make()
        let jpg = dir.appendingPathComponent("DSC0002.jpg")
        try rich.data.write(to: jpg)
        let raw = try writeFakeRAW("DSC0002.tif")
        let export = dir.appendingPathComponent("DSC0002-raw-edit.jpg")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: jpg, raw: raw)
        try await startEditing(viewModel, photo, isRAW: true)

        // Twice: the second export overwrites the first, and the photo's JPG is then the export itself.
        for round in 1...2 {
            let version = viewModel.editedFilesVersion
            viewModel.exportRAWToJPG(replaceExisting: false)
            try await waitForExport(viewModel, from: version)

            XCTAssertEqual(photo.jpgPath, export.path, "round \(round)")
            KeptMetadata.assertKeeps(original: rich.data, output: try Data(contentsOf: export),
                                     pixelSize: CGSize(width: 160, height: 240), rating: 4, keywords: Self.keywords,
                                     readBack: readBack(export))
            XCTAssertEqual(try Data(contentsOf: jpg), rich.data, "the camera JPG is untouched (round \(round))")
        }
    }

    func testARAWOnlyExportCarriesTheRAWsMetadata() async throws {
        let raw = try writeFakeRAW("DSC0003.tif")
        let export = dir.appendingPathComponent("DSC0003-raw-edit.jpg")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(raw: raw)
        try await startEditing(viewModel, photo, isRAW: true)
        let version = viewModel.editedFilesVersion

        viewModel.exportRAWToJPG(replaceExisting: false)

        try await waitForExport(viewModel, from: version)
        XCTAssertEqual(photo.jpgPath, export.path)
        let before = KeptMetadata.properties(try Data(contentsOf: raw))
        let after = KeptMetadata.properties(try Data(contentsOf: export))
        // What describes the RAW's own pixels and encoding can't carry over (see the metadata audit).
        let notCarried: [String: Set<String>] = [
            "{TIFF}": ["Orientation", "Compression", "PhotometricInterpretation", "BitsPerSample", "SamplesPerPixel",
                       "PlanarConfiguration", "RowsPerStrip", "TileWidth", "TileLength"],
            "{Exif}": ["PixelXDimension", "PixelYDimension", "ColorSpace"],
        ]
        for dictionary in ["{TIFF}", "{Exif}", "{GPS}"] {
            let a = try XCTUnwrap(before[dictionary] as? [String: Any], "fixture has \(dictionary)")
            let b = after[dictionary] as? [String: Any] ?? [:]
            for (key, value) in a where !(notCarried[dictionary] ?? []).contains(key) {
                XCTAssertEqual(b[key].map { "\($0)" }, "\(value)", "\(dictionary).\(key) must carry over")
            }
        }
        XCTAssertEqual(after[kCGImagePropertyOrientation as String] as? Int ?? 1, 1, "the pixels are upright")
        XCTAssertEqual(after[kCGImagePropertyPixelWidth as String] as? Int, 160)
        XCTAssertEqual(after[kCGImagePropertyPixelHeight as String] as? Int, 240)
        let metadata = readBack(export)
        XCTAssertEqual(metadata.captureDate, readBack(raw).captureDate, "the capture date carries over")
        XCTAssertNotNil(metadata.captureDate)
        XCTAssertEqual(metadata.rating, 4)
        XCTAssertEqual(Set(metadata.keywords), Set(Self.keywords))
    }

    // MARK: - An export that can't keep the metadata doesn't happen

    /// A JPEG with fill bytes between its header segments: legal, and ImageIO decodes it, but Phocasa can't carry its
    /// segments over safely. Applying the edits would lose its metadata, so the file stays as it is and the edit stays
    /// a saved edit.
    func testApplyingEditsIsRefusedWhenTheMetadataCantBeCarriedOver() async throws {
        let rich = try RichJPEG.make()
        let (segments, sos) = MetadataJPEGPreservationTests.header(rich.data)
        var padded = Data([0xFF, 0xD8])
        for segment in segments { padded += Data([0xFF, 0xFF]) + segment.bytes }
        padded += rich.data[sos...]
        XCTAssertNotNil(CGImageSourceCreateWithData(padded as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) },
                        "fixture: ImageIO decodes it")
        let url = dir.appendingPathComponent("padded.jpg")
        try padded.write(to: url)
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: url)
        try await startEditing(viewModel, photo, isRAW: false)

        viewModel.exportJPGPermanent()

        _ = try await eventually(20, "the refusal is reported") { viewModel.exportFailure }
        await MetadataWriter.shared.flush()
        XCTAssertEqual(try Data(contentsOf: url), padded, "the photo is untouched")
        XCTAssertEqual(viewModel.editSession?.parameters.exposure, 0.5, "the edit is still there")
    }

    /// A camera JPG whose metadata can't be carried over doesn't stop a new `-raw-edit` file: that takes the RAW's.
    func testARAWEditAsANewFileFallsBackToTheRAWsMetadata() async throws {
        let rich = try RichJPEG.make()
        let (segments, sos) = MetadataJPEGPreservationTests.header(rich.data)
        var padded = Data([0xFF, 0xD8])
        for segment in segments { padded += Data([0xFF, 0xFF]) + segment.bytes }
        padded += rich.data[sos...]
        let jpg = dir.appendingPathComponent("DSC0004.jpg")
        try padded.write(to: jpg)
        let raw = try writeFakeRAW("DSC0004.tif")
        let export = dir.appendingPathComponent("DSC0004-raw-edit.jpg")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: jpg, raw: raw)
        try await startEditing(viewModel, photo, isRAW: true)
        let version = viewModel.editedFilesVersion

        viewModel.exportRAWToJPG(replaceExisting: false)

        try await waitForExport(viewModel, from: version)
        let tiff = KeptMetadata.properties(try Data(contentsOf: export))["{TIFF}"] as? [String: Any]
        XCTAssertEqual(tiff?["Make"] as? String, "RawCam")
        XCTAssertEqual(readBack(export).captureDate, readBack(raw).captureDate)
        XCTAssertEqual(try Data(contentsOf: jpg), padded, "the camera JPG is untouched")
        XCTAssertNil(viewModel.exportFailure)
    }

    // MARK: - Real camera files (gated)

    /// Copies of the camera files `PHOCASA_TEST_RAW` and `PHOCASA_TEST_RAW_2` name (a RAW with its JPG beside it),
    /// in this test's folder. They are only read; every write goes to the copies.
    private func realPairs() throws -> [(raw: URL, jpg: URL)] {
        let env = ProcessInfo.processInfo.environment
        let sources = [env["PHOCASA_TEST_RAW"], env["PHOCASA_TEST_RAW_2"]].compactMap { $0 }.filter { !$0.isEmpty }
        guard !sources.isEmpty else { throw XCTSkip("set PHOCASA_TEST_RAW to a camera RAW (a copy) with its JPG beside it") }
        return try sources.map { path in
            let source = URL(fileURLWithPath: path)
            let sourceJPG = try XCTUnwrap(["JPG", "jpg", "jpeg", "JPEG"].lazy
                .map { source.deletingPathExtension().appendingPathExtension($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }, "a JPG beside \(path)")
            let raw = dir.appendingPathComponent(source.lastPathComponent)
            let jpg = dir.appendingPathComponent(sourceJPG.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: raw)
            try FileManager.default.copyItem(at: sourceJPG, to: jpg)
            return (raw, jpg)
        }
    }

    /// The upright size of an image: the JPG decoded with its orientation, or the RAW as `CIRAWFilter` renders it.
    private func uprightSize(_ url: URL, raw: Bool) throws -> CGSize {
        if raw { return try XCTUnwrap(CIRAWFilter(imageURL: url)?.outputImage?.extent.size) }
        let props = KeptMetadata.properties(try Data(contentsOf: url))
        let w = try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int)
        let h = try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int)
        let rotated = [5, 6, 7, 8].contains(props[kCGImagePropertyOrientation as String] as? Int ?? 1)
        return rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    func testRealCameraFilesKeepTheirMetadataThroughEveryExport() async throws {
        for (raw, jpg) in try realPairs() {
            let cameraJPG = try Data(contentsOf: jpg)
            let stem = raw.deletingPathExtension().lastPathComponent
            let export = dir.appendingPathComponent("\(stem)-raw-edit.jpg")
            let rawSize = try uprightSize(raw, raw: true)

            // A new -raw-edit file: the camera JPG's metadata.
            let viewModel = makeViewModel()
            let photo = try insertPhoto(jpg: jpg, raw: raw)
            try await startEditing(viewModel, photo, isRAW: true)
            var version = viewModel.editedFilesVersion
            viewModel.exportRAWToJPG(replaceExisting: false)
            try await waitForExport(viewModel, from: version)
            KeptMetadata.assertKeeps(original: cameraJPG, output: try Data(contentsOf: export), pixelSize: rawSize,
                                     rating: 4, keywords: Self.keywords, readBack: readBack(export))
            XCTAssertEqual(try Data(contentsOf: jpg), cameraJPG, "\(stem): the camera JPG is untouched")

            // Replace the camera JPG: its own metadata, read before it's replaced.
            photo.jpgPath = jpg.path
            try context.save()
            version = viewModel.editedFilesVersion
            viewModel.exportRAWToJPG(replaceExisting: true)
            try await waitForExport(viewModel, from: version)
            KeptMetadata.assertKeeps(original: cameraJPG, output: try Data(contentsOf: jpg), pixelSize: rawSize,
                                     rating: 4, keywords: Self.keywords, readBack: readBack(jpg))
            viewModel.stopEditing(save: false)

            // Bake a JPG edit into a fresh copy of the camera JPG.
            let bakeURL = dir.appendingPathComponent("\(stem)-bake.jpg")
            try cameraJPG.write(to: bakeURL)
            let bakeSize = try uprightSize(bakeURL, raw: false)
            let bakePhoto = try insertPhoto(jpg: bakeURL)
            try await startEditing(viewModel, bakePhoto, isRAW: false)
            version = viewModel.editedFilesVersion
            viewModel.exportJPGPermanent()
            try await waitForExport(viewModel, from: version)
            KeptMetadata.assertKeeps(original: cameraJPG, output: try Data(contentsOf: bakeURL), pixelSize: bakeSize,
                                     rating: 4, keywords: Self.keywords, readBack: readBack(bakeURL))
            viewModel.stopEditing(save: false)
        }
    }

    /// A RAW-only export carries what ImageIO reads from the RAW. Prints what doesn't carry over (`RAWONLY|` lines,
    /// for the metadata audit).
    func testRealRAWOnlyExportCarriesTheRAWsMetadata() async throws {
        for (raw, jpg) in try realPairs() {
            try FileManager.default.removeItem(at: jpg)
            let stem = raw.deletingPathExtension().lastPathComponent
            let export = dir.appendingPathComponent("\(stem)-raw-edit.jpg")
            let viewModel = makeViewModel()
            let photo = try insertPhoto(raw: raw)
            try await startEditing(viewModel, photo, isRAW: true)
            let version = viewModel.editedFilesVersion
            viewModel.exportRAWToJPG(replaceExisting: false)
            try await waitForExport(viewModel, from: version)
            viewModel.stopEditing(save: false)

            // By URL: ImageIO needs the file name to tell a camera RAW from its bytes.
            let before = CGImageSourceCreateWithURL(raw as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
            let after = KeptMetadata.properties(try Data(contentsOf: export))
            for dictionary in KeptMetadata.comparedDictionaries(before) {
                let a = before[dictionary] as? [String: Any] ?? [:], b = after[dictionary] as? [String: Any] ?? [:]
                let lost = a.keys.filter { b[$0] == nil }.sorted()
                let changed = a.keys.filter { b[$0] != nil && "\(b[$0]!)" != "\(a[$0]!)" }.sorted()
                print("RAWONLY|\(stem)|\(dictionary)|kept \(a.count - lost.count - changed.count)/\(a.count)|lost \(lost)|changed \(changed)")
            }
            let size = try uprightSize(raw, raw: true)
            XCTAssertEqual(after[kCGImagePropertyPixelWidth as String] as? Int, Int(size.width))
            XCTAssertEqual(after[kCGImagePropertyOrientation as String] as? Int ?? 1, 1)
            XCTAssertEqual(readBack(export).captureDate, readBack(raw).captureDate, "\(stem): capture date")
            XCTAssertNotNil(readBack(export).captureDate)
            XCTAssertEqual(readBack(export).rating, 4)
            XCTAssertEqual(Set(readBack(export).keywords), Set(Self.keywords))
            let exif = try XCTUnwrap(before["{Exif}"] as? [String: Any]).keys
            let kept = (after["{Exif}"] as? [String: Any] ?? [:]).keys
            // The RAW's own pixel encoding (its sensor pattern and compression) doesn't apply to the JPEG.
            XCTAssertTrue(Set(exif).subtracting(kept).isSubset(of: ["CFAPattern", "CompressedBitsPerPixel"]),
                          "\(stem): Exif carried over, lost \(Set(exif).subtracting(kept).sorted())")
        }
    }
}
