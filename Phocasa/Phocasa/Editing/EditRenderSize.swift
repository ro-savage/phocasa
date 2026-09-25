import Foundation
import CoreGraphics
import ImageIO

/// How large an edit render needs to be on screen.
///
/// At fit, the detail view draws an edit into `viewport` device pixels, so rendering more than that only matters once
/// the view zooms in. A render "fitted to a viewport" is `ImageEditingService`'s sized render (`maxSize`) with the
/// `maxSize` below, so its pixels are exactly the service's output for that size; a native render passes no `maxSize`.
enum EditRenderSize {
    /// The file's pixel size after its EXIF orientation, from its header (ImageIO; for camera RAW files this is the
    /// size `CIRAWFilter` decodes to). Nil if it can't be read. Reads the file: call it off the main thread.
    static func nativeSize(ofImageAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        return orientation.swapsWidthAndHeight
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// `nativeSize(ofImageAt:)` on a background queue.
    static func loadNativeSize(ofImageAt url: URL) async -> CGSize? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: nativeSize(ofImageAt: url))
            }
        }
    }

    /// The edited image's size when rendered at native resolution: the rotated photo's bounding box, then the crop,
    /// as `ImageEditingService` applies them.
    static func outputSize(native: CGSize, parameters: EditParameters) -> CGSize {
        let radians = abs(parameters.rotation) * .pi / 180
        let cosine = abs(cos(radians)), sine = abs(sin(radians))
        var width = native.width * cosine + native.height * sine
        var height = native.width * sine + native.height * cosine
        if let crop = parameters.cropRect, crop != .full {
            width *= CGFloat(crop.width)
            height *= CGFloat(crop.height)
        }
        return CGSize(width: width, height: height)
    }

    /// The `maxSize` whose render fills `viewport` at fit: the photo (`native`, oriented) scaled so that the edited
    /// output, after rotation and crop, fits the viewport. Rounded up, so the output is never short of the viewport.
    /// Nil when that takes the photo's full resolution or more: render natively then.
    static func fitMaxSize(native: CGSize, parameters: EditParameters, viewport: CGSize) -> CGSize? {
        guard native.width > 0, native.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let output = outputSize(native: native, parameters: parameters)
        guard output.width > 0, output.height > 0 else { return nil }
        let scale = min(viewport.width / output.width, viewport.height / output.height)
        guard scale < 1 else { return nil }
        // A hair below the exact product before rounding up, so 2894.0000001 stays 2894.
        func up(_ value: CGFloat) -> CGFloat { (value - 1e-6).rounded(.up) }
        return CGSize(width: up(native.width * scale), height: up(native.height * scale))
    }

    /// Whether a render made with `rendered` as its `maxSize` (nil: native) has the pixels of one made with `wanted`
    /// (nil: native), give or take a pixel of rounding.
    static func covers(_ rendered: CGSize?, _ wanted: CGSize?) -> Bool {
        guard let rendered else { return true }
        guard let wanted else { return false }
        return rendered.width + 1 >= wanted.width && rendered.height + 1 >= wanted.height
    }
}
