import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails kept on disk across launches: one small JPEG per photo and size bucket.
///
/// - **Layout:** `<directory>/<h0h1>/<h>/<bucket>-<fileSize>-<mtime>.jpg`, where `h` is the SHA-256 hex of the photo's
///   path. Each photo has its own folder, so `removeAll(forPath:)` is one folder delete and a store can drop the stale
///   versions of its photo. There is no index file that could go out of date.
/// - **Staleness:** the file name carries the photo's size and modification date, so a changed photo misses.
/// - **Re-keying:** a metadata-only rewrite (a rating or keyword write) changes a JPEG's size but not its pixels or,
///   since `MetadataService` puts it back, its date. `rekey(path:from:to:)` renames the photo's files to the new
///   version instead of letting them miss. `ImageLoader` decides when that is safe.
/// - **Reads** (`image(for:)`) are synchronous, on the caller's thread: the thumbnail scheduler's workers.
/// - **Writes** (encoding, stores, re-keys, removals, LRU touches, trimming) run in order on one private utility
///   queue. Queued stores hold decoded images, so a store is dropped while more than `maxPendingBytes` are waiting.
/// - **LRU:** a hit sets the cached file's modification date to now. Every `trimInterval` stores, and on
///   `trimIfNeeded()`, the oldest files are deleted once the total passes `byteLimit`, down to 90% of it.
/// - **Byte total:** kept up to date in the `byte-total` file in `directory`, so a relaunch doesn't have to scan the
///   whole cache before it can skip a trim. It is trusted when it is intact and a full scan confirmed it less than
///   `byteTotalMaxAge` ago; otherwise the first trim scans, as it does for a directory without one.
/// - **Outside deletion:** someone may empty the folder at any time (the user clearing `~/Library/Caches`). Anything
///   missing is a miss, stores recreate folders, and trimming ignores files that are already gone. The byte total
///   then counts too much, which only brings the next scan forward.
/// - One instance per directory at a time (the app's is `ImageLoader.shared`'s).
final class ThumbnailDiskCache: @unchecked Sendable {
    /// One version of a photo file: its size and modification date.
    struct Version: Hashable, Sendable {
        let fileSize: Int64
        let modificationDate: Date

        /// Reads size and mtime for `path` (one `stat`); nil if it is missing or not a regular file.
        static func current(path: String) -> Version? {
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            let mtime = info.st_mtimespec
            return Version(
                fileSize: Int64(info.st_size),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1e9)
            )
        }

