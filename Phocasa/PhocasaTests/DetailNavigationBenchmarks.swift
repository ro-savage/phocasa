import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Detail-view navigation benchmark (spec §D2). Skipped unless `PHOCASA_BENCH=1`
/// (set via `TEST_RUNNER_PHOCASA_BENCH=1`). Uses generated JPEGs in a temp dir only.
///
/// Simulates arrow-key navigation through a folder of 24 MP photos with a dwell time between key presses and
/// measures, per navigation, the time until the image to show is decoded:
/// - `old`: what the detail view did before task 12, a full-resolution decode per navigation with no cache or
///   prefetch. `ImageLoader.loadFullResolution(for:)` was removed in task 34; `loadFullResolutionAsBefore(_:)` below
///   is its code, so this line still measures the same thing under the same label;
/// - `new`: `FullImageLoader.loadFit` (subsampled when the viewport allows), with the neighbours prefetched
///   the way `PhotoDetailView` does it.
///
/// Output lines start with `BENCH|detail|`.
final class DetailNavigationBenchmarks: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["PHOCASA_BENCH"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_PHOCASA_BENCH=1 to run benchmarks")
        }
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaDetailBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testDetailNavigation() async throws {
        let count = 16
        let (paths, genMs) = try measure { try makePhotos(count: count, width: 6000, height: 4000) }
        let fileMB = Double((try? FileManager.default.attributesOfItem(atPath: paths[0])[.size] as? Int) ?? 0) / 1_048_576
        report("setup|generate \(count) × 6000x4000 JPEG (harness)|ms=\(fmt(genMs))|fileMB=\(fmt(fileMB))")

        let viewports: [(String, CGSize)] = [
            ("16in full window 3456x2060", CGSize(width: 3456, height: 2060)),
            ("14in full window 3024x1780", CGSize(width: 3024, height: 1780)),
            ("window 1400x900pt@2x", CGSize(width: 2800, height: 1800)),
        ]
        for dwell in [250, 60] {
            // Old path: independent of the viewport.
            let old = try await navigateOld(paths: paths, dwellMs: dwell)
            report("old loadFullResolution|dwell=\(dwell)ms|median_ms=\(fmt(median(old.latencies)))|p90_ms=\(fmt(p90(old.latencies)))|max_ms=\(fmt(old.latencies.max() ?? 0))|MB_per_image=\(fmt(old.mbPerImage))|n=\(old.latencies.count)")
            for (name, viewport) in viewports {
                let new = try await navigateNew(paths: paths, viewport: viewport, dwellMs: dwell)
                report("new loadFit+prefetch|\(name)|dwell=\(dwell)ms|median_ms=\(fmt(median(new.latencies)))|p90_ms=\(fmt(p90(new.latencies)))|max_ms=\(fmt(new.latencies.max() ?? 0))|MB_per_image=\(fmt(new.mbPerImage))|subsample=\(new.subsample)|cacheMB=\(fmt(new.cacheMB))|decodes=\(new.decodes)|n=\(new.latencies.count)")
            }
        }
    }

    // MARK: - Scenarios

    private struct Run {
        var latencies: [Double] = []
        var mbPerImage: Double = 0
        var subsample = 1
        var cacheMB: Double = 0
        var decodes = 0
    }

    private func navigateOld(paths: [String], dwellMs: Int) async throws -> Run {
        var run = Run()
        for path in paths {
            let (image, ms) = await measureAsync { await Self.loadFullResolutionAsBefore(path) }
            let cg = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            run.latencies.append(ms)
            run.mbPerImage = Double(cg.bytesPerRow * cg.height) / 1_048_576
            try await Task.sleep(for: .milliseconds(dwellMs))
        }
        return run
    }

    private func navigateNew(paths: [String], viewport: CGSize, dwellMs: Int) async throws -> Run {
        let loader = FullImageLoader()   // fresh cache per scenario, same byte limit as the app
        var run = Run()
        for (index, path) in paths.enumerated() {
            let (image, ms) = await measureAsync { await loader.loadFit(path: path, viewportPixelSize: viewport) }
            let shown = try XCTUnwrap(image)
            run.latencies.append(ms)
            run.mbPerImage = Double(shown.byteCost) / 1_048_576
            run.subsample = Int((6000 / CGFloat(shown.cgImage.width)).rounded())
            // What PhotoDetailView prefetches after showing a photo while moving forward: +1, +2, -1.
            let neighbours = [index + 1, index + 2, index - 1].filter { paths.indices.contains($0) }.map { paths[$0] }
            loader.prefetchFit(paths: neighbours, viewportPixelSize: viewport)
            try await Task.sleep(for: .milliseconds(dwellMs))
        }
        run.cacheMB = Double(loader.cachedBytes) / 1_048_576
        run.decodes = loader.decodeCount
        return run
    }

    // MARK: - Helpers

    private static let fullResolutionQueue = DispatchQueue(
        label: "com.phocasa.bench.full-resolution", qos: .userInitiated, attributes: .concurrent
    )

    /// The removed `ImageLoader.loadFullResolution(for:)`, unchanged: a full decode on a concurrent queue.
    private static func loadFullResolutionAsBefore(_ path: String) async -> NSImage? {
        await withCheckedContinuation { continuation in
            fullResolutionQueue.async {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(
                    cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
                ))
            }
        }
    }

    private func report(_ line: String) { print("BENCH|detail|" + line) }

    private func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }

    private func measureAsync<T>(_ body: () async -> T) async -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = await body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private func p90(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    /// One textured master JPEG (gradient plus tiled noise, so it decodes like a photo rather than a flat
    /// colour), written `count` times as separate files so no decode is shared.
    private func makePhotos(count: Int, width: Int, height: Int) throws -> [String] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.1, green: 0.3, blue: 0.6, alpha: 1),
            CGColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1),
            CGColor(srgbRed: 0.2, green: 0.6, blue: 0.2, alpha: 1),
        ] as CFArray, locations: [0, 0.5, 1]))
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

        let tileSide = 509   // prime, so the tiling doesn't line up with JPEG blocks
        var noise = [UInt8](repeating: 0, count: tileSide * tileSide * 4)
        arc4random_buf(&noise, noise.count)
        for i in stride(from: 3, to: noise.count, by: 4) { noise[i] = 40 }   // ~16% alpha
        let provider = try XCTUnwrap(CGDataProvider(data: Data(noise) as CFData))
        let tile = try XCTUnwrap(CGImage(width: tileSide, height: tileSide, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: tileSide * 4, space: space,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tileSide, height: tileSide), byTiling: true)
        let image = try XCTUnwrap(ctx.makeImage())

        let master = tempDir.appendingPathComponent("master.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(master as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let data = try Data(contentsOf: master)
        return try (0..<count).map { i in
            let url = tempDir.appendingPathComponent(String(format: "photo_%03d.jpg", i))
            try data.write(to: url)
            return url.path
        }
    }
}
