import XCTest
import SwiftUI
import AppKit
@testable import Phocasa

/// `RatingView` on its own, as the detail view uses it (full-size stars, no double-click gesture around it),
/// driven with synthesized clicks in a borderless, non-activating panel (see `PhotoGridItemViewClickTests`).
@MainActor
final class RatingViewTests: XCTestCase {

    private final class Log {
        var ratings: [Int] = []
    }

    /// Holds the rating the way the detail view's model does, so the stars redraw after each click.
    private struct Harness: View {
        @State var rating: Int
        let log: Log

        var body: some View {
            RatingView(rating: rating) { newRating in
                log.ratings.append(newRating)
                rating = newRating
            }
            .padding(10)
        }
    }

    private var window: NSWindow!
    private var log: Log!

    private func host(rating: Int) {
        let log = Log()
        self.log = log
        let hosting = NSHostingView(rootView: Harness(rating: rating, log: log))
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: 240, y: 240), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        window = panel
        spin(0.2)
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        log = nil
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func send(_ type: NSEvent.EventType, clickCount: Int) {
        // The third of five equal stars sits at the centre.
        let size = window.contentView!.frame.size
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: size.width / 2, y: size.height / 2), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
        )!
        window.sendEvent(event)
    }

    private func click(clickCount: Int = 1) {
        send(.leftMouseDown, clickCount: clickCount)
        send(.leftMouseUp, clickCount: clickCount)
    }

    private func doubleClick() {
        click()
        spin(0.05)
        click(clickCount: 2)
    }

    private var settle: TimeInterval { NSEvent.doubleClickInterval + 0.3 }

    func testClickSetsTheRating() {
        host(rating: 0)
        click()
        spin(0.1)
        XCTAssertEqual(log.ratings, [3])
    }

    func testDoubleClickLeavesTheRatingSet() {
        host(rating: 0)
        doubleClick()
        spin(settle)
        XCTAssertEqual(log.ratings.last, 3, "a double-click on ★3 gives 3, not 3 then cleared")
    }

    func testClickOnTheCurrentStarClearsIt() {
        host(rating: 3)
        click()
        spin(0.1)
        XCTAssertEqual(log.ratings, [0])
    }
}
