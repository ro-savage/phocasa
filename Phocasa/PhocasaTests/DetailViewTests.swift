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
