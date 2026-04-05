import XCTest
@testable import Phocasa

final class NormalizedRectTests: XCTestCase {

    func testInitValues() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        XCTAssertEqual(rect.x, 0.1)
        XCTAssertEqual(rect.y, 0.2)
        XCTAssertEqual(rect.width, 0.6)
        XCTAssertEqual(rect.height, 0.7)
    }

    func testCGRectConversion() {
        let rect = NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let cgRect = rect.cgRect
        XCTAssertEqual(cgRect.origin.x, 0.25)
        XCTAssertEqual(cgRect.origin.y, 0.5)
        XCTAssertEqual(cgRect.size.width, 0.5)
        XCTAssertEqual(cgRect.size.height, 0.25)
    }

    func testInitFromCGRect() {
        let cgRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let rect = NormalizedRect(cgRect)
        XCTAssertEqual(rect.x, 0.1)
        XCTAssertEqual(rect.y, 0.2)
        XCTAssertEqual(rect.width, 0.3)
        XCTAssertEqual(rect.height, 0.4)
    }

    func testCGRectRoundtrip() {
        let original = NormalizedRect(x: 0.15, y: 0.25, width: 0.6, height: 0.7)
        let roundtripped = NormalizedRect(original.cgRect)
        XCTAssertEqual(original, roundtripped)
    }

    func testFullConstant() {
        let full = NormalizedRect.full
        XCTAssertEqual(full.x, 0)
        XCTAssertEqual(full.y, 0)
        XCTAssertEqual(full.width, 1)
        XCTAssertEqual(full.height, 1)
    }

    func testIsApproximatelyFullExact() {
        XCTAssertTrue(NormalizedRect.full.isApproximatelyFull)
    }

    func testIsApproximatelyFullWithTinyErrors() {
        let rect = NormalizedRect(x: 0.0001, y: -0.0001, width: 0.9999, height: 1.0001)
        XCTAssertTrue(rect.isApproximatelyFull)
    }

    func testIsApproximatelyFullFalse() {
        XCTAssertFalse(NormalizedRect(x: 0.1, y: 0, width: 0.9, height: 1).isApproximatelyFull)
        XCTAssertFalse(NormalizedRect(x: 0, y: 0, width: 0.5, height: 1).isApproximatelyFull)
        XCTAssertFalse(NormalizedRect(x: 0, y: 0.1, width: 1, height: 0.9).isApproximatelyFull)
    }

    func testEquatable() {
        let a = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let b = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let c = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCodable() throws {
        let original = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NormalizedRect.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
