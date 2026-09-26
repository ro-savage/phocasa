import XCTest
import SwiftUI
import AppKit
import SwiftData
@testable import Phocasa

/// Selecting everything doesn't make each visible cell walk the selection. Every cell's context menu is built with the
/// cell (its checked tags need the tags every selected photo has), so the grid asks once per visible cell on each
/// redraw: that walked the whole selection per cell (22 s after ⌘A at 150,000 photos, `ScaleChecks`). The answer is
/// worked out once per change of the selection. Hosts the window's real content (`MainContentView`) in a window.
@MainActor
final class GridSelectionTests: XCTestCase {
    private var container: ModelContainer!
    private var viewModel: PhotoLibraryViewModel!
    private var window: NSWindow!

    override func tearDown() async throws {
        window?.close()
        window = nil
        viewModel = nil
        container = nil
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testSelectingEverythingWorksOutTheSelectionsTagsOnce() throws {
        container = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let shared = Tag(name: "shared", category: "t")
        let some = Tag(name: "some", category: "t")
        context.insert(shared)
        context.insert(some)
        let base = Date()
        for i in 0..<400 {
            let photo = PhotoAsset(fileName: "p\(i).jpg", folderPath: "/grid", creationDate: base.addingTimeInterval(Double(-i)))
            context.insert(photo)
            photo.tags = i % 2 == 0 ? [shared, some] : [shared]
        }
        try context.save()
        viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainContentView(viewModel: viewModel))
        spin(0.6)

        let lookups = PhotoLibraryViewModel.contextMenuTagLookups
        let computations = PhotoLibraryViewModel.selectionTagComputations
        viewModel.selection.selectAll()
        spin(0.6)

        let asked = PhotoLibraryViewModel.contextMenuTagLookups - lookups
        XCTAssertGreaterThan(asked, 10, "the visible cells' menus asked for their checked tags when the grid redrew")
        XCTAssertEqual(PhotoLibraryViewModel.selectionTagComputations - computations, 1,
                       "worked out once for all \(asked) cells")
        XCTAssertEqual(viewModel.contextMenuTagIDs(for: viewModel.library.photos[0]), [shared.id])

        // A change to the selection's tags is picked up, once.
        viewModel.addTagToSelection(name: "all", category: "t")
        spin(0.4)
        let all = try XCTUnwrap(viewModel.library.allTags.first { $0.name == "all" })
        XCTAssertEqual(viewModel.contextMenuTagIDs(for: viewModel.library.photos[0]), [shared.id, all.id])
        XCTAssertEqual(PhotoLibraryViewModel.selectionTagComputations - computations, 2)
    }
}
