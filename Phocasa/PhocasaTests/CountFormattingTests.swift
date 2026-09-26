import XCTest
@testable import Phocasa

/// Bug test (REL-4 #2): counts showed as "1 photos" and "123456 photos". They agree with their noun and are grouped
/// for the locale.
final class CountFormattingTests: XCTestCase {
    func testCountsArePluralisedAndGrouped() {
        XCTAssertEqual(0.counted("photo"), "0 photos")
        XCTAssertEqual(1.counted("photo"), "1 photo")
        XCTAssertEqual(2.counted("photo"), "2 photos")
        XCTAssertEqual(123_456.counted("photo"), "\(123_456.formatted()) photos")
        XCTAssertEqual(1.counted("file"), "1 file")
        XCTAssertEqual(3.counted("Star"), "3 Stars")
        XCTAssertEqual(1.counted("star"), "1 star")
    }
}
