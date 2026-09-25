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

        XCTAssertEqual(viewModel.library.allPhotos.count, 2)
        XCTAssertEqual(viewModel.library.binCount, 1)
    }

    func testLoadSetsPhotosArray() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")

        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.library.photos.count, 2)
    }

    func testLoadBinViewShowsDeletedPhotos() {
        insertPhoto(name: "active")
        insertPhoto(name: "binned", isDeleted: true)

        viewModel.library.viewingBin = true
        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.library.photos.count, 1)
        XCTAssertEqual(viewModel.library.photos.first?.fileName, "binned")
    }

    // MARK: - Rating Counts

    func testRatingCountsComputed() {
        insertPhoto(name: "a", rating: 0)
        insertPhoto(name: "b", rating: 3)
        insertPhoto(name: "c", rating: 3)
        insertPhoto(name: "d", rating: 5)

        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.library.ratingCounts[0], 1)
        XCTAssertEqual(viewModel.library.ratingCounts[3], 2)
        XCTAssertEqual(viewModel.library.ratingCounts[5], 1)
        XCTAssertNil(viewModel.library.ratingCounts[1])
        XCTAssertNil(viewModel.library.ratingCounts[2])
    }

    func testRatingCountsEmptyLibrary() {
        viewModel.loadExistingData()
        XCTAssertTrue(viewModel.library.ratingCounts.isEmpty)
    }

    // MARK: - Filtering

    func testFilterAll() {
        insertPhoto(name: "a", rating: 1)
        insertPhoto(name: "b", rating: 3)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.all)

        XCTAssertEqual(viewModel.library.photos.count, 2)
    }

    func testFilterByRating() {
        insertPhoto(name: "a", rating: 1)
        insertPhoto(name: "b", rating: 3)
        insertPhoto(name: "c", rating: 3)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rated(3))

        XCTAssertEqual(viewModel.library.photos.count, 2)
        XCTAssertTrue(viewModel.library.photos.allSatisfy { $0.rating == 3 })
    }

    func testFilterUnrated() {
        insertPhoto(name: "a", rating: 0)
        insertPhoto(name: "b", rating: 3)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.unrated)

        XCTAssertEqual(viewModel.library.photos.count, 1)
        XCTAssertEqual(viewModel.library.photos.first?.rating, 0)
    }

    func testFilterBin() {
        insertPhoto(name: "a")
        insertPhoto(name: "b", isDeleted: true)
        insertPhoto(name: "c", isDeleted: true)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.bin)

        XCTAssertTrue(viewModel.library.viewingBin)
        XCTAssertEqual(viewModel.library.photos.count, 2)
    }

    func testFilterBinDoesNotShowActivePhotos() {
        insertPhoto(name: "active")
        insertPhoto(name: "binned", isDeleted: true)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.bin)

        XCTAssertEqual(viewModel.library.photos.count, 1)
        XCTAssertEqual(viewModel.library.photos.first?.fileName, "binned")
    }

    // MARK: - In-memory contract

    /// The store is read by `loadExistingData()` (and by scans). UI interactions work on the in-memory
    /// state; in the app every store change goes through the view model, so nothing is lost.
    func testFilterChangesDoNotRefetch() {
        insertPhoto(name: "loaded")
        viewModel.loadExistingData()

        let late = insertPhoto(name: "late")
        viewModel.library.applyFilter(.all)
        XCTAssertFalse(viewModel.library.photos.contains { $0.id == late.id })

        viewModel.loadExistingData()
        XCTAssertTrue(viewModel.library.photos.contains { $0.id == late.id })
    }

    // MARK: - Selection

    func testToggleSelectionSingle() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.selection.toggleSelection(for: photo, addToSelection: false)

        XCTAssertEqual(viewModel.selection.selectedPhotos, [photo.id])
        XCTAssertEqual(viewModel.selection.lastSelectedId, photo.id)
    }

    func testToggleSelectionReplacesExisting() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()

        viewModel.selection.toggleSelection(for: a, addToSelection: false)
        viewModel.selection.toggleSelection(for: b, addToSelection: false)

        XCTAssertEqual(viewModel.selection.selectedPhotos, [b.id])
    }

    func testToggleSelectionAddToSelection() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()

        viewModel.selection.toggleSelection(for: a, addToSelection: false)
        viewModel.selection.toggleSelection(for: b, addToSelection: true)

        XCTAssertEqual(viewModel.selection.selectedPhotos, [a.id, b.id])
    }

    func testToggleSelectionRemoveFromSelection() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()

        viewModel.selection.toggleSelection(for: a, addToSelection: false)
        viewModel.selection.toggleSelection(for: b, addToSelection: true)
        viewModel.selection.toggleSelection(for: a, addToSelection: true)

        XCTAssertEqual(viewModel.selection.selectedPhotos, [b.id])
    }

    func testSelectAll() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        viewModel.loadExistingData()

        viewModel.selection.selectAll()

        XCTAssertEqual(viewModel.selection.selectedPhotos, [a.id, b.id, c.id])
    }

    func testClearSelection() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()
        viewModel.selection.selectedPhotos = [photo.id]
        viewModel.selection.lastSelectedId = photo.id

        viewModel.selection.clearSelection()

        XCTAssertTrue(viewModel.selection.selectedPhotos.isEmpty)
        XCTAssertNil(viewModel.selection.lastSelectedId)
    }

    func testRangeSelect() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        viewModel.loadExistingData()

        viewModel.selection.toggleSelection(for: a, addToSelection: false)
        viewModel.selection.rangeSelect(to: c)

        XCTAssertTrue(viewModel.selection.selectedPhotos.contains(a.id))
        XCTAssertTrue(viewModel.selection.selectedPhotos.contains(b.id))
        XCTAssertTrue(viewModel.selection.selectedPhotos.contains(c.id))
    }

    func testRangeSelectReverse() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        viewModel.loadExistingData()

        viewModel.selection.toggleSelection(for: c, addToSelection: false)
        viewModel.selection.rangeSelect(to: a)

        XCTAssertTrue(viewModel.selection.selectedPhotos.contains(a.id))
        XCTAssertTrue(viewModel.selection.selectedPhotos.contains(b.id))
        XCTAssertTrue(viewModel.selection.selectedPhotos.contains(c.id))
    }

    // MARK: - Rating

    func testSetRating() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.library.setRating(4, for: photo)

        XCTAssertEqual(photo.rating, 4)
    }

    func testSetRatingForSelection() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()
        viewModel.selection.selectedPhotos = [a.id, b.id]

        viewModel.setRatingForSelection(3)

        XCTAssertEqual(a.rating, 3)
        XCTAssertEqual(b.rating, 3)
    }

    func testSetRatingForSelectionOrCurrentInDetail() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        viewModel.loadExistingData()
        viewModel.selection.selectedPhotos = [a.id, b.id]
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
        viewModel.selection.selectedPhotos = [photo.id]

        let previousBinCount = viewModel.library.binCount
        viewModel.deleteSelected()

        XCTAssertTrue(viewModel.selection.selectedPhotos.isEmpty)
        XCTAssertEqual(viewModel.library.binCount, previousBinCount + 1)
    }

    func testDeletePhotoSingle() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.deletePhoto(photo)

        // After moveToBin + loadExistingData, the photo should be in the bin
        XCTAssertEqual(viewModel.library.binCount, 1)
        XCTAssertEqual(viewModel.library.allPhotos.count, 0)
    }

    func testRestoreFromBin() {
        let photo = insertPhoto(name: "a", isDeleted: true)
        viewModel.loadExistingData()

        viewModel.restoreFromBin([photo])

        XCTAssertFalse(photo.isDeleted)
        XCTAssertTrue(viewModel.library.allPhotos.contains { $0.id == photo.id })
    }

    // MARK: - File Availability

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testRefreshAvailabilityHidesPhotosWithMissingFiles() throws {
        let dir = try makeTempDir()
        let presentPath = dir.appendingPathComponent("present.jpg").path
        FileManager.default.createFile(atPath: presentPath, contents: Data())

        let present = insertPhoto(name: "present")
        present.jpgPath = presentPath
        let gone = insertPhoto(name: "gone")
        gone.jpgPath = dir.appendingPathComponent("gone.jpg").path
        try context.save()

        viewModel.library.refreshAvailability()

        XCTAssertEqual(viewModel.library.allPhotos.map(\.id), [present.id])
    }

    func testRestoringPhotoBinnedBeforeAvailabilityCheckShowsIt() throws {
        let dir = try makeTempDir()
        let path = dir.appendingPathComponent("binned.jpg").path
        FileManager.default.createFile(atPath: path, contents: Data())

        let photo = insertPhoto(name: "binned", isDeleted: true)
        photo.jpgPath = path
        try context.save()

        // The availability check only looks at non-binned photos (as at app launch).
        viewModel.library.refreshAvailability()
        viewModel.restoreFromBin([photo])

        XCTAssertTrue(viewModel.library.allPhotos.contains { $0.id == photo.id })
    }

    func testRestoreSelected() {
        let a = insertPhoto(name: "a", isDeleted: true)
        let b = insertPhoto(name: "b", isDeleted: true)
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.bin)
        viewModel.selection.selectedPhotos = [a.id, b.id]

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
        XCTAssertTrue(viewModel.library.sortNewestFirst)
        viewModel.library.toggleSortOrder()
        XCTAssertFalse(viewModel.library.sortNewestFirst)
        viewModel.library.toggleSortOrder()
        XCTAssertTrue(viewModel.library.sortNewestFirst)
    }

    // MARK: - Grid Navigation

    func testNavigateGridRight() {
        // sortNewestFirst=true means newest (later date) appears first in the array
        let a = insertPhoto(name: "a", creationDate: Date(timeIntervalSince1970: 2000))
        let b = insertPhoto(name: "b", creationDate: Date(timeIntervalSince1970: 1000))
        viewModel.loadExistingData()
        // a is newest → index 0, b is oldest → index 1
        viewModel.selection.selectedPhotos = [a.id]
        viewModel.selection.lastSelectedId = a.id

        viewModel.selection.navigateGrid(direction: .right, extendSelection: false, columns: viewModel.gridColumns)

        XCTAssertEqual(viewModel.selection.selectedPhotos, [b.id])
        XCTAssertEqual(viewModel.selection.lastSelectedId, b.id)
    }

    func testNavigateGridWithExtendSelection() {
        let a = insertPhoto(name: "a", creationDate: Date(timeIntervalSince1970: 2000))
        let b = insertPhoto(name: "b", creationDate: Date(timeIntervalSince1970: 1000))
        viewModel.loadExistingData()
        viewModel.selection.selectedPhotos = [a.id]
        viewModel.selection.lastSelectedId = a.id

        viewModel.selection.navigateGrid(direction: .right, extendSelection: true, columns: viewModel.gridColumns)

        XCTAssertTrue(viewModel.selection.selectedPhotos.contains(a.id))
        XCTAssertTrue(viewModel.selection.selectedPhotos.contains(b.id))
    }

    func testNavigateGridEmptyPhotos() {
        viewModel.loadExistingData()
        viewModel.selection.navigateGrid(direction: .right, extendSelection: false, columns: viewModel.gridColumns)
        // Should not crash
    }

    func testNavigateGridNoSelection() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")
        viewModel.loadExistingData()

        viewModel.selection.navigateGrid(direction: .right, extendSelection: false, columns: viewModel.gridColumns)

        // Should select the first photo
        XCTAssertEqual(viewModel.selection.selectedPhotos.count, 1)
    }

    // MARK: - Tags

    func testFindOrCreateTag() {
        let tag = viewModel.library.findOrCreateTag(name: "sunset", category: "time", in: context)
        XCTAssertEqual(tag.name, "sunset")
        XCTAssertEqual(tag.category, "time")

        // Finding again should return the same tag
        let same = viewModel.library.findOrCreateTag(name: "sunset", category: "time", in: context)
        XCTAssertEqual(tag.id, same.id)
    }

    func testAddTag() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.library.addTag(name: "sunset", category: "time", to: photo)

        XCTAssertEqual(photo.tags.count, 1)
        XCTAssertEqual(photo.tags.first?.name, "sunset")
        XCTAssertEqual(photo.tags.first?.category, "time")
    }

    func testAddDuplicateTag() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.library.addTag(name: "sunset", category: "time", to: photo)
        viewModel.library.addTag(name: "sunset", category: "time", to: photo)

        XCTAssertEqual(photo.tags.count, 1, "Duplicate tags should not be added")
    }

    func testRemoveTag() {
        let photo = insertPhoto(name: "a")
        viewModel.loadExistingData()

        viewModel.library.addTag(name: "sunset", category: "time", to: photo)
        let tag = photo.tags.first!

        viewModel.library.removeTag(tag, from: photo)

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
        viewModel.library.searchText = "sunset"

        viewModel.library.applyCurrentFilter()

        XCTAssertEqual(viewModel.library.photos.count, 1)
        XCTAssertEqual(viewModel.library.photos.first?.fileName, "sunset_beach")
    }

    func testSearchCaseInsensitive() {
        insertPhoto(name: "Sunset_Beach")
        viewModel.loadExistingData()
        viewModel.library.searchText = "sunset"

        viewModel.library.applyCurrentFilter()

        XCTAssertEqual(viewModel.library.photos.count, 1)
    }

    func testSearchClearedRestoresAll() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")
        viewModel.loadExistingData()
        viewModel.library.searchText = "a"
        viewModel.library.applyCurrentFilter()
        XCTAssertEqual(viewModel.library.photos.count, 1)

        viewModel.library.searchText = ""
        viewModel.library.applyCurrentFilter()
        XCTAssertEqual(viewModel.library.photos.count, 2)
    }

    // MARK: - File Type Filter

    func testFilterJPGOnly() {
        insertPhoto(name: "jpg_only")
        let rawOnly = PhotoAsset(fileName: "raw_only", rawPath: "/fake/raw_only.cr3",
                                 folderPath: "/fake", creationDate: Date(), fileSize: 1000)
        context.insert(rawOnly)
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.jpgOnly)

        XCTAssertEqual(viewModel.library.photos.count, 2, "Should show jpg_only and paired (both have jpgPath)")
        XCTAssertTrue(viewModel.library.photos.allSatisfy { $0.jpgPath != nil })
    }

    func testFilterRAWOnly() {
        insertPhoto(name: "jpg_only")
        let rawOnly = PhotoAsset(fileName: "raw_only", rawPath: "/fake/raw_only.cr3",
                                 folderPath: "/fake", creationDate: Date(), fileSize: 1000)
        context.insert(rawOnly)
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rawOnly)

        XCTAssertEqual(viewModel.library.photos.count, 2, "Should show raw_only and paired (both have rawPath)")
        XCTAssertTrue(viewModel.library.photos.allSatisfy { $0.rawPath != nil })
    }

    func testFileTypeCountsComputed() {
        insertPhoto(name: "jpg_only")
        let rawOnly = PhotoAsset(fileName: "raw_only", rawPath: "/fake/raw_only.cr3",
                                 folderPath: "/fake", creationDate: Date(), fileSize: 1000)
        context.insert(rawOnly)
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.library.jpgCount, 2, "jpg_only + paired")
        XCTAssertEqual(viewModel.library.rawCount, 2, "raw_only + paired")
    }

    // MARK: - Multi-Filter

    func testMultiFilterAutoCombinesDifferentCategories() {
        let a = insertPhoto(name: "a", rating: 3)
        a.rawPath = "/fake/a.cr3"
        insertPhoto(name: "b", rating: 3)
        // b has no rawPath
        let c = insertPhoto(name: "c", rating: 5)
        c.rawPath = "/fake/c.cr3"
        try? context.save()
        viewModel.loadExistingData()

        // Click rating 3
        viewModel.library.applyFilter(.rated(3))
        XCTAssertEqual(viewModel.library.photos.count, 2, "a and b are rated 3")

        // Click RAW only — should auto-combine (different category)
        viewModel.library.applyFilter(.rawOnly)
        XCTAssertEqual(viewModel.library.photos.count, 1, "Only a is rated 3 AND has RAW")
        XCTAssertEqual(viewModel.library.photos.first?.fileName, "a")
        XCTAssertEqual(viewModel.library.activeFilters.count, 2)
    }

    func testMultiFilterReplacesWithinCategory() {
        insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", rating: 4)
        insertPhoto(name: "c", rating: 5)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rated(3))
        XCTAssertEqual(viewModel.library.photos.count, 1)

        // Click 4-star — should replace 3-star (same category)
        viewModel.library.applyFilter(.rated(4))
        XCTAssertEqual(viewModel.library.photos.count, 1)
        XCTAssertEqual(viewModel.library.photos.first?.rating, 4)
        XCTAssertEqual(viewModel.library.activeFilters.count, 1)
    }

    func testMultiFilterShiftToggle() {
        insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", rating: 4)
        insertPhoto(name: "c", rating: 5)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rated(3))
        XCTAssertEqual(viewModel.library.photos.count, 1)

        // Shift-click 4-star — should add (now showing 3 AND 4)
        viewModel.library.applyFilter(.rated(4), isShiftHeld: true)
        XCTAssertEqual(viewModel.library.photos.count, 2)
        XCTAssertTrue(viewModel.library.activeFilters.contains(.rated(3)))
        XCTAssertTrue(viewModel.library.activeFilters.contains(.rated(4)))

        // Shift-click 3-star again — should remove it
        viewModel.library.applyFilter(.rated(3), isShiftHeld: true)
        XCTAssertEqual(viewModel.library.photos.count, 1)
        XCTAssertEqual(viewModel.library.photos.first?.rating, 4)
    }

    func testClearFiltersWithAll() {
        insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", rating: 5)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rated(3))
        XCTAssertEqual(viewModel.library.photos.count, 1)

        viewModel.library.applyFilter(.all)
        XCTAssertTrue(viewModel.library.activeFilters.isEmpty)
        XCTAssertEqual(viewModel.library.photos.count, 2)
    }

    func testBinFilterIsExclusive() {
        insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", isDeleted: true)
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rated(3))
        viewModel.library.applyFilter(.bin)

        XCTAssertTrue(viewModel.library.viewingBin)
        XCTAssertEqual(viewModel.library.activeFilters, [.bin])
        XCTAssertEqual(viewModel.library.photos.count, 1)
        XCTAssertEqual(viewModel.library.photos.first?.fileName, "b")
    }

    // MARK: - Smart Delete (File Type)

    func testDeleteInRAWOnlyModeRemovesOnlyRAW() {
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rawOnly)
        viewModel.selection.selectedPhotos = [paired.id]

        viewModel.deleteSelected()

        // RAW path should be cleared, JPG should remain
        XCTAssertNil(paired.rawPath)
        XCTAssertEqual(paired.jpgPath, "/fake/paired.jpg")
        XCTAssertFalse(paired.isDeleted, "Photo should NOT be in bin")
        XCTAssertFalse(paired.hasRawEdits, "RAW edits should be cleared")
    }

    func testDeleteInJPGOnlyModeRemovesOnlyJPG() {
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.jpgOnly)
        viewModel.selection.selectedPhotos = [paired.id]

        viewModel.deleteSelected()

        // JPG path should be cleared, RAW should remain
        XCTAssertNil(paired.jpgPath)
        XCTAssertEqual(paired.rawPath, "/fake/paired.cr3")
        XCTAssertFalse(paired.isDeleted, "Photo should NOT be in bin")
    }

    func testDeleteNonPairedInRAWOnlyModeSoftDeletes() {
        let rawOnly = PhotoAsset(fileName: "raw_only", rawPath: "/fake/raw_only.cr3",
                                 folderPath: "/fake", creationDate: Date(), fileSize: 1000)
        context.insert(rawOnly)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rawOnly)
        viewModel.selection.selectedPhotos = [rawOnly.id]

        viewModel.deleteSelected()

        // Non-paired RAW should go to bin — check via binCount since the photo
        // gets refetched by loadExistingData after delete
        XCTAssertEqual(viewModel.library.binCount, 1, "Non-paired photo should be soft-deleted to bin")
        XCTAssertEqual(viewModel.library.allPhotos.count, 0, "No active photos should remain")
    }

    func testDeleteClearsSelectionAfterFileTypeDelete() {
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rawOnly)
        viewModel.selection.selectedPhotos = [paired.id]

        viewModel.deleteSelected()

        XCTAssertTrue(viewModel.selection.selectedPhotos.isEmpty)
    }

    func testHasFileTypeFilter() {
        XCTAssertFalse(viewModel.library.hasFileTypeFilter)

        viewModel.library.applyFilter(.rawOnly)
        XCTAssertTrue(viewModel.library.hasFileTypeFilter)

        viewModel.library.applyFilter(.all)
        XCTAssertFalse(viewModel.library.hasFileTypeFilter)
    }

    // MARK: - In-memory library state

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func ids(_ photos: [PhotoAsset]) -> [UUID] { photos.map(\.id) }

    /// Ids of the binned photos as stored, read through a separate context. Reading `photo.isDeleted`
    /// after a save isn't reliable: it collides with Core Data's own `isDeleted` (spec §H5).
    private func storedBinIDs() -> Set<UUID> {
        let fresh = ModelContext(container)
        let rows = (try? fresh.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.isDeleted }))) ?? []
        return Set(rows.map(\.id))
    }

    func testMoveToBinAndRestoreKeepOrder() {
        let a = insertPhoto(name: "a", creationDate: date(4000))
        let b = insertPhoto(name: "b", creationDate: date(3000))
        let c = insertPhoto(name: "c", creationDate: date(2000))
        let d = insertPhoto(name: "d", creationDate: date(1000))
        viewModel.loadExistingData()
        XCTAssertEqual(ids(viewModel.library.photos), [a.id, b.id, c.id, d.id])

        viewModel.deletePhoto(b)
        viewModel.deletePhoto(d)
        XCTAssertEqual(ids(viewModel.library.allPhotos), [a.id, c.id])
        XCTAssertEqual(ids(viewModel.library.photos), [a.id, c.id])
        XCTAssertEqual(viewModel.library.binCount, 2)
        XCTAssertEqual(storedBinIDs(), [b.id, d.id])

        viewModel.library.applyFilter(.bin)
        XCTAssertEqual(ids(viewModel.library.photos), [b.id, d.id])

        viewModel.restoreFromBin([d])
        XCTAssertEqual(ids(viewModel.library.photos), [b.id])
        XCTAssertEqual(viewModel.library.binCount, 1)
        XCTAssertEqual(storedBinIDs(), [b.id])

        viewModel.library.applyFilter(.all)
        XCTAssertEqual(ids(viewModel.library.photos), [a.id, c.id, d.id])
        viewModel.restoreFromBin([b])
        XCTAssertEqual(ids(viewModel.library.photos), [a.id, b.id, c.id, d.id])
        XCTAssertEqual(viewModel.library.binCount, 0)

        // Oldest first: inserts keep the reversed order too.
        viewModel.library.toggleSortOrder()
        XCTAssertEqual(ids(viewModel.library.photos), [d.id, c.id, b.id, a.id])
        viewModel.deletePhoto(c)
        viewModel.deletePhoto(a)
        XCTAssertEqual(ids(viewModel.library.photos), [d.id, b.id])
        viewModel.library.applyFilter(.bin)
        XCTAssertEqual(ids(viewModel.library.photos), [c.id, a.id])
        viewModel.restoreFromBin([a, c])
        viewModel.library.applyFilter(.all)
        XCTAssertEqual(ids(viewModel.library.photos), [d.id, c.id, b.id, a.id])
        XCTAssertEqual(storedBinIDs(), [])
    }

    func testMoveToBinKeepsActiveFilter() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 1, creationDate: date(2000))
        let c = insertPhoto(name: "c", rating: 3, creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.rated(3))

        viewModel.deletePhoto(a)

        XCTAssertEqual(ids(viewModel.library.photos), [c.id])
        XCTAssertEqual(ids(viewModel.library.allPhotos), [b.id, c.id])
        XCTAssertEqual(viewModel.library.activeFilters, [.rated(3)])
        XCTAssertEqual(viewModel.library.ratingCounts, [3: 1, 1: 1])
    }

    func testMovingPhotoLoadedAfterLastFetchToBinShowsItInBin() {
        viewModel.loadExistingData()
        let late = insertPhoto(name: "late")

        viewModel.deletePhoto(late)
        viewModel.library.applyFilter(.bin)

        XCTAssertEqual(viewModel.library.binCount, 1)
        XCTAssertEqual(ids(viewModel.library.photos), [late.id])
    }

    func testPhotosDidChangePicksUpDirectModelChanges() {
        let raw = PhotoAsset(fileName: "raw", rawPath: "/fake/raw.arw", folderPath: "/fake", creationDate: date(2000))
        context.insert(raw)
        let jpg = insertPhoto(name: "jpg", creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.jpgOnly)
        XCTAssertEqual(ids(viewModel.library.photos), [jpg.id])
        XCTAssertEqual(viewModel.library.jpgCount, 1)

        // As an export that writes a JPG next to a RAW-only photo does.
        raw.jpgPath = "/fake/raw-raw-edit.jpg"
        viewModel.library.photosDidChange([raw])

        XCTAssertEqual(ids(viewModel.library.photos), [raw.id, jpg.id])
        XCTAssertEqual(viewModel.library.jpgCount, 2)
    }

    func testEmptyBinUsesInMemoryBin() {
        let a = insertPhoto(name: "a", isDeleted: true, creationDate: date(2000))
        let b = insertPhoto(name: "b", isDeleted: true, creationDate: date(1000))
        insertPhoto(name: "c")
        viewModel.loadExistingData()

        viewModel.emptyBin()

        XCTAssertTrue(viewModel.showPermanentDeleteConfirmation)
        XCTAssertEqual(Set(ids(viewModel.photosToDelete)), [a.id, b.id])
    }

    func testConfirmPermanentDeleteEmptiesBin() {
        insertPhoto(name: "a", isDeleted: true)
        insertPhoto(name: "b")
        viewModel.loadExistingData()
        viewModel.emptyBin()

        viewModel.confirmPermanentDelete()

        XCTAssertEqual(viewModel.library.binCount, 0)
        XCTAssertEqual(viewModel.library.allPhotos.count, 1)
    }

    func testSetRatingUpdatesFilterAndCountsInMemory() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 3, creationDate: date(2000))
        insertPhoto(name: "c", rating: 5, creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.rated(3))
        XCTAssertEqual(viewModel.library.ratingCounts, [3: 2, 5: 1])

        viewModel.library.setRating(4, for: a)

        XCTAssertEqual(ids(viewModel.library.photos), [b.id])
        XCTAssertEqual(viewModel.library.ratingCounts, [3: 1, 4: 1, 5: 1])
    }

    func testSetRatingForSelectionUpdatesCounts() {
        let a = insertPhoto(name: "a", creationDate: date(3000))
        let b = insertPhoto(name: "b", creationDate: date(2000))
        insertPhoto(name: "c", creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.selection.selectedPhotos = [a.id, b.id]

        viewModel.setRatingForSelection(2)
        XCTAssertEqual(viewModel.library.ratingCounts, [0: 1, 2: 2])

        viewModel.library.applyFilter(.rated(2))
        XCTAssertEqual(ids(viewModel.library.photos), [a.id, b.id])
    }

    func testFacetCountsWithActiveFilter() {
        let a = insertPhoto(name: "a", rating: 3)
        let b = insertPhoto(name: "b", rating: 5)
        viewModel.loadExistingData()
        viewModel.library.addTag(name: "alice", category: "people", to: a)
        viewModel.library.addTag(name: "alice", category: "people", to: b)
        let alice = a.tags[0]

        viewModel.library.applyFilter(.rated(3))

        XCTAssertEqual(viewModel.library.ratingCounts, [3: 1, 5: 1], "rating counts ignore the rating filter")
        XCTAssertEqual(viewModel.library.tagCounts, [alice.id: 1], "tag counts only cover 3-star photos")
        XCTAssertEqual(viewModel.library.categoryCounts, ["people": 1])
        XCTAssertEqual(viewModel.library.jpgCount, 1)
    }

    func testAddAndRemoveTagUpdateTagListsCountsAndFiltersInMemory() {
        let a = insertPhoto(name: "a", creationDate: date(2000))
        let b = insertPhoto(name: "b", creationDate: date(1000))
        viewModel.loadExistingData()

        viewModel.library.addTag(name: "bob", category: "people", to: a)
        let bob = a.tags[0]
        XCTAssertEqual(viewModel.library.tagsByCategory["people"]?.map(\.name), ["bob"])
        XCTAssertEqual(viewModel.library.tagCategories, ["people"])
        XCTAssertEqual(viewModel.library.tagCounts, [bob.id: 1])
        XCTAssertEqual(viewModel.library.categoryCounts, ["people": 1])

        viewModel.library.addTag(name: "alice", category: "people", to: b)
        viewModel.library.addTag(name: "zed", category: "", to: a)
        XCTAssertEqual(viewModel.library.tagsByCategory["people"]?.map(\.name), ["alice", "bob"])
        XCTAssertEqual(viewModel.library.uncategorizedTags.map(\.name), ["zed"])
        XCTAssertEqual(viewModel.library.allTags.map(\.name), ["zed", "alice", "bob"])
        XCTAssertEqual(viewModel.library.categoryCounts, ["people": 2])

        viewModel.library.applyFilter(.tag(bob.id))
        XCTAssertEqual(ids(viewModel.library.photos), [a.id])
        viewModel.library.applyFilter(.tagCategory("people"))
        XCTAssertEqual(ids(viewModel.library.photos), [a.id, b.id])

        viewModel.library.removeTag(bob, from: a)
        XCTAssertEqual(ids(viewModel.library.photos), [b.id])
        XCTAssertNil(viewModel.library.tagCounts[bob.id])
        XCTAssertEqual(viewModel.library.categoryCounts, ["people": 1])
    }

    func testToggleTagForMultiSelectionAddsThenRemoves() {
        let a = insertPhoto(name: "a", creationDate: date(2000))
        let b = insertPhoto(name: "b", creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.library.addTag(name: "x", category: "cat", to: a)
        let x = a.tags[0]
        viewModel.selection.selectedPhotos = [a.id, b.id]

        viewModel.toggleTag(x, for: a)
        XCTAssertTrue(b.tags.contains { $0.id == x.id })
        XCTAssertEqual(viewModel.library.tagCounts[x.id], 2)
        XCTAssertTrue(viewModel.contextMenuTagState(x, for: a))

        viewModel.toggleTag(x, for: a)
        XCTAssertTrue(a.tags.isEmpty)
        XCTAssertTrue(b.tags.isEmpty)
        XCTAssertNil(viewModel.library.tagCounts[x.id])
    }

    func testSearchFindsTagAddedInMemory() {
        let a = insertPhoto(name: "IMG_1")
        insertPhoto(name: "IMG_2")
        viewModel.loadExistingData()
        viewModel.library.addTag(name: "Sunset", category: "Time", to: a)

        viewModel.library.searchText = "sunset"
        viewModel.library.applyCurrentFilter()
        XCTAssertEqual(ids(viewModel.library.photos), [a.id])

        viewModel.library.searchText = "time"
        viewModel.library.applyCurrentFilter()
        XCTAssertEqual(ids(viewModel.library.photos), [a.id])
    }

    func testSearchAppliesInBinView() {
        insertPhoto(name: "sunset", isDeleted: true)
        insertPhoto(name: "forest", isDeleted: true)
        viewModel.loadExistingData()
        viewModel.library.searchText = "sun"

        viewModel.library.applyFilter(.bin)

        XCTAssertEqual(viewModel.library.photos.map(\.fileName), ["sunset"])
    }

    func testSearchSuggestions() {
        let a = insertPhoto(name: "a")
        viewModel.loadExistingData()
        viewModel.library.addTag(name: "Sundown", category: "time", to: a)
        viewModel.library.addTag(name: "sunrise", category: "time", to: a)
        viewModel.library.addTag(name: "beach", category: "sunny places", to: a)

        // Matching categories first (in sidebar order), then matching tag names (in `allTags` order).
        viewModel.library.searchText = "SUN"
        XCTAssertEqual(viewModel.library.searchSuggestions, ["sunny places", "Sundown", "sunrise"])

        viewModel.library.searchText = "tim"
        XCTAssertEqual(viewModel.library.searchSuggestions, ["time"])

        viewModel.library.searchText = ""
        XCTAssertEqual(viewModel.library.searchSuggestions, [])
    }

    func testToggleSortOrderReversesInMemory() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 1, creationDate: date(2000))
        let c = insertPhoto(name: "c", rating: 3, creationDate: date(1000))
        viewModel.loadExistingData()

        viewModel.library.toggleSortOrder()
        XCTAssertEqual(ids(viewModel.library.photos), [c.id, b.id, a.id])

        viewModel.library.applyFilter(.rated(3))
        XCTAssertEqual(ids(viewModel.library.photos), [c.id, a.id])

        viewModel.library.toggleSortOrder()
        XCTAssertEqual(ids(viewModel.library.photos), [a.id, c.id])

        // A later full load uses the same order.
        viewModel.library.toggleSortOrder()
        viewModel.loadExistingData()
        XCTAssertEqual(ids(viewModel.library.photos), [c.id, a.id])
    }

    func testLoadExistingDataKeepsActiveFiltersAndSearch() {
        insertPhoto(name: "sunset", rating: 3, creationDate: date(3000))
        insertPhoto(name: "forest", rating: 3, creationDate: date(2000))
        insertPhoto(name: "sunrise", rating: 5, creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.rated(3))
        viewModel.library.searchText = "sun"
        viewModel.library.applyCurrentFilter()

        insertPhoto(name: "sundown", rating: 3, creationDate: date(500))
        viewModel.loadExistingData()

        XCTAssertEqual(viewModel.library.photos.map(\.fileName), ["sunset", "sundown"])
    }

    func testIndexOfTracksFiltering() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 1, creationDate: date(2000))
        let c = insertPhoto(name: "c", rating: 3, creationDate: date(1000))
        viewModel.loadExistingData()
        XCTAssertEqual(viewModel.library.index(of: a.id), 0)
        XCTAssertEqual(viewModel.library.index(of: b.id), 1)
        XCTAssertEqual(viewModel.library.index(of: c.id), 2)

        viewModel.library.applyFilter(.rated(3))
        XCTAssertEqual(viewModel.library.index(of: a.id), 0)
        XCTAssertNil(viewModel.library.index(of: b.id))
        XCTAssertEqual(viewModel.library.index(of: c.id), 1)

        viewModel.library.toggleSortOrder()
        XCTAssertEqual(viewModel.library.index(of: c.id), 0)
        XCTAssertEqual(viewModel.library.index(of: a.id), 1)

        viewModel.library.applyFilter(.all)
        XCTAssertEqual(viewModel.library.index(of: b.id), 1)
        XCTAssertNil(viewModel.library.index(of: UUID()))
    }

    func testSelectedPhotosListInGridOrder() {
        let photos = (0..<5).map { insertPhoto(name: "p\($0)", rating: $0 % 2, creationDate: date(Double(10 - $0))) }
        viewModel.loadExistingData()
        viewModel.selection.selectedPhotos = [photos[3].id, photos[0].id, photos[4].id, photos[1].id]

        XCTAssertEqual(ids(viewModel.selection.selectedPhotosList), [photos[0].id, photos[1].id, photos[3].id, photos[4].id])

        viewModel.library.toggleSortOrder()
        XCTAssertEqual(ids(viewModel.selection.selectedPhotosList), [photos[4].id, photos[3].id, photos[1].id, photos[0].id])

        // Only photos in the grid are listed.
        viewModel.library.applyFilter(.rated(1))
        XCTAssertEqual(ids(viewModel.selection.selectedPhotosList), [photos[3].id, photos[1].id])
    }

    func testPrimarySelectedPhotoPrefersLastSelected() {
        let a = insertPhoto(name: "a", creationDate: date(3000))
        let b = insertPhoto(name: "b", creationDate: date(2000))
        let c = insertPhoto(name: "c", creationDate: date(1000))
        viewModel.loadExistingData()
        XCTAssertNil(viewModel.selection.primarySelectedPhoto)

        viewModel.selection.toggleSelection(for: c, addToSelection: false)
        viewModel.selection.toggleSelection(for: a, addToSelection: true)
        XCTAssertEqual(viewModel.selection.primarySelectedPhoto?.id, a.id)

        // Deselecting the last-clicked photo falls back to the first selected photo in grid order.
        viewModel.selection.toggleSelection(for: a, addToSelection: true)
        XCTAssertEqual(viewModel.selection.primarySelectedPhoto?.id, c.id)

        viewModel.selection.selectedPhotos = [c.id, b.id]
        viewModel.selection.lastSelectedId = nil
        XCTAssertEqual(viewModel.selection.primarySelectedPhoto?.id, b.id)
    }

    func testRangeSelectOnlySelectsVisiblePhotos() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 1, creationDate: date(2000))
        let c = insertPhoto(name: "c", rating: 3, creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.rated(3))

        viewModel.selection.toggleSelection(for: a, addToSelection: false)
        viewModel.selection.rangeSelect(to: c)

        XCTAssertEqual(viewModel.selection.selectedPhotos, [a.id, c.id])
        XCTAssertFalse(viewModel.selection.selectedPhotos.contains(b.id))
    }

    func testSelectAllSelectsVisiblePhotosOnly() {
        let a = insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", rating: 1)
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.rated(3))

        viewModel.selection.selectAll()

        XCTAssertEqual(viewModel.selection.selectedPhotos, [a.id])
    }

    func testNavigateDetailMovesThroughGridOrder() {
        let a = insertPhoto(name: "a", creationDate: date(3000))
        let b = insertPhoto(name: "b", creationDate: date(2000))
        viewModel.loadExistingData()
        viewModel.openDetail(for: a)

        viewModel.navigateDetail(direction: 1)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, b.id)
        viewModel.navigateDetail(direction: 1)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, b.id, "stays on the last photo")
        viewModel.navigateDetail(direction: -1)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, a.id)
    }

    func testNavigateGridUpAndDownUseColumns() {
        let photos = (0..<5).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        viewModel.loadExistingData()
        viewModel.gridColumns = 2
        viewModel.selection.toggleSelection(for: photos[0], addToSelection: false)

        viewModel.selection.navigateGrid(direction: .down, extendSelection: false, columns: viewModel.gridColumns)
        XCTAssertEqual(viewModel.selection.selectedPhotos, [photos[2].id])
        viewModel.selection.navigateGrid(direction: .down, extendSelection: true, columns: viewModel.gridColumns)
        XCTAssertEqual(viewModel.selection.selectedPhotos, [photos[2].id, photos[3].id, photos[4].id])
        viewModel.selection.navigateGrid(direction: .up, extendSelection: false, columns: viewModel.gridColumns)
        XCTAssertEqual(viewModel.selection.selectedPhotos, [photos[2].id])
    }

    // MARK: - In-memory state vs a fresh load

    /// A second view model on the same store, created before seeding so its one availability check
    /// runs on an empty store (like `viewModel`'s). Its `loadExistingData()` is the reference.
    private func makeOracle() -> PhotoLibraryViewModel {
        let oracle = PhotoLibraryViewModel()
        oracle.setModelContext(context)
        return oracle
    }

    /// The in-memory state after mutations must equal what a full reload of the store gives.
    private func assertMatchesFreshLoad(_ oracle: PhotoLibraryViewModel, _ step: String, line: UInt = #line) {
        oracle.library.sort = viewModel.library.sort
        oracle.library.activeFilters = viewModel.library.activeFilters
        oracle.library.viewingBin = viewModel.library.viewingBin
        oracle.library.searchText = viewModel.library.searchText
        oracle.loadExistingData()
        XCTAssertEqual(ids(viewModel.library.photos), ids(oracle.library.photos), "photos after \(step)", line: line)
        XCTAssertEqual(ids(viewModel.library.allPhotos), ids(oracle.library.allPhotos), "allPhotos after \(step)", line: line)
        XCTAssertEqual(viewModel.library.binCount, oracle.library.binCount, "binCount after \(step)", line: line)
        XCTAssertEqual(viewModel.library.ratingCounts, oracle.library.ratingCounts, "ratingCounts after \(step)", line: line)
        XCTAssertEqual(viewModel.library.tagCounts, oracle.library.tagCounts, "tagCounts after \(step)", line: line)
        XCTAssertEqual(viewModel.library.categoryCounts, oracle.library.categoryCounts, "categoryCounts after \(step)", line: line)
        XCTAssertEqual(viewModel.library.jpgCount, oracle.library.jpgCount, "jpgCount after \(step)", line: line)
        XCTAssertEqual(viewModel.library.rawCount, oracle.library.rawCount, "rawCount after \(step)", line: line)
        XCTAssertEqual(viewModel.library.allTags.map(\.id), oracle.library.allTags.map(\.id), "allTags after \(step)", line: line)
        XCTAssertEqual(viewModel.library.tagCategories, oracle.library.tagCategories, "tagCategories after \(step)", line: line)
        XCTAssertEqual(viewModel.library.uncategorizedTags.map(\.id), oracle.library.uncategorizedTags.map(\.id),
                       "uncategorizedTags after \(step)", line: line)
        XCTAssertEqual(viewModel.library.tagsByCategory.mapValues { $0.map(\.id) },
                       oracle.library.tagsByCategory.mapValues { $0.map(\.id) }, "tagsByCategory after \(step)", line: line)
        XCTAssertEqual(viewModel.library.photos.indices.map { viewModel.library.index(of: viewModel.library.photos[$0].id) },
                       viewModel.library.photos.indices.map { $0 }, "index(of:) after \(step)", line: line)
    }

    func testInMemoryStateMatchesFreshLoad() {
        let oracle = makeOracle()
        let people = Tag(name: "alice", category: "people")
        let places = Tag(name: "paris", category: "places")
        let loose = Tag(name: "misc")
        [people, places, loose].forEach { context.insert($0) }
        var photos: [PhotoAsset] = []
        for i in 0..<24 {
            let photo = insertPhoto(name: "IMG_\(i)", rating: i % 4, isDeleted: i == 11, creationDate: date(Double(100 - i)))
            if i % 3 == 0 { photo.rawPath = "/fake/IMG_\(i).cr3" }
            if i % 3 == 1 { photo.jpgPath = nil; photo.rawPath = "/fake/IMG_\(i).arw" }
            if i % 2 == 0 { photo.tags.append(people) }
            if i % 5 == 0 { photo.tags.append(places) }
            if i == 7 { photo.tags.append(loose) }
            photos.append(photo)
        }
        let undated = PhotoAsset(fileName: "undated", jpgPath: "/fake/undated.jpg", folderPath: "/fake", creationDate: nil)
        context.insert(undated)
        try? context.save()
        viewModel.loadExistingData()
        let check = { (step: String, line: UInt) in self.assertMatchesFreshLoad(oracle, step, line: line) }

        check("load", #line)
        viewModel.library.setRating(5, for: photos[1]); check("setRating", #line)
        viewModel.library.applyFilter(.rated(0)); check("rating filter", #line)
        viewModel.library.applyFilter(.rated(2), isShiftHeld: true); check("shift rating filter", #line)
        viewModel.library.setRating(3, for: viewModel.library.photos[0]); check("setRating out of the filter", #line)
        viewModel.library.setRating(2, for: photos[1]); check("setRating of a hidden photo into the filter", #line)
        viewModel.library.applyFilter(.jpgOnly); check("file-type filter", #line)
        viewModel.library.addTag(name: "rome", category: "places", to: viewModel.library.photos[0]); check("addTag new tag", #line)
        viewModel.library.applyFilter(.tagCategory("places")); check("tag category filter", #line)
        viewModel.library.removeTag(places, from: photos[0]); check("removeTag out of a tag filter", #line)
        viewModel.library.addTag(name: "paris", category: "places", to: photos[3]); check("addTag into a tag filter", #line)
        viewModel.deletePhoto(viewModel.library.photos[0]); check("deletePhoto under a filter", #line)
        viewModel.library.applyFilter(.all); check("clear filters", #line)
        viewModel.selection.selectedPhotos = [photos[0].id, photos[2].id, photos[4].id]
        viewModel.setRatingForSelection(1); check("setRatingForSelection", #line)
        viewModel.addTagToSelection(name: "beach", category: "scenes"); check("addTagToSelection new category", #line)
        viewModel.addTagToSelection(name: "misc", category: ""); check("addTagToSelection existing tag", #line)
        viewModel.toggleTag(people, for: photos[0]); check("toggleTag multi (remove)", #line)
        viewModel.toggleTag(people, for: photos[0]); check("toggleTag multi (add)", #line)
        viewModel.library.removeTag(places, from: photos[5]); check("removeTag", #line)
        viewModel.library.applyFilter(.tag(people.id)); check("tag filter", #line)
        viewModel.selection.selectedPhotos = Set(viewModel.library.photos.prefix(2).map(\.id))
        viewModel.deleteSelected(); check("deleteSelected", #line)
        viewModel.library.toggleSortOrder(); check("toggleSortOrder", #line)
        viewModel.library.applyFilter(.bin); check("bin", #line)
        viewModel.library.searchText = "img_1"; viewModel.library.applyCurrentFilter(); check("search in bin", #line)
        viewModel.selection.selectAll()
        viewModel.restoreSelected(); check("restoreSelected", #line)
        viewModel.library.searchText = ""; viewModel.library.applyFilter(.all); check("back to all", #line)
        viewModel.deletePhoto(viewModel.library.photos[3]); check("deletePhoto", #line)
        viewModel.deletePhoto(undated); check("deletePhoto undated", #line)
        viewModel.library.toggleSortOrder(); check("toggleSortOrder back", #line)
        viewModel.library.applyFilter(.bin)
        viewModel.restoreFromBin(Array(viewModel.library.photos)); check("restore everything", #line)

        // Bulk paths (more photos than are patched in place).
        viewModel.library.applyFilter(.all)
        viewModel.selection.selectAll()
        viewModel.setRatingForSelection(4); check("bulk setRatingForSelection", #line)
        viewModel.library.applyFilter(.rated(4))
        viewModel.selection.selectedPhotos = Set(viewModel.library.photos.prefix(12).map(\.id))
        viewModel.setRatingForSelection(5); check("bulk setRatingForSelection out of the filter", #line)
        viewModel.library.applyFilter(.all)
        viewModel.selection.selectAll()
        viewModel.addTagToSelection(name: "bulk", category: "scenes"); check("bulk addTagToSelection", #line)
        viewModel.selection.selectedPhotos = Set(viewModel.library.photos.prefix(15).map(\.id))
        viewModel.deleteSelected(); check("bulk deleteSelected", #line)
        viewModel.library.applyFilter(.bin)
        viewModel.selection.selectAll()
        viewModel.restoreSelected(); check("bulk restoreSelected", #line)

        viewModel.library.applyFilter(.rawOnly)
        viewModel.selection.selectedPhotos = [viewModel.library.photos[0].id]
        viewModel.deleteSelected(); check("deleteFileTypeOnly", #line)
    }

    /// Random sequences of every interaction, checked against a fresh load after each step.
    func testRandomisedInteractionsMatchFreshLoad() {
        let oracle = makeOracle()
        var rng = SeededGenerator(seed: 0x5EED_0010)
        let tagPool: [(name: String, category: String)] = [
            ("alice", "people"), ("bob", "people"), ("paris", "places"), ("rome", "places"), ("misc", ""), ("x", "zz"),
        ]
        for i in 0..<30 {
            let photo = insertPhoto(name: "IMG_\(i)", rating: Int.random(in: 0...5, using: &rng),
                                    isDeleted: i % 7 == 0, creationDate: date(Double(1000 - i * 10)))
            if Bool.random(using: &rng) { photo.rawPath = "/fake/IMG_\(i).arw" }
        }
        viewModel.loadExistingData()

        func randomSubset(_ photos: [PhotoAsset], upTo max: Int) -> [PhotoAsset] {
            Array(photos.shuffled(using: &rng).prefix(Int.random(in: 1...max, using: &rng)))
        }
        let filters: [SidebarFilter] = [.all, .unrated, .rated(1), .rated(3), .rated(5), .jpgOnly, .rawOnly,
                                        .tagCategory("people"), .tagCategory("places"), .bin]

        for step in 0..<250 {
            let visible = viewModel.library.photos
            let action = Int.random(in: 0..<12, using: &rng)
            switch action {
            case 0:
                viewModel.library.applyFilter(filters.randomElement(using: &rng)!, isShiftHeld: Bool.random(using: &rng))
            case 1:
                if let tag = viewModel.library.allTags.randomElement(using: &rng) {
                    viewModel.library.applyFilter(.tag(tag.id), isShiftHeld: Bool.random(using: &rng))
                }
            case 2:
                let pool = Bool.random(using: &rng) ? visible : viewModel.library.allPhotos
                if let photo = pool.randomElement(using: &rng) {
                    viewModel.library.setRating(Int.random(in: 0...5, using: &rng), for: photo)
                }
            case 3 where !visible.isEmpty:
                viewModel.selection.selectedPhotos = Set(randomSubset(visible, upTo: 20).map(\.id))
                viewModel.setRatingForSelection(Int.random(in: 0...5, using: &rng))
            case 4:
                let tag = tagPool.randomElement(using: &rng)!
                if let photo = viewModel.library.allPhotos.randomElement(using: &rng) {
                    viewModel.library.addTag(name: tag.name, category: tag.category, to: photo)
                }
            case 5:
                if let photo = viewModel.library.allPhotos.randomElement(using: &rng), let tag = photo.tags.randomElement(using: &rng) {
                    viewModel.library.removeTag(tag, from: photo)
                }
            case 6 where !visible.isEmpty:
                let tag = tagPool.randomElement(using: &rng)!
                viewModel.selection.selectedPhotos = Set(randomSubset(visible, upTo: 20).map(\.id))
                viewModel.addTagToSelection(name: tag.name, category: tag.category)
            case 7 where visible.count > 1:
                let subset = randomSubset(visible, upTo: 20)
                viewModel.selection.selectedPhotos = Set(subset.map(\.id))
                if let tag = viewModel.library.allTags.randomElement(using: &rng) {
                    viewModel.toggleTag(tag, for: subset[0])
                }
            case 8 where !visible.isEmpty && !viewModel.library.viewingBin && !viewModel.library.hasFileTypeFilter:
                if Bool.random(using: &rng) {
                    viewModel.deletePhoto(visible.randomElement(using: &rng)!)
                } else {
                    viewModel.selection.selectedPhotos = Set(randomSubset(visible, upTo: 20).map(\.id))
                    viewModel.deleteSelected()
                }
            case 9:
                if !viewModel.library.viewingBin { viewModel.library.applyFilter(.bin) }
                if !viewModel.library.photos.isEmpty {
                    viewModel.restoreFromBin(randomSubset(viewModel.library.photos, upTo: 20))
                }
            case 10:
                viewModel.library.toggleSortOrder()
            case 11:
                viewModel.library.searchText = ["", "", "img_1", "img_2", "people", "a", "zz"].randomElement(using: &rng)!
                viewModel.library.applyCurrentFilter()
            default:
                break
            }
            assertMatchesFreshLoad(oracle, "step \(step) (action \(action))")
        }
    }
}

/// Deterministic generator (SplitMix64) for the randomised tests.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