        /// `-<fileSize>-<mtime>`: identifies this version in file names. The mtime is written as its exact bit pattern.
        fileprivate var tag: String {
            "-\(fileSize)-\(String(modificationDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16))"
        }
    }

    struct Key: Hashable, Sendable {
        let path: String
        let fileSize: Int64
        let modificationDate: Date
        let bucket: Int

        /// Reads size and mtime for `path`; nil if the file is missing.
        static func current(path: String, bucket: Int) -> Key? {
            Version.current(path: path).map { Key(path: path, version: $0, bucket: bucket) }
        }

        var version: Version { Version(fileSize: fileSize, modificationDate: modificationDate) }

        /// The same version of the same photo, in another bucket.
        func inBucket(_ bucket: Int) -> Key {
            Key(path: path, fileSize: fileSize, modificationDate: modificationDate, bucket: bucket)
        }

        fileprivate var fileName: String { "\(bucket)\(version.tag).jpg" }
    }

    /// Default location: Caches/<bundle id>/Thumbnails/v1
    static let defaultDirectory: URL = defaultDirectory(in: userCachesDirectory)

    /// The user's Caches folder.
    static var userCachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
    }

    /// `<caches>/<bundle id>/Thumbnails/v1`.
    static func defaultDirectory(in caches: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        directory(in: caches.appendingPathComponent(bundleIdentifier ?? "com.phocasa.app", isDirectory: true))
    }

    /// `<folder>/Thumbnails/v1`: this version of the cache inside `folder`.
    static func directory(in folder: URL) -> URL {
        folder
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    static let jpegQuality = 0.8

    /// How long a persisted byte total is trusted without a full scan. It bounds whatever the running total can't
    /// see: a crash between a write and its total, or an older build adding files without updating it.
    static let byteTotalMaxAge: TimeInterval = 7 * 24 * 3600

    /// Paths whose re-keys are remembered for late stores (see `rekeyed`).
    private static let maxRekeyedPaths = 1024

    let directory: URL
    let byteLimit: Int
    /// Stores between automatic trims.
    let trimInterval: Int
    /// Decoded bytes that queued stores may hold before new stores are dropped.
    let maxPendingBytes: Int

    private let queue = DispatchQueue(label: "com.phocasa.thumbnail-disk-cache", qos: .utility)

    private let lock = NSLock()
    /// Paths with a queued `removeAll(forPath:)`, and how many. Reads of them miss until the removal has run.
    private var pendingRemovals: [String: Int] = [:]
    /// Decoded bytes held by queued stores.
    private var pendingStoreBytes = 0
    /// Full scans of the cache so far. Guarded by `lock`.
    private var scans = 0

    // Only touched on `queue`.
    /// Bytes on disk, from the persisted total or the last scan, plus what has been written and deleted since. nil
    /// until one of those is known.
    private var knownBytes: Int?
    /// When a full scan last confirmed `knownBytes` (a new, empty directory counts as confirmed).
    private var bytesVerifiedAt = Date.distantPast
    private var loadedByteTotal = false
    /// The open `byte-total` file, or -1.
    private var byteTotalFile: Int32 = -1
    private var storesSinceTrim = 0
    /// For each recently re-keyed path, the versions it was re-keyed from and the one it is now. A store queued after
    /// the re-key for one of the old versions (its decode read the file's size before the rewrite) has the same
    /// pixels, so it is filed under the new version.
    private var rekeyed: [String: (from: Set<Version>, to: Version)] = [:]

    init(directory: URL, byteLimit: Int = 1 << 30, trimInterval: Int = 100, maxPendingBytes: Int = 64 << 20) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.trimInterval = max(1, trimInterval)
        self.maxPendingBytes = maxPendingBytes
    }

    deinit {
        if byteTotalFile >= 0 { close(byteTotalFile) }
    }

    // MARK: - API

    /// The cached thumbnail for `key`, or nil. Synchronous; call it from the scheduler's work closure.
    ///
    /// With `maxPixelSize`, the cached image is decoded down so its long edge is at most that: a larger bucket
    /// serving a smaller request.
    func image(for key: Key, maxPixelSize: Int? = nil) -> CGImage? {
        if lock.withLock({ pendingRemovals[key.path] != nil }) {
            return nil
        }
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let image = Self.decode(data, maxPixelSize: maxPixelSize) else {
            queue.async { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        queue.async { _ = utimes(url.path, nil) }
        return image
    }

    /// Whether anything may be cached for `path`: its folder exists. One `access` call, so a photo that was never
    /// cached costs a caller that would try several buckets one failed call rather than several.
    func mayHaveThumbnails(forPath path: String) -> Bool {
        access(folderURL(forPath: path).path, F_OK) == 0
    }

    /// Encodes `image` as a JPEG and writes it on the utility queue. Images with transparency aren't stored, and
    /// neither is anything while the queue is backed up (the thumbnail is simply stored the next time it's decoded).
    func store(_ image: CGImage, for key: Key) {
        let bytes = image.bytesPerRow * image.height
        let accepted = lock.withLock {
            // One store is always allowed, however large.
            guard pendingStoreBytes == 0 || pendingStoreBytes + bytes <= maxPendingBytes else { return false }
            pendingStoreBytes += bytes
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            defer { lock.withLock { pendingStoreBytes -= bytes } }
            guard Self.isOpaque(image), let data = Self.encodeJPEG(image) else { return }
            write(data, for: key)
        }
    }

    /// `path` was rewritten from version `old` to `new` without changing its pixels: its thumbnails stored for exactly
    /// `old` are renamed to `new`, in every bucket. A bucket already stored for `new` is kept. Runs on the utility
    /// queue, in order with stores and removals; stores for `old` queued after it are filed under `new`.
    ///
    /// The caller must know the pixels are unchanged. `ImageLoader.rewritingMetadata(ofImageAt:_:)` checks that.
    func rekey(path: String, from old: Version, to new: Version) {
        guard old != new else { return }
        queue.async { [self] in
            loadByteTotalIfNeeded()
            let folder = folderURL(forPath: path)
            let oldSuffix = old.tag + ".jpg"
            var freed = 0
            for file in cachedFiles(in: folder) {
                let name = file.lastPathComponent
                guard name.hasSuffix(oldSuffix), let bucket = Int(name.dropLast(oldSuffix.count)) else { continue }
                let target = folder.appendingPathComponent("\(bucket)\(new.tag).jpg", isDirectory: false)
                if access(target.path, F_OK) == 0 {
                    // Decoded again since the rewrite: that copy is just as good.
                    let bytes = Self.allocatedSize(of: file)
                    if (try? FileManager.default.removeItem(at: file)) != nil { freed += bytes }
                } else {
                    _ = rename(file.path, target.path)
                }
            }
            if freed > 0, let known = knownBytes {
                knownBytes = max(0, known - freed)
                persistByteTotal()
            }
            rememberRekey(of: path, from: old, to: new)
        }
    }

    /// Deletes every bucket of `path`. Reads miss from now on; the files go on the utility queue.
    func removeAll(forPath path: String) {
        lock.withLock { pendingRemovals[path, default: 0] += 1 }
        queue.async { [self] in
            loadByteTotalIfNeeded()
            let folder = folderURL(forPath: path)
            let bytes = cachedFiles(in: folder).reduce(0) { $0 + Self.allocatedSize(of: $1) }
            if (try? FileManager.default.removeItem(at: folder)) != nil, let known = knownBytes {
                knownBytes = max(0, known - bytes)
                persistByteTotal()
            }
            // The pixels changed: nothing may follow an earlier re-key any more.
            rekeyed[path] = nil
            lock.withLock {
                let remaining = (pendingRemovals[path] ?? 1) - 1
                pendingRemovals[path] = remaining > 0 ? remaining : nil
            }
        }
    }

    /// LRU by access time until under `byteLimit` (down to 90% of it). Runs on the utility queue.
    func trimIfNeeded() {
        queue.async { [self] in trim() }
    }

    /// Blocks until everything queued so far has run. For tests and benchmarks.
    func waitForPendingWork() {
        queue.sync {}
    }

    /// Where `key`'s thumbnail lives.
    func fileURL(for key: Key) -> URL {
        folderURL(forPath: key.path).appendingPathComponent(key.fileName, isDirectory: false)
    }

    /// Where the running byte total is kept.
    var byteTotalURL: URL {
        directory.appendingPathComponent("byte-total", isDirectory: false)
    }

    /// How many times this instance has scanned the whole cache. For tests and benchmarks.
    var fullScanCount: Int {
        lock.withLock { scans }
    }

    /// The byte total this instance works with (after loading the persisted one), or nil if it isn't known yet. Waits
    /// for queued work. For tests and benchmarks.
    var knownByteTotal: Int? {
        queue.sync {
            loadByteTotalIfNeeded()
            return knownBytes
        }
    }

    // MARK: - Files (on `queue`)

    private func folderURL(forPath path: String) -> URL {
        let digest = Self.hexDigest(path)
        return directory
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private func write(_ data: Data, for stored: Key) {
        loadByteTotalIfNeeded()
        let key = currentKey(for: stored)
        let folder = folderURL(forPath: key.path)
        let url = folder.appendingPathComponent(key.fileName, isDirectory: false)
        let replaced = Self.allocatedSize(of: url)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // First store for this photo, or the folder was deleted from outside.
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                return
            }
        }
        var delta = Self.allocatedSize(of: url) - replaced
        // Older versions of this photo (it changed since they were stored) can never be read again.
        let versionSuffix = key.version.tag + ".jpg"
        for stale in cachedFiles(in: folder) where !stale.lastPathComponent.hasSuffix(versionSuffix) {
            let bytes = Self.allocatedSize(of: stale)
            if (try? FileManager.default.removeItem(at: stale)) != nil {
                delta -= bytes
            }
        }
        if delta != 0, let known = knownBytes {
            knownBytes = max(0, known + delta)
            persistByteTotal()
        }

        storesSinceTrim += 1
        if storesSinceTrim >= trimInterval {
            trim()
        }
    }

    /// `key`, or the version a re-key moved its version to.
    private func currentKey(for key: Key) -> Key {
        guard let entry = rekeyed[key.path], entry.from.contains(key.version) else { return key }
        return Key(path: key.path, version: entry.to, bucket: key.bucket)
    }

    private func rememberRekey(of path: String, from old: Version, to new: Version) {
        var from: Set<Version> = [old]
        if let earlier = rekeyed[path], earlier.to == old {
            from.formUnion(earlier.from)   // a chain: a rating, then a keyword
        } else if rekeyed.count >= Self.maxRekeyedPaths {
            // Only stores already queued behind a rewrite need this; losing it costs one decode at most.
            rekeyed.removeAll()
        }
        from.remove(new)
        rekeyed[path] = (from, new)
    }

    private func trim() {
        loadByteTotalIfNeeded()
        storesSinceTrim = 0
        if let knownBytes, knownBytes <= byteLimit {
            return
        }
        lock.withLock { scans += 1 }
        var files = scan()
        var total = files.reduce(0) { $0 + $1.bytes }
        if total > byteLimit {
            // Trim below the limit, so the next few stores don't each trigger a full scan.
            let target = byteLimit - byteLimit / 10
            files.sort { $0.used < $1.used }
            for file in files where total > target {
                // Already gone (deleted from outside) counts as deleted.
                try? FileManager.default.removeItem(at: file.url)
                // Drop the photo's folder once it's empty (rmdir fails on a folder that isn't).
                _ = rmdir(file.url.deletingLastPathComponent().path)
                total -= file.bytes
            }
        }
        knownBytes = total
        bytesVerifiedAt = Date()
        persistByteTotal()
    }

    private func scan() -> [(url: URL, bytes: Int, used: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return [] }
        var files: [(url: URL, bytes: Int, used: Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jpg",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.totalFileAllocatedSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        return files
    }

    private func cachedFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".jpg") }.map { folder.appendingPathComponent($0, isDirectory: false) }
    }

    private static func allocatedSize(of url: URL) -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return Int(info.st_blocks) * 512
    }

    // MARK: - Byte total (on `queue`)

    /// Once per instance, before the first change: a directory that doesn't exist yet holds nothing, and otherwise
    /// the persisted total is used if it is plausible. If not, `knownBytes` stays nil and the next trim scans.
    private func loadByteTotalIfNeeded() {
        guard !loadedByteTotal else { return }
        loadedByteTotal = true
        guard access(directory.path, F_OK) == 0 else {
            knownBytes = 0
            bytesVerifiedAt = Date()
            return
        }
        guard let data = try? Data(contentsOf: byteTotalURL),
              let record = Self.parseByteTotalRecord(data, now: Date()) else { return }
        knownBytes = record.bytes
        bytesVerifiedAt = record.verifiedAt
    }

    /// Overwrites the `byte-total` file in place (one `pwrite` of 40 bytes on a descriptor kept open). If the file was
    /// deleted from outside, it is recreated; if the directory is gone, nothing is written until a store recreates it.
    private func persistByteTotal() {
        guard let knownBytes else { return }
        if byteTotalFile >= 0 {
            var info = stat()
            if fstat(byteTotalFile, &info) != 0 || info.st_nlink == 0 {
                close(byteTotalFile)
                byteTotalFile = -1
            }
        }
        let record = Self.byteTotalRecord(bytes: knownBytes, verifiedAt: bytesVerifiedAt)
        if byteTotalFile < 0 {
            byteTotalFile = open(byteTotalURL.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
            guard byteTotalFile >= 0 else { return }
            // Whatever was there before may have been longer (a foreign or damaged file).
            _ = ftruncate(byteTotalFile, off_t(record.count))
        }
        record.withUnsafeBytes { buffer in
            _ = pwrite(byteTotalFile, buffer.baseAddress, buffer.count, 0)
        }
    }

    private static let byteTotalMagic: UInt64 = 0x4C41_544F_5442_4850   // "PHBTOTAL", little endian
    private static let byteTotalFormat: UInt64 = 1

    /// The `byte-total` file's contents: five little-endian 64-bit words (magic, format, bytes, the bit pattern of
    /// `verifiedAt`'s seconds since 1970, and a check word over the two), so a torn or foreign file is recognised.
    static func byteTotalRecord(bytes: Int, verifiedAt: Date) -> Data {
        let bytesWord = UInt64(bitPattern: Int64(bytes))
        let dateWord = verifiedAt.timeIntervalSince1970.bitPattern
        let words = [byteTotalMagic, byteTotalFormat, bytesWord, dateWord, ~(bytesWord ^ dateWord ^ byteTotalMagic)]
        var data = Data(capacity: words.count * 8)
        for word in words {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A persisted total worth trusting: intact, not negative, and confirmed by a scan within `byteTotalMaxAge`.
    private static func parseByteTotalRecord(_ data: Data, now: Date) -> (bytes: Int, verifiedAt: Date)? {
        guard data.count == 40 else { return nil }
        let words = (0..<5).map { i in
            data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) }
        }
        guard words[0] == byteTotalMagic, words[1] == byteTotalFormat,
              words[4] == ~(words[2] ^ words[3] ^ byteTotalMagic) else { return nil }
        let bytes = Int64(bitPattern: words[2])
        let verifiedAt = Date(timeIntervalSince1970: TimeInterval(bitPattern: words[3]))
        let age = now.timeIntervalSince(verifiedAt)
        // A date in the future (beyond clock adjustments) means the record can't be relied on either.
        guard bytes >= 0, age.isFinite, age <= byteTotalMaxAge, age >= -3600 else { return nil }
        return (Int(bytes), verifiedAt)
    }

    // MARK: - Encoding

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func hexDigest(_ path: String) -> String {
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(path.utf8)) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func decode(_ data: Data, maxPixelSize: Int?) -> CGImage? {
        // Every file this cache writes ends with the JPEG end-of-image marker. One cut short doesn't, and ImageIO
        // would happily decode it with a grey bottom half.
        guard data.count > 4, data[data.endIndex - 2] == 0xFF, data[data.endIndex - 1] == 0xD9,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        // The cached file is already upright and has no embedded thumbnail, so this decodes and scales its pixels.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// JPEG drops transparency. ImageIO gives HEIC thumbnails an alpha channel even when every pixel is opaque, so
    /// an image with an alpha channel is checked pixel by pixel.
    private static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return false }
        var alpha = [UInt8](repeating: 0, count: width * height)
        return alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Eight pixels at a time.
            let words = buffer.count / 8
            for i in 0..<words where buffer.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) != .max {
                return false
            }
            for i in (words * 8)..<buffer.count where buffer[i] != 0xFF {
                return false
            }
            return true
        }
    }
}

extension ThumbnailDiskCache.Key {
    init(path: String, version: ThumbnailDiskCache.Version, bucket: Int) {
        self.init(path: path, fileSize: version.fileSize, modificationDate: version.modificationDate, bucket: bucket)
    }
}
