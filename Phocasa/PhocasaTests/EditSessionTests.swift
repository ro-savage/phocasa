// Tests for EditSession (task 22): render scheduling, saving (JPG → model, RAW → MetadataWriter), revert, the
// JPG comparison, crop, presets, and the view model's session lifecycle.
//
// Everything runs on generated JPEGs and fake RAW paths (a RAW path only needs its `.xmp` sidecar here) in a temp
// folder, with a temp-file SwiftData store. The one test that needs a real RAW file skips unless PHOCASA_TEST_RAW
// names one (set TEST_RUNNER_PHOCASA_TEST_RAW to a *copy*: the test writes next to it).

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftData
@testable import Phocasa

@MainActor
final class EditSessionTests: XCTestCase {
    private var dir: URL!
    private var container: ModelContainer!
    private var context: ModelContext!
    /// Sessions a test created; ended in tearDown so no render outlives its test.
    private var sessions: [EditSession] = []
    private var viewModels: [PhotoLibraryViewModel] = []

    /// Every test's folder lives in here. A test deletes its own folder once its SwiftData store has closed (the store
    /// can outlive the test briefly, through objects finishing tasks still hold, and deleting an open store makes
    /// SQLite complain). The root goes when the class is done.
    private nonisolated static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("phocasa-22-EditSessionTests-\(UUID().uuidString)", isDirectory: true)

