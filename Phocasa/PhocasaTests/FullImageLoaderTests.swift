import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

final class FullImageLoaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaFullImageLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Decode

    func testLoadReturnsRawPixelsAndOrientation() async throws {
        let path = try writeJPEG(width: 600, height: 400, orientation: .right)
        let loader = FullImageLoader(byteLimit: 64 << 20)

        let image = try await unwrap(await loader.load(path: path, subsample: 1))

        XCTAssertEqual(image.cgImage.width, 600, "no pixel rotation")
        XCTAssertEqual(image.cgImage.height, 400)
        XCTAssertEqual(image.orientation, .right)
        XCTAssertEqual(image.orientedSize, CGSize(width: 400, height: 600))
    }

    func testSubsampleHalvesDimensions() async throws {
        let path = try writeJPEG(width: 600, height: 400, orientation: .up)
        let loader = FullImageLoader(byteLimit: 64 << 20)

        let image = try await unwrap(await loader.load(path: path, subsample: 2))

        XCTAssertEqual(image.cgImage.width, 300)
        XCTAssertEqual(image.cgImage.height, 200)
        XCTAssertEqual(image.orientation, .up)
    }

    func testLoadMissingFileReturnsNil() async {
        let loader = FullImageLoader(byteLimit: 64 << 20)
        let image = await loader.load(path: tempDir.appendingPathComponent("missing.jpg").path, subsample: 1)
        XCTAssertNil(image)
    }

    // MARK: - Subsample factor

    func testSubsampleFactorChoosesLargestThatCoversViewport() {
        let image = CGSize(width: 6000, height: 4000)
        XCTAssertEqual(FullImageLoader.subsampleFactor(imagePixelSize: image, viewportPixelSize: CGSize(width: 2800, height: 1800)), 2)
        XCTAssertEqual(FullImageLoader.subsampleFactor(imagePixelSize: image, viewportPixelSize: CGSize(width: 1400, height: 900)), 4)
        XCTAssertEqual(FullImageLoader.subsampleFactor(imagePixelSize: image, viewportPixelSize: CGSize(width: 5000, height: 3000)), 1)
        // Never more than 8, however small the viewport.
        XCTAssertEqual(FullImageLoader.subsampleFactor(imagePixelSize: image, viewportPixelSize: CGSize(width: 100, height: 60)), 8)
        // A viewport bigger than the image never subsamples.
        XCTAssertEqual(FullImageLoader.subsampleFactor(imagePixelSize: image, viewportPixelSize: CGSize(width: 8000, height: 6000)), 1)
        // Exactly half still covers.
        XCTAssertEqual(FullImageLoader.subsampleFactor(imagePixelSize: image, viewportPixelSize: CGSize(width: 3000, height: 2000)), 2)
        // Degenerate sizes fall back to full resolution.
        XCTAssertEqual(FullImageLoader.subsampleFactor(imagePixelSize: .zero, viewportPixelSize: CGSize(width: 100, height: 100)), 1)
        XCTAssertEqual(FullImageLoader.subsampleFactor(imagePixelSize: image, viewportPixelSize: .zero), 1)
    }

    /// The fit decode must choose the factor from the size *after* orientation: a portrait photo stored
    /// landscape needs fewer pixels across than its stored width suggests.
    func testFitUsesOrientedSizeToChooseSubsample() async throws {
        let path = try writeJPEG(width: 600, height: 400, orientation: .right)   // displays 400×600
        let loader = FullImageLoader(byteLimit: 64 << 20)

        // Oriented: min(400/400, 300/600) = 0.5 → factor 2. Using the stored size would give min(400/600, 300/400) → 1.
        let image = try await unwrap(await loader.loadFit(path: path, viewportPixelSize: CGSize(width: 400, height: 300)))

        XCTAssertEqual(image.cgImage.width, 300)
        XCTAssertEqual(image.orientedSize, CGSize(width: 200, height: 300))
        XCTAssertNotNil(loader.cachedImage(path: path, subsample: 2), "fit decode is cached under its subsample")
        XCTAssertEqual(loader.cachedFit(path: path, viewportPixelSize: CGSize(width: 400, height: 300)), image)
    }

    // MARK: - Cache

    func testCacheIsBoundedByBytes() async throws {
        // 200×100 RGBA ≈ 80 KB each; room for two, not three.
        let paths = try (0..<3).map { _ in try writeJPEG(width: 200, height: 100, orientation: .up) }
        let probe = try await unwrap(await FullImageLoader(byteLimit: 64 << 20).load(path: paths[0], subsample: 1))
        let loader = FullImageLoader(byteLimit: probe.byteCost * 2 + probe.byteCost / 2)

        _ = await loader.load(path: paths[0], subsample: 1)
        _ = await loader.load(path: paths[1], subsample: 1)
        // Touch 0 so that 1 becomes the least recently used.
        XCTAssertNotNil(loader.cachedImage(path: paths[0], subsample: 1))
        _ = await loader.load(path: paths[2], subsample: 1)

        XCTAssertNotNil(loader.cachedImage(path: paths[0], subsample: 1), "recently used entry is kept")
        XCTAssertNil(loader.cachedImage(path: paths[1], subsample: 1), "least recently used entry is evicted")
        XCTAssertNotNil(loader.cachedImage(path: paths[2], subsample: 1), "newest entry is kept")
        XCTAssertLessThanOrEqual(loader.cachedBytes, loader.byteLimit)
    }

    func testCacheKeysIncludeSubsample() async throws {
        let path = try writeJPEG(width: 400, height: 200, orientation: .up)
        let loader = FullImageLoader(byteLimit: 64 << 20)

        _ = await loader.load(path: path, subsample: 2)

        XCTAssertNotNil(loader.cachedImage(path: path, subsample: 2))
        XCTAssertNil(loader.cachedImage(path: path, subsample: 1))
    }

    func testCachedLoadDoesNotDecodeAgain() async throws {
        let path = try writeJPEG(width: 300, height: 200, orientation: .up)
        let loader = FullImageLoader(byteLimit: 64 << 20)

        let first = await loader.load(path: path, subsample: 1)
        let second = await loader.load(path: path, subsample: 1)

        XCTAssertEqual(first, second)
        XCTAssertEqual(loader.decodeCount, 1)
    }

    func testConcurrentLoadsOfOneImageShareOneDecode() async throws {
        let path = try writeJPEG(width: 1200, height: 800, orientation: .up)
        let loader = FullImageLoader(byteLimit: 64 << 20)

        async let a = loader.load(path: path, subsample: 1)
        async let b = loader.load(path: path, subsample: 1)
        async let c = loader.load(path: path, subsample: 1)
        let results = await [a, b, c]

        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(loader.decodeCount, 1, "loads of the same key join the decode in flight")
    }

    // MARK: - Prefetch

    func testPrefetchPopulatesCache() async throws {
        let paths = try (0..<2).map { _ in try writeJPEG(width: 300, height: 200, orientation: .up) }
        let loader = FullImageLoader(byteLimit: 64 << 20)

        loader.prefetch(paths: paths, subsample: 1)

        for path in paths {
            let cached = await poll { loader.cachedImage(path: path, subsample: 1) }
            XCTAssertNotNil(cached, "prefetched \(path) should end up in the cache")
        }
    }

    func testPrefetchFitPopulatesCachedFit() async throws {
        let path = try writeJPEG(width: 600, height: 400, orientation: .up)
        let loader = FullImageLoader(byteLimit: 64 << 20)
        let viewport = CGSize(width: 300, height: 200)

        loader.prefetchFit(paths: [path], viewportPixelSize: viewport)

        let cached = await poll { loader.cachedFit(path: path, viewportPixelSize: viewport) }
        XCTAssertEqual(cached?.cgImage.width, 300, "prefetch uses the same per-image fit choice as loadFit")
    }

    /// A new prefetch set drops queued items of the previous set that haven't started yet.
    func testNewPrefetchSetCancelsQueuedPrefetches() async throws {
        let stale = try (0..<8).map { _ in try writeJPEG(width: 800, height: 600, orientation: .up) }
        let fresh = try writeJPEG(width: 300, height: 200, orientation: .up)
        let loader = FullImageLoader(byteLimit: 256 << 20)

        loader.prefetch(paths: stale, subsample: 1)
        loader.prefetch(paths: [fresh], subsample: 1)

        let cached = await poll { loader.cachedImage(path: fresh, subsample: 1) }
        XCTAssertNotNil(cached)
        let staleDecoded = stale.filter { loader.cachedImage(path: $0, subsample: 1) != nil }.count
        // At most the one item that had already started when the set was replaced.
        XCTAssertLessThanOrEqual(staleDecoded, 1)
        XCTAssertLessThanOrEqual(loader.decodeCount, 2)
    }

    func testForegroundLoadUsesPrefetchedImage() async throws {
        let path = try writeJPEG(width: 300, height: 200, orientation: .up)
        let loader = FullImageLoader(byteLimit: 64 << 20)

        loader.prefetch(paths: [path], subsample: 1)
        let prefetched = await poll { loader.cachedImage(path: path, subsample: 1) }
        let loaded = await loader.load(path: path, subsample: 1)

        XCTAssertNotNil(prefetched)
        XCTAssertEqual(loaded, prefetched)
        XCTAssertEqual(loader.decodeCount, 1)
    }

    // MARK: - RAW (needs a real file; never searched for)

    /// Runs only when `PHOCASA_TEST_RAW` (set via `TEST_RUNNER_PHOCASA_TEST_RAW`) names a camera RAW file.
    /// The file is only read.
    func testRAWUsesEmbeddedPreviewFirst() async throws {
        guard let rawPath = ProcessInfo.processInfo.environment["PHOCASA_TEST_RAW"], !rawPath.isEmpty,
              FileManager.default.isReadableFile(atPath: rawPath) else {
            throw XCTSkip("PHOCASA_TEST_RAW isn't set to a readable RAW file")
        }
        let loader = FullImageLoader(byteLimit: 512 << 20)
        let info = try await unwrap(await loader.info(path: rawPath))
        XCTAssertTrue(info.isRAW)
        let viewport = CGSize(width: 3000, height: 2000)

        let fit = try await unwrap(await loader.loadFit(path: rawPath, viewportPixelSize: viewport))

        // The embedded preview is already oriented and smaller than the sensor image.
        XCTAssertEqual(fit.orientation, .up)
        XCTAssertLessThan(max(fit.orientedSize.width, fit.orientedSize.height),
                          max(info.orientedSize.width, info.orientedSize.height))
        XCTAssertEqual(fit.orientedSize.width > fit.orientedSize.height,
                       info.orientedSize.width > info.orientedSize.height, "preview has the photo's orientation")
        XCTAssertNil(loader.cachedImage(path: rawPath, subsample: 1), "no full RAW decode for the fit image")

        // Zooming asks for full resolution: the full RAW decode, oriented at display time.
        let full = try await unwrap(await loader.load(path: rawPath, subsample: 1))
        XCTAssertEqual(full.orientedSize, info.orientedSize)
        XCTAssertEqual(full.orientation, info.orientation)
        XCTAssertEqual(full.cgImage.bitsPerComponent, 8, "the RAW decode is forced to an 8-bit bitmap off the main thread")
    }

    // MARK: - Helpers

    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    /// Polls `body` every 10 ms until it returns non-nil or `timeout` passes.
    private func poll<T>(timeout: TimeInterval = 5, _ body: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return body()
    }

    private func writeJPEG(width: Int, height: Int, orientation: CGImagePropertyOrientation) throws -> String {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).jpg")
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 3, height: height / 2))
        let image = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }
}
