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
/// - **Reads** (`image(for:)`) are synchronous, on the caller's thread: the thumbnail scheduler's workers.
/// - **Writes** (encoding, stores, removals, LRU touches, trimming) run in order on one private utility queue.
/// - **LRU:** a hit sets the cached file's modification date to now. Every `trimInterval` stores, and on
///   `trimIfNeeded()`, the oldest files are deleted once the total passes `byteLimit`, down to 90% of it.
/// - **Outside deletion:** someone may empty the folder at any time (the user clearing `~/Library/Caches`). Anything
///   missing is a miss, stores recreate folders, and trimming ignores files that are already gone.
final class ThumbnailDiskCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let path: String
        let fileSize: Int64
        let modificationDate: Date
        let bucket: Int

        /// Reads size and mtime for `path`; nil if the file is missing.
        static func current(path: String, bucket: Int) -> Key? {
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            let mtime = info.st_mtimespec
            return Key(
                path: path, fileSize: Int64(info.st_size),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1e9),
                bucket: bucket
            )
        }

        /// `-<fileSize>-<mtime>`: identifies one version of the photo. The mtime is written as its exact bit pattern.
        fileprivate var versionTag: String {
            "-\(fileSize)-\(String(modificationDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16))"
        }

        fileprivate var fileName: String { "\(bucket)\(versionTag).jpg" }
    }

    /// Default location: Caches/<bundle id>/Thumbnails/v1
    static let defaultDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.phocasa.app", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }()

    static let jpegQuality = 0.8

    let directory: URL
    let byteLimit: Int
    /// Stores between automatic trims.
    let trimInterval: Int

    private let queue = DispatchQueue(label: "com.phocasa.thumbnail-disk-cache", qos: .utility)

    /// Paths with a queued `removeAll(forPath:)`, and how many. Reads of them miss until the removal has run.
    private let lock = NSLock()
    private var pendingRemovals: [String: Int] = [:]

    // Only touched on `queue`.
    /// Bytes on disk, from the last scan plus what has been written and deleted since. nil until the first scan.
    private var knownBytes: Int?
    private var storesSinceTrim = 0

    init(directory: URL, byteLimit: Int = 1 << 30, trimInterval: Int = 100) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.trimInterval = max(1, trimInterval)
    }

    // MARK: - API

    /// The cached thumbnail for `key`, or nil. Synchronous; call it from the scheduler's work closure.
    func image(for key: Key) -> CGImage? {
        if lock.withLock({ pendingRemovals[key.path] != nil }) {
            return nil
        }
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let image = Self.decode(data) else {
            queue.async { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        queue.async { _ = utimes(url.path, nil) }
        return image
    }

    /// Encodes `image` as a JPEG and writes it on the utility queue. Images with transparency aren't stored.
    func store(_ image: CGImage, for key: Key) {
        queue.async { [self] in
            guard Self.isOpaque(image), let data = Self.encodeJPEG(image) else { return }
            write(data, for: key)
        }
    }

    /// Deletes every bucket of `path`. Reads miss from now on; the files go on the utility queue.
    func removeAll(forPath path: String) {
        lock.withLock { pendingRemovals[path, default: 0] += 1 }
        queue.async { [self] in
            let folder = folderURL(forPath: path)
            let bytes = cachedFiles(in: folder).reduce(0) { $0 + Self.allocatedSize(of: $1) }
            if (try? FileManager.default.removeItem(at: folder)) != nil {
                knownBytes = knownBytes.map { max(0, $0 - bytes) }
            }
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

    // MARK: - Files (on `queue`)

    private func folderURL(forPath path: String) -> URL {
        let digest = Self.hexDigest(path)
        return directory
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private func write(_ data: Data, for key: Key) {
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
        for stale in cachedFiles(in: folder) where !stale.lastPathComponent.hasSuffix(key.versionTag + ".jpg") {
            let bytes = Self.allocatedSize(of: stale)
            if (try? FileManager.default.removeItem(at: stale)) != nil {
                delta -= bytes
            }
        }
        knownBytes = knownBytes.map { max(0, $0 + delta) }

        storesSinceTrim += 1
        if storesSinceTrim >= trimInterval {
            trim()
        }
    }

    private func trim() {
        storesSinceTrim = 0
        if let knownBytes, knownBytes <= byteLimit {
            return
        }
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

    private static func decode(_ data: Data) -> CGImage? {
        // Every file this cache writes ends with the JPEG end-of-image marker. One cut short doesn't, and ImageIO
        // would happily decode it with a grey bottom half.
        guard data.count > 4, data[data.endIndex - 2] == 0xFF, data[data.endIndex - 1] == 0xD9,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
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
