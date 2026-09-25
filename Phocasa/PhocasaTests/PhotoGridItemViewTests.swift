import XCTest
import SwiftUI
import SwiftData
@testable import Phocasa

// MARK: - Thumbnail size bucket (spec §C4)

final class PhotoGridThumbnailBucketTests: XCTestCase {

    func testResizingWithinABucketKeepsTheCellTaskIdentity() {
        // 6 columns on a 2× display: every width from 1000 to 1100 pt maps to one bucket, so a live resize across
        // that range never changes a cell's `.task(id:)` and never restarts its load.
        let buckets = Set(stride(from: 1000.0, through: 1100.0, by: 0.5).map {
            PhotoGridView.thumbnailBucket(gridWidth: $0, columns: 6, displayScale: 2)
        })
        XCTAssertEqual(buckets, [384])

        let ids = Set(buckets.map { PhotoGridItemView.ThumbnailTaskID(path: "/p/a.jpg", bucket: $0) })
        XCTAssertEqual(ids.count, 1)
    }

    func testCrossingABucketEdgeChangesTheBucket() {
        let small = PhotoGridView.thumbnailBucket(gridWidth: 1000, columns: 6, displayScale: 2)
        let large = PhotoGridView.thumbnailBucket(gridWidth: 1400, columns: 6, displayScale: 2)
        XCTAssertEqual(small, 384)
        XCTAssertEqual(large, 512)
        XCTAssertNotEqual(PhotoGridItemView.ThumbnailTaskID(path: "/p/a.jpg", bucket: small),
                          PhotoGridItemView.ThumbnailTaskID(path: "/p/a.jpg", bucket: large))
    }

    func testBucketFollowsDisplayScale() {
        XCTAssertEqual(PhotoGridView.thumbnailBucket(gridWidth: 1000, columns: 6, displayScale: 1), 256)
        XCTAssertEqual(PhotoGridView.thumbnailBucket(gridWidth: 1000, columns: 6, displayScale: 2), 384)
    }

    func testBucketCoversTheDrawnThumbnail() {
        for columns in 2...20 {
            for width in stride(from: 400.0, through: 3000.0, by: 50.0) {
                let bucket = PhotoGridView.thumbnailBucket(gridWidth: width, columns: columns, displayScale: 2)
                let cellWidth = (width - 32 - 8 * CGFloat(columns - 1)) / CGFloat(columns)
                let drawnPixels = (cellWidth - 12) * 2
                if drawnPixels <= 1536 {
                    XCTAssertGreaterThanOrEqual(CGFloat(bucket) + 0.5, drawnPixels,
                                                "columns \(columns), width \(width)")
                }
            }
        }
    }

    func testDegenerateLayoutsStillProduceABucket() {
        XCTAssertEqual(PhotoGridView.thumbnailBucket(gridWidth: 0, columns: 6, displayScale: 2), 256)
        XCTAssertEqual(PhotoGridView.thumbnailBucket(gridWidth: 800, columns: 0, displayScale: 2), 1536)
    }
}

// MARK: - Click handling (spec §C5)

/// Drives the real `PhotoGridItemView` with synthesized mouse events in a borderless, non-activating panel.
///
/// The panel doesn't need to be key: a borderless panel hands the events straight to SwiftUI, with the same
/// gesture results as a key window (checked for five gesture wirings, task 23). So these tests also run while
/// the screen is locked or another app is frontmost, instead of skipping.
@MainActor
final class PhotoGridItemViewClickTests: XCTestCase {

    private final class Log {
        var events: [String] = []
        var ratings: [Int] = []
        /// When each rating arrived (`systemUptime`, the clock the synthesized events use).
        var ratingTimes: [TimeInterval] = []
        func count(_ name: String) -> Int { events.filter { $0 == name }.count }
    }

    private var container: ModelContainer!
    private var window: NSWindow!
    private var log: Log!
    private var photo: PhotoAsset!
    private static let cellWidth: CGFloat = 160

    override func setUp() async throws {
        container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        // No file paths: the cell shows its placeholder and never touches the disk.
        let photo = PhotoAsset(fileName: "click.jpg", folderPath: "/nonexistent")
        context.insert(photo)
        self.photo = photo

        let log = Log()
        self.log = log
        let cell = PhotoGridItemView(
            photo: photo,
            isSelected: false,
            thumbnailBucket: 384,
            // Like the grid: the rating lands on the model, so the cell redraws with it.
            onRate: { rating in
                log.ratings.append(rating)
                log.ratingTimes.append(ProcessInfo.processInfo.systemUptime)
                photo.rating = rating
            },
            onSelect: { log.events.append("select") },
            onOpen: { log.events.append("open") }
        )
        .frame(width: Self.cellWidth)

        // Size the panel to the cell up front, so click positions don't depend on when layout settles.
        let hosting = NSHostingView(rootView: cell)
        let size = hosting.fittingSize
        XCTAssertGreaterThan(size.height, Self.cellWidth, "square thumbnail plus name and rating rows")
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        window = panel
        spin(0.2)
        XCTAssertEqual(hosting.frame.size, size)
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        photo = nil
        container = nil
        log = nil
    }

