import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Test images and pixel comparisons shared by the disk-cache tests and benchmarks.
enum DiskCacheTestImages {
    /// An opaque sRGB image with a diagonal gradient and, optionally, a bright square.
    /// JPEG rings at the square's hard edges, so pixel-fidelity checks use the smooth gradient alone.
    static func makeImage(width: Int, height: Int, hue: CGFloat = 0.9, square: Bool = true) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(srgbRed: hue, green: 0.2, blue: 0.1, alpha: 1),
                     CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        if square {
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 4, height: height / 4))
        }
        return context.makeImage()
    }

    /// Writes `image` as a JPEG with an EXIF orientation.
    static func writeJPEG(_ image: CGImage, to url: URL, orientation: Int = 1, quality: Double = 0.9) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// The largest per-channel difference between two images of the same size, both drawn into RGBA8 sRGB.
    static func maxChannelDifference(_ a: CGImage, _ b: CGImage) -> Int? {
        guard a.width == b.width, a.height == b.height else { return nil }
        func pixels(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            return drawn ? bytes : nil
        }
        guard let pa = pixels(a), let pb = pixels(b) else { return nil }
        var worst = 0
        for i in pa.indices {
            worst = max(worst, abs(Int(pa[i]) - Int(pb[i])))
        }
        return worst
    }
}

final class ThumbnailDiskCacheTests: XCTestCase {

    private var tempDir: URL!
    private var cacheDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        cacheDir = tempDir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    private func makeCache(byteLimit: Int = 1 << 30, trimInterval: Int = 100) -> ThumbnailDiskCache {
        ThumbnailDiskCache(directory: cacheDir, byteLimit: byteLimit, trimInterval: trimInterval)
    }

    private func key(_ path: String, bucket: Int = 384, size: Int64 = 1000, date: TimeInterval = 1_700_000_000)
        -> ThumbnailDiskCache.Key {
        ThumbnailDiskCache.Key(path: path, fileSize: size, modificationDate: Date(timeIntervalSince1970: date),
                               bucket: bucket)
    }

    private func image(_ width: Int = 96, _ height: Int = 64, hue: CGFloat = 0.9, square: Bool = true) throws -> CGImage {
        try XCTUnwrap(DiskCacheTestImages.makeImage(width: width, height: height, hue: hue, square: square))
    }

