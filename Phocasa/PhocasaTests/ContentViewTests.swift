import XCTest
import SwiftUI
import AppKit
import SwiftData
@testable import Phocasa

/// `ContentView`'s body stays out of selection changes: the status bar and the toolbar are their own types, so a
/// click in the grid re-evaluates them, not the whole window (task 30, step 7).
@MainActor
final class ContentViewTests: XCTestCase {

    func testSelectionChangesReEvaluateTheStatusBarNotContentView() throws {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // No files: the cells show placeholders.
        for i in 0..<12 {
            container.mainContext.insert(PhotoAsset(fileName: "p\(i).jpg", folderPath: "/cv",
                                                    creationDate: Date(timeIntervalSince1970: Double(1000 - i))))
        }
        try container.mainContext.save()
        let viewModel = PhotoLibraryViewModel()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ContentView(viewModel: viewModel).modelContainer(container))
        spin(0.5)
        XCTAssertEqual(viewModel.library.photos.count, 12, "onAppear opened the library")

        let contentBefore = ContentView.bodyEvaluations
        let statusBefore = StatusBarView.bodyEvaluations
        let photos = viewModel.library.photos
        for photo in photos.prefix(3) {
            viewModel.selection.toggleSelection(for: photo, addToSelection: true)
            spin(0.1)
        }
        viewModel.selection.selectAll()
        spin(0.2)

        XCTAssertEqual(ContentView.bodyEvaluations, contentBefore, "selection changes don't re-evaluate ContentView")
        XCTAssertGreaterThan(StatusBarView.bodyEvaluations, statusBefore, "the status bar shows the selection count")
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
