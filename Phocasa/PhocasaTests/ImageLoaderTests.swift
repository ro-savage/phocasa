import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

final class ImageLoaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    /// Writes a JPEG with a diagonal gradient (so every decode path has real content).
    private func writeJPEG(
        _ name: String, width: Int, height: Int,
        orientation: Int = 1, embedThumbnail: Bool = false
    ) throws -> String {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1),
                     CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let image = try XCTUnwrap(context.makeImage())

        let url = tempDir.appendingPathComponent(name)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        )
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ]
        if embedThumbnail {
            properties[kCGImageDestinationEmbedThumbnail] = true
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url.path
    }

    private func longEdge(_ image: NSImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return max(cg.width, cg.height)
    }

    // MARK: - Buckets

    func testBucketRoundsUp() {
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: 1), 256)
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: 300), 384)
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: 384), 384)
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: 385), 512)
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: 5000), 1536)
    }

    func testBucketHandlesDegenerateInput() {
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: 0), 256)
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: -10), 256)
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: .nan), 256)
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: .infinity), 1536)
        // Floating-point noise from cellWidth × scale must not jump a whole bucket.
        XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: 384.0001), 384)
    }

    func testEveryBucketMapsToItself() {
        for bucket in ImageLoader.thumbnailBuckets {
            XCTAssertEqual(ImageLoader.thumbnailBucket(forPixels: CGFloat(bucket)), bucket)
        }
        XCTAssertEqual(ImageLoader.thumbnailBuckets, ImageLoader.thumbnailBuckets.sorted())
    }

    // MARK: - Decoding

    func testThumbnailRespectsBucketAndOrientation() async throws {
        let path = try writeJPEG("portrait.jpg", width: 1200, height: 800, orientation: 6)

        let image = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 300)

        let thumbnail = try XCTUnwrap(image)
        let cg = try XCTUnwrap(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(max(cg.width, cg.height), 384, "300 px rounds up to the 384 bucket")
        XCTAssertGreaterThan(cg.height, cg.width, "EXIF orientation 6 must be applied")
        XCTAssertEqual(thumbnail.size, NSSize(width: cg.width, height: cg.height))
    }

    func testRAWStylePathFallsBackWhenEmbeddedPreviewTooSmall() throws {
        let path = try writeJPEG("embedded.jpg", width: 2000, height: 1500, embedThumbnail: true)

        let image = try XCTUnwrap(ImageLoader.decodeThumbnail(at: path, maxPixels: 512, preferEmbedded: true))

        XCTAssertEqual(max(image.width, image.height), 512,
                       "the ~160 px embedded preview is too small, so the full image must be decoded")
    }

    func testRAWStylePathUsesEmbeddedPreviewWhenLargeEnough() throws {
        let path = try writeJPEG("embedded.jpg", width: 2000, height: 1500, embedThumbnail: true)

        let embedded = try XCTUnwrap(ImageLoader.decodeThumbnail(at: path, maxPixels: 200, preferEmbedded: true))
        let full = try XCTUnwrap(ImageLoader.decodeThumbnail(at: path, maxPixels: 200, preferEmbedded: false))

        // ImageIO embeds a thumbnail of about 160 px, which is at least 0.75 × 200: preferEmbedded returns it
        // as-is, while the standard path decodes the full image down to exactly 200 px.
        XCTAssertLessThan(max(embedded.width, embedded.height), 200)
        XCTAssertGreaterThanOrEqual(max(embedded.width, embedded.height), 150)
        XCTAssertEqual(max(full.width, full.height), 200)
    }

    func testRAWExtensionsPreferTheEmbeddedPreview() {
        XCTAssertTrue(ImageLoader.prefersEmbeddedPreview(path: "/photos/DSC0001.ARW"))
        XCTAssertTrue(ImageLoader.prefersEmbeddedPreview(path: "/photos/img.cr3"))
        XCTAssertTrue(ImageLoader.prefersEmbeddedPreview(path: "/photos/img.dng"))
        XCTAssertFalse(ImageLoader.prefersEmbeddedPreview(path: "/photos/DSC0001.JPG"))
        XCTAssertFalse(ImageLoader.prefersEmbeddedPreview(path: "/photos/img.heic"))
        XCTAssertFalse(ImageLoader.prefersEmbeddedPreview(path: "/photos/img.png"))
    }

    func testMissingFileReturnsNil() async {
        let image = await ImageLoader.shared.loadThumbnail(for: tempDir.appendingPathComponent("nope.jpg").path,
                                                           maxSize: 300)
        XCTAssertNil(image)
    }

    // MARK: - Cache

    func testCacheHitReturnsSameInstance() async throws {
        let path = try writeJPEG("cached.jpg", width: 800, height: 600)

        let first = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 300)
        let second = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 320)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "300 and 320 share the 384 bucket, so the second call is a cache hit")
        XCTAssertTrue(ImageLoader.shared.cachedThumbnail(for: path, maxSize: 300) === first)
    }

    func testLargerCachedBucketServesSmallerRequest() async throws {
        let path = try writeJPEG("larger.jpg", width: 1600, height: 1200)

        let large = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 700)
        let small = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 300)

        XCTAssertEqual(try longEdge(try XCTUnwrap(large)), 768)
        XCTAssertTrue(small === large, "a cached larger thumbnail is never smaller than requested, so reuse it")
    }

    func testInvalidateEvictsAllSizes() async throws {
        let path = try writeJPEG("invalidate.jpg", width: 1600, height: 1200)

        let small = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 300)
        let large = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 1000)
        XCTAssertNotNil(small)
        XCTAssertNotNil(large)

        ImageLoader.shared.invalidate(path: path)

        XCTAssertNil(ImageLoader.shared.cachedThumbnail(for: path, maxSize: 300))
        XCTAssertNil(ImageLoader.shared.cachedThumbnail(for: path, maxSize: 1000))
        let smallAgain = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 300)
        let largeAgain = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 1000)
        XCTAssertNotNil(smallAgain)
        XCTAssertNotNil(largeAgain)
        XCTAssertFalse(smallAgain === small)
        XCTAssertFalse(largeAgain === large)
    }

    func testInvalidateDoesNotEvictOtherPaths() async throws {
        let a = try writeJPEG("a.jpg", width: 800, height: 600)
        let b = try writeJPEG("b.jpg", width: 800, height: 600)

        _ = await ImageLoader.shared.loadThumbnail(for: a, maxSize: 300)
        let bImage = await ImageLoader.shared.loadThumbnail(for: b, maxSize: 300)
        ImageLoader.shared.invalidate(path: a)

        XCTAssertNil(ImageLoader.shared.cachedThumbnail(for: a, maxSize: 300))
        XCTAssertTrue(ImageLoader.shared.cachedThumbnail(for: b, maxSize: 300) === bImage)
    }

    func testClearCacheEvictsEverything() async throws {
        let path = try writeJPEG("clear.jpg", width: 800, height: 600)

        _ = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 300)
        ImageLoader.shared.clearCache()

        XCTAssertNil(ImageLoader.shared.cachedThumbnail(for: path, maxSize: 300))
    }

    // Full-resolution images: `ImageLoader.loadFullResolution(for:)` is gone (task 34). The detail view and editing
    // decode through `FullImageLoader`, which has its own tests.
}
