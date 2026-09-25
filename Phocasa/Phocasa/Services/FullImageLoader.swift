import Foundation
import ImageIO
import CoreGraphics

/// Decodes photos for the detail view (spec §D2).
///
/// - **Decode:** `CGImageSourceCreateImageAtIndex`, the hardware path, with `kCGImageSourceSubsampleFactor`
///   when the viewport needs fewer pixels. No pixels are rotated: the EXIF orientation is returned in the
///   `DisplayImage` and applied when displaying.
/// - **RAW:** the fit image is the embedded preview (already upright); a full RAW decode only runs when
///   zooming asks for more pixels. RAW decodes are deferred by ImageIO, so they're forced here, off the
///   main thread, into an 8-bit bitmap.
/// - **Cache:** an LRU keyed by (path, variant), bounded by decoded bytes.
/// - **Queues:** one serial queue for foreground loads, one at `.utility` for prefetch. A new prefetch
///   set drops queued prefetches that haven't started. Loads of a key already being decoded join it.
final class FullImageLoader: @unchecked Sendable {
    static let shared = FullImageLoader()
    static let defaultByteLimit = 512 << 20

    /// What the loader knows about a file from its header.
    struct ImageInfo: Sendable, Equatable {
        let pixelSize: CGSize
        let orientation: CGImagePropertyOrientation
        let isRAW: Bool

        var orientedSize: CGSize {
            orientation.swapsWidthAndHeight ? CGSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
        }
    }

    enum Variant: Hashable, Sendable {
        /// `CreateImageAtIndex` with this subsample factor (1 = full resolution).
        case subsample(Int)
        /// A RAW file's embedded preview, capped at this many pixels on the long edge.
        case rawPreview(maxPixelSize: Int)
    }

    private struct Key: Hashable {
        let path: String
        let variant: Variant
    }

    private struct Entry {
        let image: DisplayImage
        var lastUse: UInt64
    }

