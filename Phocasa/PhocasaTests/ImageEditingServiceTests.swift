// Characterisation tests and gated benchmarks for ImageEditingService (task 13).
//
// The pixel tests compare the service against `ReferenceRenderer`, a verbatim copy of the pre-refactor standard
// render path. The reference is the oracle: don't edit it.
//
// Benchmarks are opt-in: skipped unless PHOCASA_BENCH=1 is set for the test runner, e.g.
//   TEST_RUNNER_PHOCASA_BENCH=1 xcodebuild ... test -only-testing:PhocasaTests/ImageEditingServiceBenchmarks
// Results are printed as lines starting with "BENCH|" — grep the xcodebuild log for them.
// All images are generated into temp directories; nothing here reads real photos.

import XCTest
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import SwiftData
@testable import Phocasa

// MARK: - Test images and pixel comparison

enum EditTestImages {
    /// Writes a JPEG with a gradient, shapes and fine detail, so every filter in the chain has something to act on.
    /// `detail` adds hundreds of small shapes (edges for sharpening, noise reduction and clarity).
    static func writeJPEG(to url: URL, width: Int, height: Int, orientation: UInt32, detail: Bool = true) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "EditTestImages", code: 1)
        }
        let w = CGFloat(width), h = CGFloat(height)
        let gradient = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 0.05, green: 0.10, blue: 0.35, alpha: 1),
            CGColor(srgbRed: 0.90, green: 0.55, blue: 0.20, alpha: 1),
            CGColor(srgbRed: 0.98, green: 0.97, blue: 0.92, alpha: 1)
        ] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])

        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 0.10, y: h * 0.15, width: w * 0.30, height: h * 0.35))
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 0.85))
        ctx.fill(CGRect(x: w * 0.55, y: h * 0.50, width: w * 0.30, height: h * 0.30))
        ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1))
        ctx.fill(CGRect(x: w * 0.05, y: h * 0.80, width: w * 0.20, height: h * 0.12))

        if detail {
            // Deterministic pseudo-random small shapes and a fine checkerboard.
            var state: UInt64 = 0x9E3779B97F4A7C15
            func next() -> CGFloat {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
            }
            let count = max(200, width * height / 4000)
            for _ in 0..<count {
                ctx.setFillColor(CGColor(srgbRed: next(), green: next(), blue: next(), alpha: 0.4 + 0.6 * next()))
                let s = 2 + next() * w * 0.01
                ctx.fillEllipse(in: CGRect(x: next() * w, y: next() * h, width: s, height: s * (0.5 + next())))
            }
            let cell = max(2, width / 300)
            for yy in stride(from: 0, to: height / 4, by: cell) {
                for xx in stride(from: width / 2, to: width / 2 + width / 4, by: cell) where ((xx + yy) / cell) % 2 == 0 {
                    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.7))
                    ctx.fill(CGRect(x: xx, y: yy, width: cell, height: cell))
                }
            }
        }

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "EditTestImages", code: 2)
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "EditTestImages", code: 3) }
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Draws `image` into an RGBA8 sRGB bitmap of its own pixel size.
    static func rgba8(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    /// Max per-channel difference after drawing both into RGBA8 sRGB bitmaps; nil if the pixel sizes differ.
    static func maxChannelDifference(_ a: CGImage, _ b: CGImage) -> Int? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let pa = rgba8(a), pb = rgba8(b)
        var maxDiff = 0
        pa.withUnsafeBufferPointer { ua in
            pb.withUnsafeBufferPointer { ub in
                for i in 0..<ua.count {
                    let d = abs(Int(ua[i]) - Int(ub[i]))
                    if d > maxDiff { maxDiff = d }
                }
            }
        }
        return maxDiff
    }
}

// MARK: - Frozen reference renderer (pre-refactor code, copied verbatim; do not edit)

