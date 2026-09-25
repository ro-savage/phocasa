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

    // MARK: - Rating

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

    /// The context menu's checked tags come from the in-memory facts, once per menu. They must be what reading each
    /// targeted photo's tags gives: the tags all selected photos share, or the clicked photo's own.
    func testContextMenuTagIDsMatchTheTargetedPhotosTags() {
        let photos = (0..<4).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        viewModel.loadExistingData()
        viewModel.library.addTag(name: "shared", category: "cat", to: photos[0])
        viewModel.library.addTag(name: "shared", category: "cat", to: photos[1])
        viewModel.library.addTag(name: "shared", category: "cat", to: photos[2])
        viewModel.library.addTag(name: "some", category: "", to: photos[0])
        viewModel.library.addTag(name: "one", category: "cat", to: photos[3])
        let tags = viewModel.library.allTags
        func fromModels(_ targets: [PhotoAsset]) -> Set<UUID> {
            Set(tags.filter { tag in targets.allSatisfy { $0.tags.contains { $0.id == tag.id } } }.map(\.id))
        }

        viewModel.selection.selectedPhotos = [photos[0].id, photos[1].id, photos[2].id]
        XCTAssertEqual(viewModel.contextMenuTagIDs(for: photos[1]), fromModels(Array(photos[0...2])))
        XCTAssertEqual(viewModel.contextMenuTagIDs(for: photos[1]).count, 1, "only the shared tag")
        // A photo outside the selection: its own tags.
        XCTAssertEqual(viewModel.contextMenuTagIDs(for: photos[3]), fromModels([photos[3]]))
        viewModel.selection.selectedPhotos = [photos[0].id]
        XCTAssertEqual(viewModel.contextMenuTagIDs(for: photos[0]), fromModels([photos[0]]))
        for tag in tags {
            XCTAssertEqual(viewModel.contextMenuTagState(tag, for: photos[0]), photos[0].tags.contains { $0.id == tag.id })
        }
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
