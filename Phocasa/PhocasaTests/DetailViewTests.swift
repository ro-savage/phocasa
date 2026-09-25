import XCTest
import SwiftUI
import AppKit
@testable import Phocasa

/// Detail-view logic that can be checked without UI automation.
final class DetailViewTests: XCTestCase {

    // MARK: - Scroll-wheel monitor (spec §D5)

    /// Window 1000×700 (AppKit, bottom-left origin); image viewport 800×600 at the top-left, below a
    /// 100 pt band (title bar and toolbar); an edit sidebar to its right.
    private let windowHeight: CGFloat = 700
    private let viewport = CGRect(x: 0, y: 100, width: 800, height: 600)

    func testScrollInsideViewportIsHandled() {
        // AppKit y 300 → top-left y 400, inside 100..<700.
        XCTAssertTrue(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 400, y: 300), windowHeight: windowHeight, viewportFrame: viewport))
    }

    func testScrollOverEditSidebarIsNotHandled() {
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 900, y: 300), windowHeight: windowHeight, viewportFrame: viewport))
    }

    func testScrollConvertsFromBottomLeftOrigin() {
        // Near the top of the window in AppKit terms (y 650) is the toolbar band in top-left terms (y 50).
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 400, y: 650), windowHeight: windowHeight, viewportFrame: viewport))
        // Near the bottom in AppKit terms (y 50) is inside the viewport (top-left y 650).
        XCTAssertTrue(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 400, y: 50), windowHeight: windowHeight, viewportFrame: viewport))
    }

    func testScrollWithoutViewportIsNotHandled() {
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 10, y: 10), windowHeight: windowHeight, viewportFrame: .zero))
    }

    func testScrollInAnotherWindowIsNotHandled() {
        let host = NSObject(), popover = NSObject()
        let inside = CGPoint(x: 400, y: 300)
        XCTAssertTrue(ZoomPanState.shouldHandleScroll(
            eventWindow: host, hostWindow: host, locationInWindow: inside,
            windowHeight: windowHeight, viewportFrame: viewport))
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            eventWindow: popover, hostWindow: host, locationInWindow: inside,
            windowHeight: windowHeight, viewportFrame: viewport), "e.g. the tag popover's own window")
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            eventWindow: nil, hostWindow: host, locationInWindow: inside,
            windowHeight: windowHeight, viewportFrame: viewport))
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            eventWindow: nil, hostWindow: nil, locationInWindow: inside,
            windowHeight: windowHeight, viewportFrame: viewport), "no host window captured: never consume")
    }

    // MARK: - Portrait photos in the detail image view (spec §D1)

    /// A 60×40 bitmap tagged orientation 6 (`.right`) displays as 40×60. In a 120×120 viewport it must be fitted
    /// by its oriented size (80×120, letterboxed left and right) and drawn upright.
    @MainActor
    func testZoomableImageViewFitsAndDrawsPortraitPhotoUpright() throws {
        let stored = try makeQuadrantBitmap(width: 60, height: 40)
        let display = DisplayImage(cgImage: stored, orientation: .right)
        let renderer = ImageRenderer(content: ZoomableImageView(image: display, zoom: ZoomPanState())
            .frame(width: 120, height: 120))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.cgImage)
        let pixels = try readRGBA(rendered)

        // Letterbox: nothing drawn left of x = 20 or right of x = 100.
        XCTAssertEqual(pixels(5, 60).a, 0, "left of the fitted image")
        XCTAssertEqual(pixels(114, 60).a, 0, "right of the fitted image")
        // EXIF 6: stored row 0 is the displayed right edge, stored column 0 the displayed top edge. So the
        // stored quadrants red TL, blue TR, green BL, white BR display as green TL, red TR, white BL, blue BR.
        XCTAssertTrue(pixels(40, 30).isClose(to: RGBA(r: 0, g: 255, b: 0, a: 255)), "top-left: \(pixels(40, 30))")
        XCTAssertTrue(pixels(80, 30).isClose(to: RGBA(r: 255, g: 0, b: 0, a: 255)), "top-right: \(pixels(80, 30))")
        XCTAssertTrue(pixels(40, 90).isClose(to: RGBA(r: 255, g: 255, b: 255, a: 255)), "bottom-left: \(pixels(40, 90))")
        XCTAssertTrue(pixels(80, 90).isClose(to: RGBA(r: 0, g: 0, b: 255, a: 255)), "bottom-right: \(pixels(80, 90))")
    }

    /// The crop overlay's `imageDisplayRect` comes from the oriented size.
    func testCropDisplayRectUsesOrientedSize() throws {
        let display = DisplayImage(cgImage: try makeQuadrantBitmap(width: 60, height: 40), orientation: .left)
        let container = CGSize(width: 120, height: 120)
        let fit = ZoomableImageView.fittedSize(imageSize: display.orientedSize, in: container)
        XCTAssertEqual(fit, CGSize(width: 80, height: 120))
        XCTAssertEqual(ZoomableImageView.displayRect(fitSize: fit, in: container), CGRect(x: 20, y: 0, width: 80, height: 120))
    }

    // MARK: - Saved edit renders (spec §D4)

    @MainActor
    func testSavedJPGEditSkipsRAWRender() async {
        let jpgImage = NSImage(size: NSSize(width: 4, height: 4))
        var rawRendered = false
        let shown = await PhotoDetailView.renderSavedEdit(
            jpg: { jpgImage },
            raw: { rawRendered = true; return NSImage(size: NSSize(width: 8, height: 8)) })
        XCTAssertTrue(shown === jpgImage)
        XCTAssertFalse(rawRendered, "the RAW render would be discarded, so it must not run")
    }

    @MainActor
    func testSavedRAWEditRendersWithoutJPGEdit() async {
        let rawImage = NSImage(size: NSSize(width: 8, height: 8))
        let shown = await PhotoDetailView.renderSavedEdit(jpg: nil, raw: { rawImage })
        XCTAssertTrue(shown === rawImage)
    }

    @MainActor
    func testSavedRAWEditRendersWhenJPGRenderFails() async {
        let rawImage = NSImage(size: NSSize(width: 8, height: 8))
        let shown = await PhotoDetailView.renderSavedEdit(jpg: { nil }, raw: { rawImage })
        XCTAssertTrue(shown === rawImage)
    }

    @MainActor
    func testNoSavedEditsRenderNothing() async {
        let shown = await PhotoDetailView.renderSavedEdit(jpg: nil, raw: nil)
        XCTAssertNil(shown)
    }

    /// The monitor compares `NSEvent.locationInWindow`, flipped with the window's height, against a SwiftUI
    /// `.global` frame. Check that against ground truth in a real hosting window, with and without a full-size
    /// content view: an AppKit probe view placed exactly where the viewport is reports its own window-coordinate
    /// rect. (Flipping with the *content view's* height instead is off by the title bar in the non-full-size case.)
    @MainActor
    func testGlobalFrameMatchesFlippedWindowCoordinates() throws {
        for fullSize in [false, true] {
            let probe = FrameProbe()
            let root = VStack(spacing: 0) {
                Color.clear.frame(height: 40)
                HStack(spacing: 0) {
                    Color.clear.frame(width: 30)
                    GeometryReader { geo in
                        ProbeView(probe: probe)
                            .onAppear { probe.frame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, new in probe.frame = new }
                    }
                    .frame(width: 200, height: 150)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 300, height: 260)

            var style: NSWindow.StyleMask = [.titled]
            if fullSize { style.insert(.fullSizeContentView) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                                  styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: root)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(2)
            while (probe.frame == .zero || probe.view?.window == nil) && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                hosting.layoutSubtreeIfNeeded()
            }
            // Let any follow-up layout pass (safe-area insets) settle.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            let frame = probe.frame
            let probeView = try XCTUnwrap(probe.view, "fullSize=\(fullSize)")
            XCTAssertEqual(frame.size, CGSize(width: 200, height: 150), "fullSize=\(fullSize)")

            // Ground truth: where the viewport really is, in window coordinates (bottom-left origin).
            let truth = probeView.convert(probeView.bounds, to: nil)
            XCTAssertEqual(truth.size, CGSize(width: 200, height: 150), "fullSize=\(fullSize)")
            let windowHeight = window.frame.height
            func handles(_ p: CGPoint) -> Bool {
                ZoomPanState.shouldHandleScroll(locationInWindow: p, windowHeight: windowHeight, viewportFrame: frame)
            }
            let context = "fullSize=\(fullSize) global=\(frame) truth(window)=\(truth) windowHeight=\(windowHeight)"
            XCTAssertTrue(handles(CGPoint(x: truth.midX, y: truth.midY)), context)
            XCTAssertTrue(handles(CGPoint(x: truth.minX + 3, y: truth.maxY - 3)), "top-left corner: " + context)
            XCTAssertTrue(handles(CGPoint(x: truth.maxX - 3, y: truth.minY + 3)), "bottom-right corner: " + context)
            XCTAssertFalse(handles(CGPoint(x: truth.maxX + 3, y: truth.midY)), "right of it: " + context)
            XCTAssertFalse(handles(CGPoint(x: truth.minX - 3, y: truth.midY)), "left of it: " + context)
            XCTAssertFalse(handles(CGPoint(x: truth.midX, y: truth.maxY + 3)), "above it: " + context)
            XCTAssertFalse(handles(CGPoint(x: truth.midX, y: truth.minY - 3)), "below it: " + context)
            window.close()
        }
    }
}

