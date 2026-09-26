import XCTest
import SwiftUI
import AppKit
import SwiftData
@testable import Phocasa

/// Small things the release audit found (REL-4 #2): counts, the tag editor's Return, the star rating's accessibility
/// and contrast.
@MainActor
final class PolishTests: XCTestCase {

    // MARK: - The tag editor

    func testTheNewTagIsTrimmedAndNeedsAName() {
        XCTAssertNil(TagEditorView.newTag(name: "  ", category: "people"))
        let tag = TagEditorView.newTag(name: " Ann ", category: " People ")
        XCTAssertEqual(tag?.name, "Ann")
        XCTAssertEqual(tag?.category, "people")
    }

    /// Bug test: Return in the tag editor's name field did nothing (no `.onSubmit`); only the Add button added a tag.
    func testReturnInTheNameFieldAddsTheTag() throws {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let photo = PhotoAsset(fileName: "t", jpgPath: "/tags/t.jpg", folderPath: "/tags")
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(container.mainContext)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: TagEditorView(viewModel: viewModel, photo: photo)
            .frame(width: 300, height: 400))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let field = try XCTUnwrap(textFields(in: try XCTUnwrap(window.contentView))
            .first { $0.placeholderString == "Name" }, "the name field")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("sunset", replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(photo.tags.map(\.name), ["sunset"])
        XCTAssertEqual(field.stringValue, "", "cleared for the next tag")
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview -> [NSTextField] in
            if let field = subview as? NSTextField { return [field] }
            return textFields(in: subview)
        }
    }

    // MARK: - The star rating

    func testTheRatingReadsAsStars() {
        XCTAssertEqual(RatingView.accessibilityValue(0), "No rating")
        XCTAssertEqual(RatingView.accessibilityValue(1), "1 star")
        XCTAssertEqual(RatingView.accessibilityValue(3), "3 stars")
    }

    /// VoiceOver finds one "Rating" element, "3 stars", that increments and decrements the rating.
    func testTheRatingIsOneAdjustableElement() throws {
        final class Log { var ratings: [Int] = [] }
        struct Harness: View {
            @State var rating = 3
            let log: Log
            var body: some View {
                RatingView(rating: rating) { new in
                    log.ratings.append(new)
                    rating = new
                }
                .padding(10)
            }
        }
        let log = Log()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: Harness(log: log))
        window.orderFront(nil)

        let rating = try XCTUnwrap(AccessibilityTree.wait { $0.label == "Rating" && $0.valueDescription == "3 stars" })
        XCTAssertEqual(rating.role, kAXSliderRole)
        XCTAssertEqual(AccessibilityTree.elements().filter { $0.label == "Rating" }.count, 1, "the stars are one element")

        XCTAssertTrue(rating.perform(kAXIncrementAction))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(log.ratings, [4])
        let updated = try XCTUnwrap(AccessibilityTree.wait {
            $0.label == "Rating" && $0.valueDescription == "4 stars"
        })
        XCTAssertTrue(updated.perform(kAXDecrementAction))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(log.ratings, [4, 3])
    }

    // MARK: - Controls VoiceOver can use

    private func show<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        return window
    }

    /// Bug test: the detail view's chevrons and "Tags" were images with tap gestures: no buttons for VoiceOver or the
    /// keyboard, and live at either end of the grid.
    func testTheDetailViewsChevronsAndTagsAreButtonsDisabledAtTheEnds() throws {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        for i in 0..<2 {
            container.mainContext.insert(PhotoAsset(fileName: "d\(i)", jpgPath: "/detail/d\(i).jpg", folderPath: "/detail",
                                                    creationDate: Date(timeIntervalSince1970: Double(100 - i))))
        }
        try container.mainContext.save()
        let viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(container.mainContext)
        let first = try XCTUnwrap(viewModel.library.photos.first)
        viewModel.openDetail(for: first)
        let window = show(DetailOverlayControls(viewModel: viewModel, photo: first, onShowTags: {}),
                          size: NSSize(width: 600, height: 400))
        defer { window.close() }

        let previous = try XCTUnwrap(AccessibilityTree.wait { $0.label == "Previous Photo" })
        let next = try XCTUnwrap(AccessibilityTree.wait { $0.label == "Next Photo" })
        XCTAssertEqual(previous.role, kAXButtonRole)
        XCTAssertFalse(previous.isEnabled, "nothing before the first photo")
        XCTAssertTrue(next.isEnabled)
        XCTAssertEqual(AccessibilityTree.wait { $0.label == "Tags" }?.role, kAXButtonRole)

        XCTAssertTrue(next.perform(kAXPressAction))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(viewModel.selectedDetailPhoto?.fileName, "d1")
    }

    /// Bug test: the edit sliders had empty labels.
    func testAnEditSliderIsNamedAndReadsItsValue() throws {
        let window = show(EditSlider(label: "Exposure", value: .constant(1.5), range: -5...5, format: "%.1f")
            .frame(width: 260), size: NSSize(width: 260, height: 60))
        defer { window.close() }
        let slider = try XCTUnwrap(AccessibilityTree.wait { $0.role == kAXSliderRole && $0.label == "Exposure" })
        XCTAssertEqual(slider.valueDescription, "1.5")
    }

    func testTheTagEditorsIconButtonsAreNamed() throws {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let photo = PhotoAsset(fileName: "t", jpgPath: "/tags/t.jpg", folderPath: "/tags")
        container.mainContext.insert(photo)
        try container.mainContext.save()
        let viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(container.mainContext)
        viewModel.library.addTag(name: "ann", category: "people", to: photo)
        let window = show(TagEditorView(viewModel: viewModel, photo: photo).frame(width: 300, height: 400),
                          size: NSSize(width: 300, height: 400))
        defer { window.close() }

        XCTAssertEqual(AccessibilityTree.wait { $0.label == "Close" }?.role, kAXButtonRole)
        XCTAssertEqual(AccessibilityTree.wait { $0.label == "Remove people:ann" }?.role, kAXButtonRole)
    }

    // MARK: - Star contrast

    /// Bug test: the filled stars were the system yellow, 1.6:1 against a white background. They need 3:1 (WCAG's
    /// minimum for graphics) against the window's background in light and dark mode.
    func testFilledStarsStandOutInLightAndDarkMode() throws {
        func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
            func luminance(_ color: NSColor) -> CGFloat {
                let c = color.usingColorSpace(.sRGB) ?? color
                func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
            }
            let (l1, l2) = (luminance(a), luminance(b))
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        func resolved(_ appearance: NSAppearance.Name, _ body: () -> (NSColor, NSColor)) throws -> (NSColor, NSColor) {
            var colors: (NSColor, NSColor)?
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                let (a, b) = body()
                colors = (a.usingColorSpace(.sRGB) ?? a, b.usingColorSpace(.sRGB) ?? b)
            }
            return try XCTUnwrap(colors)
        }
        let star = try XCTUnwrap(NSColor(named: "RatingStar"))

        let (lightStar, lightBackground) = try resolved(.aqua) { (star, .windowBackgroundColor) }
        XCTAssertGreaterThanOrEqual(contrast(lightStar, lightBackground), 3)
        XCTAssertGreaterThanOrEqual(contrast(lightStar, .white), 4.5)
        let (lightYellow, white) = try resolved(.aqua) { (.systemYellow, .white) }
        XCTAssertLessThan(contrast(lightYellow, white), 3, "why the system yellow isn't used in light mode")

        let (darkStar, darkBackground) = try resolved(.darkAqua) { (star, .windowBackgroundColor) }
        XCTAssertGreaterThanOrEqual(contrast(darkStar, darkBackground), 3)
    }
}
