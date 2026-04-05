import XCTest
@testable import Phocasa

final class EditParametersTests: XCTestCase {

    func testDefaultValues() {
        let params = EditParameters()
        XCTAssertEqual(params.exposure, 0)
        XCTAssertEqual(params.highlights, 0)
        XCTAssertEqual(params.shadows, 0)
        XCTAssertEqual(params.brightness, 0)
        XCTAssertEqual(params.contrast, 0)
        XCTAssertEqual(params.temperature, 0)
        XCTAssertEqual(params.tint, 0)
        XCTAssertEqual(params.saturation, 0)
        XCTAssertEqual(params.vibrance, 0)
        XCTAssertEqual(params.sharpness, 0)
        XCTAssertEqual(params.noiseReduction, 0)
        XCTAssertEqual(params.colorNoiseReduction, 0)
        XCTAssertEqual(params.clarity, 0)
        XCTAssertEqual(params.vignetteAmount, 0)
        XCTAssertEqual(params.localToneMap, 0)
        XCTAssertEqual(params.moireReduction, 0)
        XCTAssertFalse(params.enableLensCorrection)
        XCTAssertTrue(params.enableGamutMapping)
        XCTAssertNil(params.cropRect)
        XCTAssertEqual(params.rotation, 0)
        XCTAssertFalse(params.flipHorizontal)
        XCTAssertFalse(params.flipVertical)
    }

    func testIsDefault() {
        XCTAssertTrue(EditParameters().isDefault)

        var modified = EditParameters()
        modified.exposure = 1.0
        XCTAssertFalse(modified.isDefault)
    }

    func testIsDefaultWithSmallChanges() {
        var params = EditParameters()
        params.vignetteAmount = 5
        XCTAssertFalse(params.isDefault)

        params.vignetteAmount = 0
        XCTAssertTrue(params.isDefault)
    }

    func testIsDefaultWithBoolChange() {
        var params = EditParameters()
        params.enableLensCorrection = true
        XCTAssertFalse(params.isDefault)
    }

    func testIsDefaultWithCrop() {
        var params = EditParameters()
        params.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertFalse(params.isDefault)
    }

    func testReset() {
        var params = EditParameters()
        params.exposure = 2.0
        params.brightness = -50
        params.saturation = 30
        params.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        params.flipHorizontal = true

        params.reset()

        XCTAssertTrue(params.isDefault)
    }

    func testResetTransformKeepsOtherParams() {
        var params = EditParameters()
        params.exposure = 2.0
        params.brightness = -50
        params.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        params.rotation = 15.0
        params.flipHorizontal = true
        params.flipVertical = true

        params.resetTransform()

        XCTAssertNil(params.cropRect)
        XCTAssertEqual(params.rotation, 0)
        XCTAssertFalse(params.flipHorizontal)
        XCTAssertFalse(params.flipVertical)
        // Non-transform params preserved
        XCTAssertEqual(params.exposure, 2.0)
        XCTAssertEqual(params.brightness, -50)
    }

    func testJSONRoundtrip() throws {
        var params = EditParameters()
        params.exposure = 1.5
        params.highlights = -30
        params.saturation = 20
        params.enableLensCorrection = true
        params.cropRect = NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        params.rotation = 12.5
        params.flipVertical = true

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(EditParameters.self, from: data)

        XCTAssertEqual(params, decoded)
    }

    func testJSONRoundtripDefaultValues() throws {
        let params = EditParameters()
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(EditParameters.self, from: data)

        XCTAssertEqual(params, decoded)
        XCTAssertTrue(decoded.isDefault)
    }

    func testEquatable() {
        var a = EditParameters()
        var b = EditParameters()
        XCTAssertEqual(a, b)

        a.exposure = 1.0
        XCTAssertNotEqual(a, b)

        b.exposure = 1.0
        XCTAssertEqual(a, b)
    }

    func testEquatableWithTransform() {
        var a = EditParameters()
        var b = EditParameters()

        a.cropRect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        b.cropRect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(a, b)

        b.cropRect = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        XCTAssertNotEqual(a, b)
    }
}
