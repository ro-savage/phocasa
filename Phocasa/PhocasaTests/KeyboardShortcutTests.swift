import XCTest
import SwiftUI
import AppKit
import SwiftData
@testable import Phocasa

/// Keys pressed in the window reach `ContentView`'s key handling as the keyboard sends them. The events are
/// `NSEvent` key-downs with the characters macOS puts in them, sent to a hosted window.
@MainActor
final class KeyboardShortcutTests: XCTestCase {

    private var container: ModelContainer!
    private var viewModel: PhotoLibraryViewModel!
    private var window: NSWindow!

    override func setUp() async throws {
        container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // No files: the cells show placeholders, and moving to the bin trashes nothing.
        for i in 0..<3 {
            container.mainContext.insert(PhotoAsset(fileName: "k\(i).jpg", folderPath: "/keys",
                                                    creationDate: Date(timeIntervalSince1970: Double(1000 - i))))
        }
        try container.mainContext.save()
        viewModel = PhotoLibraryViewModel()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(viewModel: viewModel).modelContainer(container))
        window.makeKeyAndOrderFront(nil)
        spin(0.5)
        XCTAssertEqual(viewModel.library.photos.count, 3, "onAppear opened the library")
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        viewModel = nil
        container = nil
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A key-down and key-up as the keyboard sends them: `characters` is what macOS puts in the event.
    private func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )!
            window.sendEvent(event)
        }
        spin(0.2)
    }

    private func selectFirstPhoto() throws -> PhotoAsset {
        let photo = try XCTUnwrap(viewModel.library.photos.first)
        viewModel.selection.select(only: photo.id)
        spin(0.1)
        return photo
    }

    /// The harness itself: a digit key reaches the handler (it rates the selection).
    func testDigitKeyRatesTheSelection() throws {
        let photo = try selectFirstPhoto()
        press(keyCode: 20, characters: "3")
        XCTAssertEqual(photo.rating, 3)
    }

    /// The Delete key (⌫, key code 51) sends U+007F, which is neither SwiftUI's `.delete` (U+0008) nor its
    /// `.deleteForward` (U+F728).
    func testDeleteKeyMovesTheSelectionToTheBin() throws {
        let photo = try selectFirstPhoto()
        press(keyCode: 51, characters: "\u{7F}")
        XCTAssertTrue(photo.isInBin, "⌫ moves the selected photo to the bin")
        XCTAssertEqual(viewModel.library.binCount, 1)
        XCTAssertEqual(viewModel.library.photos.count, 2)
    }

    /// Forward delete (⌦, fn-⌫, key code 117) sends U+F728.
    func testForwardDeleteKeyMovesTheSelectionToTheBin() throws {
        let photo = try selectFirstPhoto()
        press(keyCode: 117, characters: "\u{F728}")
        XCTAssertTrue(photo.isInBin, "⌦ moves the selected photo to the bin")
    }

    /// The detail view open on the second photo, with the whole grid selected underneath.
    private func openSecondPhotoWithEverythingSelected() throws -> [PhotoAsset] {
        let photos = viewModel.library.photos
        viewModel.selection.selectAll()
        viewModel.openDetail(for: try XCTUnwrap(photos.first))
        viewModel.navigateDetail(direction: 1)
        spin(0.2)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[1].id)
        return photos
    }

    /// Bug test (REL-1 #1): ⌫ in the detail view binned the grid's selection. It bins the photo on screen.
    func testDeleteKeyInTheDetailViewBinsThePhotoOnScreen() throws {
        let photos = try openSecondPhotoWithEverythingSelected()
        press(keyCode: 51, characters: "\u{7F}")
        XCTAssertEqual(viewModel.library.binPhotos.map(\.id), [photos[1].id])
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[2].id, "the next photo is on screen")
    }

    /// Bug test (REL-1 #1): Return in the detail view re-opened the grid's primary photo in place of the one on screen
    /// (in edit mode it then showed that photo while the sliders edited the other).
    func testReturnInTheDetailViewKeepsThePhotoOnScreen() throws {
        let photos = try openSecondPhotoWithEverythingSelected()
        press(keyCode: 36, characters: "\r")
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[1].id)
        XCTAssertTrue(viewModel.showingDetail)
    }

    /// ⌘A in the detail view doesn't select the (hidden) grid.
    func testCommandAInTheDetailViewSelectsNothing() throws {
        let photo = try selectFirstPhoto()
        viewModel.openDetail(for: photo)
        spin(0.2)
        press(keyCode: 0, characters: "a", modifiers: .command)
        XCTAssertEqual(viewModel.selection.selectedPhotos, [photo.id])
    }

    /// Space closes the detail view whatever the grid's selection is.
    func testSpaceClosesTheDetailView() throws {
        let photo = try XCTUnwrap(viewModel.library.photos.first)
        viewModel.selection.clearSelection()
        viewModel.openDetail(for: photo)
        spin(0.2)
        press(keyCode: 49, characters: " ")
        XCTAssertFalse(viewModel.showingDetail)
    }
}