private final class ReferenceRenderer {
    private let ciContext: CIContext

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .highQualityDownsample: true,
                .cacheIntermediates: false
            ])
        } else {
            ciContext = CIContext(options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB()
            ])
        }
    }

    /// `processStandard` without the cache: load → orient → scale → filters → transform → createCGImage(_:from:).
    func processStandard(url: URL, parameters: EditParameters, maxSize: CGSize? = nil) -> CGImage? {
        guard let img = CIImage(contentsOf: url) else { return nil }
        var ciImage = orientedImage(img)
        if let maxSize {
            ciImage = scaleToFit(ciImage, maxSize: maxSize)
        }
        ciImage = applyStandardFilters(to: ciImage, parameters: parameters)
        ciImage = applyTransform(to: ciImage, parameters: parameters)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        return ciContext.createCGImage(ciImage, from: extent)
    }

    /// `exportStandardToJPEG` + `writeJPEG` (without the file-date capture/restore).
    func exportStandardToJPEG(sourceURL: URL, parameters: EditParameters, outputURL: URL, quality: Double = 0.95) -> Bool {
        guard let rawImage = CIImage(contentsOf: sourceURL) else { return false }
        var ciImage = orientedImage(rawImage)
        ciImage = applyStandardFilters(to: ciImage, parameters: parameters)
        ciImage = applyTransform(to: ciImage, parameters: parameters)
        let extent = ciImage.extent
        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return false }
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private func applyStandardFilters(to image: CIImage, parameters: EditParameters) -> CIImage {
        var result = image

        // Exposure — direct EV mapping, works well
        if parameters.exposure != 0 {
            result = applyFilter("CIExposureAdjust", to: result, params: [
                "inputEV": parameters.exposure
            ])
        }

        // Highlights & Shadows — tone curve for precise tonal recovery
        // Positive highlights: pull down bright areas (recover cloud detail)
        // Negative highlights: push up bright areas
        // Positive shadows: lift dark areas (reveal shadow detail)
        // Negative shadows: crush dark areas
        if parameters.highlights != 0 || parameters.shadows != 0 {
            result = applyToneCurve(to: result, highlights: parameters.highlights, shadows: parameters.shadows)
        }

        // Brightness, Contrast, Saturation
        // inputBrightness: -1 to 1 (default 0)
        // inputContrast: 0.25 to 4.0 (default 1.0)
        // inputSaturation: 0 to 3.0 (default 1.0)
        if parameters.brightness != 0 || parameters.contrast != 0 || parameters.saturation != 0 {
            result = applyFilter("CIColorControls", to: result, params: [
                "inputBrightness": parameters.brightness / 100.0 * 0.3,
                "inputContrast": 1.0 + parameters.contrast / 100.0 * 0.5,
                "inputSaturation": 1.0 + parameters.saturation / 100.0 * 0.5
            ])
        }

        // Temperature & Tint
        if parameters.temperature != 0 || parameters.tint != 0 {
            result = applyFilter("CITemperatureAndTint", to: result, params: [
                "inputNeutral": CIVector(x: 6500.0 + parameters.temperature * 25.0, y: parameters.tint),
                "inputTargetNeutral": CIVector(x: 6500.0, y: 0.0)
            ])
        }

        // Vibrance
        if parameters.vibrance != 0 {
            result = applyFilter("CIVibrance", to: result, params: [
                "inputAmount": parameters.vibrance / 100.0
            ])
        }

        // Sharpness — CIUnsharpMask with small radius for visible edge sharpening
        if parameters.sharpness > 0 {
            result = applyFilter("CIUnsharpMask", to: result, params: [
                "inputRadius": 1.5,
                "inputIntensity": parameters.sharpness / 100.0 * 2.0
            ])
        }

        // Noise Reduction
        if parameters.noiseReduction > 0 {
            result = applyFilter("CINoiseReduction", to: result, params: [
                "inputNoiseLevel": parameters.noiseReduction / 100.0 * 0.1,
                "inputSharpness": 0.5
            ])
        }

        // Clarity — local contrast (large-radius unsharp mask) or softening
        if parameters.clarity > 0 {
            result = applyFilter("CIUnsharpMask", to: result, params: [
                "inputRadius": 20.0,
                "inputIntensity": parameters.clarity / 100.0
            ])
        } else if parameters.clarity < 0 {
            let extent = result.extent
            result = applyFilter("CIGaussianBlur", to: result, params: [
                "inputRadius": -parameters.clarity / 100.0 * 5.0
            ])
            result = result.cropped(to: extent)
        }

        // Vignette
        if parameters.vignetteAmount != 0 {
            result = applyFilter("CIVignette", to: result, params: [
                "inputIntensity": parameters.vignetteAmount / 100.0 * 2.0,
                "inputRadius": 1.0
            ])
        }

        return result
    }

    private func applyTransform(to image: CIImage, parameters: EditParameters) -> CIImage {
        var result = image

        if parameters.rotation != 0 {
            let radians = parameters.rotation * .pi / 180.0
            result = result.transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
            let ext = result.extent
            if ext.origin.x < 0 || ext.origin.y < 0 {
                result = result.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
            }
        }

        if parameters.flipHorizontal {
            result = result.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -result.extent.width, y: 0))
        }
        if parameters.flipVertical {
            result = result.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -result.extent.height))
        }

        if let crop = parameters.cropRect, crop != .full {
            let ext = result.extent
            let rect = CGRect(
                x: ext.origin.x + CGFloat(crop.x) * ext.width,
                y: ext.origin.y + (1.0 - CGFloat(crop.y) - CGFloat(crop.height)) * ext.height,
                width: CGFloat(crop.width) * ext.width,
                height: CGFloat(crop.height) * ext.height
            )
            result = result.cropped(to: rect)
            result = result.transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        }

        return result
    }

    private func orientedImage(_ image: CIImage) -> CIImage {
        let o = image.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
        return image.oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
    }

    /// Tone curve for highlight recovery and shadow lifting.
    /// h: -100 to +100 (positive = recover/darken highlights, negative = brighten)
    /// s: -100 to +100 (positive = lift/brighten shadows, negative = crush)
    private func applyToneCurve(to image: CIImage, highlights h: Double, shadows s: Double) -> CIImage {
        let hNorm = h / 100.0  // -1 to 1
        let sNorm = s / 100.0  // -1 to 1

        // Shadow region (points 0 and 1)
        // Positive s lifts shadows, negative crushes them
        let p0y = max(0, sNorm * 0.08)                       // slight black point lift
        let p1y = min(1.0, max(0, 0.25 + sNorm * 0.20))      // shadow midpoint shift

        // Highlight region (points 3 and 4)
        // Positive h pulls down highlights (recover cloud detail), negative pushes them up
        let p3y = min(1.0, max(0, 0.75 - hNorm * 0.20))      // upper-mid shift
        let p4y = min(1.0, max(0.3, 1.0 - hNorm * 0.30))     // white point pull-down

        return applyFilter("CIToneCurve", to: image, params: [
            "inputPoint0": CIVector(x: 0.0,  y: CGFloat(p0y)),
            "inputPoint1": CIVector(x: 0.25, y: CGFloat(p1y)),
            "inputPoint2": CIVector(x: 0.5,  y: 0.5),            // midtones untouched
            "inputPoint3": CIVector(x: 0.75, y: CGFloat(p3y)),
            "inputPoint4": CIVector(x: 1.0,  y: CGFloat(p4y))
        ])
    }

    private func applyFilter(_ name: String, to image: CIImage, params: [String: Any]) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in params {
            filter.setValue(value, forKey: key)
        }
        return filter.outputImage ?? image
    }

    private func scaleToFit(_ image: CIImage, maxSize: CGSize) -> CIImage {
        let scale = min(maxSize.width / image.extent.width, maxSize.height / image.extent.height)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

// MARK: - Characterisation tests

final class ImageEditingServiceTests: XCTestCase {
    private var tempDir: URL!
    private var sourceURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-edit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // 1200x800 stored, EXIF orientation 6: displays as 800x1200.
        sourceURL = tempDir.appendingPathComponent("source.jpg")
        try EditTestImages.writeJPEG(to: sourceURL, width: 1200, height: 800, orientation: 6)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// The parameter sets every pixel test runs through.
    static let parameterSets: [(String, EditParameters)] = {
        func p(_ edit: (inout EditParameters) -> Void) -> EditParameters {
            var params = EditParameters()
            edit(&params)
            return params
        }
        return [
            ("default", EditParameters()),
            ("exposure +1", p { $0.exposure = 1 }),
            ("highlights 50 / shadows 50", p { $0.highlights = 50; $0.shadows = 50 }),
            ("contrast -30 + saturation 40", p { $0.contrast = -30; $0.saturation = 40 }),
            ("brightness -25", p { $0.brightness = -25 }),
            ("temperature 30 + tint -20", p { $0.temperature = 30; $0.tint = -20 }),
            ("vibrance 60", p { $0.vibrance = 60 }),
            ("sharpness 50", p { $0.sharpness = 50 }),
            ("noise reduction 40", p { $0.noiseReduction = 40 }),
            ("clarity +50", p { $0.clarity = 50 }),
            ("clarity -50", p { $0.clarity = -50 }),
            ("vignette 60", p { $0.vignetteAmount = 60 }),
            ("rotation 10", p { $0.rotation = 10 }),
            ("rotation -7 + flip vertical", p { $0.rotation = -7; $0.flipVertical = true }),
            ("flip horizontal", p { $0.flipHorizontal = true }),
            ("crop (0.1, 0.1, 0.5, 0.6)", p { $0.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.6) }),
            ("combined", p {
                $0.exposure = 0.4; $0.highlights = 30; $0.shadows = -20; $0.brightness = 10; $0.contrast = 15
                $0.temperature = -15; $0.tint = 10; $0.saturation = 10; $0.vibrance = 20; $0.sharpness = 40
                $0.noiseReduction = 20; $0.clarity = 30; $0.vignetteAmount = -25; $0.rotation = 5
                $0.flipHorizontal = true; $0.cropRect = NormalizedRect(x: 0.05, y: 0.1, width: 0.8, height: 0.7)
            })
        ]
    }()

    private func assertMatchesReference(_ image: NSImage?, _ reference: CGImage?, _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let image, let cg = EditTestImages.cgImage(image) else {
            return XCTFail("\(label): service returned no image", file: file, line: line)
        }
        guard let reference else { return XCTFail("\(label): reference returned no image", file: file, line: line) }
        XCTAssertEqual(image.size, CGSize(width: reference.width, height: reference.height),
                       "\(label): NSImage size", file: file, line: line)
        XCTAssertEqual(cg.width, reference.width, "\(label): width", file: file, line: line)
        XCTAssertEqual(cg.height, reference.height, "\(label): height", file: file, line: line)
        XCTAssertEqual(cg.colorSpace?.name, reference.colorSpace?.name, "\(label): colour-space tag", file: file, line: line)
        guard let diff = EditTestImages.maxChannelDifference(cg, reference) else { return }
        XCTAssertLessThanOrEqual(diff, 1, "\(label): max channel difference", file: file, line: line)
    }

    func testStandardRenderMatchesReference() async {
        let reference = ReferenceRenderer()
        let maxSize = CGSize(width: 600, height: 600)
        for (label, params) in Self.parameterSets {
            let image = await ImageEditingService.shared.processStandard(url: sourceURL, parameters: params, maxSize: maxSize)
            let expected = reference.processStandard(url: sourceURL, parameters: params, maxSize: maxSize)
            assertMatchesReference(image, expected, "preview \(label)")
        }
        ImageEditingService.shared.clearCache()
    }

    func testStandardFullRenderMatchesReference() async {
        let reference = ReferenceRenderer()
        let labels: Set<String> = ["default", "combined", "clarity -50", "rotation 10"]
        for (label, params) in Self.parameterSets where labels.contains(label) {
            let image = await ImageEditingService.shared.processStandard(url: sourceURL, parameters: params)
            let expected = reference.processStandard(url: sourceURL, parameters: params)
            assertMatchesReference(image, expected, "full \(label)")
        }
        ImageEditingService.shared.clearCache()
    }

    /// Exports at quality 1.0: ImageIO's JPEG encoder at 0.95 isn't deterministic (the first encode in a process
    /// differs from later ones by up to 6 levels on identical pixels), while at 1.0 identical pixels give identical
    /// files. `quality` is passed straight through to ImageIO, so this still checks the whole render + write path.
    func testStandardExportMatchesReference() async throws {
        let reference = ReferenceRenderer()
        let labels: Set<String> = ["default", "combined"]
        for (label, params) in Self.parameterSets where labels.contains(label) {
            let serviceOut = tempDir.appendingPathComponent("service-\(label).jpg")
            let referenceOut = tempDir.appendingPathComponent("reference-\(label).jpg")
            let ok = await ImageEditingService.shared.exportStandardToJPEG(
                sourceURL: sourceURL, parameters: params, outputURL: serviceOut, quality: 1.0)
            XCTAssertTrue(ok, label)
            XCTAssertTrue(reference.exportStandardToJPEG(sourceURL: sourceURL, parameters: params,
                                                         outputURL: referenceOut, quality: 1.0), label)

            let a = try XCTUnwrap(CGImageSourceCreateWithURL(serviceOut as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let b = try XCTUnwrap(CGImageSourceCreateWithURL(referenceOut as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(a.width, b.width, label)
            XCTAssertEqual(a.height, b.height, label)
            XCTAssertEqual(a.colorSpace?.name, b.colorSpace?.name, "\(label): exported colour space")
            let diff = try XCTUnwrap(EditTestImages.maxChannelDifference(a, b), label)
            XCTAssertLessThanOrEqual(diff, 1, "\(label): export max channel difference")
        }
    }
}

// MARK: - Scheduling: lanes and stale-skip

final class ImageEditingServiceSchedulingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-edit-lanes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testRawScaleFactor() {
        let box = CGSize(width: 1600, height: 1100)
        XCTAssertEqual(ImageEditingService.rawScaleFactor(nativeSize: CGSize(width: 6000, height: 4000), maxSize: box),
                       0.2667, accuracy: 0.0001)
        XCTAssertEqual(ImageEditingService.rawScaleFactor(nativeSize: CGSize(width: 1000, height: 800), maxSize: box), 1)
        // Height-limited, and portrait (the caller passes the oriented size).
        XCTAssertEqual(ImageEditingService.rawScaleFactor(nativeSize: CGSize(width: 4912, height: 3264), maxSize: box),
                       Float(1600.0 / 4912.0), accuracy: 0.0001)
        XCTAssertEqual(ImageEditingService.rawScaleFactor(nativeSize: CGSize(width: 3264, height: 4912), maxSize: box),
                       Float(1100.0 / 4912.0), accuracy: 0.0001)
        // Never above 1, and degenerate sizes don't scale.
        for native in [CGSize(width: 1600, height: 1100), CGSize(width: 10, height: 10), CGSize(width: 1601, height: 1),
                       CGSize(width: 0, height: 0), CGSize(width: 50_000, height: 30_000)] {
            let s = ImageEditingService.rawScaleFactor(nativeSize: native, maxSize: box)
            XCTAssertLessThanOrEqual(s, 1, "\(native)")
            XCTAssertGreaterThan(s, 0, "\(native)")
        }
    }

    func testCancelledRenderReturnsNilWithoutRendering() async throws {
        let url = tempDir.appendingPathComponent("source.jpg")
        try EditTestImages.writeJPEG(to: url, width: 1200, height: 800, orientation: 6)
        let service = ImageEditingService()
        await service.prepareStandard(url: url)
        let before = service.renderCount

        let task = Task { () -> Bool in
            try? await Task.sleep(for: .seconds(30))   // returns early once cancelled, like the view model's debounce
            let image = await service.processStandard(url: url, parameters: EditParameters(),
                                                      maxSize: CGSize(width: 600, height: 600), lane: .preview)
            return image == nil
        }
        task.cancel()
        let returnedNil = await task.value

        XCTAssertTrue(returnedNil, "a cancelled render returns nil")
        XCTAssertEqual(service.renderCount, before, "a cancelled render does no work")

        // Control: the same render, not cancelled, does work.
        let image = await service.processStandard(url: url, parameters: EditParameters(),
                                                  maxSize: CGSize(width: 600, height: 600), lane: .preview)
        XCTAssertNotNil(image)
        XCTAssertEqual(service.renderCount, before + 1)
    }

    func testPreviewNotBlockedByFullLane() async throws {
        let url = tempDir.appendingPathComponent("large.jpg")
        try EditTestImages.writeJPEG(to: url, width: 6000, height: 4000, orientation: 1)
        let service = ImageEditingService()
        let previewBox = CGSize(width: 1600, height: 1100)
        var params = EditParameters()
        params.exposure = 0.5
        params.clarity = 30
        // Warm both lanes (source decode, kernels) so the race below measures steady-state renders.
        await service.prepareStandard(url: url)
        _ = await service.processStandard(url: url, parameters: params, maxSize: previewBox, lane: .preview)
        _ = await service.processStandard(url: url, parameters: params, maxSize: nil, lane: .full)

        params.exposure = 0.6
        let fullParams = params
        let full = Task.detached { () -> ContinuousClock.Instant in
            _ = await service.processStandard(url: url, parameters: fullParams, maxSize: nil, lane: .full)
            return .now
        }
        try await Task.sleep(for: .milliseconds(5))
        params.exposure = 0.7
        let preview = await service.processStandard(url: url, parameters: params, maxSize: previewBox, lane: .preview)
        let previewDone = ContinuousClock.now
        let fullDone = await full.value

        XCTAssertNotNil(preview)
        XCTAssertLessThan(previewDone, fullDone, "the preview completes while the full-resolution render is in flight")
    }
}

// MARK: - Gated view-model benchmark (PHOCASA_BENCH=1)

final class EditViewModelBenchmarks: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOCASA_BENCH"] == "1", "Set PHOCASA_BENCH=1 to run benchmarks")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-edit-vm-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    @MainActor
    func testBenchViewModelTicks24MPJPEG() async throws {
        let url = tempDir.appendingPathComponent("vm-24mp.jpg")
        try EditTestImages.writeJPEG(to: url, width: 6000, height: 4000, orientation: 1)
        try await EditViewModelBench.run(label: "24MP JPEG", url: url, isRAW: false)
    }
}

/// End to end through the view model: `startEditing`, then a slider tick (`editParameters.exposure` +
/// `updateEditPreview()`), timed until `editedPreviewImage` changes, including the 30 ms debounce.
/// - idle: nothing else is rendering;
/// - during: the tick lands 5 ms after the 300 ms full-resolution pass starts;
/// - draw: main-thread time of the first `CGContext.draw` of `fullResEditImage` into a 1600x1067 bitmap.
@MainActor
enum EditViewModelBench {
    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw XCTSkip("timed out waiting for the view model") }
            try await Task.sleep(for: .microseconds(250))
        }
    }

    /// One slider tick: returns its latency and when the new preview landed.
    private static func tick(_ vm: PhotoLibraryViewModel, exposure: Double) async throws
        -> (ms: Double, landed: ContinuousClock.Instant) {
        let old = vm.editedPreviewImage
        vm.editParameters.exposure = exposure
        let start = ContinuousClock.now
        vm.updateEditPreview()
        try await waitUntil { vm.editedPreviewImage != nil && vm.editedPreviewImage !== old }
        let landed = ContinuousClock.now
        return (ms(landed - start), landed)
    }

    /// `url` must be a file in a temp directory. `stopEditing(save: false)` never writes, but nothing here should
    /// ever point at a real photo folder.
    static func run(label: String, url: URL, isRAW: Bool, rounds: Int = 8) async throws {
        let container = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        let photo = PhotoAsset(fileName: "bench", jpgPath: isRAW ? nil : url.path, rawPath: isRAW ? url.path : nil,
                               folderPath: url.deletingLastPathComponent().path, creationDate: Date(), fileSize: 1)
        context.insert(photo)

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var idle: [Double] = [], during: [Double] = [], draw: [Double] = []
        for round in 0...rounds {   // round 0 is a warm-up
            vm.startEditing(photo: photo, isRAW: isRAW)
            try await waitUntil { vm.fullResEditImage != nil }

            let a = try await tick(vm, exposure: 0.30 + Double(round) * 0.01)
            try await Task.sleep(until: a.landed + .milliseconds(305), clock: .continuous)
            let b = try await tick(vm, exposure: 0.60 + Double(round) * 0.01)

            try await waitUntil { vm.fullResEditImage != nil }
            let cg = try XCTUnwrap(vm.fullResEditImage.flatMap(EditTestImages.cgImage))
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1067, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let drawStart = ContinuousClock.now
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1600, height: 1067))
            let drawMs = ms(ContinuousClock.now - drawStart)
            vm.stopEditing(save: false)

            if round > 0 {
                idle.append(a.ms)
                during.append(b.ms)
                draw.append(drawMs)
            }
        }
        func report(_ name: String, _ samples: [Double]) {
            let s = samples.sorted()
            func f(_ x: Double) -> String { String(format: "%.1f", x) }
            print("BENCH|editvm|\(label)|\(name)|median_ms=\(f(s[s.count / 2]))|min_ms=\(f(s.first!))|max_ms=\(f(s.last!))|runs=\(s.count)")
        }
        report("tick idle", idle)
        report("tick during full pass", during)
        report("main-thread first draw of fullResEditImage", draw)
    }
}

