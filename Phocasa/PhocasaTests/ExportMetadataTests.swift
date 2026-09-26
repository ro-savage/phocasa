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

    /// Where replaced originals go: a temp folder, never the user's Trash.
    private var trashDir: URL { dir.appendingPathComponent(".test-trash", isDirectory: true) }

    private func makeViewModel() -> PhotoLibraryViewModel {
        let viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
        viewModels.append(viewModel)
        let trash = trashDir
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        viewModel.library.fileTrasher = FileTrasher { url in
            try FileManager.default.moveItem(
                at: url, to: trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)"))
        }
        return viewModel
    }

    /// The files the temp trash received, by the name they had.
    private func trashed() throws -> [(name: String, data: Data)] {
        try FileManager.default.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil).map {
            (String($0.lastPathComponent.dropFirst(37)), try Data(contentsOf: $0))
        }
    }

    /// Saves the session's edit as a new file and waits for it (and its metadata writes); returns its URL.
    private func exportToNewFile(_ viewModel: PhotoLibraryViewModel) async throws -> URL {
        viewModel.exportNotice = nil
        viewModel.exportToNewFile()
        let notice = try await eventually(20, "the export finishes") {
            viewModel.exportNotice?.message ?? viewModel.exportFailure
        }
        await MetadataWriter.shared.flush()
        XCTAssertNil(viewModel.exportFailure)
        return dir.appendingPathComponent(String(notice.dropFirst("Saved ".count)))
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

    /// The rich JPEG with an Exif structure that can't be walked (IFD0's offset points past its end): ImageIO decodes
    /// the image, but the Exif can't be patched for new pixels, so the metadata can't be carried over.
    private static func unwalkableExifJPEG() throws -> Data {
        let rich = try RichJPEG.make()
        var (segments, sos) = MetadataJPEGPreservationTests.header(rich.data)
        let exif = try XCTUnwrap(segments.firstIndex { $0.id == "Exif" })
        var payload = [UInt8](segments[exif].bytes.dropFirst(4))
        payload[10 + 4] = 0xF0; payload[10 + 5] = 0xFF
        segments[exif] = MetadataJPEGPreservationTests.segment(0xE1, Data(payload))
        return MetadataJPEGPreservationTests.assemble(segments, tail: rich.data[sos...])
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
        let original = try trashed()
        XCTAssertEqual(original.map(\.name), ["cam.jpg"], "a copy of the original went to the Trash first (REL-1 #3)")
        XCTAssertEqual(original.first?.data, rich.data)
    }

    func testReplacingTheExistingJPGKeepsTheCameraJPGsMetadata() async throws {
        let rich = try RichJPEG.make()
        let jpg = dir.appendingPathComponent("DSC0001.jpg")
        try rich.data.write(to: jpg)
        let raw = try writeFakeRAW("DSC0001.tif")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: jpg, raw: raw)
        var jpgEdit = EditParameters()
        jpgEdit.exposure = -1
        photo.jpgEditParameters = jpgEdit
        try context.save()
        try await startEditing(viewModel, photo, isRAW: true)
        let session = try XCTUnwrap(viewModel.editSession)
        session.presentExportOptions()
        XCTAssertEqual(session.exportOptions.replaceableCameraJPG, "DSC0001.jpg", "its bytes are a JPEG")
        // Cancelled at the second step: nothing changes.
        session.pendingExportConfirmation = .replaceCameraJPG
        session.pendingExportConfirmation = nil
        XCTAssertEqual(photo.jpgEditParameters, jpgEdit)
        let version = viewModel.editedFilesVersion

        viewModel.exportReplacingCameraJPG()

        try await waitForExport(viewModel, from: version)
        XCTAssertEqual(photo.jpgPath, jpg.path)
        XCTAssertNil(photo.jpgEditParametersData, "the JPG edit was for the pixels the RAW render replaced")
        let stored = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>()).first { $0.id == photo.id }
        XCTAssertNil(stored?.jpgEditParametersData, "and that's saved")
        let output = try Data(contentsOf: jpg)
        KeptMetadata.assertKeeps(original: rich.data, output: output, pixelSize: CGSize(width: 160, height: 240),
                                 rating: 4, keywords: Self.keywords, readBack: readBack(jpg))
        let tiff = KeptMetadata.properties(output)["{TIFF}"] as? [String: Any]
        XCTAssertEqual(tiff?["Make"] as? String, "TestCam", "the metadata is the JPG's, not the RAW's")
        XCTAssertEqual(try trashed().map(\.data), [rich.data], "the camera JPG went to the Trash first")
    }

    /// Bug test (REL-1 #4): "Create new file" made `<stem>-raw-edit.jpg` the photo's JPG (its thumbnail, JPG edit and
    /// comparison all switched to it, and the next rescan flipped it back and added the export as a photo anyway), and
    /// a second export overwrote the first. The photo keeps its files; each export is a photo of its own, under a free
    /// name, with the photo's rating and tags, and a rescan knows it.
    func testARAWEditAsANewFileCarriesThePairedJPGsMetadata() async throws {
        let rich = try RichJPEG.make()
        let jpg = dir.appendingPathComponent("DSC0002.jpg")
        try rich.data.write(to: jpg)
        _ = try writeFakeRAW("DSC0002.tif")
        // The photo's paths as a scan gives them (`/private/var/…`: `dir` is `/var/…`), as in the app.
        let scanned = await FolderScanner().scan(folderURL: dir)
        let folder = URL(fileURLWithPath: try XCTUnwrap(scanned.first).folderPath)
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: folder.appendingPathComponent("DSC0002.jpg"),
                                    raw: folder.appendingPathComponent("DSC0002.tif"))
        var jpgEdit = EditParameters()
        jpgEdit.exposure = -1
        photo.jpgEditParameters = jpgEdit
        try context.save()
        try await startEditing(viewModel, photo, isRAW: true)
        defer { XCTAssertEqual(photo.jpgEditParameters, jpgEdit, "a new file leaves the camera JPG's edit alone") }

        var exports: [URL] = []
        for round in 1...2 {
            let export = try await exportToNewFile(viewModel)
            exports.append(export)
            XCTAssertEqual(photo.jpgPath, folder.appendingPathComponent("DSC0002.jpg").path,
                           "the photo keeps its camera JPG (round \(round))")
            KeptMetadata.assertKeeps(original: rich.data, output: try Data(contentsOf: export),
                                     pixelSize: CGSize(width: 160, height: 240), rating: 4, keywords: Self.keywords,
                                     readBack: readBack(export))
            XCTAssertEqual(try Data(contentsOf: jpg), rich.data, "the camera JPG is untouched (round \(round))")
        }
        XCTAssertEqual(exports.map(\.lastPathComponent), ["DSC0002-raw-edit.jpg", "DSC0002-raw-edit-2.jpg"],
                       "the second export doesn't overwrite the first")

        let added = viewModel.library.allPhotos.filter { $0.id != photo.id }
        XCTAssertEqual(Set(added.compactMap(\.jpgPath)), Set(exports.map { folder.appendingPathComponent($0.lastPathComponent).path }))
        for export in added {
            XCTAssertNil(export.rawPath)
            XCTAssertEqual(export.rating, 4)
            XCTAssertEqual(Set(export.tags.map(\.fullName)), Set(Self.keywords))
        }
        XCTAssertEqual(viewModel.library.tagCounts.values.sorted(), [3, 3], "the counts include the new photos")
        // A rescan finds them known: nothing new, no duplicate.
        let discovered = await FolderScanner().scan(folderURL: dir)
        let plan = ScanPlan(stored: try StoredPhoto.fetchAllNow(in: container), discovered: discovered)
        XCTAssertEqual(plan.newPhotos.map(\.fileName).filter { $0.contains("raw-edit") }, [], "a rescan adds no export")
    }

    func testARAWOnlyExportCarriesTheRAWsMetadata() async throws {
        let raw = try writeFakeRAW("DSC0003.tif")
        let export = dir.appendingPathComponent("DSC0003-raw-edit.jpg")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(raw: raw)
        try await startEditing(viewModel, photo, isRAW: true)

        let exported = try await exportToNewFile(viewModel); XCTAssertEqual(exported, export)

        XCTAssertNil(photo.jpgPath, "the RAW-only photo stays RAW-only")
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

    /// A JPEG whose Exif structure can't be walked: ImageIO decodes it, but Phocasa can't carry its metadata over
    /// safely. Applying the edits would lose its metadata, so the file stays as it is and the edit stays a saved edit.
    /// (Before task D the fixture used fill bytes between segments, which are legal and now carried over; see
    /// `ExportMetadataCompositionTests.testASourceWithFillBytesIsCarriedOver`.)
    func testApplyingEditsIsRefusedWhenTheMetadataCantBeCarriedOver() async throws {
        let padded = try Self.unwalkableExifJPEG()
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
        XCTAssertTrue(try trashed().isEmpty, "nothing was replaced, so no copy went to the Trash")
    }

    // MARK: - Only JPEGs are replaced, and a copy of the original goes to the Trash first (REL-1 #3)

    /// A still image in `format` (PNG, TIFF, HEIC) at `url`, whatever its name; nil when this Mac can't write it.
    private func writeImage(_ format: UTType, to url: URL) throws -> Data? {
        let jpeg = try RichJPEG.encodedPixels(width: 120, height: 80)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Bug test: "Apply edits permanently" on a HEIC, PNG or TIFF wrote JPEG bytes over it (losing 16-bit pixels,
    /// alpha, layers, depth). The dialog doesn't offer it for them (a file named `.jpg` isn't trusted either), and the
    /// service refuses to replace them if asked anyway.
    func testANonJPEGIsNeverOverwritten() async throws {
        let files: [(UTType, String)] = [(.png, "shot.png"), (.tiff, "scan.tiff"), (.heic, "phone.heic"), (.png, "fake.jpg")]
        for (format, name) in files {
            let url = dir.appendingPathComponent(name)
            guard let original = try writeImage(format, to: url) else { continue }
            let viewModel = makeViewModel()
            let photo = try insertPhoto(jpg: url)
            try await startEditing(viewModel, photo, isRAW: false)
            let session = try XCTUnwrap(viewModel.editSession)
            session.presentExportOptions()
            XCTAssertFalse(session.exportOptions.canApplyPermanently, "\(name): not offered")

            viewModel.exportJPGPermanent()

            let failure = try await eventually(20, "\(name): refused") { viewModel.exportFailure }
            XCTAssertTrue(failure.contains("isn't a JPEG"), failure)
            XCTAssertEqual(try Data(contentsOf: url), original, "\(name) is untouched")
            XCTAssertTrue(try trashed().isEmpty)
            viewModel.stopEditing(save: false)
        }
    }

    /// Bug test: for a Canon/Sony HEIF+RAW pair, "Replace existing JPG" wrote the RAW's JPEG over the HEIF. A RAW
    /// session offers no replace unless the other file is a JPEG by its bytes, and the service refuses anyway.
    func testReplacingAPairsNonJPEGFileIsRefused() async throws {
        let heif = dir.appendingPathComponent("IMG_0001.jpg") // HEIC bytes under a JPG name
        guard let original = try writeImage(.heic, to: heif) ?? writeImage(.png, to: heif) else {
            throw XCTSkip("can't write a HEIC or PNG here")
        }
        let raw = try writeFakeRAW("IMG_0001.tif")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: heif, raw: raw)
        photo.jpgEditParameters = EditParameters(exposure: -1)
        try context.save()
        try await startEditing(viewModel, photo, isRAW: true)
        let session = try XCTUnwrap(viewModel.editSession)
        session.presentExportOptions()
        XCTAssertNil(session.exportOptions.replaceableCameraJPG)

        let result = await session.exportReplacingCameraJPG(originalTo: viewModel.library.fileTrasher)

        XCTAssertEqual(result, .notAJPEG)
        XCTAssertEqual(try Data(contentsOf: heif), original)
        XCTAssertEqual(photo.jpgEditParameters?.exposure, -1, "a refused replace keeps the saved edit")
        XCTAssertTrue(try trashed().isEmpty)
    }

    /// If the copy of the original can't be put in the Trash, the JPEG isn't replaced.
    func testAJPEGIsNotReplacedWhenItsOriginalCantGoToTheTrash() async throws {
        let rich = try RichJPEG.make()
        let url = dir.appendingPathComponent("keep.jpg")
        try rich.data.write(to: url)
        let refusing = FileTrasher { _ in throw CocoaError(.featureUnsupported) }

        let result = await ImageEditingService.shared.exportStandardToJPEG(
            sourceURL: url, parameters: EditParameters(), to: .replacing(url, originalTo: refusing))

        XCTAssertEqual(result, .originalNotTrashed)
        XCTAssertEqual(try Data(contentsOf: url), rich.data)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(left.contains { $0.hasPrefix(".phocasa-original") }, "the copy is cleaned up: \(left)")
    }

    /// A new file never overwrites one that is there.
    func testANewFileExportNeverOverwrites() async throws {
        let rich = try RichJPEG.make()
        let source = dir.appendingPathComponent("src.jpg")
        try rich.data.write(to: source)
        let taken = dir.appendingPathComponent("taken.jpg")
        try Data("someone's file".utf8).write(to: taken)

        let result = await ImageEditingService.shared.exportStandardToJPEG(
            sourceURL: source, parameters: EditParameters(), to: .newFile(taken))

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(try Data(contentsOf: taken), Data("someone's file".utf8))
    }

    /// New files take the first free name: not one a file in the folder has with any extension or case, nor one a
    /// photo of the library has (its file may be missing).
    func testNewFilesTakeAFreeName() async throws {
        XCTAssertEqual(EditSession.freeExportStem("A", suffix: "edit") { _ in false }, "A-edit")
        XCTAssertEqual(EditSession.freeExportStem("A", suffix: "edit") { ["A-edit", "A-edit-2"].contains($0) }, "A-edit-3")

        let rich = try RichJPEG.make()
        let jpg = dir.appendingPathComponent("P1.jpg")
        try rich.data.write(to: jpg)
        try Data().write(to: dir.appendingPathComponent("P1-edit.JPEG"))
        let missing = PhotoAsset(fileName: "P1-edit-2", jpgPath: dir.appendingPathComponent("P1-edit-2.jpg").path,
                                 folderPath: dir.path)
        context.insert(missing)
        try context.save()
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: jpg)
        try await startEditing(viewModel, photo, isRAW: false)

        let exported = try await exportToNewFile(viewModel); XCTAssertEqual(exported.lastPathComponent, "P1-edit-3.jpg")
    }

    /// A camera JPG whose metadata can't be carried over doesn't stop a new `-raw-edit` file: that takes the RAW's.
    func testARAWEditAsANewFileFallsBackToTheRAWsMetadata() async throws {
        let padded = try Self.unwalkableExifJPEG()
        let jpg = dir.appendingPathComponent("DSC0004.jpg")
        try padded.write(to: jpg)
        let raw = try writeFakeRAW("DSC0004.tif")
        let export = dir.appendingPathComponent("DSC0004-raw-edit.jpg")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: jpg, raw: raw)
        try await startEditing(viewModel, photo, isRAW: true)

        let exported = try await exportToNewFile(viewModel); XCTAssertEqual(exported, export)

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
            // The copies are the test's to write, whatever the source's permissions (a read-only file is left alone).
            for copy in [raw, jpg] {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
            }
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
            let exported = try await exportToNewFile(viewModel); XCTAssertEqual(exported, export)
            KeptMetadata.assertKeeps(original: cameraJPG, output: try Data(contentsOf: export), pixelSize: rawSize,
                                     rating: 4, keywords: Self.keywords, readBack: readBack(export))
            XCTAssertEqual(try Data(contentsOf: jpg), cameraJPG, "\(stem): the camera JPG is untouched")

            // Replace the camera JPG: its own metadata, read before it's replaced.
            var version = viewModel.editedFilesVersion
            viewModel.exportReplacingCameraJPG()
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
            let exported = try await exportToNewFile(viewModel); XCTAssertEqual(exported, export)
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