    /// One caller waiting for a decode. Guarded by the loader's `lock`; `cancelled` is set by the caller's
    /// cancellation handler.
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<DisplayImage?, Never>?
        var cancelled = false
    }

    private enum Start {
        case hit(DisplayImage)
        case join
        case decode
    }

    let byteLimit: Int

    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var entries: [Key: Entry] = [:]
    private var totalBytes = 0
    private var useClock: UInt64 = 0
    private var inFlight: [Key: [Waiter]] = [:]
    private var infoCache: [String: ImageInfo] = [:]
    private var prefetchGeneration = 0
    private var decodes = 0

    private let foregroundQueue = DispatchQueue(label: "com.phocasa.fullimage", qos: .userInitiated)
    private let prefetchQueue = DispatchQueue(label: "com.phocasa.fullimage.prefetch", qos: .utility)

    init(byteLimit: Int = FullImageLoader.defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    // MARK: - Public API

    /// Hardware-path decode at `subsample` (1, 2, 4 or 8). Applies no rotation: the orientation is returned
    /// for display.
    func load(path: String, subsample: Int) async -> DisplayImage? {
        await load(Key(path: path, variant: .subsample(Self.validFactor(subsample))), queue: foregroundQueue)
    }

    func cachedImage(path: String, subsample: Int) -> DisplayImage? {
        lookup(Key(path: path, variant: .subsample(Self.validFactor(subsample))))
    }

    /// Prefetches `paths` at one subsample factor. Replaces any previous prefetch set.
    func prefetch(paths: [String], subsample: Int) {
        let factor = Self.validFactor(subsample)
        enqueuePrefetch(paths) { path in Key(path: path, variant: .subsample(factor)) }
    }

    /// The image to show at fit-to-viewport: the largest subsample that still covers the viewport, or a RAW
    /// file's embedded preview.
    func loadFit(path: String, viewportPixelSize: CGSize) async -> DisplayImage? {
        guard let info = await info(path: path) else { return nil }
        if let hit = cachedCovering(path: path, info: info, viewportPixelSize: viewportPixelSize) { return hit }
        return await load(Key(path: path, variant: Self.fitVariant(info: info, viewportPixelSize: viewportPixelSize)),
                          queue: foregroundQueue)
    }

    /// The cached fit image, if the file's header has been read and its fit variant (or a decode with more
    /// pixels) is cached.
    func cachedFit(path: String, viewportPixelSize: CGSize) -> DisplayImage? {
        guard let info = cachedInfo(path: path) else { return nil }
        return cachedCovering(path: path, info: info, viewportPixelSize: viewportPixelSize)
    }

    /// Prefetches the fit image of each path, choosing the variant per image. Replaces any previous prefetch set.
    func prefetchFit(paths: [String], viewportPixelSize: CGSize) {
        enqueuePrefetch(paths) { [self] path in
            guard let info = readInfo(path: path),
                  cachedCovering(path: path, info: info, viewportPixelSize: viewportPixelSize) == nil else { return nil }
            return Key(path: path, variant: Self.fitVariant(info: info, viewportPixelSize: viewportPixelSize))
        }
    }

    /// Drops queued prefetches and empties the cache (the detail view closing). Decodes already running
    /// still finish.
    func clear() {
        lock.withLock {
            prefetchGeneration += 1
            entries.removeAll()
            totalBytes = 0
        }
    }

    /// Header information (size, orientation), read once per path.
    func info(path: String) async -> ImageInfo? {
        if let cached = cachedInfo(path: path) { return cached }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: readInfo(path: path))
            }
        }
    }

    func cachedInfo(path: String) -> ImageInfo? {
        lock.withLock { infoCache[path] }
    }

    /// Largest factor in {1, 2, 4, 8} whose subsampled image still has at least as many pixels as the image
    /// shows when fitted into the viewport. Pass the image size *after* orientation.
    static func subsampleFactor(imagePixelSize: CGSize, viewportPixelSize: CGSize) -> Int {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              viewportPixelSize.width > 0, viewportPixelSize.height > 0 else { return 1 }
        let scale = min(viewportPixelSize.width / imagePixelSize.width,
                        viewportPixelSize.height / imagePixelSize.height)
        guard scale < 1 else { return 1 }
        let fitted = CGSize(width: imagePixelSize.width * scale, height: imagePixelSize.height * scale)
        var factor = 1
        while factor < 8 {
            let next = CGFloat(factor * 2)
            // Half a pixel of slack for rounding in the fitted size.
            guard imagePixelSize.width / next + 0.5 >= fitted.width,
                  imagePixelSize.height / next + 0.5 >= fitted.height else { break }
            factor *= 2
        }
        return factor
    }

    static func isRAW(path: String) -> Bool {
        FolderScanner.rawExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: - Test and benchmark hooks

    /// Bytes currently held by the cache.
    var cachedBytes: Int { lock.withLock { totalBytes } }

    /// Decodes performed so far (cache misses that reached ImageIO).
    var decodeCount: Int { lock.withLock { decodes } }

    // MARK: - Variants

    private static func validFactor(_ subsample: Int) -> Int {
        switch subsample {
        case ...1: return 1
        case 2..<4: return 2
        case 4..<8: return 4
        default: return 8
        }
    }

    private static func fitVariant(info: ImageInfo, viewportPixelSize: CGSize) -> Variant {
        if info.isRAW {
            let longEdge = max(viewportPixelSize.width, viewportPixelSize.height)
            return .rawPreview(maxPixelSize: max(1, Int(longEdge.rounded(.up))))
        }
        return .subsample(subsampleFactor(imagePixelSize: info.orientedSize, viewportPixelSize: viewportPixelSize))
    }

    /// The fit variant if cached, else any cached decode of the file with more pixels. For RAW files a cached
    /// full decode is preferred to the embedded preview.
    private func cachedCovering(path: String, info: ImageInfo, viewportPixelSize: CGSize) -> DisplayImage? {
        let fit = Self.fitVariant(info: info, viewportPixelSize: viewportPixelSize)
        var candidates: [Variant]
        switch fit {
        case .subsample(let factor):
            candidates = [fit]
            var larger = factor / 2
            while larger >= 1 {
                candidates.append(.subsample(larger))
                larger /= 2
            }
        case .rawPreview:
            candidates = [.subsample(1), fit]
        }
        for variant in candidates {
            if let hit = lookup(Key(path: path, variant: variant)) { return hit }
        }
        return nil
    }

    // MARK: - Loading

    private func load(_ key: Key, queue: DispatchQueue) async -> DisplayImage? {
        if let hit = lookup(key) { return hit }

        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DisplayImage?, Never>) in
                let start = lock.withLock { () -> Start in
                    if let entry = entries[key] { return .hit(entry.image) }
                    waiter.continuation = continuation
                    if inFlight[key] != nil {
                        inFlight[key]!.append(waiter)
                        return .join
                    }
                    inFlight[key] = [waiter]
                    return .decode
                }
                switch start {
                case .hit(let image):
                    continuation.resume(returning: image)
                case .join:
                    // The decode may be a prefetch running at .utility. Enqueuing a higher-QoS item on the serial
                    // prefetch queue makes GCD raise the running item's QoS, so the caller doesn't wait on a
                    // starved background decode.
                    if queue !== prefetchQueue {
                        prefetchQueue.async(qos: .userInitiated, flags: .enforceQoS) {}
                    }
                case .decode:
                    queue.async { [self] in
                        // Skip the decode if everyone who asked for it has gone away (fast navigation).
                        // Checked and removed atomically, so a caller that joins later starts its own decode.
                        let abandoned = lock.withLock { () -> [Waiter]? in
                            guard let waiters = inFlight[key], waiters.allSatisfy(\.cancelled) else { return nil }
                            inFlight.removeValue(forKey: key)
                            return waiters
                        }
                        if let abandoned {
                            for w in abandoned { w.continuation?.resume(returning: nil) }
                            return
                        }
                        finish(key, with: decode(key))
                    }
                }
            }
        } onCancel: {
            lock.withLock { waiter.cancelled = true }
        }
    }

    private func enqueuePrefetch(_ paths: [String], key makeKey: @escaping @Sendable (String) -> Key?) {
        let generation = lock.withLock { () -> Int in
            prefetchGeneration += 1
            return prefetchGeneration
        }
        for path in paths {
            prefetchQueue.async { [self] in
                guard lock.withLock({ prefetchGeneration == generation }) else { return }
                guard let key = makeKey(path) else { return }
                let starts = lock.withLock { () -> Bool in
                    guard entries[key] == nil, inFlight[key] == nil else { return false }
                    inFlight[key] = []
                    return true
                }
                guard starts else { return }
                finish(key, with: decode(key))
            }
        }
    }

    /// Caches the result and resumes everyone waiting for `key`.
    private func finish(_ key: Key, with image: DisplayImage?) {
        let waiters = lock.withLock { () -> [Waiter] in
            if let image { insert(image, for: key) }
            return inFlight.removeValue(forKey: key) ?? []
        }
        for waiter in waiters { waiter.continuation?.resume(returning: image) }
    }

    // MARK: - Cache (callers hold no lock)

    private func lookup(_ key: Key) -> DisplayImage? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            useClock += 1
            entry.lastUse = useClock
            entries[key] = entry
            return entry.image
        }
    }

    /// Caller holds `lock`.
    private func insert(_ image: DisplayImage, for key: Key) {
        let cost = image.byteCost
        guard cost <= byteLimit else { return }
        if let old = entries[key] { totalBytes -= old.image.byteCost }
        useClock += 1
        entries[key] = Entry(image: image, lastUse: useClock)
        totalBytes += cost
        while totalBytes > byteLimit,
              let oldest = entries.lazy.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            totalBytes -= oldest.value.image.byteCost
            entries.removeValue(forKey: oldest.key)
        }
    }

    // MARK: - ImageIO (runs on the decode queues)

    private func readInfo(path: String) -> ImageInfo? {
        if let cached = cachedInfo(path: path) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let info = ImageInfo(pixelSize: CGSize(width: width, height: height),
                             orientation: Self.orientation(props),
                             isRAW: Self.isRAW(path: path))
        lock.withLock {
            if infoCache.count > 4096 { infoCache.removeAll() }
            infoCache[path] = info
        }
        return info
    }

    private func decode(_ key: Key) -> DisplayImage? {
        lock.withLock { decodes += 1 }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: key.path) as CFURL, nil) else { return nil }

        switch key.variant {
        case .rawPreview(let maxPixelSize):
            // Returns the embedded preview (already oriented), creating one only if the file has none.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return DisplayImage(cgImage: cg, orientation: .up)

        case .subsample(let factor):
            var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
            guard var cg = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            if Self.isRAW(path: key.path) {
                // ImageIO defers RAW decoding until first draw, which would land on the main thread.
                cg = Self.forceDecoded(cg) ?? cg
            }
            return DisplayImage(cgImage: cg, orientation: Self.orientation(props))
        }
    }

    private static func orientation(_ props: [CFString: Any]) -> CGImagePropertyOrientation {
        let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    /// Draws `image` into an 8-bit bitmap, which decodes it now (on the calling thread).
    private static func forceDecoded(_ image: CGImage) -> CGImage? {
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: bitmapInfo)
        }
        guard let ctx = image.colorSpace.flatMap(context) ?? context(CGColorSpace(name: CGColorSpace.sRGB)!) else {
            return nil
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
