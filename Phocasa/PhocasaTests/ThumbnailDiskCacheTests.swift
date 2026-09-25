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
    /// Every cache a test made, drained in tearDown: a store still queued would otherwise recreate folders while
    /// the temp directory is being deleted.
    private var caches: [ThumbnailDiskCache] = []

    override func setUpWithError() throws {
        caches = []
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        cacheDir = tempDir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        caches.forEach { $0.waitForPendingWork() }
        caches = []
        if let tempDir {
            // Fails if a queued store recreated a folder while the tree was being deleted.
            XCTAssertNoThrow(try FileManager.default.removeItem(at: tempDir), "leaked \(tempDir.lastPathComponent)")
        }
    }

    // MARK: - Helpers

    private func makeCache(
        byteLimit: Int = 1 << 30, trimInterval: Int = 100, maxPendingBytes: Int = 64 << 20, in directory: URL? = nil
    ) -> ThumbnailDiskCache {
        let cache = ThumbnailDiskCache(directory: directory ?? cacheDir, byteLimit: byteLimit,
                                       trimInterval: trimInterval, maxPendingBytes: maxPendingBytes)
        caches.append(cache)
        return cache
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

    /// Every cached thumbnail (a regular `.jpg` file) under the cache directory, relative to it. The byte-total file
    /// isn't a thumbnail.
    private func cachedFiles() -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: cacheDir.path) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if relative.hasSuffix(".jpg"),
               FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(relative).path,
                                              isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(relative)
            }
        }
        return files.sorted()
    }

    /// The bytes the cached thumbnails take on disk, as a full scan counts them.
    private func cachedBytes() throws -> Int {
        try cachedFiles().reduce(0) { total, relative in
            let values = try cacheDir.appendingPathComponent(relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return total + (values.totalFileAllocatedSize ?? 0)
        }
    }

    private func version(size: Int64, date: TimeInterval = 1_700_000_000) -> ThumbnailDiskCache.Version {
        ThumbnailDiskCache.Version(fileSize: size, modificationDate: Date(timeIntervalSince1970: date))
    }

    /// Rates `path` through the app's writer and `MetadataService`, wired to `loader` the way
    /// `MetadataWriter.shared` is wired to `ImageLoader.shared`, and waits for the disk cache.
    private func rate(_ path: String, _ rating: Int, keywords: [String] = [], observedBy loader: ImageLoader?) async {
        let writer = MetadataWriter(service: .shared, rewriteObserver: loader)
        writer.enqueue([MetadataWriteItem(path: path, rating: rating, keywords: keywords)])
        await writer.flush()
        loader?.diskCache?.waitForPendingWork()
    }

    /// Rewrites `path` with new pixels and puts its modification date back, as an export does
    /// (`ImageEditingService.writeJPEG` restores the file dates).
    private func rewritePixelsKeepingTheDate(_ path: String, hue: CGFloat) throws {
        let dates = captureFileDates(URL(fileURLWithPath: path))
        _ = try writeSource((path as NSString).lastPathComponent, hue: hue, square: false)
        restoreFileDates(URL(fileURLWithPath: path), dates: dates)
    }

    private func cgImage(_ image: NSImage?) throws -> CGImage {
        try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
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

    func testStoresAreDroppedWhileTooManyBytesAreWaiting() throws {
        // Pending stores hold decoded images; a backlog must not grow into a second, unbounded memory cache.
        let big = try image(1024, 768)
        let imageBytes = big.bytesPerRow * big.height
        let cache = makeCache(maxPendingBytes: imageBytes * 2)

        for i in 0..<50 {
            cache.store(big, for: key("/photos/\(i).jpg"))
        }
        cache.waitForPendingWork()

        let stored = cachedFiles().count
        XCTAssertGreaterThanOrEqual(stored, 1)
        XCTAssertLessThan(stored, 50, "stores beyond the pending-bytes limit are dropped, not queued")

        // Once the backlog has drained, stores are accepted again.
        let later = key("/photos/later.jpg")
        cache.store(big, for: later)
        cache.waitForPendingWork()
        XCTAssertNotNil(cache.image(for: later))
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
        let probe = makeCache(in: probeDir)
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

    // MARK: - Re-keying after a metadata-only rewrite (task 34)

    func testRekeyRenamesEveryBucketOfTheOldVersion() throws {
        let cache = makeCache()
        let old384 = key("/photos/a.jpg", bucket: 384, size: 1000)
        let old512 = key("/photos/a.jpg", bucket: 512, size: 1000)
        let other = key("/photos/b.jpg", bucket: 384, size: 1000)
        for k in [old384, old512, other] { cache.store(try image(), for: k) }
        cache.waitForPendingWork()

        // A rating write grew the file by 4,567 bytes; its modification date was put back.
        cache.rekey(path: "/photos/a.jpg", from: version(size: 1000), to: version(size: 5567))
        cache.waitForPendingWork()

        XCTAssertNotNil(cache.image(for: key("/photos/a.jpg", bucket: 384, size: 5567)))
        XCTAssertNotNil(cache.image(for: key("/photos/a.jpg", bucket: 512, size: 5567)))
        XCTAssertFalse(fileExists(cache.fileURL(for: old384)))
        XCTAssertFalse(fileExists(cache.fileURL(for: old512)))
        XCTAssertNotNil(cache.image(for: other), "other photos are untouched")
        XCTAssertEqual(cachedFiles().count, 3)
    }

    func testRekeyMovesOnlyTheVersionItWasGiven() throws {
        // The cached thumbnail is of an older version than the one that was rewritten: it stays stale.
        let cache = makeCache()
        let stale = key("/photos/a.jpg", size: 900)
        cache.store(try image(), for: stale)
        cache.waitForPendingWork()

        cache.rekey(path: "/photos/a.jpg", from: version(size: 1000), to: version(size: 1200))
        cache.waitForPendingWork()

        XCTAssertNil(cache.image(for: key("/photos/a.jpg", size: 1200)))
        XCTAssertTrue(fileExists(cache.fileURL(for: stale)))
    }

    func testRekeyKeepsAThumbnailAlreadyStoredForTheNewVersion() throws {
        let cache = makeCache()
        let newer = try image(hue: 0.2, square: false)
        cache.store(try image(hue: 0.9, square: false), for: key("/photos/a.jpg", size: 1000))
        cache.store(newer, for: key("/photos/a.jpg", size: 1200))
        cache.waitForPendingWork()

        cache.rekey(path: "/photos/a.jpg", from: version(size: 1000), to: version(size: 1200))
        cache.waitForPendingWork()

        let read = try XCTUnwrap(cache.image(for: key("/photos/a.jpg", size: 1200)))
        XCTAssertLessThanOrEqual(try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(newer, read)), 12)
        XCTAssertEqual(cachedFiles().count, 1)
    }

    func testStoreForTheOldVersionQueuedAfterARekeyIsFiledUnderTheNewOne() throws {
        // A decode that read the file's size before the rewrite finishes after it: same pixels, new version.
        let cache = makeCache()
        cache.rekey(path: "/photos/a.jpg", from: version(size: 1000), to: version(size: 1200))
        cache.store(try image(), for: key("/photos/a.jpg", size: 1000))
        cache.waitForPendingWork()

        XCTAssertNotNil(cache.image(for: key("/photos/a.jpg", size: 1200)))
        XCTAssertNil(cache.image(for: key("/photos/a.jpg", size: 1000)))
        XCTAssertEqual(cachedFiles().count, 1)
    }

    func testRekeysChain() throws {
        let cache = makeCache()
        cache.store(try image(), for: key("/photos/a.jpg", size: 1000))
        cache.rekey(path: "/photos/a.jpg", from: version(size: 1000), to: version(size: 1200))
        cache.rekey(path: "/photos/a.jpg", from: version(size: 1200), to: version(size: 1240))
        // A late store of the first version follows both.
        cache.store(try image(), for: key("/photos/a.jpg", bucket: 512, size: 1000))
        cache.waitForPendingWork()

        XCTAssertNotNil(cache.image(for: key("/photos/a.jpg", size: 1240)))
        XCTAssertNotNil(cache.image(for: key("/photos/a.jpg", bucket: 512, size: 1240)))
        XCTAssertEqual(cachedFiles().count, 2)
    }

    func testRemoveAllForgetsARekey() throws {
        // invalidate(path:) means the pixels changed: nothing may be filed under the re-keyed version any more.
        let cache = makeCache()
        cache.rekey(path: "/photos/a.jpg", from: version(size: 1000), to: version(size: 1200))
        cache.removeAll(forPath: "/photos/a.jpg")
        cache.store(try image(), for: key("/photos/a.jpg", size: 1000))
        cache.waitForPendingWork()

        XCTAssertNil(cache.image(for: key("/photos/a.jpg", size: 1200)))
        XCTAssertNotNil(cache.image(for: key("/photos/a.jpg", size: 1000)))
    }

    // MARK: - Byte total across launches (task 34)

    func testByteTotalSurvivesARelaunch() throws {
        let first = makeCache()
        for name in ["a", "b", "c"] { first.store(try image(), for: key("/photos/\(name).jpg")) }
        first.waitForPendingWork()
        XCTAssertTrue(fileExists(first.byteTotalURL))

        let relaunched = makeCache()
        relaunched.trimIfNeeded()
        relaunched.waitForPendingWork()

        XCTAssertEqual(relaunched.fullScanCount, 0, "a trusted total needs no scan")
        XCTAssertEqual(relaunched.knownByteTotal, try cachedBytes())
    }

    func testTheFirstAutomaticTrimOfASessionDoesNotRescan() throws {
        let first = makeCache(trimInterval: 2)
        for name in ["a", "b", "c", "d"] { first.store(try image(), for: key("/photos/\(name).jpg")) }
        first.waitForPendingWork()

        let relaunched = makeCache(trimInterval: 2)
        relaunched.store(try image(), for: key("/photos/e.jpg"))
        relaunched.store(try image(), for: key("/photos/f.jpg"))
        relaunched.waitForPendingWork()

        XCTAssertEqual(first.fullScanCount, 0, "a new cache starts with a known total of zero")
        XCTAssertEqual(relaunched.fullScanCount, 0)
        XCTAssertEqual(relaunched.knownByteTotal, try cachedBytes())
    }

    func testCorruptByteTotalTriggersARescan() throws {
        let first = makeCache()
        for name in ["a", "b", "c"] { first.store(try image(), for: key("/photos/\(name).jpg")) }
        first.waitForPendingWork()
        try Data("garbage".utf8).write(to: first.byteTotalURL)

        let relaunched = makeCache()
        XCTAssertNil(relaunched.knownByteTotal, "an unreadable total isn't trusted")
        relaunched.trimIfNeeded()
        relaunched.waitForPendingWork()
        XCTAssertEqual(relaunched.fullScanCount, 1)
        XCTAssertEqual(relaunched.knownByteTotal, try cachedBytes())

        // The scan wrote a good total back.
        let again = makeCache()
        again.trimIfNeeded()
        again.waitForPendingWork()
        XCTAssertEqual(again.fullScanCount, 0)
    }

    func testMissingOrImplausibleByteTotalTriggersARescan() throws {
        let first = makeCache()
        first.store(try image(), for: key("/photos/a.jpg"))
        first.waitForPendingWork()
        let url = first.byteTotalURL
        let now = Date()
        let cases: [(String, Data?)] = [
            ("missing", nil),
            ("negative", ThumbnailDiskCache.byteTotalRecord(bytes: -5, verifiedAt: now)),
            ("last verified too long ago", ThumbnailDiskCache.byteTotalRecord(
                bytes: 10, verifiedAt: now.addingTimeInterval(-ThumbnailDiskCache.byteTotalMaxAge - 60))),
            ("verified in the future", ThumbnailDiskCache.byteTotalRecord(
                bytes: 10, verifiedAt: now.addingTimeInterval(86_400))),
            ("truncated", ThumbnailDiskCache.byteTotalRecord(bytes: 10, verifiedAt: now).prefix(20)),
        ]
        for (name, record) in cases {
            try? FileManager.default.removeItem(at: url)
            if let record { try record.write(to: url) }
            let relaunched = makeCache()
            XCTAssertNil(relaunched.knownByteTotal, name)
            relaunched.trimIfNeeded()
            relaunched.waitForPendingWork()
            XCTAssertEqual(relaunched.fullScanCount, 1, name)
            XCTAssertEqual(relaunched.knownByteTotal, try cachedBytes(), name)
        }
        // And a good record is trusted as it is.
        try ThumbnailDiskCache.byteTotalRecord(bytes: 12_345, verifiedAt: now).write(to: url)
        XCTAssertEqual(makeCache().knownByteTotal, 12_345)
    }

    func testByteTotalFollowsStoresRemovalsTrimsAndRekeys() throws {
        let thumbnail = try image()
        let fileBytes = try cachedFileBytes(for: thumbnail)
        let first = makeCache(byteLimit: fileBytes * 4, trimInterval: 1000)
        for i in 0..<6 { first.store(thumbnail, for: key("/photos/\(i).jpg")) }
        first.store(try image(300, 200), for: key("/photos/0.jpg", bucket: 512))
        first.removeAll(forPath: "/photos/1.jpg")
        first.store(try image(200, 150), for: key("/photos/2.jpg", size: 2000))   // replaces a stale version
        first.store(thumbnail, for: key("/photos/3.jpg", size: 3000))
        first.rekey(path: "/photos/3.jpg", from: version(size: 1000), to: version(size: 3000))  // drops a duplicate
        first.trimIfNeeded()   // over the limit: scans and deletes the oldest
        first.store(thumbnail, for: key("/photos/7.jpg"))
        first.waitForPendingWork()
        XCTAssertEqual(first.knownByteTotal, try cachedBytes())

        let relaunched = makeCache(byteLimit: fileBytes * 4)
        XCTAssertEqual(relaunched.knownByteTotal, try cachedBytes())
    }

    func testByteTotalFileIsNotCountedAsAThumbnail() throws {
        let cache = makeCache()
        cache.store(try image(), for: key("/photos/a.jpg"))
        cache.waitForPendingWork()
        let bytes = try cachedBytes()

        let relaunched = makeCache(byteLimit: 1 << 30)
        try? FileManager.default.removeItem(at: relaunched.byteTotalURL)
        relaunched.trimIfNeeded()
        relaunched.waitForPendingWork()

        XCTAssertEqual(relaunched.fullScanCount, 1)
        XCTAssertEqual(relaunched.knownByteTotal, bytes)
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

    // MARK: - Rating writes keep the disk cache (task 34)

    func testRatingWritesKeepTheThumbnailOnDiskAcrossARelaunch() async throws {
        let path = try writeSource("rated.jpg", orientation: 6, square: false)
        let session = loader(makeCache())
        let shown = try cgImage(await session.loadThumbnail(for: path, maxSize: 300))
        session.diskCache?.waitForPendingWork()
        let unrated = try XCTUnwrap(ThumbnailDiskCache.Key.current(path: path, bucket: 384))

        // The first rating adds an XMP segment; a keyword grows it again. Both change the size, not the date.
        await rate(path, 3, observedBy: session)
        let rated = try XCTUnwrap(ThumbnailDiskCache.Key.current(path: path, bucket: 384))
        XCTAssertNotEqual(rated.fileSize, unrated.fileSize, "precondition: the write changes the file's size")
        XCTAssertEqual(rated.modificationDate.timeIntervalSince1970, unrated.modificationDate.timeIntervalSince1970,
                       accuracy: 1e-6, "precondition: and puts its date back")
        await rate(path, 4, keywords: ["people:ann"], observedBy: session)
        XCTAssertNotEqual(ThumbnailDiskCache.Key.current(path: path, bucket: 384), rated)
        XCTAssertEqual(MetadataService.shared.readMetadata(from: path).rating, 4)

        let relaunched = loader(makeCache())
        let loaded = try cgImage(await relaunched.loadThumbnail(for: path, maxSize: 300))

        XCTAssertEqual(relaunched.originalDecodeCount, 0, "a metadata-only rewrite must not cost a decode")
        XCTAssertEqual(session.originalDecodeCount, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(shown, loaded)), 12)
        XCTAssertEqual(cachedFiles().count, 1, "renamed, not stored twice")
    }

    func testRewriteThatRoundsTheDateToTheMicrosecondIsRekeyed() async throws {
        // APFS keeps nanoseconds; restoreFileDates goes through Date and puts back microseconds.
        let path = try writeSource("rated.jpg")
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
                     timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
        XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0)
        let session = loader(makeCache())
        _ = await session.loadThumbnail(for: path, maxSize: 300)
        session.diskCache?.waitForPendingWork()
        let before = try XCTUnwrap(ThumbnailDiskCache.Version.current(path: path))

        await rate(path, 3, observedBy: session)
        let after = try XCTUnwrap(ThumbnailDiskCache.Version.current(path: path))
        XCTAssertNotEqual(after.modificationDate, before.modificationDate, "precondition: the date was rounded")
        let relaunched = loader(makeCache())
        _ = await relaunched.loadThumbnail(for: path, maxSize: 300)

        XCTAssertEqual(relaunched.originalDecodeCount, 0)
    }

    func testRatingWriteWithoutTheObserverStillMisses() async throws {
        // Why the hook is needed: the key follows the file's size.
        let path = try writeSource("rated.jpg")
        let session = loader(makeCache())
        _ = await session.loadThumbnail(for: path, maxSize: 300)
        session.diskCache?.waitForPendingWork()

        await rate(path, 3, observedBy: nil)
        let relaunched = loader(makeCache())
        _ = await relaunched.loadThumbnail(for: path, maxSize: 300)

        XCTAssertEqual(relaunched.originalDecodeCount, 1)
    }

    func testRatingWriteToARAWFileLeavesItsThumbnailAlone() async throws {
        // A RAW's rating goes to its .xmp sidecar; the RAW itself, and so its key, doesn't change.
        let path = try writeSource("photo.dng")
        let session = loader(makeCache())
        _ = await session.loadThumbnail(for: path, maxSize: 300)
        session.diskCache?.waitForPendingWork()
        let before = cachedFiles()

        await rate(path, 5, observedBy: session)
        let relaunched = loader(makeCache())
        _ = await relaunched.loadThumbnail(for: path, maxSize: 300)

        XCTAssertEqual(cachedFiles(), before)
        XCTAssertEqual(relaunched.originalDecodeCount, 0)
    }

    func testExportAfterARatingDecodesAgain() async throws {
        let path = try writeSource("photo.jpg", hue: 0.9, square: false)
        let session = loader(makeCache())
        _ = await session.loadThumbnail(for: path, maxSize: 300)
        session.diskCache?.waitForPendingWork()
        await rate(path, 3, observedBy: session)

        // "Apply edits permanently": new pixels, the old date, then invalidate(path:).
        try rewritePixelsKeepingTheDate(path, hue: 0.2)
        session.invalidate(path: path)
        session.diskCache?.waitForPendingWork()

        let relaunched = loader(makeCache())
        let loaded = try cgImage(await relaunched.loadThumbnail(for: path, maxSize: 300))
        XCTAssertEqual(relaunched.originalDecodeCount, 1)
        let fresh = try XCTUnwrap(ImageLoader.decodeThumbnail(at: path, maxPixels: 384, preferEmbedded: false))
        XCTAssertLessThanOrEqual(try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(fresh, loaded)), 12)
    }

    func testRewriteThatAlsoChangesTheDateIsNotRekeyed() async throws {
        // Another app saved new pixels while the rating was written: the date moved, so the pixels may have too.
        let path = try writeSource("photo.jpg", hue: 0.9, square: false)
        let session = loader(makeCache())
        _ = await session.loadThumbnail(for: path, maxSize: 300)
        session.diskCache?.waitForPendingWork()

        session.rewritingMetadata(ofImageAt: path) {
            _ = try? writeSource("photo.jpg", hue: 0.2, square: false)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
        }
        session.diskCache?.waitForPendingWork()

        let relaunched = loader(makeCache())
        let loaded = try cgImage(await relaunched.loadThumbnail(for: path, maxSize: 300))
        XCTAssertEqual(relaunched.originalDecodeCount, 1)
        let fresh = try XCTUnwrap(ImageLoader.decodeThumbnail(at: path, maxPixels: 384, preferEmbedded: false))
        XCTAssertLessThanOrEqual(try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(fresh, loaded)), 12)
    }

    func testRewriteDuringWhichThePathIsInvalidatedIsNotRekeyed() async throws {
        // An export that keeps the date overlaps the rating write, and its invalidate(path:) lands during it. A
        // thumbnail of the old pixels, decoded between the invalidation and the new pixels, is stored under the old
        // key: the re-key must not make it current.
        let path = try writeSource("photo.jpg", hue: 0.9, square: false)
        let session = loader(makeCache())
        let oldPixels = try cgImage(await session.loadThumbnail(for: path, maxSize: 300))
        session.diskCache?.waitForPendingWork()
        let unrated = try XCTUnwrap(ThumbnailDiskCache.Key.current(path: path, bucket: 384))

        session.rewritingMetadata(ofImageAt: path) {
            session.invalidate(path: path)
            session.diskCache?.store(oldPixels, for: unrated)
            try? rewritePixelsKeepingTheDate(path, hue: 0.2)
        }
        session.diskCache?.waitForPendingWork()

        let relaunched = loader(makeCache())
        let loaded = try cgImage(await relaunched.loadThumbnail(for: path, maxSize: 300))
        XCTAssertEqual(relaunched.originalDecodeCount, 1, "no thumbnail of the old pixels may be current")
        let fresh = try XCTUnwrap(ImageLoader.decodeThumbnail(at: path, maxPixels: 384, preferEmbedded: false))
        XCTAssertLessThanOrEqual(try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(fresh, loaded)), 12)
    }

    func testDecodeRunningDuringARatingWriteIsKeptUnderTheNewKey() async throws {
        // The decode reads the file's size before the write and stores after the re-key.
        let path = try writeSource("big.jpg", width: 4000, height: 3000)
        let session = loader(makeCache())
        let load = Task { await session.loadThumbnail(for: path, maxSize: 300) }
        try await waitFor("the decode to start") { session.originalDecodeCount == 1 }
        await rate(path, 2, observedBy: session)
        _ = await load.value
        session.diskCache?.waitForPendingWork()

        let relaunched = loader(makeCache())
        _ = await relaunched.loadThumbnail(for: path, maxSize: 300)
        XCTAssertEqual(relaunched.originalDecodeCount, 0)
    }

    // MARK: - Smaller buckets from larger ones on disk (task 34)

    func testSmallerBucketIsServedFromALargerOneOnDisk() async throws {
        // 4:3, so every bucket scales to whole pixels. (Otherwise ImageIO darkens the partly covered last column of
        // every thumbnail, and a larger bucket's darker column shows up in the smaller one.)
        let path = try writeSource("photo.jpg", width: 1200, height: 900, orientation: 6, square: false)
        let previous = loader(makeCache())
        _ = await previous.loadThumbnail(for: path, maxSize: 1000)   // bucket 1024
        previous.diskCache?.waitForPendingWork()

        let relaunched = loader(makeCache())
        // Smallest first: the memory cache would serve the 768 image for a 512 request as it is.
        let loaded512 = await relaunched.loadThumbnail(for: path, maxSize: 400)
        let loaded768 = await relaunched.loadThumbnail(for: path, maxSize: 700)
        let at768 = try XCTUnwrap(loaded768), at512 = try XCTUnwrap(loaded512)

        XCTAssertEqual(relaunched.originalDecodeCount, 0, "zoomed out since the last launch: served from disk")
        let cg768 = try cgImage(at768), cg512 = try cgImage(at512)
        XCTAssertEqual(max(cg768.width, cg768.height), 768, "the requested bucket's size, like a fresh decode")
        XCTAssertEqual(max(cg512.width, cg512.height), 512)
        XCTAssertGreaterThan(cg768.height, cg768.width, "EXIF orientation 6 stays applied")
        let fresh = try XCTUnwrap(ImageLoader.decodeThumbnail(at: path, maxPixels: 768, preferEmbedded: false))
        XCTAssertLessThanOrEqual(try XCTUnwrap(DiskCacheTestImages.maxChannelDifference(fresh, cg768)), 12)
        XCTAssertTrue(relaunched.cachedThumbnail(for: path, maxSize: 700) === at768, "and it fills the memory cache")
        XCTAssertEqual(cachedFiles().count, 1, "nothing new is stored: the larger file serves it")
    }

    func testDiskBucketsMoreThanTwiceAsLargeOrSmallerAreNotUsed() async throws {
        let path = try writeSource("photo.jpg", width: 2000, height: 1500)
        let previous = loader(makeCache())
        _ = await previous.loadThumbnail(for: path, maxSize: 1000)   // bucket 1024
        previous.diskCache?.waitForPendingWork()

        let relaunched = loader(makeCache())
        _ = await relaunched.loadThumbnail(for: path, maxSize: 250)    // bucket 256: 1024 is 4× larger
        XCTAssertEqual(relaunched.originalDecodeCount, 1)
        _ = await relaunched.loadThumbnail(for: path, maxSize: 1400)   // bucket 1536: 1024 is smaller
        XCTAssertEqual(relaunched.originalDecodeCount, 2)
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

    /// Fills `directory` with every path's thumbnail at `size`, decoding concurrently. A store can be dropped while
    /// the disk queue is backed up, so passes repeat until a fresh loader finds everything on disk.
    private func populate(_ directory: URL, paths: [String], size: CGFloat) async {
        for _ in 0..<5 {
            let loader = ImageLoader(diskCache: ThumbnailDiskCache(directory: directory))
            await withTaskGroup(of: Void.self) { group in
                for path in paths {
                    group.addTask { _ = await loader.loadThumbnail(for: path, maxSize: size) }
                }
            }
            loader.diskCache?.waitForPendingWork()
            if loader.originalDecodeCount == 0 { return }
        }
        XCTFail("the disk cache didn't fill up")
    }

    /// `count` 6000×4000 JPEGs with photo-like entropy (a gradient under tiled noise), EXIF orientation 6.
    /// `folder` (under the temp dir) keeps the sets of several runs apart; they share one master.
    private func makeSources(count: Int, folder: String? = nil) throws -> [String] {
        let master = try makeMaster()
        var directory = tempDir!
        if let folder {
            directory = tempDir.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return try (0..<count).map { i in
            let url = directory.appendingPathComponent(String(format: "copy_%03d.jpg", i))
            try FileManager.default.copyItem(at: master, to: url)
            return url.path
        }
    }

    private func makeMaster() throws -> URL {
        let master = tempDir.appendingPathComponent("master.jpg")
        if FileManager.default.fileExists(atPath: master.path) { return master }
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
        XCTAssertTrue(DiskCacheTestImages.writeJPEG(try XCTUnwrap(context.makeImage()), to: master, orientation: 6))
        return master
    }

    /// The task's primary metric: 100 thumbnails at bucket 512, one at a time. A cold decode from the original
    /// (no disk cache) against a warm disk cache with an empty memory cache, as after a relaunch.
    func testWarmDiskVsColdDecode() async throws {
        let paths = try makeSources(count: 100)
        let directory = newCacheDirectory()
        // This also brings the originals into the page cache for the cold runs.
        await populate(directory, paths: paths, size: 512)

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
        disk.waitForPendingWork()

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
        await populate(warmDirectory, paths: paths, size: 380)

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

    // MARK: - Task 34: rating writes, zooming out, the first trim of a session

    private func info(_ line: String) {
        print("BENCH|thumbDisk|" + line)
    }

    /// Loads every path once, one at a time, through `loader`, and returns the time of each load.
    private func loadEach(_ paths: [String], size: CGFloat, with loader: ImageLoader) async -> [Double] {
        var samples: [Double] = []
        for path in paths {
            let start = clock.now
            let image = await loader.loadThumbnail(for: path, maxSize: size)
            samples.append(ms(clock.now - start))
            XCTAssertNotNil(image)
        }
        return samples
    }

    /// The writer the app would use for a session whose thumbnails `loader` holds (as `MetadataWriter.shared` reports
    /// to `ImageLoader.shared`), or, with `rekey: false`, one without the hook: main's path before task 34.
    private func makeRatingWriter(observing loader: ImageLoader, rekey: Bool = true) -> MetadataWriter {
        MetadataWriter(service: .shared, rewriteObserver: rekey ? loader : nil)
    }

    /// Task 34's primary metric. 100 photos whose thumbnails are cached get a first rating through the app's writer
    /// and `MetadataService` (it adds an XMP segment, so every file's size changes), then the app relaunches: a fresh
    /// loader on the same cache. Counts the decodes from the original and times each load. Three runs with the
    /// re-key hook, then three without it (main's path before task 34), each on fresh copies.
    func testRatedJPEGsAfterRelaunch() async throws {
        for rekey in [true, false] {
            try await ratedJPEGsAfterRelaunch(rekey: rekey)
        }
    }

    private func ratedJPEGsAfterRelaunch(rekey: Bool) async throws {
        var loads: [Double] = [], decodes: [Int] = [], changed: [Int] = []
        for run in 0..<3 {
            let paths = try makeSources(count: 100, folder: "rated-\(rekey)-\(run)")
            let directory = newCacheDirectory()
            await populate(directory, paths: paths, size: 380)
            let before = paths.map { ThumbnailDiskCache.Key.current(path: $0, bucket: 384) }

            // The session in which the user rates them: thumbnails on screen, then one batch rating.
            let session = ImageLoader(diskCache: ThumbnailDiskCache(directory: directory))
            _ = await loadEach(paths, size: 380, with: session)
            XCTAssertEqual(session.originalDecodeCount, 0)
            let writer = makeRatingWriter(observing: session, rekey: rekey)
            writer.enqueue(paths.map { MetadataWriteItem(path: $0, rating: 3, keywords: []) })
            await writer.flush()
            session.diskCache?.waitForPendingWork()
            let after = paths.map { ThumbnailDiskCache.Key.current(path: $0, bucket: 384) }
            changed.append(zip(before, after).filter { $0 != $1 }.count)
            XCTAssertEqual(MetadataService.shared.readMetadata(from: paths[0]).rating, 3)

            let relaunched = ImageLoader(diskCache: ThumbnailDiskCache(directory: directory))
            loads += await loadEach(paths, size: 380, with: relaunched)
            decodes.append(relaunched.originalDecodeCount)
            relaunched.diskCache?.waitForPendingWork()
            // Each rated copy is a full 12 MB file now (no longer a clone of the master).
            try? FileManager.default.removeItem(atPath: (paths[0] as NSString).deletingLastPathComponent)
        }
        let label = rekey ? "100 x 6000x4000 JPEG rated" : "100 x 6000x4000 JPEG rated without the re-key hook (main's path)"
        report("\(label), then relaunch @380: load", loads)
        info("\(label), then relaunch @380: decodes from the original|per_run=\(decodes)|keys_changed=\(changed)")
    }

    /// What a larger bucket costs to serve: the 512 file read as is, or decoded down to 384 or 256, against the exact
    /// 384 file. One read of each per photo (order rotated), fresh from the page cache. `KB` is the decoded image.
    func testLargerBucketReadAsIsOrDecodedDown() async throws {
        let paths = try makeSources(count: 100)
        let directory = newCacheDirectory()
        await populate(directory, paths: paths, size: 512)
        await populate(directory, paths: paths, size: 380)
        let disk = ThumbnailDiskCache(directory: directory)
        let variants: [(String, Int, Int?)] = [
            ("exact 384 file", 384, nil), ("512 file as is", 512, nil),
            ("512 file decoded down to 384", 512, 384), ("512 file decoded down to 256", 512, 256),
        ]
        var samples = Array(repeating: [Double](), count: variants.count), kilobytes = Array(repeating: 0, count: variants.count)
        for (index, path) in paths.enumerated() {
            for v in (0..<variants.count).map({ ($0 + index) % variants.count }) {
                let key = try XCTUnwrap(ThumbnailDiskCache.Key.current(path: path, bucket: variants[v].1))
                let start = clock.now
                let image = try XCTUnwrap(disk.image(for: key, maxPixelSize: variants[v].2))
                samples[v].append(ms(clock.now - start))
                kilobytes[v] = image.bytesPerRow * image.height / 1024
            }
        }
        disk.waitForPendingWork()
        for (v, variant) in variants.enumerated() {
            report("100 x disk read: \(variant.0) (decoded KB=\(kilobytes[v]))", samples[v])
        }
    }

    /// Deletes every cached file that isn't in `bucket`, so each run starts from the same cache.
    private func keepOnlyBucket(_ bucket: Int, in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "jpg", !url.lastPathComponent.hasPrefix("\(bucket)-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// A grid zoomed out since the last launch: thumbnails cached at 512, then requested at 380 (bucket 384) and at
    /// 256, against exact hits at 512. Fresh loaders (empty memory caches), one load at a time, variants rotated.
    func testZoomOutAfterRelaunch() async throws {
        let paths = try makeSources(count: 100)
        let directory = newCacheDirectory()
        await populate(directory, paths: paths, size: 512)
        let sizes: [CGFloat] = [512, 380, 256]
        var loads: [CGFloat: [Double]] = [:], decodes: [CGFloat: [Int]] = [:], edges: [CGFloat: Int] = [:]
        for run in 0..<3 {
            for size in (0..<sizes.count).map({ sizes[($0 + run) % sizes.count] }) {
                let disk = ThumbnailDiskCache(directory: directory)
                let relaunched = ImageLoader(diskCache: disk)
                loads[size, default: []] += await loadEach(paths, size: size, with: relaunched)
                decodes[size, default: []].append(relaunched.originalDecodeCount)
                let image = await relaunched.loadThumbnail(for: paths[0], maxSize: size)
                edges[size] = image.map { Int(max($0.size.width, $0.size.height)) } ?? 0
                disk.waitForPendingWork()
                keepOnlyBucket(512, in: directory)
            }
        }
        for size in sizes {
            report("100 x 6000x4000 JPEG cached @512, relaunch, load @\(Int(size))", loads[size]!)
            info("100 x 6000x4000 JPEG cached @512, relaunch, load @\(Int(size)): decodes from the original|per_run=\(decodes[size]!)|long_edge_px=\(edges[size]!)")
        }
    }

    /// The first automatic trim of a session, with 10,000 files cached and under the limit. A new cache instance (a
    /// relaunch) must know the byte total before it can skip the trim.
    func testFirstTrimOfASession() async throws {
        let directory = newCacheDirectory()
        let thumbnail = try XCTUnwrap(DiskCacheTestImages.makeImage(width: 64, height: 48))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func key(_ name: String) -> ThumbnailDiskCache.Key {
            ThumbnailDiskCache.Key(path: "/bench/\(name).jpg", fileSize: 1000, modificationDate: date, bucket: 384)
        }
        let filler = ThumbnailDiskCache(directory: directory, trimInterval: .max)
        for i in 0..<10_000 {
            filler.store(thumbnail, for: key("\(i)"))
            // Stay under the pending-store bound, so nothing is dropped.
            if i % 500 == 499 { filler.waitForPendingWork() }
        }
        filler.waitForPendingWork()

        var explicit: [Double] = [], automatic: [Double] = []
        for run in 0..<3 {
            let relaunched = ThumbnailDiskCache(directory: directory)
            var start = clock.now
            relaunched.trimIfNeeded()
            relaunched.waitForPendingWork()
            explicit.append(ms(clock.now - start))

            // The automatic one: the 100th store of the session trims.
            let other = ThumbnailDiskCache(directory: directory)
            start = clock.now
            for i in 0..<100 { other.store(thumbnail, for: key("run\(run)-\(i)")) }
            other.waitForPendingWork()
            automatic.append(ms(clock.now - start))
        }
        report("10,000 cached files, relaunch: first trimIfNeeded()", explicit)
        report("10,000 cached files, relaunch: 100 stores including the first automatic trim", automatic)
    }

    /// `MetadataWriter` throughput: rating writes to 200 JPEGs of 1024x1024 whose thumbnails are cached, each write
    /// changing the file's size (a keyword comes and goes). From the first enqueue until `flush()` returns.
    func testWriterThroughput() async throws {
        let folder = tempDir.appendingPathComponent("writer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try XCTUnwrap(DiskCacheTestImages.makeImage(width: 1024, height: 1024))
        let paths = (0..<200).map { folder.appendingPathComponent(String(format: "w_%03d.jpg", $0)).path }
        for path in paths {
            XCTAssertTrue(DiskCacheTestImages.writeJPEG(source, to: URL(fileURLWithPath: path)))
        }
        let directory = newCacheDirectory()
        await populate(directory, paths: paths, size: 380)
        let session = ImageLoader(diskCache: ThumbnailDiskCache(directory: directory))
        _ = await loadEach(paths, size: 380, with: session)

        // Alternate: with the re-key hook (every write re-keys), and without it (main's path).
        var perWrite: [Bool: [Double]] = [:]
        for round in 0..<12 {
            let rekey = (round / 2) % 2 == 0
            let writer = makeRatingWriter(observing: session, rekey: rekey)
            let items = paths.map {
                MetadataWriteItem(path: $0, rating: round % 5 + 1, keywords: round % 2 == 0 ? ["k\(round)"] : [])
            }
            let start = clock.now
            writer.enqueue(items)
            await writer.flush()
            perWrite[rekey, default: []].append(ms(clock.now - start) / Double(paths.count))
            session.diskCache?.waitForPendingWork()
        }
        report("MetadataWriter 200 x 1024x1024 JPEG rating writes, per write", perWrite[true]!)
        report("MetadataWriter 200 x 1024x1024 JPEG rating writes, per write, without the re-key hook (main's path)",
               perWrite[false]!)
    }
}
