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
        isInBin: Bool = false,
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
        photo.isInBin = isInBin
        context.insert(photo)
        try? context.save()
        return photo
    }

    // MARK: - Launch

    /// The app owns the view model, so a window that closes and opens again calls `setModelContext` with the context
    /// the library already has: nothing is loaded or rescanned again.
    func testSettingTheSameContextAgainIsANoOp() {
        insertPhoto(name: "a")
        viewModel.loadExistingData()
        let generation = viewModel.library.loading.generation
        let photos = viewModel.library.photos

        viewModel.setModelContext(context)

        XCTAssertEqual(viewModel.library.loading.generation, generation, "no second load")
        XCTAssertEqual(viewModel.library.photos.map(\.id), photos.map(\.id))
        XCTAssertTrue(viewModel.library.modelContext === context)
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
        let photo = insertPhoto(name: "a", isInBin: true)
        viewModel.loadExistingData()

        viewModel.restoreFromBin([photo])

        XCTAssertFalse(photo.isInBin)
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

        let photo = insertPhoto(name: "binned", isInBin: true)
        photo.jpgPath = path
        try context.save()

        // The availability check only looks at non-binned photos (as at app launch).
        viewModel.library.refreshAvailability()
        viewModel.restoreFromBin([photo])

        XCTAssertTrue(viewModel.library.allPhotos.contains { $0.id == photo.id })
    }

    func testRestoreSelected() {
        let a = insertPhoto(name: "a", isInBin: true)
        let b = insertPhoto(name: "b", isInBin: true)
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.bin)
        viewModel.selection.selectedPhotos = [a.id, b.id]

        viewModel.restoreSelected()

        XCTAssertFalse(a.isInBin)
        XCTAssertFalse(b.isInBin)
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

    /// Bug test (REL-1 #6): "Revert All Edits" cleared the saved edits at once, and only the clicked photo's even on a
    /// multi-selection. It asks first, with the count, and reverts every selected photo that has edits.
    func testRevertAllEditsAsksFirstAndRevertsTheSelection() {
        let photos = (0..<3).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        var params = EditParameters()
        params.exposure = 1
        photos[0].jpgEditParameters = params
        photos[1].jpgEditParameters = params
        try? context.save()
        viewModel.loadExistingData()
        viewModel.selection.selectAll()

        viewModel.requestRevertEdits(from: photos[0])

        XCTAssertEqual(Set(ids(viewModel.photosToRevert)), [photos[0].id, photos[1].id], "the selected photos with edits")
        XCTAssertNotNil(photos[0].jpgEditParametersData, "nothing reverted before the confirmation")
        viewModel.confirmRevertEdits()
        XCTAssertTrue(viewModel.photosToRevert.isEmpty)
        XCTAssertNil(photos[0].jpgEditParametersData)
        XCTAssertNil(photos[1].jpgEditParametersData)

        // Outside the selection: only the clicked photo.
        photos[2].jpgEditParameters = params
        photos[0].jpgEditParameters = params
        viewModel.selection.select(only: photos[1].id)
        viewModel.requestRevertEdits(from: photos[2])
        XCTAssertEqual(ids(viewModel.photosToRevert), [photos[2].id])
    }

    // MARK: - Smart Delete (File Type)

    /// ⌫ with the RAW or JPG filter on asks first (files go to the Trash); this confirms what it asked.
    private func deleteConfirmingFileTypeDelete(file: StaticString = #filePath, line: UInt = #line) async {
        viewModel.deleteSelected()
        guard let request = viewModel.pendingFileTypeDelete else {
            return XCTFail("the file-type delete asks first", file: file, line: line)
        }
        await viewModel.confirmFileTypeDelete(request)?.value
    }

    /// Bug test (REL-1 #5): with the RAW filter on, ⌫ (and "Move to Bin") put every selected pair's RAW in the Trash
    /// at once, with no confirmation (⌘A ⌫ trashed every RAW in the library). It asks first, naming the count and the
    /// file type, and nothing happens until it's confirmed.
    func testFileTypeDeleteAsksFirstNamingTheCountAndTheFileType() async {
        let pairs = (0..<3).map { i -> PhotoAsset in
            let photo = PhotoAsset(fileName: "p\(i)", jpgPath: "/fake/p\(i).jpg", rawPath: "/fake/p\(i).cr3",
                                   folderPath: "/fake", creationDate: date(Double(10 - i)), fileSize: 2000)
            context.insert(photo)
            return photo
        }
        let rawOnly = PhotoAsset(fileName: "solo", rawPath: "/fake/solo.cr3", folderPath: "/fake", creationDate: date(1))
        context.insert(rawOnly)
        try? context.save()
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.rawOnly)
        XCTAssertEqual(viewModel.deleteActionTitle(count: 4), "Delete RAW Files…")
        XCTAssertEqual(viewModel.deleteActionTitle(count: 1), "Delete RAW File…")
        viewModel.selection.selectAll()

        XCTAssertNil(viewModel.deleteSelected(), "nothing starts before the confirmation")

        let request = try? XCTUnwrap(viewModel.pendingFileTypeDelete)
        XCTAssertEqual(request?.title, "Move 3 RAW files to the Trash?")
        XCTAssertEqual(request?.message, "The JPGs stay in the library. 1 photo has only a RAW file and goes to the Bin instead.")
        XCTAssertEqual(request?.confirmTitle, "Move to Trash")
        XCTAssertTrue(pairs.allSatisfy { $0.rawPath != nil }, "nothing deleted yet")
        guard let request else { return }

        await viewModel.confirmFileTypeDelete(request)?.value
        XCTAssertNil(viewModel.pendingFileTypeDelete)
        XCTAssertTrue(pairs.allSatisfy { $0.rawPath == nil && $0.jpgPath != nil })
        XCTAssertTrue(rawOnly.isInBin)

        viewModel.library.applyFilter(.jpgOnly)
        XCTAssertEqual(viewModel.deleteActionTitle(count: 2), "Delete JPG Files…")
        viewModel.library.applyFilter(.all)
        XCTAssertEqual(viewModel.deleteActionTitle(count: 2), "Move to Bin")
        viewModel.library.applyFilter(.bin)
        XCTAssertEqual(viewModel.deleteActionTitle(count: 2), "Delete Forever…")
    }

    /// In the detail view, the RAW filter's ⌫ asks about the photo on screen, then moves on.
    func testFileTypeDeleteInTheDetailViewAsksAboutThePhotoOnScreen() async throws {
        let photos = (0..<2).map { i -> PhotoAsset in
            let photo = PhotoAsset(fileName: "p\(i)", jpgPath: "/fake/p\(i).jpg", rawPath: "/fake/p\(i).cr3",
                                   folderPath: "/fake", creationDate: date(Double(10 - i)), fileSize: 2000)
            context.insert(photo)
            return photo
        }
        try context.save()
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.rawOnly)
        viewModel.selection.selectAll()
        viewModel.openDetail(for: photos[0])

        viewModel.deleteSelectionOrCurrent()
        let request = try XCTUnwrap(viewModel.pendingFileTypeDelete)
        XCTAssertEqual(ids(request.photos), [photos[0].id])
        XCTAssertEqual(request.title, "Move 1 RAW file to the Trash?")
        await viewModel.confirmFileTypeDelete(request)?.value

        XCTAssertNil(photos[0].rawPath)
        XCTAssertNotNil(photos[1].rawPath)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[1].id)
    }

    func testDeleteInRAWOnlyModeRemovesOnlyRAW() async {
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rawOnly)
        viewModel.selection.selectedPhotos = [paired.id]

        await deleteConfirmingFileTypeDelete()

        // RAW path should be cleared, JPG should remain
        XCTAssertNil(paired.rawPath)
        XCTAssertEqual(paired.jpgPath, "/fake/paired.jpg")
        XCTAssertFalse(paired.isInBin, "Photo should NOT be in bin")
        XCTAssertFalse(paired.hasRawEdits, "RAW edits should be cleared")
    }

    func testDeleteInJPGOnlyModeRemovesOnlyJPG() async {
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.jpgOnly)
        viewModel.selection.selectedPhotos = [paired.id]

        await deleteConfirmingFileTypeDelete()

        // JPG path should be cleared, RAW should remain
        XCTAssertNil(paired.jpgPath)
        XCTAssertEqual(paired.rawPath, "/fake/paired.cr3")
        XCTAssertFalse(paired.isInBin, "Photo should NOT be in bin")
    }

    func testDeleteNonPairedInRAWOnlyModeSoftDeletes() async {
        let rawOnly = PhotoAsset(fileName: "raw_only", rawPath: "/fake/raw_only.cr3",
                                 folderPath: "/fake", creationDate: Date(), fileSize: 1000)
        context.insert(rawOnly)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rawOnly)
        viewModel.selection.selectedPhotos = [rawOnly.id]

        await deleteConfirmingFileTypeDelete()

        // Non-paired RAW should go to bin — check via binCount since the photo
        // gets refetched by loadExistingData after delete
        XCTAssertEqual(viewModel.library.binCount, 1, "Non-paired photo should be soft-deleted to bin")
        XCTAssertEqual(viewModel.library.allPhotos.count, 0, "No active photos should remain")
    }

    func testDeleteClearsSelectionAfterFileTypeDelete() async {
        let paired = PhotoAsset(fileName: "paired", jpgPath: "/fake/paired.jpg", rawPath: "/fake/paired.cr3",
                                folderPath: "/fake", creationDate: Date(), fileSize: 2000)
        context.insert(paired)
        try? context.save()
        viewModel.loadExistingData()

        viewModel.library.applyFilter(.rawOnly)
        viewModel.selection.selectedPhotos = [paired.id]

        await deleteConfirmingFileTypeDelete()

        XCTAssertTrue(viewModel.selection.selectedPhotos.isEmpty)
    }

    // MARK: - In-memory library state

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func ids(_ photos: [PhotoAsset]) -> [UUID] { photos.map(\.id) }

    /// Ids of the binned photos as stored, read through a separate context.
    private func storedBinIDs() -> Set<UUID> {
        let fresh = ModelContext(container)
        let rows = (try? fresh.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.isInBin }))) ?? []
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
        let a = insertPhoto(name: "a", isInBin: true, creationDate: date(2000))
        let b = insertPhoto(name: "b", isInBin: true, creationDate: date(1000))
        insertPhoto(name: "c")
        viewModel.loadExistingData()

        viewModel.emptyBin()

        XCTAssertTrue(viewModel.showPermanentDeleteConfirmation)
        XCTAssertEqual(Set(ids(viewModel.photosToDelete)), [a.id, b.id])
    }

    func testConfirmPermanentDeleteEmptiesBin() async {
        insertPhoto(name: "a", isInBin: true)
        insertPhoto(name: "b")
        viewModel.loadExistingData()
        viewModel.emptyBin()

        await viewModel.confirmPermanentDelete()?.value

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

    /// Bug test (REL-1 #2): culling in a filter, the photo on screen is rated out of it. ←/→ did nothing (its index was
    /// gone) and the counter disappeared. They now go to the photos either side of where it was.
    func testNavigateDetailAfterThePhotoLeftTheFilter() {
        let photos = (0..<4).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.unrated)
        viewModel.openDetail(for: photos[1])

        viewModel.setRatingForSelectionOrCurrent(3)
        XCTAssertNil(viewModel.library.index(of: photos[1].id), "rated out of Unrated")
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[1].id, "still on screen")
        viewModel.navigateDetail(direction: 1)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[2].id, "the photo after it")

        viewModel.setRatingForSelectionOrCurrent(4)
        viewModel.navigateDetail(direction: -1)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[0].id, "the photo before it")

        // After the sort is reversed too.
        viewModel.setRatingForSelectionOrCurrent(5)
        viewModel.library.toggleSortOrder()
        XCTAssertEqual(ids(viewModel.library.photos), [photos[3].id])
        viewModel.navigateDetail(direction: -1)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[3].id)
    }

    // MARK: - The detail view acts on the photo on screen

    /// Bug test (REL-1 #1): ⌫ in the detail view binned the grid's selection, whatever was on screen (open A, → to B,
    /// ⌫: A went to the bin while B stayed on screen; opened from a selection of 200, ⌫ binned all 200). It bins the
    /// photo on screen, then shows the next one (the previous one at the end), and closes when none is left.
    func testDeleteInTheDetailViewBinsThePhotoOnScreenThenShowsTheNext() {
        let photos = (0..<4).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        viewModel.loadExistingData()
        viewModel.selection.selectAll()
        viewModel.openDetail(for: photos[0])
        viewModel.navigateDetail(direction: 1)

        viewModel.deleteSelectionOrCurrent()

        XCTAssertEqual(ids(viewModel.library.binPhotos), [photos[1].id], "only the photo on screen")
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[2].id, "then the next photo")
        XCTAssertTrue(viewModel.showingDetail)
        viewModel.navigateDetail(direction: 1)
        viewModel.deleteSelectionOrCurrent()
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[2].id, "at the end, the previous photo")
        viewModel.deleteSelectionOrCurrent()
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[0].id)
        viewModel.deleteSelectionOrCurrent()
        XCTAssertFalse(viewModel.showingDetail, "none left: the detail view closes")
        XCTAssertNil(viewModel.selectedDetailPhoto)
        XCTAssertEqual(viewModel.library.binCount, 4)
    }

    /// Deleting while editing saves the edit and carries on editing the next photo, as navigating does.
    func testDeleteWhileEditingSavesAndEditsTheNextPhoto() throws {
        let photos = (0..<2).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        viewModel.loadExistingData()
        viewModel.openDetail(for: photos[0])
        viewModel.startEditing(photo: photos[0], isRAW: false)
        viewModel.editSession?.parameters.exposure = 1

        viewModel.deleteSelectionOrCurrent()

        XCTAssertEqual(photos[0].jpgEditParameters?.exposure, 1, "saved")
        XCTAssertEqual(viewModel.editSession?.photo.id, photos[1].id)
        viewModel.stopEditing(save: false)
    }

    /// In the bin, the Delete Forever prompt is about the photo on screen, not the grid's selection.
    func testDeleteForeverInTheDetailViewAsksAboutThePhotoOnScreen() async {
        let a = insertPhoto(name: "a", isInBin: true, creationDate: date(2000))
        let b = insertPhoto(name: "b", isInBin: true, creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.bin)
        viewModel.selection.selectAll()
        viewModel.openDetail(for: a)
        viewModel.navigateDetail(direction: 1)

        viewModel.deleteSelectionOrCurrent()

        XCTAssertTrue(viewModel.showPermanentDeleteConfirmation)
        XCTAssertEqual(ids(viewModel.photosToDelete), [b.id])
        await viewModel.confirmPermanentDelete()?.value
        XCTAssertEqual(ids(viewModel.library.binPhotos), [a.id])
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, a.id, "the photo left")
    }

    /// Emptying the bin from the toolbar while one of its photos is on screen closes the detail view before the
    /// photos are deleted (it mustn't go on showing a deleted photo).
    func testEmptyingTheBinWhileItsPhotoIsOnScreenClosesTheDetailView() async {
        let a = insertPhoto(name: "a", isInBin: true)
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.bin)
        viewModel.openDetail(for: a)

        viewModel.emptyBin()
        let deleting = viewModel.confirmPermanentDelete()

        XCTAssertFalse(viewModel.showingDetail)
        XCTAssertNil(viewModel.selectedDetailPhoto)
        await deleting?.value
        XCTAssertEqual(viewModel.library.binCount, 0)
    }

    /// Restore in the bin's detail view restores the photo on screen, then shows the next one.
    func testRestoreInTheDetailViewRestoresThePhotoOnScreen() {
        let a = insertPhoto(name: "a", isInBin: true, creationDate: date(2000))
        let b = insertPhoto(name: "b", isInBin: true, creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.library.applyFilter(.bin)
        viewModel.selection.selectAll()
        viewModel.openDetail(for: a)

        viewModel.restoreSelectionOrCurrent()

        XCTAssertFalse(a.isInBin)
        XCTAssertTrue(b.isInBin, "the rest of the selection stays in the bin")
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, b.id)
    }

    /// Bug test (REL-1 #1): the detail view's tag editor tagged the grid's (hidden) multi-selection. It tags the photo
    /// on screen; from the grid's context menu it still tags the selection.
    func testTheDetailViewsTagEditorTagsOnlyThePhotoOnScreen() throws {
        let a = insertPhoto(name: "a", creationDate: date(2000))
        let b = insertPhoto(name: "b", creationDate: date(1000))
        viewModel.loadExistingData()
        viewModel.selection.selectAll()
        viewModel.openDetail(for: a)
        viewModel.navigateDetail(direction: 1)

        XCTAssertFalse(viewModel.tagEditorEditsSelection)
        viewModel.addTagFromEditor(name: "x", category: "c", photo: b)
        XCTAssertEqual(b.tags.map(\.name), ["x"])
        XCTAssertTrue(a.tags.isEmpty, "not the rest of the selection")
        let x = try XCTUnwrap(b.tags.first)
        viewModel.toggleTagFromEditor(x, photo: b)
        XCTAssertTrue(b.tags.isEmpty)

        viewModel.closeDetail()
        viewModel.selection.selectAll()
        XCTAssertTrue(viewModel.tagEditorEditsSelection)
        viewModel.toggleTagFromEditor(x, photo: a)
        XCTAssertEqual(a.tags.map(\.id), [x.id])
        XCTAssertEqual(b.tags.map(\.id), [x.id], "from the grid: the whole selection")
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

    func testInMemoryStateMatchesFreshLoad() async {
        let oracle = makeOracle()
        let people = Tag(name: "alice", category: "people")
        let places = Tag(name: "paris", category: "places")
        let loose = Tag(name: "misc")
        [people, places, loose].forEach { context.insert($0) }
        var photos: [PhotoAsset] = []
        for i in 0..<24 {
            let photo = insertPhoto(name: "IMG_\(i)", rating: i % 4, isInBin: i == 11, creationDate: date(Double(100 - i)))
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
        await deleteConfirmingFileTypeDelete(); check("deleteFileTypeOnly", #line)
    }

    /// Random sequences of every interaction, checked against a fresh load after each step.
    func testRandomisedInteractionsMatchFreshLoad() async {
        await randomisedInteractions(seed: 0x5EED_0010)
    }

    /// The same with the rows written in chunks of 2 (actions on more than 2 photos are queued). Two steps in three go
    /// on without waiting, so later actions meet queued changes (merged, or written early by a small action); every
    /// third waits for the queue, then checks that the store holds what memory shows.
    func testRandomisedInteractionsWithRowsWrittenInChunksMatchFreshLoad() async {
        viewModel.library.rowWrites.sizer.maximumRows = 2
        viewModel.library.rowWrites.immediateLimit = 2
        viewModel.library.rowWrites.pausesBetweenChunks = false
        await randomisedInteractions(seed: 0x5EED_0011, chunked: true)
    }

    private func randomisedInteractions(seed: UInt64, chunked: Bool = false) async {
        let oracle = makeOracle()
        var rng = SeededGenerator(seed: seed)
        let tagPool: [(name: String, category: String)] = [
            ("alice", "people"), ("bob", "people"), ("paris", "places"), ("rome", "places"), ("misc", ""), ("x", "zz"),
        ]
        for i in 0..<30 {
            let photo = insertPhoto(name: "IMG_\(i)", rating: Int.random(in: 0...5, using: &rng),
                                    isInBin: i % 7 == 0, creationDate: date(Double(1000 - i * 10)))
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
                if let photo = viewModel.library.allPhotos.randomElement(using: &rng), let tag = viewModel.library.tags(of: photo).randomElement(using: &rng) {
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
            if chunked {
                // Every third step goes on before the queue is written, so later actions meet queued changes.
                guard step % 3 == 0 else { continue }
                await viewModel.library.waitForRowWrites()
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
