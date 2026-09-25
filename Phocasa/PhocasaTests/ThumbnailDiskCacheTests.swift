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

    // MARK: - ImageLoader integration

    private func loader(_ cache: ThumbnailDiskCache?) -> ImageLoader {
        ImageLoader(diskCache: cache)
    }

    func testLoaderUsesDiskCacheOnSecondLaunch() async throws {
        let path = try writeSource("portrait.jpg", width: 1200, height: 800, orientation: 6, square: false)

        let first = loader(makeCache())
        let firstImage = await first.loadThumbnail(for: path, maxSize: 300)
        XCTAssertNotNil(firstImage)
        XCTAssertEqual(first.originalDecodeCount, 1)
        first.diskCache?.waitForPendingWork()

        // A relaunch: same directory, empty memory cache.
        let second = loader(makeCache())
        let loaded = await second.loadThumbnail(for: path, maxSize: 300)

        XCTAssertEqual(second.originalDecodeCount, 0, "the thumbnail must come from the disk cache")
        let thumbnail = try XCTUnwrap(loaded)
        let cg = try XCTUnwrap(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(max(cg.width, cg.height), 384, "same bucket as a fresh decode")
        XCTAssertGreaterThan(cg.height, cg.width, "EXIF orientation 6 stays applied")
        XCTAssertEqual(thumbnail.size, NSSize(width: cg.width, height: cg.height))
        let decoded = try XCTUnwrap(firstImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(decoded, cg)), 12)
        XCTAssertTrue(second.cachedThumbnail(for: path, maxSize: 300) === thumbnail, "a disk hit fills the memory cache")
    }

    func testLoaderWithoutDiskCacheDecodesAfterClearCache() async throws {
        let path = try writeSource("photo.jpg")
        let plain = loader(nil)

        _ = await plain.loadThumbnail(for: path, maxSize: 300)
        plain.clearCache()
        _ = await plain.loadThumbnail(for: path, maxSize: 300)

        XCTAssertEqual(plain.originalDecodeCount, 2)
    }

    func testClearCacheKeepsTheDiskCache() async throws {
        // The coordinator's relaunch benchmark relies on this: memory emptied, disk kept.
        let path = try writeSource("photo.jpg")
        let cached = loader(makeCache())

        _ = await cached.loadThumbnail(for: path, maxSize: 300)
        cached.diskCache?.waitForPendingWork()
        cached.clearCache()
        XCTAssertNil(cached.cachedThumbnail(for: path, maxSize: 300))
        let again = await cached.loadThumbnail(for: path, maxSize: 300)

        XCTAssertNotNil(again)
        XCTAssertEqual(cached.originalDecodeCount, 1)
    }

    func testChangedSourceIsDecodedAgain() async throws {
        let path = try writeSource("photo.jpg", width: 1200, height: 800, hue: 0.9)
        let first = loader(makeCache())
        _ = await first.loadThumbnail(for: path, maxSize: 300)
        first.diskCache?.waitForPendingWork()

        _ = try writeSource("photo.jpg", width: 800, height: 1200, hue: 0.2)
        let second = loader(makeCache())
        let loaded = await second.loadThumbnail(for: path, maxSize: 300)

        XCTAssertEqual(second.originalDecodeCount, 1, "a rewritten file misses the disk cache")
        let cg = try XCTUnwrap(loaded?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(cg.height, cg.width, "the new file's pixels, not the cached ones")
    }

    func testInvalidateRemovesDiskEntries() async throws {
        let path = try writeSource("photo.jpg")
        let first = loader(makeCache())
        _ = await first.loadThumbnail(for: path, maxSize: 300)
        _ = await first.loadThumbnail(for: path, maxSize: 1000)
        first.diskCache?.waitForPendingWork()
        XCTAssertEqual(cachedFiles().count, 2)

        first.invalidate(path: path)
        first.diskCache?.waitForPendingWork()

        XCTAssertEqual(cachedFiles(), [])
        let second = loader(makeCache())
        _ = await second.loadThumbnail(for: path, maxSize: 300)
        XCTAssertEqual(second.originalDecodeCount, 1)
    }

    func testInvalidateDuringDecodeDoesNotWriteAStaleEntryToDisk() async throws {
        // Big enough that the decode takes tens of milliseconds.
        let path = try writeSource("big.jpg", width: 4000, height: 3000)
        let cached = loader(makeCache())

        let load = Task { await cached.loadThumbnail(for: path, maxSize: 300) }
        try await waitFor("the decode to start") { cached.originalDecodeCount == 1 }
        cached.invalidate(path: path)
        _ = await load.value
        cached.diskCache?.waitForPendingWork()

        XCTAssertEqual(cachedFiles(), [], "a decode that started before invalidate(path:) must not reach the disk")
        XCTAssertNil(cached.cachedThumbnail(for: path, maxSize: 300))
    }

    func testClearCacheDuringDecodeStillStoresToDisk() async throws {
        // clearCache() is memory-only: a decode running across it is still a valid thumbnail for the disk.
        let path = try writeSource("big.jpg", width: 4000, height: 3000)
        let cached = loader(makeCache())

        let load = Task { await cached.loadThumbnail(for: path, maxSize: 300) }
        try await waitFor("the decode to start") { cached.originalDecodeCount == 1 }
        cached.clearCache()
        _ = await load.value
        cached.diskCache?.waitForPendingWork()

        XCTAssertEqual(cachedFiles().count, 1)
        XCTAssertNil(cached.cachedThumbnail(for: path, maxSize: 300), "the memory cache still drops it")
    }

    // MARK: - Where the shared loader caches

    func testDiskCacheDirectorySelection() {
        let override = "/private/tmp/phocasa-thumbs-test"
        XCTAssertNil(ImageLoader.diskCacheDirectory(environment: ["XCTestConfigurationFilePath": "/x"]),
                     "the test host never uses a disk cache unless one is configured")
        XCTAssertEqual(
            ImageLoader.diskCacheDirectory(environment: ["XCTestConfigurationFilePath": "/x",
                                                         "PHOCASA_THUMBNAIL_CACHE_DIR": override])?.path,
            override
        )
        XCTAssertEqual(ImageLoader.diskCacheDirectory(environment: [:]), ThumbnailDiskCache.defaultDirectory,
                       "a normal launch uses the default directory")
        XCTAssertEqual(ImageLoader.diskCacheDirectory(environment: ["PHOCASA_THUMBNAIL_CACHE_DIR": override]),
                       ThumbnailDiskCache.defaultDirectory, "the override is for test hosts only")
    }

    func testDefaultDirectoryIsInTheUsersCachesFolder() throws {
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let path = ThumbnailDiskCache.defaultDirectory.standardizedFileURL.path

        XCTAssertTrue(path.hasPrefix(caches.standardizedFileURL.path + "/"))
        XCTAssertTrue(path.hasSuffix("/Thumbnails/v1"))
    }

    func testSharedLoaderInThisTestHostNeverUsesTheRealCachesFolder() throws {
        let configured = ProcessInfo.processInfo.environment["PHOCASA_THUMBNAIL_CACHE_DIR"]
        if let configured {
            XCTAssertEqual(ImageLoader.shared.diskCache?.directory.path, URL(fileURLWithPath: configured).path)
        } else {
            XCTAssertNil(ImageLoader.shared.diskCache)
        }
        XCTAssertNotEqual(ImageLoader.shared.diskCache?.directory, ThumbnailDiskCache.defaultDirectory)
    }
}

