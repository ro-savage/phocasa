import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftData
@testable import Phocasa

/// The grid stays alive under the detail view (spec §G4): coming back keeps its scroll position, and while hidden it
/// starts no thumbnail work. Hosts the window's real content (`MainContentView`) in a window.
@MainActor
final class GridKeepAliveTests: XCTestCase {

    private var container: ModelContainer!
    private var viewModel: PhotoLibraryViewModel!
    private var window: NSWindow!
    private var tempDir: URL?

    override func tearDown() async throws {
        window?.close()
        window = nil
        viewModel = nil
        container = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    /// A view model over `count` photos, newest first, whose files are at `paths` (nil: no file, so no thumbnail).
    private func makeViewModel(count: Int, path: (Int) -> String? = { _ in nil }) throws -> [PhotoAsset] {
        container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let base = Date()
        for i in 0..<count {
            context.insert(PhotoAsset(fileName: "p\(i).jpg", jpgPath: path(i), folderPath: "/grid",
                                      creationDate: base.addingTimeInterval(Double(-i))))
        }
        try context.save()
        viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
        return viewModel.library.photos
    }

    private func host(width: CGFloat = 900, height: CGFloat = 700) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainContentView(viewModel: viewModel))
        spin(0.5)
    }

    /// Runs the main run loop, so SwiftUI lays out and main-actor tasks run.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes (the tests run under load).
    @discardableResult
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { spin(0.02) }
        return condition()
    }

    /// The grid's scroll view: the one with the tallest document (the sidebar's list is short).
    private func gridScrollView() -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func gridScrollOffset() -> CGFloat? {
        gridScrollView()?.contentView.bounds.origin.y
    }

    // MARK: - Scroll position

    func testClosingTheDetailViewKeepsTheGridScrollPosition() throws {
        let photos = try makeViewModel(count: 300)
        host()
        // Scroll down, as a user would, by selecting a photo far down the grid.
        viewModel.selection.select(only: photos[240].id)
        spin(until: { (gridScrollOffset() ?? 0) > 500 })
        spin(0.4) // let the scroll animation finish
        let scrolled = try XCTUnwrap(gridScrollOffset())
        XCTAssertGreaterThan(scrolled, 500, "the grid scrolled down")

        viewModel.openDetail(for: photos[240])
        spin(0.4)
        viewModel.closeDetail()
        spin(0.6)

        let offset = try XCTUnwrap(gridScrollOffset())
        XCTAssertEqual(offset, scrolled, accuracy: 1, "the grid is where it was, not back at the top")
    }

    /// Navigating in the detail view to a photo the grid doesn't show scrolls the grid to it on the way back.
    func testClosingOnAnotherPhotoScrollsItIntoView() throws {
        let photos = try makeViewModel(count: 300)
        host()
        viewModel.openDetail(for: photos[0])
        spin(0.3)
        for _ in 0..<250 { viewModel.navigateDetail(direction: 1) }
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[250].id)
        viewModel.closeDetail()
        spin(until: { (gridScrollOffset() ?? 0) > 500 })

        XCTAssertGreaterThan(try XCTUnwrap(gridScrollOffset()), 500, "scrolled down to the photo")
        XCTAssertEqual(viewModel.selection.selectedPhotos, [photos[250].id])
    }

    // MARK: - Thumbnails while hidden

    func testHiddenGridStartsNoThumbnailWork() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phocasa-30-grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let image = try makeImage()
        let photos = try makeViewModel(count: 80) { i in
            let url = dir.appendingPathComponent("p\(i).jpg")
            try? Self.writeJPEG(image, to: url)
            return url.path
        }
        let before = PhotoGridItemView.thumbnailLoadsStarted
        host()
        XCTAssertTrue(spin(until: { PhotoGridItemView.thumbnailLoadsStarted > before }),
                      "the visible cells load their thumbnails")
        spin(0.5)

        viewModel.openDetail(for: photos[0])
        spin(0.3)
        let whenOpened = PhotoGridItemView.thumbnailLoadsStarted

        // What would start loads in a visible grid: new cells (another order), another bucket, a resize.
        viewModel.library.toggleSortOrder()
        viewModel.gridColumns = 3
        window.setContentSize(NSSize(width: 1300, height: 900))
        spin(0.6)
        XCTAssertEqual(PhotoGridItemView.thumbnailLoadsStarted, whenOpened, "the hidden grid started no thumbnail loads")

        viewModel.closeDetail()
        XCTAssertTrue(spin(until: { PhotoGridItemView.thumbnailLoadsStarted > whenOpened }),
                      "back in the grid, cells load again")
    }

    private func makeImage() throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
