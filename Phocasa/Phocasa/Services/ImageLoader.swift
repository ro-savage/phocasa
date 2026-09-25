import AppKit
import ImageIO

final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.phocasa.imageloader", qos: .userInitiated, attributes: .concurrent)

    private init() {
        thumbnailCache.countLimit = 500
    }

    func loadThumbnail(for path: String, maxSize: CGFloat = 300) async -> NSImage? {
        // Bucket the size to nearest 100 to avoid excessive cache fragmentation
        let sizeBucket = Int(maxSize / 100) * 100
        let cacheKey = "\(path)_\(sizeBucket)" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                let url = URL(fileURLWithPath: path)
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]

                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }

                let nsImage = NSImage(cgImage: cgImage, size: NSSize(
                    width: CGFloat(cgImage.width),
                    height: CGFloat(cgImage.height)
                ))

                self.thumbnailCache.setObject(nsImage, forKey: cacheKey)
                continuation.resume(returning: nsImage)
            }
        }
    }

    func loadFullResolution(for path: String) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            queue.async {
                let url = URL(fileURLWithPath: path)
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
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

                let nsImage = NSImage(cgImage: cgImage, size: NSSize(
                    width: CGFloat(cgImage.width),
                    height: CGFloat(cgImage.height)
                ))
                continuation.resume(returning: nsImage)
            }
        }
    }

    func clearCache() {
        thumbnailCache.removeAllObjects()
    }

    func thumbnailJPEGData(for path: String, maxSize: CGFloat = 300) async -> Data? {
        let cacheKey = path as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            guard let cgImage = cached.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                let url = URL(fileURLWithPath: path)
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]

                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }

                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                continuation.resume(returning: data)
            }
        }
    }
}