    /// Writes a source photo into the temp dir and returns its path.
    private func writeSource(
        _ name: String, width: Int = 1200, height: Int = 800, orientation: Int = 1, hue: CGFloat = 0.9,
        square: Bool = true
    ) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        let source = try image(width, height, hue: hue, square: square)
        XCTAssertTrue(DiskCacheTestImages.writeJPEG(source, to: url, orientation: orientation))
        return url.path
    }

    /// Every regular file under the cache directory, relative to it.
    private func cachedFiles() -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: cacheDir.path) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(relative).path,
                                              isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(relative)
            }
        }
        return files.sorted()
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - Key

    func testKeyReadsSizeAndModificationDate() throws {
        let path = try writeSource("photo.jpg")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).int64Value

        let current = try XCTUnwrap(ThumbnailDiskCache.Key.current(path: path, bucket: 512))

        XCTAssertEqual(current.path, path)
        XCTAssertEqual(current.fileSize, size)
        XCTAssertEqual(current.modificationDate.timeIntervalSince1970, 1_600_000_000, accuracy: 0.001)
        XCTAssertEqual(current.bucket, 512)
    }

    func testKeyIsNilForMissingFile() {
        XCTAssertNil(ThumbnailDiskCache.Key.current(path: tempDir.appendingPathComponent("gone.jpg").path,
                                                    bucket: 384))
    }

    func testKeyChangesWhenFileChanges() throws {
        let path = try writeSource("photo.jpg", hue: 0.9)
        let cache = makeCache()
        let before = try XCTUnwrap(ThumbnailDiskCache.Key.current(path: path, bucket: 384))
        cache.store(try image(), for: before)
        cache.waitForPendingWork()
        XCTAssertNotNil(cache.image(for: before))

        // Different pixels, hence different bytes.
        _ = try writeSource("photo.jpg", width: 1000, height: 700, hue: 0.2)
        let afterRewrite = try XCTUnwrap(ThumbnailDiskCache.Key.current(path: path, bucket: 384))
        XCTAssertNotEqual(afterRewrite, before)
        XCTAssertNil(cache.image(for: afterRewrite), "the rewritten file must miss")

        // Same bytes, new modification date.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)],
                                              ofItemAtPath: path)
        let afterTouch = try XCTUnwrap(ThumbnailDiskCache.Key.current(path: path, bucket: 384))
        XCTAssertEqual(afterTouch.fileSize, afterRewrite.fileSize)
        XCTAssertNotEqual(afterTouch, afterRewrite)
        XCTAssertNil(cache.image(for: afterTouch), "a new modification date must miss")
    }

    // MARK: - Store and read

    func testStoreThenReadRoundTrips() throws {
        let cache = makeCache()
        let original = try image(120, 80, square: false)
        let k = key("/photos/a.jpg")

        cache.store(original, for: k)
        cache.waitForPendingWork()
        let read = try XCTUnwrap(cache.image(for: k))

        XCTAssertEqual(read.width, 120)
        XCTAssertEqual(read.height, 80)
        let diff = try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(original, read))
        XCTAssertLessThanOrEqual(diff, 12, "JPEG at quality 0.8 stays within ±12 per channel")
        XCTAssertTrue(cache.fileURL(for: k).path.hasPrefix(cacheDir.path + "/"))
    }

    func testMissBeforeStoreAndForOtherBucket() throws {
        let cache = makeCache()
        XCTAssertNil(cache.image(for: key("/photos/a.jpg")))

        cache.store(try image(), for: key("/photos/a.jpg", bucket: 384))
        cache.waitForPendingWork()

        XCTAssertNil(cache.image(for: key("/photos/a.jpg", bucket: 512)))
        XCTAssertNil(cache.image(for: key("/photos/b.jpg", bucket: 384)))
    }

    func testANewCacheInstanceReadsWhatAnEarlierOneStored() throws {
        let k = key("/photos/a.jpg")
        let first = makeCache()
        first.store(try image(), for: k)
        first.waitForPendingWork()

        let second = makeCache()

        XCTAssertNotNil(second.image(for: k))
    }

    func testImagesWithAlphaAreNotStored() throws {
        // JPEG can't keep transparency, so a cached copy would draw differently from a fresh decode.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let translucent = try XCTUnwrap(context.makeImage())
        let cache = makeCache()

        cache.store(translucent, for: key("/photos/a.png"))
        cache.waitForPendingWork()

        XCTAssertNil(cache.image(for: key("/photos/a.png")))
        XCTAssertEqual(cachedFiles(), [])
    }

    func testOpaqueImagesWithAnAlphaChannelAreStored() throws {
        // ImageIO returns HEIC thumbnails with a premultiplied alpha channel even when every pixel is opaque.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let opaque = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(opaque.alphaInfo, .premultipliedLast)
        let cache = makeCache()

        cache.store(opaque, for: key("/photos/a.heic"))
        cache.waitForPendingWork()

        let read = try XCTUnwrap(cache.image(for: key("/photos/a.heic")))
        XCTAssertLessThanOrEqual(try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(opaque, read)), 12)
    }

    func testStoringANewVersionRemovesStaleEntriesForThatPath() throws {
        let cache = makeCache()
        let old384 = key("/photos/a.jpg", bucket: 384, size: 1000)
        let old512 = key("/photos/a.jpg", bucket: 512, size: 1000)
        let other = key("/photos/b.jpg", bucket: 384, size: 1000)
        cache.store(try image(), for: old384)
        cache.store(try image(), for: old512)
        cache.store(try image(), for: other)
        cache.waitForPendingWork()

        // The photo was rewritten (a rating write changes its size), so its thumbnail is stored under a new key.
        let new384 = key("/photos/a.jpg", bucket: 384, size: 1200)
        cache.store(try image(), for: new384)
        cache.waitForPendingWork()

        XCTAssertNotNil(cache.image(for: new384))
        XCTAssertFalse(fileExists(cache.fileURL(for: old384)), "the old version of the same bucket is stale")
        XCTAssertFalse(fileExists(cache.fileURL(for: old512)), "every bucket of the old version is stale")
        XCTAssertTrue(fileExists(cache.fileURL(for: other)), "other photos are untouched")
        XCTAssertEqual(cachedFiles().count, 2)
    }

    // MARK: - Removal

    func testRemoveAllForPathRemovesEveryBucket() throws {
        let cache = makeCache()
        let path = "/photos/a.jpg"
        for bucket in ImageLoader.thumbnailBuckets {
            cache.store(try image(), for: key(path, bucket: bucket))
        }
        let other = key("/photos/b.jpg")
        cache.store(try image(), for: other)
        cache.waitForPendingWork()
        XCTAssertEqual(cachedFiles().count, ImageLoader.thumbnailBuckets.count + 1)

        cache.removeAll(forPath: path)
        cache.waitForPendingWork()

        for bucket in ImageLoader.thumbnailBuckets {
            XCTAssertNil(cache.image(for: key(path, bucket: bucket)), "bucket \(bucket)")
        }
        XCTAssertNotNil(cache.image(for: other))
        XCTAssertEqual(cachedFiles().count, 1)
    }

    func testRemoveAllForPathTakesEffectBeforeTheDeletionRuns() throws {
        let cache = makeCache()
        let k = key("/photos/a.jpg")
        cache.store(try image(), for: k)
        cache.waitForPendingWork()

        cache.removeAll(forPath: k.path)

        // No waitForPendingWork: the files may still be on disk, but a read must already miss.
        XCTAssertNil(cache.image(for: k))
    }

    func testStoreAfterRemoveAllIsKept() throws {
        let cache = makeCache()
        let k = key("/photos/a.jpg")
        cache.store(try image(), for: k)
        cache.removeAll(forPath: k.path)
        cache.store(try image(hue: 0.3), for: k)
        cache.waitForPendingWork()

        XCTAssertNotNil(cache.image(for: k), "a store queued after the removal must survive it")
    }

    // MARK: - Trimming

    /// The allocated size of one cached test thumbnail, measured through a throwaway cache.
    private func cachedFileBytes(for image: CGImage) throws -> Int {
        let probeDir = tempDir.appendingPathComponent("probe", isDirectory: true)
        let probe = ThumbnailDiskCache(directory: probeDir)
        let k = key("/probe.jpg")
        probe.store(image, for: k)
        probe.waitForPendingWork()
        let values = try probe.fileURL(for: k).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return try XCTUnwrap(values.totalFileAllocatedSize)
    }

    func testTrimEvictsLeastRecentlyUsed() throws {
        let thumbnail = try image()
        let fileBytes = try cachedFileBytes(for: thumbnail)
        // Room for three and a half files: four are too many, three fit even after trimming below the limit.
        let cache = makeCache(byteLimit: fileBytes * 7 / 2)
        let a = key("/photos/a.jpg"), b = key("/photos/b.jpg"), c = key("/photos/c.jpg"), d = key("/photos/d.jpg")

        cache.store(thumbnail, for: a)
        cache.store(thumbnail, for: b)
        cache.store(thumbnail, for: c)
        cache.waitForPendingWork()
        XCTAssertNotNil(cache.image(for: a), "reading A makes it the most recently used")
        cache.store(thumbnail, for: d)
        cache.trimIfNeeded()
        cache.waitForPendingWork()

        XCTAssertFalse(fileExists(cache.fileURL(for: b)), "B is the least recently used")
        XCTAssertTrue(fileExists(cache.fileURL(for: a)))
        XCTAssertTrue(fileExists(cache.fileURL(for: c)))
        XCTAssertTrue(fileExists(cache.fileURL(for: d)))
    }

    func testTrimDoesNothingUnderTheLimit() throws {
        let cache = makeCache()
        for name in ["a", "b", "c"] {
            cache.store(try image(), for: key("/photos/\(name).jpg"))
        }
        cache.trimIfNeeded()
        cache.waitForPendingWork()

        XCTAssertEqual(cachedFiles().count, 3)
    }

    func testStoresTrimAutomatically() throws {
        let thumbnail = try image()
        let fileBytes = try cachedFileBytes(for: thumbnail)
        let cache = makeCache(byteLimit: fileBytes * 5, trimInterval: 10)

        for i in 0..<25 {
            cache.store(thumbnail, for: key("/photos/\(i).jpg"))
        }
        cache.waitForPendingWork()

        let count = cachedFiles().count
        XCTAssertLessThan(count, 25, "a trim runs every 10 stores")
        XCTAssertFalse(fileExists(cache.fileURL(for: key("/photos/0.jpg"))), "the oldest store is evicted")
        XCTAssertTrue(fileExists(cache.fileURL(for: key("/photos/24.jpg"))), "the newest store stays")
    }

    // MARK: - Damage from outside

    func testCorruptFileIsTreatedAsMissAndDeleted() throws {
        let cache = makeCache()
        let garbage = key("/photos/garbage.jpg")
        let truncated = key("/photos/truncated.jpg")
        cache.store(try image(), for: garbage)
        cache.store(try image(400, 300), for: truncated)
        cache.waitForPendingWork()

        try Data("not a jpeg".utf8).write(to: cache.fileURL(for: garbage))
        let full = try Data(contentsOf: cache.fileURL(for: truncated))
        try full.prefix(full.count / 2).write(to: cache.fileURL(for: truncated))

        XCTAssertNil(cache.image(for: garbage))
        XCTAssertNil(cache.image(for: truncated), "a half-written file must not show a half-grey thumbnail")
        cache.waitForPendingWork()
        XCTAssertFalse(fileExists(cache.fileURL(for: garbage)), "a corrupt file is deleted")
        XCTAssertFalse(fileExists(cache.fileURL(for: truncated)), "a truncated file is deleted")
    }

    func testSurvivesTheCacheDirectoryBeingDeletedFromOutside() throws {
        let cache = makeCache(byteLimit: 1 << 20, trimInterval: 2)
        let a = key("/photos/a.jpg"), b = key("/photos/b.jpg"), c = key("/photos/c.jpg")
        cache.store(try image(), for: a)
        cache.store(try image(), for: b)
        cache.waitForPendingWork()
        XCTAssertNotNil(cache.image(for: a))

        // The user empties ~/Library/Caches while the app runs.
        try FileManager.default.removeItem(at: cacheDir)

        XCTAssertNil(cache.image(for: a), "reads miss without crashing")
        cache.trimIfNeeded()
        cache.removeAll(forPath: b.path)
        cache.store(try image(), for: c)
        cache.store(try image(), for: a)
        cache.waitForPendingWork()
        XCTAssertNotNil(cache.image(for: c), "later stores recreate the folders")
        XCTAssertNotNil(cache.image(for: a))
        cache.trimIfNeeded()
        cache.waitForPendingWork()
        XCTAssertEqual(cachedFiles().count, 2)
    }
}