    // MARK: Helpers

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Runs the run loop until `condition` holds, for at most `timeout` seconds.
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            spin(0.01)
        }
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
        )!
        window.sendEvent(event)
    }

    private func click(_ point: NSPoint) {
        send(.leftMouseDown, at: point, clickCount: 1)
        send(.leftMouseUp, at: point, clickCount: 1)
    }

    private func doubleClick(_ point: NSPoint) {
        click(point)
        spin(0.05)
        send(.leftMouseDown, at: point, clickCount: 2)
        send(.leftMouseUp, at: point, clickCount: 2)
    }

    private var contentHeight: CGFloat { window.contentView!.frame.height }

    /// Centre of the square thumbnail (window coordinates, origin at the bottom left).
    private var thumbnailPoint: NSPoint {
        NSPoint(x: Self.cellWidth / 2, y: contentHeight - Self.cellWidth / 2)
    }

    /// The middle (third) star of the compact rating row, which sits 6 pt above the cell's bottom edge.
    private var middleStarPoint: NSPoint {
        NSPoint(x: Self.cellWidth / 2, y: 11)
    }

    /// Longer than any wait for double-click detection.
    private var settle: TimeInterval { NSEvent.doubleClickInterval + 0.3 }

    // MARK: Tests

    func testSingleClickSelectsWithoutWaitingForDoubleClickDetection() {
        click(thumbnailPoint)
        spin(0.1)
        XCTAssertEqual(log.events, ["select"], "selection must not wait out the double-click interval")

        spin(settle)
        XCTAssertEqual(log.events, ["select"])
        XCTAssertEqual(log.ratings, [])
    }

    func testDoubleClickSelectsThenOpens() {
        doubleClick(thumbnailPoint)
        spin(until: { log.count("open") > 0 })
        spin(0.1)

        XCTAssertEqual(log.count("open"), 1)
        XCTAssertEqual(log.events.first, "select", "the first click selects straight away, as in Finder")
        XCTAssertEqual(log.ratings, [])
    }

    func testClickOnAStarRatesWithoutSelecting() {
        click(middleStarPoint)
        spin(until: { !log.ratings.isEmpty })
        spin(0.1)

        XCTAssertEqual(log.ratings, [3])
        XCTAssertEqual(log.events, [], "rating from the grid doesn't change the selection")
    }

    // MARK: Star clicks are instant (user decision 3, task 23)

    func testClickOnAStarRatesWithoutWaitingForDoubleClickDetection() {
        let clicked = ProcessInfo.processInfo.systemUptime
        click(middleStarPoint)
        spin(until: { !log.ratings.isEmpty }, timeout: 1)

        let latency = (log.ratingTimes.first ?? .infinity) - clicked
        XCTAssertLessThan(latency, 0.05, "the rating must not wait out the double-click interval")
        XCTAssertEqual(log.ratings, [3])
        XCTAssertEqual(photo.rating, 3)
    }

    func testDoubleClickOnAStarLeavesThatRatingAndDoesNotOpen() {
        doubleClick(middleStarPoint)
        spin(settle)

        XCTAssertEqual(photo.rating, 3, "a double-click on ★3 gives 3, not 3 then cleared")
        XCTAssertEqual(log.ratings.last, 3)
        XCTAssertEqual(log.events, [], "rating isn't opening: no open, and no selection change")
    }

    func testDoubleClickOnTheCurrentStarKeepsIt() {
        photo.rating = 3
        spin(0.1)

        doubleClick(middleStarPoint)
        spin(settle)

        XCTAssertEqual(photo.rating, 3)
        XCTAssertEqual(log.events, [])
    }

    func testSingleClickOnTheCurrentStarClearsIt() {
        photo.rating = 3
        spin(0.1)

        click(middleStarPoint)
        spin(settle)

        XCTAssertEqual(log.ratings, [0])
        XCTAssertEqual(photo.rating, 0)
        XCTAssertEqual(log.events, [])
    }

    func testClickOnTheStarJustSetClearsItOnceTheDoubleClickIntervalHasPassed() {
        click(middleStarPoint)
        spin(until: { photo.rating == 3 })
        spin(settle)

        click(middleStarPoint)
        spin(settle)

        XCTAssertEqual(log.ratings, [3, 0], "a deliberate second click, not part of a double-click, clears the rating")
        XCTAssertEqual(photo.rating, 0)
    }
}