// MARK: - Bitmap helpers

private struct RGBA: CustomStringConvertible {
    let r: Int, g: Int, b: Int, a: Int
    func isClose(to o: RGBA, tolerance: Int = 8) -> Bool {
        abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance && abs(a - o.a) <= tolerance
    }
    var description: String { "(\(r), \(g), \(b), \(a))" }
}

/// Red top-left, blue top-right, green bottom-left, white bottom-right (as stored).
private func makeQuadrantBitmap(width w: Int, height h: Int) throws -> CGImage {
    let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // CGContext's origin is bottom-left.
    let quadrants: [(CGRect, CGColor)] = [
        (CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
        (CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
        (CGRect(x: 0, y: 0, width: w / 2, height: h / 2), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
        (CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
    ]
    for (rect, colour) in quadrants {
        ctx.setFillColor(colour)
        ctx.fill(rect)
    }
    return try XCTUnwrap(ctx.makeImage())
}

/// Reads `image` through an sRGB RGBA8 bitmap; the returned function takes top-left-origin coordinates.
private func readRGBA(_ image: CGImage) throws -> (Int, Int) -> RGBA {
    let w = image.width, h = image.height, bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
    try pixels.withUnsafeMutableBytes { buffer in
        let ctx = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let snapshot = pixels
    return { x, y in
        let i = y * bytesPerRow + x * 4
        return RGBA(r: Int(snapshot[i]), g: Int(snapshot[i + 1]), b: Int(snapshot[i + 2]), a: Int(snapshot[i + 3]))
    }
}

private final class FrameProbe {
    var frame: CGRect = .zero
    weak var view: NSView?
}

/// Test-only AppKit view used as ground truth for where SwiftUI placed the viewport.
private struct ProbeView: NSViewRepresentable {
    let probe: FrameProbe
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
