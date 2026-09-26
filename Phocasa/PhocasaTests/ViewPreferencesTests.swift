import XCTest
import SwiftData
@testable import Phocasa

/// The sort order and the grid's zoom last across launches (REL-4 #2); the filter doesn't. The test host keeps them in
/// memory, so no test reads or changes the owner's.
@MainActor
final class ViewPreferencesTests: XCTestCase {

    private func makeContext(photos count: Int) throws -> (ModelContext, ModelContainer) {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        for i in 0..<count {
            context.insert(PhotoAsset(fileName: "p\(i)", jpgPath: "/prefs/p\(i).jpg", folderPath: "/prefs",
                                      creationDate: Date(timeIntervalSince1970: Double(1000 + i))))
        }
        try context.save()
        return (context, container)
    }

    func testDefaultsAndBounds() {
        let store = InMemoryPreferenceStore()
        let preferences = ViewPreferences(store: store)
        XCTAssertTrue(preferences.sortNewestFirst)
        XCTAssertEqual(preferences.gridColumns, 6)

        preferences.sortNewestFirst = false
        preferences.gridColumns = 9
        XCTAssertFalse(ViewPreferences(store: store).sortNewestFirst)
        XCTAssertEqual(ViewPreferences(store: store).gridColumns, 9)

        store.set(50, forKey: ViewPreferences.gridColumnsKey)
        XCTAssertEqual(preferences.gridColumns, 20)
        store.set(0, forKey: ViewPreferences.gridColumnsKey)
        XCTAssertEqual(preferences.gridColumns, 2)
        store.set("junk", forKey: ViewPreferences.gridColumnsKey)
        XCTAssertEqual(preferences.gridColumns, 6)
    }

    func testTheZoomIsRememberedAndRestored() {
        let preferences = ViewPreferences(store: InMemoryPreferenceStore())
        let first = PhotoLibraryViewModel(preferences: preferences)
        first.zoomIn()
        first.zoomIn()
        XCTAssertEqual(preferences.gridColumns, 4)
        first.gridColumns = 11 // the toolbar's slider
        XCTAssertEqual(preferences.gridColumns, 11)

        XCTAssertEqual(PhotoLibraryViewModel(preferences: preferences).gridColumns, 11, "the next launch")
    }

    func testTheSortOrderIsRememberedAndTheNextLaunchOpensInIt() throws {
        let preferences = ViewPreferences(store: InMemoryPreferenceStore())
        let (context, container) = try makeContext(photos: 3)
        defer { _ = container }
        let first = PhotoLibraryViewModel(preferences: preferences)
        first.setModelContext(context)
        XCTAssertEqual(first.library.photos.map(\.fileName), ["p2", "p1", "p0"], "newest first by default")

        first.toggleSortOrder()
        XCTAssertFalse(preferences.sortNewestFirst)
        XCTAssertEqual(first.library.photos.map(\.fileName), ["p0", "p1", "p2"])

        let next = PhotoLibraryViewModel(preferences: preferences)
        next.setModelContext(ModelContext(container))
        XCTAssertFalse(next.library.sortNewestFirst)
        XCTAssertEqual(next.library.photos.map(\.fileName), ["p0", "p1", "p2"], "loaded oldest first")
    }

    /// The filter isn't remembered: every launch opens on All Photos.
    func testTheFilterIsNotRemembered() throws {
        let preferences = ViewPreferences(store: InMemoryPreferenceStore())
        let (context, container) = try makeContext(photos: 2)
        defer { _ = container }
        let first = PhotoLibraryViewModel(preferences: preferences)
        first.setModelContext(context)
        first.library.applyFilter(.unrated)

        let next = PhotoLibraryViewModel(preferences: preferences)
        next.setModelContext(ModelContext(container))
        XCTAssertTrue(next.library.activeFilters.isEmpty)
    }

    /// The test host's view models keep their preferences in memory, each its own; the development library its own
    /// suite; only the user's library the app's defaults.
    func testEachLaunchKeepsItsOwnPreferences() {
        XCTAssertTrue(PhotoLibraryViewModel().preferences.store is InMemoryPreferenceStore)
        XCTAssertFalse(PhotoLibraryViewModel().preferences.store === PhotoLibraryViewModel().preferences.store)

        let tmp = FileManager.default.temporaryDirectory
        let inMemory = LibraryLocation(store: .inMemory, thumbnailCacheDirectory: nil)
        XCTAssertTrue(ViewPreferences.forLaunch(inMemory).store is InMemoryPreferenceStore)
        let user = LibraryLocation(store: .user(applicationSupport: tmp), thumbnailCacheDirectory: nil)
        XCTAssertTrue(ViewPreferences.forLaunch(user).store === UserDefaults.standard)
        let development = LibraryLocation(store: .development(tmp.appendingPathComponent("x.store")),
                                          thumbnailCacheDirectory: nil)
        let developmentStore = ViewPreferences.forLaunch(development).store
        XCTAssertFalse(developmentStore === UserDefaults.standard, "real-app checks don't change the owner's")
    }
}
