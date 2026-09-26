import XCTest
import SwiftData
@testable import Phocasa

/// `SelectionModel`: clicks, range and select-all over the grid, the primary photo, and keyboard navigation. Moved
/// from `ViewModelTests` (task 30) with every assertion.
final class SelectionModelTests: LibraryTestCase {

    private var selection: SelectionModel!
    /// The grid's column count, which the view model passes to `navigateGrid` (its default is 6).
    private var columns = 6

    override func setUp() async throws {
        try await super.setUp()
        selection = SelectionModel(library: library)
    }

    override func tearDown() async throws {
        selection = nil
        try await super.tearDown()
    }

    // MARK: - Selection

    func testToggleSelectionSingle() {
        let photo = insertPhoto(name: "a")
        library.loadExistingData()

        selection.toggleSelection(for: photo, addToSelection: false)

        XCTAssertEqual(selection.selectedPhotos, [photo.id])
        XCTAssertEqual(selection.lastSelectedId, photo.id)
    }

    func testToggleSelectionReplacesExisting() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        library.loadExistingData()

        selection.toggleSelection(for: a, addToSelection: false)
        selection.toggleSelection(for: b, addToSelection: false)

        XCTAssertEqual(selection.selectedPhotos, [b.id])
    }

    func testToggleSelectionAddToSelection() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        library.loadExistingData()

        selection.toggleSelection(for: a, addToSelection: false)
        selection.toggleSelection(for: b, addToSelection: true)

        XCTAssertEqual(selection.selectedPhotos, [a.id, b.id])
    }

    func testToggleSelectionRemoveFromSelection() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        library.loadExistingData()

        selection.toggleSelection(for: a, addToSelection: false)
        selection.toggleSelection(for: b, addToSelection: true)
        selection.toggleSelection(for: a, addToSelection: true)

        XCTAssertEqual(selection.selectedPhotos, [b.id])
    }

    func testSelectAll() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        library.loadExistingData()

        selection.selectAll()

        XCTAssertEqual(selection.selectedPhotos, [a.id, b.id, c.id])
    }

    func testClearSelection() {
        let photo = insertPhoto(name: "a")
        library.loadExistingData()
        selection.selectedPhotos = [photo.id]
        selection.lastSelectedId = photo.id

        selection.clearSelection()

        XCTAssertTrue(selection.selectedPhotos.isEmpty)
        XCTAssertNil(selection.lastSelectedId)
    }

    func testRangeSelect() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        library.loadExistingData()

        selection.toggleSelection(for: a, addToSelection: false)
        selection.rangeSelect(to: c)

        XCTAssertTrue(selection.selectedPhotos.contains(a.id))
        XCTAssertTrue(selection.selectedPhotos.contains(b.id))
        XCTAssertTrue(selection.selectedPhotos.contains(c.id))
    }

    func testRangeSelectReverse() {
        let a = insertPhoto(name: "a")
        let b = insertPhoto(name: "b")
        let c = insertPhoto(name: "c")
        library.loadExistingData()

        selection.toggleSelection(for: c, addToSelection: false)
        selection.rangeSelect(to: a)

        XCTAssertTrue(selection.selectedPhotos.contains(a.id))
        XCTAssertTrue(selection.selectedPhotos.contains(b.id))
        XCTAssertTrue(selection.selectedPhotos.contains(c.id))
    }

    // MARK: - Grid Navigation

    func testNavigateGridRight() {
        // sortNewestFirst=true means newest (later date) appears first in the array
        let a = insertPhoto(name: "a", creationDate: Date(timeIntervalSince1970: 2000))
        let b = insertPhoto(name: "b", creationDate: Date(timeIntervalSince1970: 1000))
        library.loadExistingData()
        // a is newest → index 0, b is oldest → index 1
        selection.selectedPhotos = [a.id]
        selection.lastSelectedId = a.id

        selection.navigateGrid(direction: .right, extendSelection: false, columns: columns)

        XCTAssertEqual(selection.selectedPhotos, [b.id])
        XCTAssertEqual(selection.lastSelectedId, b.id)
    }

    func testNavigateGridWithExtendSelection() {
        let a = insertPhoto(name: "a", creationDate: Date(timeIntervalSince1970: 2000))
        let b = insertPhoto(name: "b", creationDate: Date(timeIntervalSince1970: 1000))
        library.loadExistingData()
        selection.selectedPhotos = [a.id]
        selection.lastSelectedId = a.id

        selection.navigateGrid(direction: .right, extendSelection: true, columns: columns)

        XCTAssertTrue(selection.selectedPhotos.contains(a.id))
        XCTAssertTrue(selection.selectedPhotos.contains(b.id))
    }

    func testNavigateGridEmptyPhotos() {
        library.loadExistingData()
        selection.navigateGrid(direction: .right, extendSelection: false, columns: columns)
        // Should not crash
    }

    func testNavigateGridNoSelection() {
        insertPhoto(name: "a")
        insertPhoto(name: "b")
        library.loadExistingData()

        selection.navigateGrid(direction: .right, extendSelection: false, columns: columns)

        // Should select the first photo
        XCTAssertEqual(selection.selectedPhotos.count, 1)
    }

    // MARK: - In-memory library state

    func testSelectedPhotosListInGridOrder() {
        let photos = (0..<5).map { insertPhoto(name: "p\($0)", rating: $0 % 2, creationDate: date(Double(10 - $0))) }
        library.loadExistingData()
        selection.selectedPhotos = [photos[3].id, photos[0].id, photos[4].id, photos[1].id]

        XCTAssertEqual(ids(selection.selectedPhotosList), [photos[0].id, photos[1].id, photos[3].id, photos[4].id])

        library.toggleSortOrder()
        XCTAssertEqual(ids(selection.selectedPhotosList), [photos[4].id, photos[3].id, photos[1].id, photos[0].id])

        // Only photos in the grid are listed.
        library.applyFilter(.rated(1))
        XCTAssertEqual(ids(selection.selectedPhotosList), [photos[3].id, photos[1].id])
    }

    func testPrimarySelectedPhotoPrefersLastSelected() {
        let a = insertPhoto(name: "a", creationDate: date(3000))
        let b = insertPhoto(name: "b", creationDate: date(2000))
        let c = insertPhoto(name: "c", creationDate: date(1000))
        library.loadExistingData()
        XCTAssertNil(selection.primarySelectedPhoto)

        selection.toggleSelection(for: c, addToSelection: false)
        selection.toggleSelection(for: a, addToSelection: true)
        XCTAssertEqual(selection.primarySelectedPhoto?.id, a.id)

        // Deselecting the last-clicked photo falls back to the first selected photo in grid order.
        selection.toggleSelection(for: a, addToSelection: true)
        XCTAssertEqual(selection.primarySelectedPhoto?.id, c.id)

        selection.selectedPhotos = [c.id, b.id]
        selection.lastSelectedId = nil
        XCTAssertEqual(selection.primarySelectedPhoto?.id, b.id)
    }

    func testRangeSelectOnlySelectsVisiblePhotos() {
        let a = insertPhoto(name: "a", rating: 3, creationDate: date(3000))
        let b = insertPhoto(name: "b", rating: 1, creationDate: date(2000))
        let c = insertPhoto(name: "c", rating: 3, creationDate: date(1000))
        library.loadExistingData()
        library.applyFilter(.rated(3))

        selection.toggleSelection(for: a, addToSelection: false)
        selection.rangeSelect(to: c)

        XCTAssertEqual(selection.selectedPhotos, [a.id, c.id])
        XCTAssertFalse(selection.selectedPhotos.contains(b.id))
    }

    func testSelectAllSelectsVisiblePhotosOnly() {
        let a = insertPhoto(name: "a", rating: 3)
        insertPhoto(name: "b", rating: 1)
        library.loadExistingData()
        library.applyFilter(.rated(3))

        selection.selectAll()

        XCTAssertEqual(selection.selectedPhotos, [a.id])
    }

    /// Bug test (REL-1 #2): once the anchor had left the grid (rated out of the filter, moved to the bin), the next
    /// arrow selected the first photo and scrolled to the top. It moves on from where the anchor was.
    func testNavigateGridFromAnAnchorThatLeftTheGrid() {
        let photos = (0..<6).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        library.loadExistingData()
        library.applyFilter(.unrated)

        selection.toggleSelection(for: photos[3], addToSelection: false)
        library.setRating(2, for: photos[3])
        XCTAssertNil(library.index(of: photos[3].id), "rated out of Unrated")
        selection.navigateGrid(direction: .right, extendSelection: false, columns: columns)
        XCTAssertEqual(selection.selectedPhotos, [photos[4].id], "the photo after it")
        XCTAssertEqual(selection.lastSelectedId, photos[4].id)

        library.moveToBin([photos[4]])
        selection.deselect([photos[4].id])
        selection.navigateGrid(direction: .left, extendSelection: false, columns: columns)
        XCTAssertEqual(selection.selectedPhotos, [photos[2].id], "the photo before it")

        // Rows: the grid is p0 p1 | p2 p5; with p2 gone, down goes to the photo that was below it.
        columns = 2
        library.applyFilter(.all)
        XCTAssertEqual(ids(library.photos), ids([photos[0], photos[1], photos[2], photos[3], photos[5]]))
        library.applyFilter(.unrated)
        selection.select(only: photos[1].id)
        library.setRating(1, for: photos[1])
        selection.navigateGrid(direction: .down, extendSelection: false, columns: columns)
        XCTAssertEqual(selection.selectedPhotos, [photos[5].id], "p0 p2 | p5: below p1's place")
        library.setRating(1, for: photos[5])
        selection.navigateGrid(direction: .up, extendSelection: false, columns: columns)
        XCTAssertEqual(selection.selectedPhotos, [photos[0].id])
    }

    /// An anchor that is no longer loaded at all (deleted) falls back to the first photo, as before.
    func testNavigateGridFromAnAnchorThatIsGoneSelectsTheFirstPhoto() {
        let photos = (0..<3).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        library.loadExistingData()
        selection.lastSelectedId = UUID()

        selection.navigateGrid(direction: .right, extendSelection: false, columns: columns)

        XCTAssertEqual(selection.selectedPhotos, [photos[0].id])
    }

    func testNavigateGridUpAndDownUseColumns() {
        let photos = (0..<5).map { insertPhoto(name: "p\($0)", creationDate: date(Double(10 - $0))) }
        library.loadExistingData()
        columns = 2
        selection.toggleSelection(for: photos[0], addToSelection: false)

        selection.navigateGrid(direction: .down, extendSelection: false, columns: columns)
        XCTAssertEqual(selection.selectedPhotos, [photos[2].id])
        selection.navigateGrid(direction: .down, extendSelection: true, columns: columns)
        XCTAssertEqual(selection.selectedPhotos, [photos[2].id, photos[3].id, photos[4].id])
        selection.navigateGrid(direction: .up, extendSelection: false, columns: columns)
        XCTAssertEqual(selection.selectedPhotos, [photos[2].id])
    }
}