// MARK: - Gated benchmarks (PHOCASA_BENCH=1)

final class ImageEditingServiceBenchmarks: XCTestCase {
    private let clock = ContinuousClock()
    private var tempDir: URL!
    private let previewBox = CGSize(width: 1600, height: 1100)

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOCASA_BENCH"] == "1", "Set PHOCASA_BENCH=1 to run benchmarks")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-edit-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private func report(_ label: String, _ samples: [Double]) {
        let s = samples.sorted()
        func f(_ x: Double) -> String { String(format: "%.3f", x) }
        print("BENCH|edit|\(label)|median_ms=\(f(s[s.count / 2]))|min_ms=\(f(s.first!))|max_ms=\(f(s.last!))|runs=\(s.count)")
    }

    /// A generated 6000x4000 (24 MP) landscape JPEG.
    private func make24MP() throws -> URL {
        let url = tempDir.appendingPathComponent("bench-24mp.jpg")
        try EditTestImages.writeJPEG(to: url, width: 6000, height: 4000, orientation: 1)
        return url
    }

    private func params(_ i: Int) -> EditParameters {
        var p = EditParameters()
        p.exposure = 0.3 + Double(i % 100) * 0.003   // a new value every tick, so nothing downstream is reusable
        p.highlights = 30; p.shadows = 20; p.brightness = 10; p.contrast = 15; p.saturation = 10
        p.vibrance = 20; p.sharpness = 40; p.clarity = 30; p.vignetteAmount = 25
        return p
    }

    /// Median of 30 preview renders (fit 1600x1100) of a 24 MP JPEG through the real service.
    func testBenchPreviewRender24MP() async throws {
        let url = try make24MP()
        let service = ImageEditingService.shared
        await service.prepareStandard(url: url)
        for i in 0..<3 { _ = await service.processStandard(url: url, parameters: params(i), maxSize: previewBox) }
        var samples: [Double] = []
        for i in 0..<30 {
            let start = clock.now
            let image = await service.processStandard(url: url, parameters: params(100 + i), maxSize: previewBox)
            samples.append(ms(clock.now - start))
            XCTAssertNotNil(image)
        }
        report("preview 24MP JPEG (fit 1600x1100)", samples)
        service.clearCache()
    }

    /// Process memory (phys_footprint and resident size), in MB.
    private static func memoryMB() -> (footprint: Double, resident: Double) {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return (-1, -1) }
        return (Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_resident_size) / 1_048_576)
    }

    /// Memory after 50 preview renders of a 24 MP JPEG through a fresh service (the `.cacheIntermediates` budget:
    /// +150 MB). Run it alone (`-only-testing:` this method) so other tests' allocations don't show up.
    func testBenchPreviewMemory24MP() async throws {
        let url = try make24MP()
        let service = ImageEditingService()
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        let start = Self.memoryMB()
        await service.prepareStandard(url: url)
        var samples: [Double] = []
        for i in 0..<50 {
            let t0 = clock.now
            let image = await service.processStandard(url: url, parameters: params(500 + i), maxSize: previewBox, lane: .preview)
            samples.append(ms(clock.now - t0))
            XCTAssertNotNil(image)
        }
        let after = Self.memoryMB()
        service.clearCache()
        try await Task.sleep(for: .milliseconds(500))
        let cleared = Self.memoryMB()
        print("BENCH|editmem|50 previews of a 24MP JPEG (fresh service)|start_footprint_mb=\(f(start.footprint))|after_footprint_mb=\(f(after.footprint))|cleared_footprint_mb=\(f(cleared.footprint))|start_resident_mb=\(f(start.resident))|after_resident_mb=\(f(after.resident))|cleared_resident_mb=\(f(cleared.resident))")
        report("preview 24MP JPEG, 50 renders on a fresh service", samples)
    }

    /// Spec §E2: a preview requested 10 ms after a full-resolution render starts. Time from the preview request to
    /// its completion (median of 10). Also reports the full render's own duration.
    func testBenchPreviewDuringFullRender24MP() async throws {
        let url = try make24MP()
        let service = ImageEditingService.shared
        await service.prepareStandard(url: url)
        for i in 0..<2 {
            _ = await service.processStandard(url: url, parameters: params(i), maxSize: previewBox)
            _ = await service.processStandard(url: url, parameters: params(i), maxSize: nil)
        }
        var previewSamples: [Double] = [], fullSamples: [Double] = []
        for i in 0..<10 {
            let fullParams = params(200 + i), previewParams = params(300 + i)
            let fullStart = clock.now
            let full = Task.detached { () -> Duration in
                let start = ContinuousClock.now
                _ = await service.processStandard(url: url, parameters: fullParams, maxSize: nil)
                return ContinuousClock.now - start
            }
            try await Task.sleep(until: fullStart + .milliseconds(10), clock: .continuous)
            let start = clock.now
            let preview = await service.processStandard(url: url, parameters: previewParams, maxSize: previewBox)
            previewSamples.append(ms(clock.now - start))
            fullSamples.append(ms(await full.value))
            XCTAssertNotNil(preview)
        }
        report("preview requested 10 ms into a full-res render (24MP JPEG)", previewSamples)
        report("full-res render duration, measured concurrently (24MP JPEG)", fullSamples)
        service.clearCache()
    }

    /// Spec §E3: main-thread time of the first draw of the full-resolution result into a 1600x1067 bitmap.
    @MainActor
    func testBenchMainThreadFirstDrawOfFullRender24MP() async throws {
        let url = try make24MP()
        let service = ImageEditingService.shared
        await service.prepareStandard(url: url)
        _ = await service.processStandard(url: url, parameters: params(0), maxSize: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var drawSamples: [Double] = [], renderSamples: [Double] = []
        for i in 0..<10 {
            let renderStart = clock.now
            let image = await service.processStandard(url: url, parameters: params(400 + i), maxSize: nil)
            renderSamples.append(ms(clock.now - renderStart))
            let cg = try XCTUnwrap(image.flatMap(EditTestImages.cgImage))
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1067, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let start = clock.now
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1600, height: 1067))
            drawSamples.append(ms(clock.now - start))
        }
        report("main-thread first draw of full-res result (24MP JPEG -> 1600x1067)", drawSamples)
        report("full-res render call, awaited (24MP JPEG)", renderSamples)
        service.clearCache()
    }
}
