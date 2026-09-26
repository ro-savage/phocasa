// Gated benchmark (PHOCASA_BENCH=1, and PHOCASA_TEST_RAW naming a *copy* of a camera RAW; PHOCASA_TEST_RAW_2 and the
// JPG beside each are used too): how far an edit rendered at fit is from the same edit rendered natively and drawn at
// the same size, for each pixel-radius filter at several strengths (post-wave-3 task C). Uses only
// `ImageEditingService`'s public renders, so the same file runs on any checkout.
//
// For each source and setting it prints `BENCH|fitlook|<source>|<setting>|pass_mad=…|preview_mad=…`: the mean absolute
// channel difference (0–255, RGB) of the fitted pass (the viewport beside the edit sidebar) and of the slider preview
// (1600×1100) against the native render drawn at their sizes with high-quality interpolation.

import XCTest
import AppKit
@testable import Phocasa

@MainActor
final class FitLookBenchmarks: XCTestCase {
    static let viewport = CGSize(width: 2894, height: 2130)

    nonisolated(unsafe) static let settings: [(String, (inout EditParameters) -> Void)] = [
        ("exposure only", { _ in }),
        ("sharpness 25", { $0.sharpness = 25 }),
        ("sharpness 50", { $0.sharpness = 50 }),
        ("sharpness 100", { $0.sharpness = 100 }),
        ("clarity 30", { $0.clarity = 30 }),
        ("clarity 60", { $0.clarity = 60 }),
        ("clarity 100", { $0.clarity = 100 }),
        ("clarity -50 (blur)", { $0.clarity = -50 }),
        ("clarity -100 (blur)", { $0.clarity = -100 }),
        ("noise reduction 30", { $0.noiseReduction = 30 }),
        ("noise reduction 60", { $0.noiseReduction = 60 }),
        ("noise reduction 100", { $0.noiseReduction = 100 }),
        ("sharpness 40 + clarity 30", { $0.sharpness = 40; $0.clarity = 30 }),
    ]

    /// RGBA8 sRGB pixels of `image` drawn at `size`.
    private func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    /// Mean absolute RGB difference between `small` and `native` drawn at `small`'s size.
    private func meanAbsoluteDifference(_ small: CGImage, _ native: CGImage) -> Double {
        let w = small.width, h = small.height
        let a = pixels(small, width: w, height: h), b = pixels(native, width: w, height: h)
        var total = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
        }
        return Double(total) / Double(w * h * 3)
    }

    private func sources() throws -> [(label: String, url: URL, isRAW: Bool)] {
        let env = ProcessInfo.processInfo.environment
        guard env["PHOCASA_BENCH"] == "1" else { throw XCTSkip("set PHOCASA_BENCH=1") }
        let raws = [env["PHOCASA_TEST_RAW"], env["PHOCASA_TEST_RAW_2"]].compactMap { $0 }.filter { !$0.isEmpty }
        guard !raws.isEmpty else { throw XCTSkip("set PHOCASA_TEST_RAW") }
        var out: [(String, URL, Bool)] = []
        for path in raws {
            let raw = URL(fileURLWithPath: path)
            out.append((raw.lastPathComponent, raw, true))
            let jpg = raw.deletingPathExtension().appendingPathExtension("JPG")
            if FileManager.default.fileExists(atPath: jpg.path) { out.append((jpg.lastPathComponent, jpg, false)) }
        }
        return out
    }

    func testFitLook() async throws {
        let service = ImageEditingService()
        for (label, url, isRAW) in try sources() {
            let native = try XCTUnwrap(EditRenderSize.nativeSize(ofImageAt: url))
            for (name, apply) in Self.settings {
                var params = EditParameters()
                params.exposure = 0.3
                apply(&params)
                func render(_ maxSize: CGSize?, _ lane: ImageEditingService.Lane) async -> CGImage? {
                    let image = isRAW
                        ? await service.processRAW(url: url, parameters: params, maxSize: maxSize, lane: lane)
                        : await service.processStandard(url: url, parameters: params, maxSize: maxSize, lane: lane)
                    return image.flatMap(EditTestImages.cgImage)
                }
                let fit = EditRenderSize.fitMaxSize(native: native, parameters: params, viewport: Self.viewport)
                let nativeImage = await render(nil, .full)
                let passImage = await render(fit, .full)
                let previewImage = await render(EditSession.previewSize, .preview)
                let nativeRender = try XCTUnwrap(nativeImage), pass = try XCTUnwrap(passImage)
                let preview = try XCTUnwrap(previewImage)
                print(String(format: "BENCH|fitlook|%@|%@|pass_mad=%.3f|preview_mad=%.3f|pass=%dx%d|preview=%dx%d",
                             label, name, meanAbsoluteDifference(pass, nativeRender),
                             meanAbsoluteDifference(preview, nativeRender), pass.width, pass.height,
                             preview.width, preview.height))
            }
        }
    }
}
