import AppKit
import ImageIO

/// NSCache key for one path at one size bucket.
final class ThumbnailCacheKey: NSObject, Sendable {
    let path: String
    let bucket: Int

    init(path: String, bucket: Int) {
        self.path = path
        self.bucket = bucket
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(path)
        hasher.combine(bucket)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ThumbnailCacheKey else { return false }
        return bucket == other.bucket && path == other.path
    }
}

final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    /// Size buckets in pixels (long edge). Requests are rounded UP to the next bucket, so a
    /// cached thumbnail is never smaller than requested.
    static let thumbnailBuckets: [Int] = [256, 384, 512, 768, 1024, 1536]

    /// Upper bound on decoded thumbnail memory held by the cache.
    static let thumbnailCacheCostLimit = 512 * 1024 * 1024

    /// Which version of the cache a decode belongs to. See `invalidate(path:)` and `clearCache()`.
    private struct CacheGeneration: Hashable, Sendable {
        let epoch: UInt64
        let path: UInt64
    }

    /// Thumbnail requests in flight: one per path, bucket and cache generation.
    private struct ThumbnailRequest: Hashable, Sendable {
        let path: String
        let bucket: Int
        let generation: CacheGeneration
    }

    private let thumbnailCache = NSCache<ThumbnailCacheKey, NSImage>()
    /// Bounded, newest-first and cancellable, so cells that scrolled away never delay the visible ones.
    /// Decodes are CPU-bound; measured throughput scales up to the active core count and not beyond.
    private let thumbnailScheduler = ThumbnailScheduler<ThumbnailRequest, CGImage>(
        maxConcurrent: ProcessInfo.processInfo.activeProcessorCount, qos: .userInitiated
    )
    /// Used by `loadFullResolution` only.
    private let queue = DispatchQueue(label: "com.phocasa.imageloader", qos: .userInitiated, attributes: .concurrent)

    /// Bumped by `invalidate(path:)` (per path) and `clearCache()` (all paths), so a decode that was already
    /// running can't put a stale thumbnail back into the cache.
    private let generationLock = NSLock()
    private var cacheEpoch: UInt64 = 0
    private var pathGenerations: [String: UInt64] = [:]

    private init() {
        thumbnailCache.totalCostLimit = Self.thumbnailCacheCostLimit
    }

    // MARK: - Thumbnails

    static func thumbnailBucket(forPixels pixels: CGFloat) -> Int {
        guard pixels.isFinite else { return pixels > 0 ? thumbnailBuckets.last! : thumbnailBuckets.first! }
        // Round to the nearest pixel first, so floating-point noise from cellWidth × scale can't jump a bucket.
        let wanted = pixels.rounded()
        return thumbnailBuckets.first { CGFloat($0) >= wanted } ?? thumbnailBuckets.last!
    }

    /// RAW files carry a large embedded JPEG preview, which is about 7× cheaper to decode than the RAW data.
    static func prefersEmbeddedPreview(path: String) -> Bool {
        FolderScanner.rawExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    func loadThumbnail(for path: String, maxSize: CGFloat = 300) async -> NSImage? {
        let bucket = Self.thumbnailBucket(forPixels: maxSize)
        if let cached = cachedThumbnail(for: path, bucket: bucket) {
            return cached
        }

        let generation = currentGeneration(for: path)
        let request = ThumbnailRequest(path: path, bucket: bucket, generation: generation)
        let key = ThumbnailCacheKey(path: path, bucket: bucket)
        let preferEmbedded = Self.prefersEmbeddedPreview(path: path)

        let cgImage = await thumbnailScheduler.value(for: request) { [self] in
            guard let cgImage = Self.decodeThumbnail(at: path, maxPixels: bucket, preferEmbedded: preferEmbedded) else {
                return nil
            }
            // Cache here rather than in the caller: if every caller was cancelled while this ran (the cell
            // scrolled away), the work isn't wasted when the cell comes back.
            store(cgImage, for: key, generation: generation)
            return cgImage
        }
        guard let cgImage else { return nil }
        return thumbnailCache.object(forKey: key) ?? Self.makeImage(cgImage)
    }

    /// The cached thumbnail for `path` at `maxSize`'s bucket or any larger bucket, without decoding.
    /// Cheap enough to call while building a view.
    func cachedThumbnail(for path: String, maxSize: CGFloat) -> NSImage? {
        cachedThumbnail(for: path, bucket: Self.thumbnailBucket(forPixels: maxSize))
    }

    /// Evicts every cached size of `path`. Task 21 wires this to the disk cache; task 30 calls it after exports.
    func invalidate(path: String) {
        generationLock.withLock {
            pathGenerations[path, default: 0] &+= 1
        }
        for bucket in Self.thumbnailBuckets {
            thumbnailCache.removeObject(forKey: ThumbnailCacheKey(path: path, bucket: bucket))
        }
    }

    func clearCache() {
        generationLock.withLock {
            cacheEpoch &+= 1
        }
        thumbnailCache.removeAllObjects()
    }

    /// Decodes a thumbnail whose long edge is at most `maxPixels`, with EXIF orientation applied.
    ///
    /// - `preferEmbedded` (RAW): use the file's embedded preview when it is at least 0.75 × `maxPixels` on its long
    ///   edge; otherwise decode the full image.
    /// - Otherwise always decode the full image: a JPEG's embedded EXIF thumbnail is only about 160 px.
    static func decodeThumbnail(at path: String, maxPixels: Int, preferEmbedded: Bool) -> CGImage? {
        guard let source = makeImageSource(atPath: path) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if preferEmbedded {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               Double(max(embedded.width, embedded.height)) >= 0.75 * Double(maxPixels) {
                return embedded
            }
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = nil
        }
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Full resolution

    func loadFullResolution(for path: String) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let imageSource = Self.makeImageSource(atPath: path) else {
                    continuation.resume(returning: nil)
                    return
                }

                let options: [CFString: Any] = [
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]

                guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: Self.makeImage(cgImage))
            }
        }
    }

    // MARK: - Private

    private static func makeImageSource(atPath path: String) -> CGImageSource? {
        CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    }

    /// An NSImage whose point size equals the pixel size, as the views expect.
    private static func makeImage(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
    }

    private func cachedThumbnail(for path: String, bucket: Int) -> NSImage? {
        // A bucket up to twice as large will do: never smaller than requested, and not so large that
        // drawing it at cell size aliases.
        for candidate in Self.thumbnailBuckets where candidate >= bucket && candidate <= bucket * 2 {
            if let image = thumbnailCache.object(forKey: ThumbnailCacheKey(path: path, bucket: candidate)) {
                return image
            }
        }
        return nil
    }

    private func currentGeneration(for path: String) -> CacheGeneration {
        generationLock.withLock { generationLocked(for: path) }
    }

    private func generationLocked(for path: String) -> CacheGeneration {
        CacheGeneration(epoch: cacheEpoch, path: pathGenerations[path] ?? 0)
    }

    private func store(_ cgImage: CGImage, for key: ThumbnailCacheKey, generation: CacheGeneration) {
        let image = Self.makeImage(cgImage)
        let cost = cgImage.bytesPerRow * cgImage.height
        // Insert while holding the lock: invalidate/clear bump the generation first and evict afterwards, so the
        // image either lands before the eviction or is dropped here.
        generationLock.withLock {
            guard generationLocked(for: key.path) == generation else { return }
            thumbnailCache.setObject(image, forKey: key, cost: cost)
        }
    }
}
