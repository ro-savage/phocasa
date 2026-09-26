import XCTest
import SwiftUI
import AppKit
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// A file that can't be decoded says so (REL-4 #2): the grid showed a spinner for ever, the detail view plain black
/// (or, after a photo that loaded, that photo under this one's name).
@MainActor
final class UnreadableFileTests: XCTestCase {
    private var dir: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("phocasa-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FullImageLoader.shared.clear()
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        FullImageLoader.shared.clear()
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
    }

    private func junk(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("this is not a JPEG".utf8).write(to: url)
        return url
    }

    private func jpeg(_ name: String) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func host<V: View>(_ view: V, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        self.window = window
    }

    /// The placeholder, as VoiceOver finds it.
    private func placeholder(seconds: TimeInterval = 5) -> AccessibilityTree.Element? {
        AccessibilityTree.wait(seconds: seconds) { $0.text.contains(UnreadableFileView.title) }
    }

    func testAGridCellSaysItCantShowTheFile() throws {
        let file = try junk("broken.jpg")
        let photo = PhotoAsset(fileName: "broken", jpgPath: file.path, folderPath: dir.path)
        host(PhotoGridItemView(photo: photo, isSelected: false, thumbnailBucket: 256, onRate: { _ in })
            .frame(width: 160, height: 190), size: NSSize(width: 160, height: 190))

        XCTAssertNotNil(placeholder(), "not a spinner for ever")
    }

    func testAGridCellWithAPictureShowsNoPlaceholder() throws {
        let file = try jpeg("fine.jpg")
        let photo = PhotoAsset(fileName: "fine", jpgPath: file.path, folderPath: dir.path)
        host(PhotoGridItemView(photo: photo, isSelected: false, thumbnailBucket: 256, onRate: { _ in })
            .frame(width: 160, height: 190), size: NSSize(width: 160, height: 190))

        XCTAssertNotNil(AccessibilityTree.wait { $0.label == "Rating" }, "the cell is in the tree")
        XCTAssertNil(placeholder(seconds: 1.5))
    }

    /// Opened on a good photo, then moved to one that can't be decoded: the detail view says so, instead of keeping
    /// the good photo on screen under the broken one's name.
    func testTheDetailViewSaysItCantShowTheFile() throws {
        let good = try jpeg("a-good.jpg")
        let bad = try junk("b-bad.jpg")
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(PhotoAsset(fileName: "a-good", jpgPath: good.path, folderPath: dir.path,
                                  creationDate: Date(timeIntervalSince1970: 200)))
        context.insert(PhotoAsset(fileName: "b-bad", jpgPath: bad.path, folderPath: dir.path,
                                  creationDate: Date(timeIntervalSince1970: 100)))
        try context.save()
        let viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
        XCTAssertEqual(viewModel.library.photos.map(\.fileName), ["a-good", "b-bad"])
        viewModel.openDetail(for: viewModel.library.photos[0])

        struct Host: View {
            let viewModel: PhotoLibraryViewModel
            var body: some View {
                if let photo = viewModel.selectedDetailPhoto { PhotoDetailView(viewModel: viewModel, photo: photo) }
            }
        }
        host(Host(viewModel: viewModel), size: NSSize(width: 700, height: 650))
        XCTAssertNotNil(AccessibilityTree.wait { $0.text.contains("a-good") }, "the detail view is in the tree")
        XCTAssertNil(placeholder(seconds: 1), "the good photo shows")

        viewModel.navigateDetail(direction: 1)
        XCTAssertNotNil(placeholder(), "the broken one says it can't be shown")
        _ = container
    }
}
