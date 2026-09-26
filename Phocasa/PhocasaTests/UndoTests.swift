import XCTest
import SwiftUI
import AppKit
import SwiftData
@testable import Phocasa

/// Edit › Undo and Redo for rating, tagging, the bin and presets: an undo gives each photo the value it had (not a
/// toggle back), in memory, in the store (through the write queue, in chunks for a big selection) and in its files, and
/// redo applies the change again. Each step is named for the menu. Permanent deletes and exports aren't undoable.
@MainActor
final class UndoTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var viewModel: PhotoLibraryViewModel!
    private var undo: UndoManager!
    private var tempDirs: [URL] = []

    override func setUp() async throws {
        container = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
        undo = UndoManager()
        undo.groupsByEvent = false // no run loop events here: each action is a group of its own
        viewModel.undoManager = undo
    }

    override func tearDown() async throws {
        await viewModel.library.waitForRowWrites()
        viewModel = nil
        undo = nil
        context = nil
        container = nil
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    // MARK: - Helpers

    @discardableResult
    private func insertPhotos(_ count: Int, ratings: (Int) -> Int = { $0 % 4 }) -> [PhotoAsset] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var photos: [PhotoAsset] = []
        for i in 0..<count {
            let photo = PhotoAsset(fileName: "u\(i)", jpgPath: "/fake/undo/u\(i).jpg", folderPath: "/fake/undo",
                                   creationDate: base.addingTimeInterval(Double(-i)), fileSize: 10)
            photo.rating = ratings(i)
            context.insert(photo)
            photos.append(photo)
        }
        try? context.save()
        viewModel.loadExistingData()
        return photos
    }

    /// The rows' ratings as stored (a context of their own).
    private func storedRatings() throws -> [String: Int] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, $0.rating) })
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-rel3-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    // MARK: - Rating

    func testUndoRatingGivesEachPhotoItsRatingBackAndRedoRatesAgain() async throws {
        let photos = insertPhotos(3, ratings: { [1, 2, 3][$0] })
        viewModel.selection.selectAll()
        viewModel.setRatingForSelection(5)
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Rating")

        undo.undo()
        XCTAssertEqual(photos.map { viewModel.library.rating(of: $0) }, [1, 2, 3], "each photo's own rating, not 0")
        XCTAssertEqual(viewModel.library.ratingCounts, [1: 1, 2: 1, 3: 1])
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(try storedRatings(), ["u0": 1, "u1": 2, "u2": 3])
        XCTAssertEqual(undo.redoMenuItemTitle, "Redo Rating")

        undo.redo()
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(Set(try storedRatings().values), [5])
        XCTAssertEqual(viewModel.library.ratingCounts, [5: 3])
        XCTAssertTrue(undo.canUndo)
    }

    /// ⌘A then a stray "0": the undo puts every rating back, while the change is still being written in chunks.
    func testUndoOfABigSelectionsRatingWhileItIsStillBeingWritten() async throws {
        let photos = insertPhotos(80)
        let before = try storedRatings()
        viewModel.library.rowWrites.sizer.maximumRows = 6
        viewModel.library.rowWrites.immediateLimit = 4
        viewModel.selection.selectAll()
        viewModel.setRatingForSelectionOrCurrent(0)
        XCTAssertTrue(viewModel.library.hasPendingRowWrites, "precondition: still being written")

        undo.undo()
        XCTAssertEqual(photos.map { viewModel.library.rating(of: $0) }, photos.map { before[$0.fileName] })
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(try storedRatings(), before)

        undo.redo()
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(Set(try storedRatings().values), [0])
    }

    /// Rating a photo with the rating it has is no step to undo.
    func testARatingThatChangesNothingIsNoUndoStep() {
        let photos = insertPhotos(2, ratings: { _ in 3 })
        viewModel.library.setRating(3, for: photos)
        XCTAssertFalse(undo.canUndo)
    }

    // MARK: - Tags

    func testUndoAddTagTakesItOffOnlyThePhotosThatGotIt() async throws {
        let photos = insertPhotos(3)
        viewModel.library.addTag(name: "x", category: "t", to: photos[0])
        undo.removeAllActions()
        viewModel.selection.selectAll()
        viewModel.addTagToSelection(name: "x", category: "t")
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Add Tag “x”")
        let x = try XCTUnwrap(viewModel.library.allTags.first { $0.name == "x" })

        undo.undo()
        XCTAssertEqual(photos.map { viewModel.library.tagIDs(of: $0).contains(x.id) }, [true, false, false])
        XCTAssertEqual(viewModel.library.tagCounts[x.id], 1)
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(photos.map { $0.tags.contains { $0 === x } }, [true, false, false])

        undo.redo()
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(photos.map { $0.tags.contains { $0 === x } }, [true, true, true])
        XCTAssertEqual(viewModel.library.tagCounts[x.id], 3)
    }

    func testUndoRemoveTagGivesItBack() async throws {
        let photos = insertPhotos(4)
        viewModel.library.addTag(name: "y", category: "", to: Array(photos.prefix(3)))
        let y = try XCTUnwrap(viewModel.library.allTags.first { $0.name == "y" })
        viewModel.library.removeTag(y, from: photos)
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Remove Tag “y”")
        XCTAssertNil(viewModel.library.tagCounts[y.id])

        undo.undo()
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(photos.map { $0.tags.contains { $0 === y } }, [true, true, true, false])
        XCTAssertEqual(viewModel.library.tagCounts[y.id], 3)

        undo.redo()
        XCTAssertNil(viewModel.library.tagCounts[y.id])
        undo.undo() // the redo, undone
        undo.undo() // the first add
        await viewModel.library.waitForRowWrites()
        XCTAssertTrue(photos.allSatisfy { $0.tags.isEmpty })
        XCTAssertFalse(undo.canUndo)
    }

    // MARK: - Bin

    func testUndoMoveToBinAndRestoreFromBin() async throws {
        let photos = insertPhotos(4)
        viewModel.selection.selectedPhotos = [photos[1].id, photos[2].id]
        viewModel.deleteSelected()
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Move to Bin")
        XCTAssertEqual(viewModel.library.binCount, 2)

        undo.undo()
        XCTAssertEqual(viewModel.library.binCount, 0)
        XCTAssertEqual(viewModel.library.allPhotos.map(\.id), photos.map(\.id), "back in their places")
        XCTAssertFalse(photos[1].isInBin)

        undo.redo()
        XCTAssertEqual(viewModel.library.binCount, 2)
        XCTAssertTrue(photos[2].isInBin)

        viewModel.library.applyFilter(.bin)
        viewModel.restoreFromBin([photos[1]])
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Restore from Bin")
        undo.undo()
        XCTAssertEqual(viewModel.library.binPhotos.map(\.id), [photos[1].id, photos[2].id])
        XCTAssertTrue(photos[1].isInBin)
    }

    /// Photos deleted forever since can't come back: the undo of their move to the bin does nothing for them.
    func testUndoSkipsPhotosDeletedForeverSince() async throws {
        let photos = insertPhotos(3)
        let trash = try makeTempDir()
        viewModel.library.fileTrasher = FileTrasher { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
        viewModel.selection.selectedPhotos = [photos[0].id]
        viewModel.deleteSelected()
        viewModel.library.applyFilter(.bin)
        viewModel.selection.selectAll()
        viewModel.deleteSelected()
        await viewModel.confirmPermanentDelete()?.value
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Move to Bin", "a permanent delete is no undo step")

        undo.undo()
        viewModel.library.applyFilter(.all)
        XCTAssertEqual(viewModel.library.allPhotos.map(\.id), [photos[1].id, photos[2].id])
        XCTAssertEqual(viewModel.library.binCount, 0)
    }

    // MARK: - Presets

    func testUndoPresetGivesEachPhotoItsEditsBack() async throws {
        let dir = try makeTempDir()
        let photos = insertPhotos(3)
        var ownEdit = EditParameters()
        ownEdit.exposure = 0.3
        ownEdit.rotation = 10
        photos[0].jpgEditParameters = ownEdit
        let raw = dir.appendingPathComponent("u1.ARW")
        photos[1].rawPath = raw.path
        var rawEdit = EditParameters()
        rawEdit.temperature = 12
        RAWEditStore.shared.save(rawEdit, forRAWAt: raw.path)
        photos[1].hasRawEdits = true
        try context.save()
        var look = EditParameters()
        look.contrast = 40
        let preset = EditPreset(name: "Punch", parameters: look)
        context.insert(preset)

        viewModel.selection.selectAll()
        viewModel.applyPresetToSelection(preset)
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Apply Preset “Punch”")
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(photos[0].jpgEditParameters?.contrast, 40)
        XCTAssertEqual(photos[0].jpgEditParameters?.rotation, 10, "the photo's own transform stays")
        XCTAssertEqual(RAWEditStore.shared.parameters(forRAWAt: raw.path)?.contrast, 40)
        XCTAssertTrue(viewModel.library.hasAnyEdits(of: photos[2]))

        undo.undo()
        XCTAssertFalse(viewModel.library.hasAnyEdits(of: photos[2]), "shown at once")
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(photos[0].jpgEditParameters, ownEdit)
        XCTAssertEqual(RAWEditStore.shared.parameters(forRAWAt: raw.path), rawEdit)
        XCTAssertTrue(photos[1].hasRawEdits)
        XCTAssertNil(photos[2].jpgEditParametersData)
        XCTAssertFalse(photos[2].hasAnyEdits)

        undo.redo()
        await viewModel.library.waitForRowWrites()
        XCTAssertEqual(photos[2].jpgEditParameters?.contrast, 40)
        XCTAssertEqual(photos[0].jpgEditParameters?.exposure, 0, "the preset's look replaces the photo's")
        XCTAssertEqual(photos[0].jpgEditParameters?.rotation, 10)
        XCTAssertEqual(RAWEditStore.shared.parameters(forRAWAt: raw.path)?.contrast, 40)
        XCTAssertEqual(RAWEditStore.shared.parameters(forRAWAt: raw.path)?.temperature, 0)
        await MetadataWriter.shared.flush()
    }

    // MARK: - The window's undo manager

    /// `ContentView` hands its window's undo manager (the one Edit › Undo and ⌘Z act on) to the view model and the
    /// library.
    func testContentViewHandsTheWindowsUndoManagerToTheLibrary() throws {
        let hostContainer = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                               configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        hostContainer.mainContext.insert(PhotoAsset(fileName: "w.jpg", folderPath: "/cv", creationDate: Date()))
        try hostContainer.mainContext.save()
        let hosted = PhotoLibraryViewModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ContentView(viewModel: hosted).modelContainer(hostContainer))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let manager = try XCTUnwrap(hosted.undoManager, "the environment's undo manager reached the view model")
        XCTAssertTrue(manager === window.undoManager, "it's the window's")
        XCTAssertTrue(hosted.library.undoManager === manager)
        hosted.library.setRating(4, for: try XCTUnwrap(hosted.library.photos.first))
        XCTAssertEqual(window.undoManager?.undoActionName, "Rating")
    }
}