// MARK: - Gated benchmarks (PHOCASA_BENCH=1)

/// Disk cache against decoding from the original, on generated 6000×4000 JPEGs (one encode, the rest APFS clones).
/// Run with `TEST_RUNNER_PHOCASA_BENCH=1 … -only-testing:PhocasaTests/ThumbnailDiskCacheBenchmarks`.
/// Everything is written under a temp directory; nothing touches ~/Library/Caches.
final class ThumbnailDiskCacheBenchmarks: XCTestCase {

    private var tempDir: URL!
    private let clock = ContinuousClock()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOCASA_BENCH"] == "1",
                          "Set PHOCASA_BENCH=1 to run benchmarks")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailDiskCacheBenchmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private func median(_ samples: [Double]) -> Double {
        samples.sorted()[samples.count / 2]
    }

    private func report(_ label: String, _ samples: [Double]) {
        let s = samples.sorted()
        print(String(format: "BENCH|thumbDisk|%@|median_ms=%.2f|min_ms=%.2f|max_ms=%.2f|runs=%d",
                     label, median(s), s.first!, s.last!, s.count))
    }

    private func newCacheDirectory() -> URL {
        tempDir.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
    }

    /// `count` 6000×4000 JPEGs with photo-like entropy (a gradient under tiled noise), EXIF orientation 6.
    private func makeSources(count: Int) throws -> [String] {
        let width = 6000, height = 4000, tile = 512
        var noise = [UInt8](repeating: 0, count: tile * tile * 4)
        noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let noiseImage: CGImage = try noise.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: tile, height: tile, bitsPerComponent: 8, bytesPerRow: tile * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
        let base = try XCTUnwrap(DiskCacheTestImages.makeImage(width: width, height: height))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(0.3)
        context.draw(noiseImage, in: CGRect(x: 0, y: 0, width: tile, height: tile), byTiling: true)
        let master = tempDir.appendingPathComponent("master.jpg")
        XCTAssertTrue(DiskCacheTestImages.writeJPEG(try XCTUnwrap(context.makeImage()), to: master, orientation: 6))

        return try (0..<count).map { i in
            let url = tempDir.appendingPathComponent(String(format: "copy_%03d.jpg", i))
            try FileManager.default.copyItem(at: master, to: url)
            return url.path
        }
    }

    /// The task's primary metric: 100 thumbnails at bucket 512, one at a time. A cold decode from the original
    /// (no disk cache) against a warm disk cache with an empty memory cache, as after a relaunch.
    func testWarmDiskVsColdDecode() async throws {
        let paths = try makeSources(count: 100)
        let directory = newCacheDirectory()
        // Populate the disk cache; this also brings the originals into the page cache for the cold runs.
        let populate = ImageLoader(diskCache: ThumbnailDiskCache(directory: directory))
        for path in paths {
            _ = await populate.loadThumbnail(for: path, maxSize: 512)
        }
        populate.diskCache?.waitForPendingWork()

        var cold: [Double] = [], warm: [Double] = []
        let disk = ThumbnailDiskCache(directory: directory)
        for path in paths {
            // Alternate per image, so both see the same load. Fresh loaders: empty memory caches.
            let plain = ImageLoader(diskCache: nil)
            var start = clock.now
            _ = await plain.loadThumbnail(for: path, maxSize: 512)
            cold.append(ms(clock.now - start))

            let relaunched = ImageLoader(diskCache: disk)
            start = clock.now
            let image = await relaunched.loadThumbnail(for: path, maxSize: 512)
            warm.append(ms(clock.now - start))
            XCTAssertNotNil(image)
            XCTAssertEqual(relaunched.originalDecodeCount, 0)
        }

        report("100 x 6000x4000 JPEG @512, one at a time: cold decode from the original", cold)
        report("100 x 6000x4000 JPEG @512, one at a time: warm disk cache, empty memory", warm)
        let speedup = median(cold) / median(warm)
        print(String(format: "BENCH|thumbDisk|100 x 6000x4000 JPEG @512: speedup|x=%.1f", speedup))
        XCTAssertGreaterThanOrEqual(speedup, 10, "a warm disk load must be at least 10x faster than a decode")
    }

    /// Task 11's fast-scroll protocol (cells 2.5 ms apart, a cell more than 40 behind cancelled, 380 px) over 200
    /// generated files, interleaved run by run: no disk cache (main's path), an empty disk cache (a miss also
    /// encodes and writes), and a warm disk cache with an empty memory cache (a relaunch).
    func testFastScrollColdAndRelaunch() async throws {
        let paths = try makeSources(count: 200)
        let warmDirectory = newCacheDirectory()
        let populate = ImageLoader(diskCache: ThumbnailDiskCache(directory: warmDirectory))
        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask { _ = await populate.loadThumbnail(for: path, maxSize: 380) }
            }
        }
        populate.diskCache?.waitForPendingWork()

        var last20: [[Double]] = [[], [], []], all: [[Double]] = [[], [], []]
        for run in 0..<5 {
            for variant in (0..<3).map({ ($0 + run) % 3 }) {
                let cache: ThumbnailDiskCache? = switch variant {
                case 0: nil
                case 1: ThumbnailDiskCache(directory: newCacheDirectory())
                default: ThumbnailDiskCache(directory: warmDirectory)
                }
                let loader = ImageLoader(diskCache: cache)
                var tasks: [Task<Void, Never>] = []
                for (i, path) in paths.enumerated() {
                    tasks.append(Task { _ = await loader.loadThumbnail(for: path, maxSize: 380) })
                    if i >= 40 { tasks[i - 40].cancel() }
                    try await Task.sleep(for: .microseconds(2500))
                }
                let tLast = clock.now
                for task in tasks.suffix(20) { await task.value }
                last20[variant].append(ms(clock.now - tLast))
                for task in tasks { await task.value }
                all[variant].append(ms(clock.now - tLast))
                // Don't let this run's queued writes overlap the next run.
                cache?.waitForPendingWork()
            }
        }

        let names = ["no disk cache", "disk cache empty (cold)", "disk warm, memory empty (relaunch)"]
        for variant in 0..<3 {
            report("200 x 6000x4000 JPEG fast scroll @380 last20: \(names[variant])", last20[variant])
            report("200 x 6000x4000 JPEG fast scroll @380 all done: \(names[variant])", all[variant])
        }
    }
}
