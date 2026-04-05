import XCTest
import SwiftData
@testable import Phocasa

@MainActor
final class ViewModelTests: XCTestCase {

    private var viewModel: PhotoLibraryViewModel!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: config
        )
        context = ModelContext(container)
        viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
    }

    override func tearDown() async throws {
        viewModel = nil
        context = nil
        container = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func insertPhoto(
        name: String,
        rating: Int = 0,
        isDeleted: Bool = false,
        creationDate: Date? = nil
    ) -> PhotoAsset {
        let photo = PhotoAsset(
            fileName: name,
            jpgPath: "/fake/\(name).jpg",
            folderPath: "/fake",
            creationDate: creationDate ?? Date(),
            fileSize: 1000
        )
        photo.rating = rating
        photo.isDeleted = isDeleted
        context.insert(photo)
        try? context.save()
        return photo
    }

    // MARK: - Loading

    func testLoadExistingData() {
        insertPhoto(name: "photo1")
        insertPhoto(name: "photo2")
        insertPhoto(name: "deleted", isDeleted: true)

        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.allPhotos.count, 2)
        XCTAssertEqual(viewModel.binCount, 1)
    }

    func testLoadSetsPhotosArray() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")

        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.photos.count, 2)
    }

    func testLoadBinViewShowsDeletedPhotos() {
        insertPhoto(name: "active")
        insertPhoto(name: "binned", isDeleted: true)

        viewModel.viewingBin = true
        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.photos.count, 1)
        XCTAssertEqual(viewModel.photos.first?.fileName, "binned")
    }

    // MARK: - Rating Counts

    func testRatingCountsComputed() {
        insertPhoto(name: "a", rating: 0)
        insertPhoto(name: "b", rating: 3)
        insertPhoto(name: "c", rating: 3)
        insertPhoto(name: "d", rating: 5)

        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.ratingCounts[0], 1)
        XCTAssertEqual(viewModel.ratingCounts[3], 2)
        XCTAssertEqual(viewModel.ratingCounts[5], 1)
        XCTAssertNil(viewModel.ratingCounts[1])
        XCTAssertNil(viewModel.ratingCounts[2])
    }

    func testRatingCountsEmptyLibrary() {
        viewModel.loadExistingData()
        XCTAssertTrue(viewModel.ratingCounts.isEmpty)
    }

    // MARK: - Filtering

    func testFilterAll() {
        insertPhoto(name: "a", rating: 1)
        insertPhoto(name: "b", rating: 3)

        viewModel.applyFilter(.all)

        XCTAssertEqual(viewModel.photos.count, 2)
    }

    func testFilterByRating() {
        insertPhoto(name: "a", rating: 1)
        insertPhoto(name: "b", rating: 3)
        insertPhoto(name: "c", rating: 3)

        viewModel.applyFilter(.rated(3))

        XCTAssertEqual(viewModel.photos.count, 2)
        XCTAssertTrue(viewModel.photos.allSatisfy { $0.rating == 3 })
    }

    func testFilterUnrated() {
        insertPhoto(name: "a", rating: 0)
        insertPhoto(name: "b", rating: 3)

        viewModel.applyFilter(.unrated)

        XCTAssertEqual(viewModel.photos.count, 1)
        XCTAssertEqual(viewModel.photos.first?.rating, 0)
    }

    func testFilterBin() {
        insertPhoto(name: "a")
        insertPhoto(name: "b", isDeleted: true)
        insertPhoto(name: "c", isDeleted: true)

        viewModel.applyFilter(.bin)

        XCTAssertTrue(viewModel.viewingBin)
        XCTAssertEqual(viewModel.photos.count, 2)
    }

    func testFilterBinDoesNotShowActivePhotos() {
        insertPhoto(name: "active")
        insertPhoto(name: "binned", isDeleted: true)

        viewModel.applyFilter(.bin)

        XCTAssertEqual(viewModel.photos.count, 1)
        XCTAssertEqual(viewModel.photos.first?.fileName, "binned")
    }

    // MARK: - Selection

    func testToggleSelectionSingle() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.toggleSelection(for: photo, addToSelection: false)

        XCTAssertEqual(viewModel.selectedPhotos, [photo.id])
        XCTAssertEqual(viewModel.lastSelectedId, photo.id)
    }

    func testToggleSelectionReplacesExisting() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()

        viewModel.toggleSelection(for: a, addToSelection: false)
        viewModel.toggleSelection(for: b, addToSelection: false)

        XCTAssertEqual(viewModel.selectedPhotos, [b.id])
    }

    func testToggleSelectionAddToSelection() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()

        viewModel.toggleSelection(for: a, addToSelection: false)
        viewModel.toggleSelection(for: b, addToSelection: true)

        XCTAssertEqual(viewModel.selectedPhotos, [a.id, b.id])
    }

    func testToggleSelectionRemoveFromSelection() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()

        viewModel.toggleSelection(for: a, addToSelection: false)
        viewModel.toggleSelection(for: b, addToSelection: true)
        viewModel.toggleSelection(for: a, addToSelection: true)

        XCTAssertEqual(viewModel.selectedPhotos, [b.id])
    }

    func testSelectAll() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        viewModel.loadExistingData()

        viewModel.selectAll()

        XCTAssertEqual(viewModel.selectedPhotos, [a.id, b.id, c.id])
    }

    func testClearSelection() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()
        viewModel.selectedPhotos = [photo.id]
        viewModel.lastSelectedId = photo.id

        viewModel.clearSelection()

        XCTAssertTrue(viewModel.selectedPhotos.isEmpty)
        XCTAssertNil(viewModel.lastSelectedId)
    }

    func testRangeSelect() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        viewModel.loadExistingData()

        viewModel.toggleSelection(for: a, addToSelection: false)
        viewModel.rangeSelect(to: c)

        XCTAssertTrue(viewModel.selectedPhotos.contains(a.id))
        XCTAssertTrue(viewModel.selectedPhotos.contains(b.id))
        XCTAssertTrue(viewModel.selectedPhotos.contains(c.id))
    }

    func testRangeSelectReverse() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        viewModel.loadExistingData()

        viewModel.toggleSelection(for: c, addToSelection: false)
        viewModel.rangeSelect(to: a)

        XCTAssertTrue(viewModel.selectedPhotos.contains(a.id))
        XCTAssertTrue(viewModel.selectedPhotos.contains(b.id))
        XCTAssertTrue(viewModel.selectedPhotos.contains(c.id))
    }

    // MARK: - Rating

    func testSetRating() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.setRating(4, for: photo)

        XCTAssertEqual(photo.rating, 4)
    }

    func testSetRatingForSelection() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()
        viewModel.selectedPhotos = [a.id, b.id]

        viewModel.setRatingForSelection(3)

        XCTAssertEqual(a.rating, 3)
        XCTAssertEqual(b.rating, 3)
    }

    func testSetRatingForSelectionOrCurrentInDetail() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()
        viewModel.selectedPhotos = [a.id, b.id]
        viewModel.showingDetail = true
        viewModel.selectedDetailPhoto = a

        viewModel.setRatingForSelectionOrCurrent(5)

        XCTAssertEqual(a.rating, 5)
        // In detail mode, only the detail photo is rated
        XCTAssertEqual(b.rating, 0)
    }

    // MARK: - Deletion

    func testDeleteSelectedMovesToBin() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()
        viewModel.selectedPhotos = [photo.id]

        let previousBinCount = viewModel.binCount
        viewModel.deleteSelected()

        XCTAssertTrue(viewModel.selectedPhotos.isEmpty)
        XCTAssertEqual(viewModel.binCount, previousBinCount + 1)
    }

    func testDeletePhotoSingle() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.deletePhoto(photo)

        // After moveToBin + loadExistingData, the photo should be in the bin
        XCTAssertEqual(viewModel.binCount, 1)
        XCTAssertEqual(viewModel.allPhotos.count, 0)
    }

    func testRestoreFromBin() {
        let photo = insertPhoto(name: "a", isDeleted: true)
        viewModel.loadExistingData()

        viewModel.restoreFromBin([photo])

        XCTAssertFalse(photo.isDeleted)
    }

    func testRestoreSelected() {
        let a = insertPhoto(name: "a", isDeleted: true)
        let b = insertPhoto(name: "b", isDeleted: true)
        viewModel.applyFilter(.bin)
        viewModel.selectedPhotos = [a.id, b.id]

        viewModel.restoreSelected()

        XCTAssertFalse(a.isDeleted)
        XCTAssertFalse(b.isDeleted)
    }

    // MARK: - Navigation

    func testOpenDetail() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.openDetail(for: photo)

        XCTAssertTrue(viewModel.showingDetail)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photo.id)
    }

    func testCloseDetail() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()
        viewModel.openDetail(for: photo)

        viewModel.closeDetail()

        XCTAssertFalse(viewModel.showingDetail)
        XCTAssertNil(viewModel.selectedDetailPhoto)
    }

    // MARK: - Crop

    func testApplyCropFull() {
        viewModel.cropRect = .full
        viewModel.editParameters.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        viewModel.isCropping = true

        viewModel.applyCrop()

        XCTAssertNil(viewModel.editParameters.cropRect, "Full crop rect should be cleared to nil")
        XCTAssertFalse(viewModel.isCropping)
    }

    func testApplyCropApproximatelyFull() {
        viewModel.cropRect = NormalizedRect(x: 0.0001, y: -0.0001, width: 0.9999, height: 1.0001)
        viewModel.isCropping = true

        viewModel.applyCrop()

        XCTAssertNil(viewModel.editParameters.cropRect, "Approximately full crop should be cleared to nil")
    }

    func testApplyCropPartial() {
        let crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        viewModel.cropRect = crop
        viewModel.isCropping = true

        viewModel.applyCrop()

        XCTAssertEqual(viewModel.editParameters.cropRect, crop)
        XCTAssertFalse(viewModel.isCropping)
    }

    func testEnterCropMode() {
        viewModel.editParameters.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        viewModel.enterCropMode()

        XCTAssertTrue(viewModel.isCropping)
        XCTAssertEqual(viewModel.cropRect.x, 0.1)
    }

    func testEnterCropModeNoCrop() {
        viewModel.editParameters.cropRect = nil

        viewModel.enterCropMode()

        XCTAssertTrue(viewModel.isCropping)
        XCTAssertEqual(viewModel.cropRect, .full)
    }

    func testCancelCrop() {
        let existing = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        viewModel.editParameters.cropRect = existing
        viewModel.isCropping = true
        viewModel.cropRect = NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)

        viewModel.cancelCrop()

        XCTAssertEqual(viewModel.cropRect, existing)
        XCTAssertFalse(viewModel.isCropping)
    }

    // MARK: - Zoom

    func testZoomIn() {
        viewModel.gridColumns = 6
        viewModel.zoomIn()
        XCTAssertEqual(viewModel.gridColumns, 5)
    }

    func testZoomInLimit() {
        viewModel.gridColumns = 2
        viewModel.zoomIn()
        XCTAssertEqual(viewModel.gridColumns, 2, "Should not zoom in past 2 columns")
    }

    func testZoomOut() {
        viewModel.gridColumns = 6
        viewModel.zoomOut()
        XCTAssertEqual(viewModel.gridColumns, 7)
    }

    func testZoomOutLimit() {
        viewModel.gridColumns = 20
        viewModel.zoomOut()
        XCTAssertEqual(viewModel.gridColumns, 20, "Should not zoom out past 20 columns")
    }

    // MARK: - Sort

    func testToggleSortOrder() {
        XCTAssertTrue(viewModel.sortNewestFirst)
        viewModel.toggleSortOrder()
        XCTAssertFalse(viewModel.sortNewestFirst)
        viewModel.toggleSortOrder()
        XCTAssertTrue(viewModel.sortNewestFirst)
    }

    // MARK: - Grid Navigation

    func testNavigateGridRight() {
        // sortNewestFirst=true means newest (later date) appears first in the array
        let a = insertPhoto(name: "a", creationDate: Date(timeIntervalSince1970: 2000))
        let b = insertPhoto(name: "b", creationDate: Date(timeIntervalSince1970: 1000))
        viewModel.loadExistingData()
        // a is newest → index 0, b is oldest → index 1
        viewModel.selectedPhotos = [a.id]
        viewModel.lastSelectedId = a.id

        viewModel.navigateGrid(direction: .right, extendSelection: false)

        XCTAssertEqual(viewModel.selectedPhotos, [b.id])
        XCTAssertEqual(viewModel.lastSelectedId, b.id)
    }

    func testNavigateGridWithExtendSelection() {
        let a = insertPhoto(name: "a", creationDate: Date(timeIntervalSince1970: 2000))
        let b = insertPhoto(name: "b", creationDate: Date(timeIntervalSince1970: 1000))
        viewModel.loadExistingData()
        viewModel.selectedPhotos = [a.id]
        viewModel.lastSelectedId = a.id

        viewModel.navigateGrid(direction: .right, extendSelection: true)

        XCTAssertTrue(viewModel.selectedPhotos.contains(a.id))
        XCTAssertTrue(viewModel.selectedPhotos.contains(b.id))
    }

    func testNavigateGridEmptyPhotos() {
        viewModel.loadExistingData()
        viewModel.navigateGrid(direction: .right, extendSelection: false)
        // Should not crash
    }

    func testNavigateGridNoSelection() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")
        viewModel.loadExistingData()

        viewModel.navigateGrid(direction: .right, extendSelection: false)

        // Should select the first photo
        XCTAssertEqual(viewModel.selectedPhotos.count, 1)
    }

    // MARK: - Tags

    func testFindOrCreateTag() {
        let tag = viewModel.findOrCreateTag(name: "sunset", category: "time", in: context)
        XCTAssertEqual(tag.name, "sunset")
        XCTAssertEqual(tag.category, "time")

        // Finding again should return the same tag
        let same = viewModel.findOrCreateTag(name: "sunset", category: "time", in: context)
        XCTAssertEqual(tag.id, same.id)
    }

    func testAddTag() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.addTag(name: "sunset", category: "time", to: photo)

        XCTAssertEqual(photo.tags.count, 1)
        XCTAssertEqual(photo.tags.first?.name, "sunset")
        XCTAssertEqual(photo.tags.first?.category, "time")
    }

    func testAddDuplicateTag() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.addTag(name: "sunset", category: "time", to: photo)
        viewModel.addTag(name: "sunset", category: "time", to: photo)

        XCTAssertEqual(photo.tags.count, 1, "Duplicate tags should not be added")
    }

    func testRemoveTag() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.addTag(name: "sunset", category: "time", to: photo)
        let tag = photo.tags.first!

        viewModel.removeTag(tag, from: photo)

        XCTAssertTrue(photo.tags.isEmpty)
    }

    // MARK: - Revert Edits

    func testRevertEditsForPhoto() {
        let photo = insertPhoto(name: "a")
        photo.jpgEditParametersData = try? JSONEncoder().encode(EditParameters())
        photo.hasRawEdits = true
        try? context.save()
        viewModel.loadExistingData()

        viewModel.revertEditsForPhoto(photo)

        XCTAssertNil(photo.jpgEditParametersData)
        XCTAssertFalse(photo.hasRawEdits)
    }

    // MARK: - Search

    func testSearchByFilename() {
        insertPhoto(name: "sunset_beach")
        insertPhoto(name: "mountain_view")
        viewModel.loadExistingData()
        viewModel.searchText = "sunset"

        viewModel.applyCurrentFilter()

        XCTAssertEqual(viewModel.photos.count, 1)
        XCTAssertEqual(viewModel.photos.first?.fileName, "sunset_beach")
    }

    func testSearchCaseInsensitive() {
        insertPhoto(name: "Sunset_Beach")
        viewModel.loadExistingData()
        viewModel.searchText = "sunset"

        viewModel.applyCurrentFilter()

        XCTAssertEqual(viewModel.photos.count, 1)
    }

    func testSearchClearedRestoresAll() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")
        viewModel.loadExistingData()
        viewModel.searchText = "a"
        viewModel.applyCurrentFilter()
        XCTAssertEqual(viewModel.photos.count, 1)

        viewModel.searchText = ""
        viewModel.applyCurrentFilter()
        XCTAssertEqual(viewModel.photos.count, 2)
    }

    // MARK: - Presets

    func testSaveAndLoadPreset() {
        viewModel.editParameters.exposure = 2.0
        viewModel.editParameters.contrast = 30
        viewModel.presetNameInput = "My Preset"

        viewModel.savePreset()

        XCTAssertEqual(viewModel.editPresets.count, 1)
        XCTAssertEqual(viewModel.editPresets.first?.name, "My Preset")
        XCTAssertEqual(viewModel.editPresets.first?.parameters.exposure, 2.0)
        XCTAssertTrue(viewModel.presetNameInput.isEmpty)
    }

    func testSavePresetEmptyNameIgnored() {
        viewModel.presetNameInput = "   "

        viewModel.savePreset()

        XCTAssertTrue(viewModel.editPresets.isEmpty)
    }

    func testDeletePreset() {
        viewModel.editParameters.exposure = 1.0
        viewModel.presetNameInput = "Test"
        viewModel.savePreset()
        XCTAssertEqual(viewModel.editPresets.count, 1)

        viewModel.deletePreset(viewModel.editPresets.first!)

        XCTAssertTrue(viewModel.editPresets.isEmpty)
    }

    func testApplyPreset() {
        viewModel.editParameters.exposure = 1.0
        viewModel.presetNameInput = "Warm"
        viewModel.savePreset()

        viewModel.editParameters = EditParameters()
        XCTAssertEqual(viewModel.editParameters.exposure, 0)

        viewModel.applyPreset(viewModel.editPresets.first!)

        XCTAssertEqual(viewModel.editParameters.exposure, 1.0)
    }
}
