import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Spec §D1: the detail view must display EXIF-rotated photos upright, without rotating pixels on the CPU.
/// `OrientedImage` applies the orientation at display time; these tests compare what it renders against
/// ImageIO's own oriented decode (the oracle) for all eight EXIF orientations.
final class ImageOrientationTests: XCTestCase {

    // Stored (unrotated) size of the generated test JPEG.
    private let storedWidth = 60
    private let storedHeight = 40

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaOrientationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - OrientedImage against the ImageIO oracle, all 8 orientations

    @MainActor
    func testOrientedImageMatchesImageIOForAllOrientations() throws {
        for raw in UInt32(1)...8 {
            let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: raw))
            try assertOrientedRenderMatchesOracle(orientation)
        }
    }

    @MainActor
    private func assertOrientedRenderMatchesOracle(_ orientation: CGImagePropertyOrientation,
                                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try writeQuadrantJPEG(orientation: orientation)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))

        // Oracle: ImageIO's oriented decode.
        let oracle = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(storedWidth, storedHeight),
        ] as CFDictionary), file: file, line: line)

        // Subject: the raw (unrotated) decode, oriented only at display time.
        let rawDecode = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(rawDecode.width, storedWidth, "CreateImageAtIndex should not rotate", file: file, line: line)
        let display = DisplayImage(cgImage: rawDecode, orientation: orientation)
        let size = display.orientedSize

        let renderer = ImageRenderer(content: OrientedImage(display).frame(width: size.width, height: size.height))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image for \(orientation)",
                                     file: file, line: line)

        XCTAssertEqual(rendered.width, oracle.width, "width for \(orientation)", file: file, line: line)
        XCTAssertEqual(rendered.height, oracle.height, "height for \(orientation)", file: file, line: line)
        XCTAssertEqual(CGFloat(oracle.width), size.width, "orientedSize.width for \(orientation)", file: file, line: line)
        XCTAssertEqual(CGFloat(oracle.height), size.height, "orientedSize.height for \(orientation)", file: file, line: line)
        guard rendered.width == oracle.width, rendered.height == oracle.height else { return }

        let expected = try quadrantCentreColours(oracle)
        let actual = try quadrantCentreColours(rendered)
        // Guard against a vacuous pass: the four quadrants must be distinguishable.
        XCTAssertEqual(Set(expected.map { "\($0.r / 64)\($0.g / 64)\($0.b / 64)" }).count, 4,
                       "oracle quadrants should be four distinct colours", file: file, line: line)
        for (i, (e, a)) in zip(expected, actual).enumerated() {
            XCTAssertTrue(e.isClose(to: a, tolerance: 8),
                          "\(orientation) quadrant \(i): expected \(e), rendered \(a)", file: file, line: line)
        }
    }

    // MARK: - DisplayImage

    func testOrientedSizeSwapsForQuarterTurns() throws {
        let cg = try makeQuadrantImage()
        let swapped: Set<CGImagePropertyOrientation> = [.left, .right, .leftMirrored, .rightMirrored]
        for raw in UInt32(1)...8 {
            let o = try XCTUnwrap(CGImagePropertyOrientation(rawValue: raw))
            let size = DisplayImage(cgImage: cg, orientation: o).orientedSize
            if swapped.contains(o) {
                XCTAssertEqual(size, CGSize(width: storedHeight, height: storedWidth), "\(o)")
            } else {
                XCTAssertEqual(size, CGSize(width: storedWidth, height: storedHeight), "\(o)")
            }
        }
    }

    func testDisplayImageFromNSImageIsUpAndReusesTheCGImage() throws {
        let cg = try makeQuadrantImage()
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let display = try XCTUnwrap(DisplayImage(nsImage: ns))
        XCTAssertEqual(display.orientation, .up)
        XCTAssertEqual(display.orientedSize, CGSize(width: storedWidth, height: storedHeight))
        // Edit previews are wrapped on every slider tick: wrapping must not re-render the bitmap.
        XCTAssertTrue(display.cgImage === cg, "DisplayImage(nsImage:) should reuse the NSImage's CGImage")
    }

    func testImageOrientationMapsByName() {
        let pairs: [(CGImagePropertyOrientation, Image.Orientation)] = [
            (.up, .up), (.upMirrored, .upMirrored), (.down, .down), (.downMirrored, .downMirrored),
            (.left, .left), (.leftMirrored, .leftMirrored), (.right, .right), (.rightMirrored, .rightMirrored),
        ]
        for (cg, swiftUI) in pairs {
            XCTAssertEqual(Image.Orientation(cg), swiftUI, "\(cg)")
        }
    }

    // MARK: - Helpers

    struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        func isClose(to o: RGB, tolerance: Int) -> Bool {
            abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
        }
        var description: String { "(\(r), \(g), \(b))" }
    }

    /// Stored image: red top-left, blue top-right, green bottom-left, white bottom-right.
    private func makeQuadrantImage() throws -> CGImage {
        let w = storedWidth, h = storedHeight
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // CGContext's origin is bottom-left, so the "top" half is y in h/2..<h.
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

    private func writeQuadrantJPEG(orientation: CGImagePropertyOrientation) throws -> URL {
        let url = tempDir.appendingPathComponent("quadrants-\(orientation.rawValue).jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try makeQuadrantImage(), [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Colours at the centre of each quadrant (TL, TR, BL, BR in display coordinates), read back through an
    /// sRGB RGBA8 bitmap so both images are compared in the same colour space.
    private func quadrantCentreColours(_ image: CGImage) throws -> [RGB] {
        let w = image.width, h = image.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        try pixels.withUnsafeMutableBytes { buffer in
            let ctx = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Bitmap memory is top row first.
        func colour(x: Int, y: Int) -> RGB {
            let i = y * bytesPerRow + x * 4
            return RGB(r: Int(pixels[i]), g: Int(pixels[i + 1]), b: Int(pixels[i + 2]))
        }
        let (qx, qy) = (w / 4, h / 4)
        return [colour(x: qx, y: qy), colour(x: w - 1 - qx, y: qy),
                colour(x: qx, y: h - 1 - qy), colour(x: w - 1 - qx, y: h - 1 - qy)]
    }
}