    override class func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    override func setUp() async throws {
        dir = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(url: dir.appendingPathComponent("test.store"))
        )
        context = ModelContext(container)
        // The code under test saves explicitly; an autosave firing after the test would only save test leftovers.
        context.autosaveEnabled = false
    }

    override func tearDown() async throws {
        for viewModel in viewModels { viewModel.stopEditing(save: false) }
        for session in sessions { session.end(save: false) }
        sessions = []
        viewModels = []
        // Let queued sidecar writes land before the next test.
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

    private func makeJPEG(_ name: String = "photo.jpg", width: Int = 1200, height: Int = 800,
                          orientation: UInt32 = 1, detail: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try EditTestImages.writeJPEG(to: url, width: width, height: height, orientation: orientation, detail: detail)
        return url
    }

    @discardableResult
    private func insertPhoto(jpg: URL? = nil, raw: URL? = nil, created: Date = Date()) throws -> PhotoAsset {
        let photo = PhotoAsset(fileName: (jpg ?? raw)?.lastPathComponent ?? "fake", jpgPath: jpg?.path,
                               rawPath: raw?.path, folderPath: dir.path, creationDate: created)
        context.insert(photo)
        try context.save()
        return photo
    }

    private func makeSession(_ photo: PhotoAsset, isRAW: Bool = false) -> EditSession {
        let session = EditSession(photo: photo, isRAW: isRAW, modelContext: context)
        sessions.append(session)
        return session
    }

    /// A session on a photo whose file doesn't exist (renders fail, which the crop tests don't need).
    private func makeFakeJPGSession() throws -> EditSession {
        makeSession(try insertPhoto(jpg: dir.appendingPathComponent("missing.jpg")))
    }

    private func makeViewModel() -> PhotoLibraryViewModel {
        let viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
        viewModels.append(viewModel)
        return viewModel
    }

    private func waitFor<T>(_ seconds: Double = 5, _ body: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if let value = body() { return value }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return body()
    }

    struct Timeout: Error {}

    /// Waits until `body` returns a value; fails the test and throws if none arrives in time.
    private func eventually<T>(_ seconds: Double = 5, _ message: String = "timed out",
                               file: StaticString = #filePath, line: UInt = #line,
                               _ body: () -> T?) async throws -> T {
        if let value = await waitFor(seconds, body) { return value }
        XCTFail(message, file: file, line: line)
        throw Timeout()
    }

    private func exposure(_ value: Double) -> EditParameters {
        var params = EditParameters()
        params.exposure = value
        return params
    }

    /// Copies of a ~3 MB noise JPEG, enough rating writes to keep the shared `MetadataWriter` busy for tens of ms.
    private func busyWrites(count: Int = 10) throws -> [MetadataWriteItem] {
        let side = 1500
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        var state: UInt32 = 12345
        for i in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 1664525 &+ 1013904223
            bytes[i] = UInt8(truncatingIfNeeded: state >> 24)
            bytes[i + 1] = UInt8(truncatingIfNeeded: state >> 16)
            bytes[i + 2] = UInt8(truncatingIfNeeded: state >> 8)
        }
        let image: CGImage = try bytes.withUnsafeMutableBytes { buffer in
            let ctx = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                              bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
        let first = dir.appendingPathComponent("busy-0.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(first as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        var urls = [first]
        for i in 1..<count {
            let url = dir.appendingPathComponent("busy-\(i).jpg")
            try FileManager.default.copyItem(at: first, to: url)
            urls.append(url)
        }
        return urls.map { MetadataWriteItem(path: $0.path, rating: 2, keywords: []) }
    }

    // MARK: - Crop (ported from ViewModelTests)

    func testApplyCropFull() throws {
        let session = try makeFakeJPGSession()
        session.cropRect = .full
        session.parameters.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        session.isCropping = true

        session.applyCrop()

        XCTAssertNil(session.parameters.cropRect, "Full crop rect should be cleared to nil")
        XCTAssertFalse(session.isCropping)
    }

    func testApplyCropApproximatelyFull() throws {
        let session = try makeFakeJPGSession()
        session.cropRect = NormalizedRect(x: 0.0001, y: -0.0001, width: 0.9999, height: 1.0001)
        session.isCropping = true

        session.applyCrop()

        XCTAssertNil(session.parameters.cropRect, "Approximately full crop should be cleared to nil")
    }

    func testApplyCropPartial() throws {
        let session = try makeFakeJPGSession()
        let crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        session.cropRect = crop
        session.isCropping = true

        session.applyCrop()

        XCTAssertEqual(session.parameters.cropRect, crop)
        XCTAssertFalse(session.isCropping)
    }

    func testEnterCropMode() throws {
        let session = try makeFakeJPGSession()
        session.parameters.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        session.enterCropMode()

        XCTAssertTrue(session.isCropping)
        XCTAssertEqual(session.cropRect.x, 0.1)
    }

    func testEnterCropModeNoCrop() throws {
        let session = try makeFakeJPGSession()
        session.parameters.cropRect = nil

        session.enterCropMode()

        XCTAssertTrue(session.isCropping)
        XCTAssertEqual(session.cropRect, .full)
    }

    func testCancelCrop() throws {
        let session = try makeFakeJPGSession()
        let existing = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        session.parameters.cropRect = existing
        session.isCropping = true
        session.cropRect = NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)

        session.cancelCrop()

        XCTAssertEqual(session.cropRect, existing)
        XCTAssertFalse(session.isCropping)
    }

    // MARK: - Presets (ported from ViewModelTests; presets stay in the view model)

    /// A view model editing a (fake) JPG.
    private func makeEditingViewModel() throws -> (PhotoLibraryViewModel, EditSession) {
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: dir.appendingPathComponent("missing.jpg"))
        viewModel.startEditing(photo: photo, isRAW: false)
        return (viewModel, try XCTUnwrap(viewModel.editSession))
    }

    func testSaveAndLoadPreset() throws {
        let (viewModel, session) = try makeEditingViewModel()
        session.parameters.exposure = 2.0
        session.parameters.contrast = 30
        viewModel.presetNameInput = "My Preset"

        viewModel.savePreset()

        XCTAssertEqual(viewModel.editPresets.count, 1)
        XCTAssertEqual(viewModel.editPresets.first?.name, "My Preset")
        XCTAssertEqual(viewModel.editPresets.first?.parameters.exposure, 2.0)
        XCTAssertTrue(viewModel.presetNameInput.isEmpty)
    }

    func testSavePresetEmptyNameIgnored() {
        let viewModel = makeViewModel()
        viewModel.presetNameInput = "   "

        viewModel.savePreset()

        XCTAssertTrue(viewModel.editPresets.isEmpty)
    }

    func testDeletePreset() throws {
        let (viewModel, session) = try makeEditingViewModel()
        session.parameters.exposure = 1.0
        viewModel.presetNameInput = "Test"
        viewModel.savePreset()
        XCTAssertEqual(viewModel.editPresets.count, 1)

        viewModel.deletePreset(viewModel.editPresets.first!)

        XCTAssertTrue(viewModel.editPresets.isEmpty)
    }

    func testApplyPreset() throws {
        let (viewModel, session) = try makeEditingViewModel()
        session.parameters.exposure = 1.0
        viewModel.presetNameInput = "Warm"
        viewModel.savePreset()

        session.parameters = EditParameters()
        XCTAssertEqual(session.parameters.exposure, 0)

        viewModel.applyPreset(viewModel.editPresets.first!)

        XCTAssertEqual(session.parameters.exposure, 1.0)
    }

    func testApplyPresetToSelectionWritesRAWEditsThroughTheWriter() async throws {
        let viewModel = makeViewModel()
        let raw = dir.appendingPathComponent("preset.ARW")
        let photo = try insertPhoto(jpg: try makeJPEG("preset.jpg", width: 60, height: 40, detail: false), raw: raw)
        viewModel.loadExistingData()
        viewModel.selection.toggleSelection(for: photo, addToSelection: false)
        let preset = EditPreset(name: "P", parameters: exposure(0.8))
        context.insert(preset)

        viewModel.applyPresetToSelection(preset)

        XCTAssertEqual(photo.jpgEditParameters?.exposure, 0.8)
        XCTAssertTrue(photo.hasRawEdits)
        XCTAssertEqual(RAWEditStore.shared.parameters(forRAWAt: raw.path)?.exposure, 0.8, "readable before the write lands")
        await MetadataWriter.shared.flush()
        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, 0.8)
    }

    // MARK: - Rendering

    func testSettingParametersProducesPreview() async throws {
        let session = makeSession(try insertPhoto(jpg: try makeJPEG(width: 3000, height: 2000)))

        session.parameters.exposure = 0.7

        let preview = await waitFor(2) { session.previewImage }
        let cg = try XCTUnwrap(preview.flatMap(EditTestImages.cgImage), "a preview within 2 s")
        XCTAssertLessThanOrEqual(cg.width, 1600)
        XCTAssertLessThanOrEqual(cg.height, 1100)
        XCTAssertEqual(cg.width, 1600, "fitted to 1600×1100")
    }

    func testRapidParameterChangesKeepLatestResult() async throws {
        let url = try makeJPEG()
        let session = makeSession(try insertPhoto(jpg: url))
        let rendersBefore = ImageEditingService.shared.renderCount

        for i in 0..<10 {
            session.parameters.exposure = -0.9 + Double(i) * 0.2
        }

        let preview = try await eventually { session.previewImage }
        XCTAssertEqual(ImageEditingService.shared.renderCount - rendersBefore, 1,
                       "the 9 superseded values never render (the full pass follows 300 ms later)")
        let expectedImage = await ImageEditingService.shared.processStandard(
            url: url, parameters: exposure(0.9), maxSize: EditSession.previewSize, lane: .preview)
        let expected = try XCTUnwrap(expectedImage)
        let difference = EditTestImages.maxChannelDifference(try XCTUnwrap(EditTestImages.cgImage(preview)),
                                                             try XCTUnwrap(EditTestImages.cgImage(expected)))
        XCTAssertNotNil(difference, "same size")
        XCTAssertLessThanOrEqual(difference ?? 255, 1, "the preview shows the last value")
    }

    func testFullResolutionPassFollowsThePreview() async throws {
        let session = makeSession(try insertPhoto(jpg: try makeJPEG(width: 2400, height: 1600)))

        session.parameters.exposure = 0.4

        _ = try await eventually { session.previewImage }
        XCTAssertNil(session.fullImage, "the full-resolution pass waits 300 ms after the preview")
        let full = try await eventually { session.fullImage }
        let cg = try XCTUnwrap(EditTestImages.cgImage(full))
        XCTAssertEqual(CGSize(width: cg.width, height: cg.height), CGSize(width: 2400, height: 1600))

        session.parameters.exposure = 0.5
        XCTAssertNil(session.fullImage, "a change drops the full-resolution render of the old value")
    }

    func testBeginRendersTheSavedEdit() async throws {
        let photo = try insertPhoto(jpg: try makeJPEG())
        photo.jpgEditParameters = exposure(1)
        try context.save()
        let session = makeSession(photo)
        XCTAssertEqual(session.parameters.exposure, 1, "a JPG session starts from the saved parameters")

        await session.begin()

        _ = try await eventually { session.fullImage }
    }

    func testEndCancelsPendingRenders() async throws {
        let session = makeSession(try insertPhoto(jpg: try makeJPEG()))
        let rendersBefore = ImageEditingService.shared.renderCount

        session.parameters.exposure = 1
        session.end(save: false)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(session.previewImage)
        XCTAssertNil(session.fullImage)
        XCTAssertEqual(ImageEditingService.shared.renderCount, rendersBefore, "nothing was rendered")
        XCTAssertNil(session.photo.jpgEditParameters, "end(save: false) doesn't save")
    }

    func testEndWithSaveHandsOverTheLatestRender() async throws {
        let session = makeSession(try insertPhoto(jpg: try makeJPEG()))
        session.parameters.exposure = 1
        let full = try await eventually { session.fullImage }

        let handoff = try XCTUnwrap(session.end(save: true))

        XCTAssertEqual(handoff.photoID, session.photo.id)
        XCTAssertEqual(handoff.saved, SavedEditKey(isRAW: false, parameters: exposure(1)))
        XCTAssertTrue(handoff.fullResolutionImage(for: handoff.saved) === full)
        XCTAssertEqual(session.photo.jpgEditParameters?.exposure, 1)
        XCTAssertNil(session.previewImage, "the session lets go of its renders")
    }

    // MARK: - Saving

    func testSaveJPGPersistsToModel() throws {
        let photo = try insertPhoto(jpg: try makeJPEG())
        let session = makeSession(photo)
        session.parameters.exposure = 1.25

        session.save()

        let id = photo.id
        let stored = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.id == id }))
        XCTAssertEqual(stored.first?.jpgEditParameters?.exposure, 1.25, "saved to the store")

        session.parameters = EditParameters()
        session.save()
        let cleared = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.id == id }))
        XCTAssertNil(cleared.first?.jpgEditParametersData, "default parameters clear the saved edit")
    }

    func testSaveRAWGoesThroughWriter() async throws {
        let raw = dir.appendingPathComponent("rawonly.ARW")
        let photo = try insertPhoto(raw: raw)
        let session = makeSession(photo, isRAW: true)
        await session.begin()
        session.parameters.exposure = -0.75

        session.save()

        XCTAssertTrue(photo.hasRawEdits)
        await MetadataWriter.shared.flush()
        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, -0.75)
    }

    /// Bug test (spec §F3, §G5): a RAW edit save used to write the sidecar synchronously on the main thread, next to
    /// (and racing) the rating writes `MetadataWriter` makes to the same sidecar. It now queues behind them.
    func testRAWSaveIsQueuedOnMetadataWriter() async throws {
        let busy = try busyWrites()
        let raw = dir.appendingPathComponent("rawonly.ARW")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(raw: raw)
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)
        viewModel.startEditing(photo: photo, isRAW: true)
        let session = try XCTUnwrap(viewModel.editSession)
        await session.begin()
        session.parameters.exposure = 1.5

        MetadataWriter.shared.enqueue(busy)
        viewModel.stopEditing(save: true)
        XCTAssertNil(MetadataService.shared.readEditParameters(forRAWAt: raw.path),
                     "the edit write must be queued behind the writes already pending, not done on the main thread")
        await MetadataWriter.shared.flush()
        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, 1.5)
        XCTAssertTrue(photo.hasRawEdits)
    }

    func testRAWEditAndRatingOnOneSidecarBothLand() async throws {
        let raw = dir.appendingPathComponent("rated.ARW")
        let viewModel = makeViewModel()
        let photo = try insertPhoto(raw: raw)
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)
        viewModel.startEditing(photo: photo, isRAW: true)
        let session = try XCTUnwrap(viewModel.editSession)
        await session.begin()
        session.parameters.exposure = 0.6

        viewModel.library.setRating(3, for: photo)
        viewModel.stopEditing(save: true)
        viewModel.library.setRating(4, for: photo)
        await MetadataWriter.shared.flush()

        XCTAssertEqual(MetadataService.shared.readMetadata(from: raw.path).rating, 4)
        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, 0.6)
    }

    /// Saves are asynchronous now, so a read right after one (a new session, the detail view's saved-edit render)
    /// must see the new value before the writer has written it.
    func testSavedRAWParametersAreReadBackBeforeTheWriterRuns() async throws {
        let busy = try busyWrites()
        let raw = dir.appendingPathComponent("again.ARW")
        let photo = try insertPhoto(raw: raw)
        let first = makeSession(photo, isRAW: true)
        await first.begin()
        first.parameters.exposure = 1.5

        MetadataWriter.shared.enqueue(busy)
        first.end(save: true)
        XCTAssertNil(MetadataService.shared.readEditParameters(forRAWAt: raw.path), "not written yet")

        let second = makeSession(photo, isRAW: true)
        await second.begin()
        XCTAssertEqual(second.parameters.exposure, 1.5)
        XCTAssertEqual(RAWEditStore.shared.parameters(forRAWAt: raw.path)?.exposure, 1.5)
        await MetadataWriter.shared.flush()
        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, 1.5)
    }

    /// A RAW session starts from the sidecar's parameters straight away (read in `init`), so clicking the RAW button
    /// twice quickly saves the edit back unchanged. (A first version loaded them in `begin()`, asynchronously; this
    /// test caught that version saving its placeholder defaults over the saved edit.)
    func testQuickRAWStartAndStopKeepsTheSavedEdit() async throws {
        let raw = dir.appendingPathComponent("quick.ARW")
        MetadataService.shared.writeEditParameters(exposure(1), forRAWAt: raw.path)
        let photo = try insertPhoto(raw: raw)
        photo.hasRawEdits = true
        try context.save()
        let viewModel = makeViewModel()
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)

        viewModel.startEditing(photo: photo, isRAW: true)
        XCTAssertEqual(viewModel.editSession?.parameters.exposure, 1, "the sliders show the saved edit at once")
        viewModel.stopEditing(save: true)   // before begin() has run

        await MetadataWriter.shared.flush()
        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, 1)
        XCTAssertTrue(photo.hasRawEdits)
        XCTAssertEqual(viewModel.savedEditHandoff?.saved, SavedEditKey(isRAW: true, parameters: exposure(1)))
    }

    // MARK: - Revert

    func testRevertClearsSavedEdits() async throws {
        // JPG
        let photo = try insertPhoto(jpg: try makeJPEG(), raw: dir.appendingPathComponent("photo.ARW"))
        photo.jpgEditParameters = exposure(1)
        try context.save()
        let jpgSession = makeSession(photo)
        XCTAssertEqual(jpgSession.parameters.exposure, 1)
        jpgSession.revert()
        XCTAssertTrue(jpgSession.parameters.isDefault)
        XCTAssertNil(photo.jpgEditParametersData)

        // RAW
        let rawPath = try XCTUnwrap(photo.rawPath)
        MetadataService.shared.writeEditParameters(exposure(2), forRAWAt: rawPath)
        photo.hasRawEdits = true
        try context.save()
        let rawSession = makeSession(photo, isRAW: true)
        await rawSession.begin()
        XCTAssertEqual(rawSession.parameters.exposure, 2, "the sidecar's parameters are loaded")
        rawSession.revert()
        XCTAssertTrue(rawSession.parameters.isDefault)
        XCTAssertFalse(photo.hasRawEdits)
        await MetadataWriter.shared.flush()
        XCTAssertNil(MetadataService.shared.readEditParameters(forRAWAt: rawPath))
    }

    func testRevertEditsForPhotoClearsTheSidecarThroughTheWriter() async throws {
        let viewModel = makeViewModel()
        let raw = dir.appendingPathComponent("grid.ARW")
        MetadataService.shared.writeEditParameters(exposure(1), forRAWAt: raw.path)
        let photo = try insertPhoto(raw: raw)
        photo.hasRawEdits = true
        try context.save()

        viewModel.revertEditsForPhoto(photo)

        XCTAssertFalse(photo.hasRawEdits)
        XCTAssertNil(RAWEditStore.shared.parameters(forRAWAt: raw.path))
        await MetadataWriter.shared.flush()
        XCTAssertNil(MetadataService.shared.readEditParameters(forRAWAt: raw.path))
    }

    func testResetAndCopyFromJPG() throws {
        let photo = try insertPhoto(jpg: dir.appendingPathComponent("missing.jpg"), raw: dir.appendingPathComponent("missing.ARW"))
        let session = makeSession(photo, isRAW: true)
        XCTAssertFalse(session.canCopyFromJPG)
        photo.jpgEditParameters = exposure(0.3)
        try context.save()
        XCTAssertTrue(session.canCopyFromJPG)

        session.copyJPGSettings()
        XCTAssertEqual(session.parameters.exposure, 0.3)

        session.resetAllParameters()
        XCTAssertTrue(session.parameters.isDefault)
        XCTAssertEqual(photo.jpgEditParameters?.exposure, 0.3, "reset doesn't touch saved edits")
    }

    // MARK: - JPG comparison

    /// Bug test (spec §D1): the JPG side of the comparison was decoded with `loadFullResolution`, which ignores
    /// EXIF orientation, so a portrait JPG showed sideways. It now carries its orientation.
    func testJPGComparisonImageIsOriented() async throws {
        let jpg = try makeJPEG("pair.jpg", width: 600, height: 400, orientation: 6, detail: false)
        let photo = try insertPhoto(jpg: jpg, raw: dir.appendingPathComponent("pair.ARW"))
        let session = makeSession(photo, isRAW: true)

        session.toggleJPGComparison()

        let shown = try await eventually { session.jpgComparisonImage }
        XCTAssertEqual(shown.orientation, .right)
        XCTAssertEqual(shown.orientedSize.width / shown.orientedSize.height, 400.0 / 600.0, accuracy: 0.01,
                       "a portrait JPG (EXIF 6) shows upright: \(shown.orientedSize)")
    }

    func testJPGComparisonShowsTheSavedJPGEditUpright() async throws {
        let jpg = try makeJPEG("pair.jpg", width: 600, height: 400, orientation: 6, detail: false)
        let photo = try insertPhoto(jpg: jpg, raw: dir.appendingPathComponent("pair.ARW"))
        photo.jpgEditParameters = exposure(0.5)
        try context.save()
        let session = makeSession(photo, isRAW: true)

        session.toggleJPGComparison()

        let shown = try await eventually { session.jpgComparisonImage }
        XCTAssertEqual(shown.orientation, .up, "the edit pipeline renders upright")
        XCTAssertEqual(shown.orientedSize, CGSize(width: 400, height: 600))
    }

    func testSideBySideAndJPGComparisonExcludeEachOther() async throws {
        let jpg = try makeJPEG("pair.jpg", width: 60, height: 40, detail: false)
        let session = makeSession(try insertPhoto(jpg: jpg, raw: dir.appendingPathComponent("pair.ARW")), isRAW: true)

        session.toggleJPGComparison()
        XCTAssertTrue(session.showJPGComparison)
        _ = try await eventually { session.jpgComparisonImage }

        session.showSideBySide = true
        XCTAssertFalse(session.showJPGComparison)
        XCTAssertNil(session.jpgComparisonImage)

        session.toggleJPGComparison()
        XCTAssertTrue(session.showJPGComparison)
        XCTAssertFalse(session.showSideBySide)
        session.toggleJPGComparison()
        XCTAssertFalse(session.showJPGComparison)
        XCTAssertNil(session.jpgComparisonImage)
    }

    // MARK: - View model lifecycle

    func testEndedSessionIsReleased() async throws {
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: try makeJPEG())
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)
        viewModel.startEditing(photo: photo, isRAW: false)
        weak let session = viewModel.editSession
        session?.parameters.exposure = 0.5
        _ = try await eventually { session?.fullImage }
        session?.toggleJPGComparison()

        viewModel.stopEditing(save: true)
        viewModel.closeDetail()

        _ = try await eventually(2, "the session (and its renders) is freed") { session == nil ? true : nil }
    }

    func testViewModelIsReleasedAfterEditing() async throws {
        weak var weakViewModel: PhotoLibraryViewModel?
        do {
            let viewModel = PhotoLibraryViewModel()
            viewModel.setModelContext(context)
            let photo = try insertPhoto(jpg: try makeJPEG())
            viewModel.loadExistingData()
            viewModel.openDetail(for: photo)
            viewModel.startEditing(photo: photo, isRAW: false)
            viewModel.editSession?.parameters.exposure = 0.5
            _ = try await eventually { viewModel.editSession?.previewImage }
            viewModel.stopEditing(save: true)
            viewModel.closeDetail()
            weakViewModel = viewModel
        }
        _ = try await eventually(2, "nothing keeps the view model alive") { weakViewModel == nil ? true : nil }
    }

    func testStartAndStopEditing() throws {
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: try makeJPEG())
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)

        viewModel.startEditing(photo: photo, isRAW: false)
        XCTAssertTrue(viewModel.isEditing)
        XCTAssertEqual(viewModel.editSession?.photo.id, photo.id)
        XCTAssertEqual(viewModel.editSession?.isRAW, false)
        viewModel.editSession?.parameters.exposure = 0.5

        viewModel.stopEditing(save: true)
        XCTAssertFalse(viewModel.isEditing)
        XCTAssertNil(viewModel.editSession)
        XCTAssertEqual(photo.jpgEditParameters?.exposure, 0.5)
        XCTAssertEqual(viewModel.savedEditHandoff?.photoID, photo.id, "the detail view is told what was saved")

        viewModel.closeDetail()
        XCTAssertNil(viewModel.savedEditHandoff, "released with the detail view")
    }

    func testStartEditingWhileEditingSavesTheCurrentSession() throws {
        let viewModel = makeViewModel()
        let photo = try insertPhoto(jpg: dir.appendingPathComponent("missing.jpg"), raw: dir.appendingPathComponent("missing.ARW"))
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)
        viewModel.startEditing(photo: photo, isRAW: false)
        let jpgSession = try XCTUnwrap(viewModel.editSession)
        jpgSession.parameters.exposure = 0.25

        viewModel.startEditing(photo: photo, isRAW: true)

        XCTAssertEqual(photo.jpgEditParameters?.exposure, 0.25, "the JPG session was saved")
        XCTAssertTrue(jpgSession.hasEnded)
        XCTAssertEqual(viewModel.editSession?.isRAW, true)
        XCTAssertTrue(viewModel.editSession?.parameters.isDefault ?? false)
    }

    /// Bug test: navigating while editing saved the photo being left, but the editing state stayed on. Leaving edit
    /// mode on the next photo then saved the *previous* photo's parameters onto it (or cleared its edits). A session
    /// belongs to one photo now: navigating saves it and starts one on the next photo.
    func testNavigatingWhileEditingSavesAndEditsTheNextPhoto() throws {
        let viewModel = makeViewModel()
        let now = Date()
        let first = try insertPhoto(jpg: dir.appendingPathComponent("a.jpg"), created: now)
        let second = try insertPhoto(jpg: dir.appendingPathComponent("b.jpg"), created: now.addingTimeInterval(-60))
        second.jpgEditParameters = exposure(-1)
        try context.save()
        viewModel.loadExistingData()
        XCTAssertEqual(viewModel.library.photos.map(\.id), [first.id, second.id])
        viewModel.openDetail(for: first)
        viewModel.startEditing(photo: first, isRAW: false)
        viewModel.editSession?.parameters.exposure = 1

        viewModel.navigateDetail(direction: 1)

        XCTAssertEqual(first.jpgEditParameters?.exposure, 1, "the photo left behind was saved")
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, second.id)
        XCTAssertEqual(viewModel.editSession?.photo.id, second.id, "still editing, now the next photo")
        XCTAssertEqual(viewModel.editSession?.parameters.exposure, -1, "with the next photo's own parameters")

        viewModel.stopEditing(save: true)
        XCTAssertEqual(second.jpgEditParameters?.exposure, -1, "the next photo keeps its own edit")
        XCTAssertEqual(first.jpgEditParameters?.exposure, 1)
    }

    func testNavigatingToAPhotoWithoutThatKindStopsEditing() throws {
        let viewModel = makeViewModel()
        let now = Date()
        let first = try insertPhoto(raw: dir.appendingPathComponent("a.ARW"), created: now)
        _ = try insertPhoto(jpg: dir.appendingPathComponent("b.jpg"), created: now.addingTimeInterval(-60))
        viewModel.loadExistingData()
        viewModel.openDetail(for: first)
        viewModel.startEditing(photo: first, isRAW: true)

        viewModel.navigateDetail(direction: 1)

        XCTAssertFalse(viewModel.isEditing, "the next photo has no RAW to edit")
    }

    func testExportJPGPermanentBakesTheEditAndClearsIt() async throws {
        let viewModel = makeViewModel()
        let url = try makeJPEG(width: 300, height: 200, detail: false)
        let photo = try insertPhoto(jpg: url)
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)
        viewModel.startEditing(photo: photo, isRAW: false)
        let session = try XCTUnwrap(viewModel.editSession)
        let originalBytes = try Data(contentsOf: url)
        let uneditedImage = await ImageEditingService.shared.processStandard(
            url: url, parameters: EditParameters(), maxSize: EditSession.previewSize, lane: .preview)
        let unedited = try XCTUnwrap(uneditedImage)
        session.parameters.exposure = 1.5
        _ = await waitFor { session.previewImage }
        let version = viewModel.editedFilesVersion

        viewModel.exportJPGPermanent()

        _ = try await eventually(5, "the detail view reloads") { viewModel.editedFilesVersion != version ? true : nil }
        XCTAssertNotEqual(try Data(contentsOf: url), originalBytes, "the file was rewritten")
        XCTAssertNil(photo.jpgEditParametersData, "the baked edit is no longer a saved edit")
        XCTAssertTrue(session.parameters.isDefault)
        // With default parameters the session now renders the baked file, not the old pixels it had cached.
        let preview = try await eventually { session.previewImage }
        let before = meanLuma(try XCTUnwrap(EditTestImages.cgImage(unedited)))
        let after = meanLuma(try XCTUnwrap(EditTestImages.cgImage(preview)))
        XCTAssertGreaterThan(after, before + 20, "the preview shows the baked +1.5 EV file (mean luma \(before) → \(after))")
    }

    /// An export rewrites the photo's file, so the grid's cached thumbnail of it goes (the view model calls
    /// `ImageLoader.invalidate(path:)`; task 22 wired it, task 30 checks it).
    func testExportJPGPermanentInvalidatesTheCachedThumbnail() async throws {
        let viewModel = makeViewModel()
        let url = try makeJPEG(width: 300, height: 200, detail: false)
        let photo = try insertPhoto(jpg: url)
        viewModel.loadExistingData()
        let thumbnail = await ImageLoader.shared.loadThumbnail(for: url.path, maxSize: 256)
        XCTAssertNotNil(thumbnail)
        XCTAssertNotNil(ImageLoader.shared.cachedThumbnail(for: url.path, maxSize: 256), "the grid's thumbnail is cached")
        viewModel.openDetail(for: photo)
        viewModel.startEditing(photo: photo, isRAW: false)
        let session = try XCTUnwrap(viewModel.editSession)
        session.parameters.exposure = 1
        _ = await waitFor { session.previewImage }
        let version = viewModel.editedFilesVersion

        viewModel.exportJPGPermanent()

        _ = try await eventually(5, "the export finishes") { viewModel.editedFilesVersion != version ? true : nil }
        XCTAssertNil(ImageLoader.shared.cachedThumbnail(for: url.path, maxSize: 256), "the old thumbnail is gone")
    }

    private func meanLuma(_ image: CGImage) -> Double {
        let pixels = EditTestImages.rgba8(image)
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
        }
        return total / Double(pixels.count / 4)
    }

    // MARK: - Real RAW (gated)

    /// Needs PHOCASA_TEST_RAW (TEST_RUNNER_PHOCASA_TEST_RAW) naming a *copy* of a camera RAW: it writes a sidecar
    /// and a `-raw-edit.jpg` next to it, and removes both afterwards.
    func testRealRAWEditSaveAndExport() async throws {
        guard let rawPath = ProcessInfo.processInfo.environment["PHOCASA_TEST_RAW"], !rawPath.isEmpty else {
            throw XCTSkip("Set PHOCASA_TEST_RAW to a copy of a camera RAW file")
        }
        let raw = URL(fileURLWithPath: rawPath)
        let sidecar = raw.xmpSidecarURL
        let export = raw.deletingLastPathComponent()
            .appendingPathComponent(raw.deletingPathExtension().lastPathComponent + "-raw-edit.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "use a copy without a sidecar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        defer {
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.removeItem(at: export)
        }

        let viewModel = makeViewModel()
        let photo = try insertPhoto(raw: raw)
        viewModel.loadExistingData()
        XCTAssertEqual(viewModel.library.jpgCount, 0)
        viewModel.openDetail(for: photo)
        viewModel.startEditing(photo: photo, isRAW: true)
        let session = try XCTUnwrap(viewModel.editSession)
        session.parameters.exposure = 0.5
        let preview = try await eventually(10) { session.previewImage }
        XCTAssertLessThanOrEqual(preview.size.width, 1600)
        _ = try await eventually(10) { session.fullImage }

        viewModel.exportRAWToJPG(replaceExisting: false)
        _ = try await eventually(20, "the export becomes the photo's JPG") { photo.jpgPath }
        XCTAssertEqual(photo.jpgPath, export.path)
        XCTAssertEqual(viewModel.library.jpgCount, 1, "photosDidChange: the library counts the new JPG")

        viewModel.stopEditing(save: true)
        XCTAssertTrue(photo.hasRawEdits)
        await MetadataWriter.shared.flush()
        XCTAssertEqual(MetadataService.shared.readEditParameters(forRAWAt: raw.path)?.exposure, 0.5)
    }
}
