import SwiftUI
import AppKit
import ImageIO

/// An image plus the EXIF orientation to apply when it is displayed.
///
/// The detail view decodes with `CGImageSourceCreateImageAtIndex`, the fastest (hardware) path, which ignores
/// orientation (spec §D1, §D2). Rotating the pixels on the CPU costs ~200 ms per photo, so the orientation is
/// carried alongside the bitmap and applied by `OrientedImage` as a view transform instead.
struct DisplayImage {
    let cgImage: CGImage
    /// `.up` for images that are already upright (edit-pipeline renders, RAW embedded previews).
    let orientation: CGImagePropertyOrientation

    init(cgImage: CGImage, orientation: CGImagePropertyOrientation) {
        self.cgImage = cgImage
        self.orientation = orientation
    }

    /// Wraps an already-upright `NSImage` (the edit pipeline's output). Reuses its backing `CGImage`
    /// without redrawing when the image is bitmap-backed, which the edit pipeline's images are.
    init?(nsImage: NSImage) {
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.init(cgImage: cg, orientation: .up)
    }

    /// The stored bitmap's size, before orientation.
    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    /// Size after orientation is applied. Points == pixels (the view scales it to fit).
    var orientedSize: CGSize {
        orientation.swapsWidthAndHeight
            ? CGSize(width: cgImage.height, height: cgImage.width)
            : CGSize(width: cgImage.width, height: cgImage.height)
    }

    /// Decoded size in memory, used as the cache cost.
    var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}

extension DisplayImage: Equatable {
    /// Identity, not pixel, equality: two values are equal when they wrap the same bitmap the same way.
    static func == (lhs: DisplayImage, rhs: DisplayImage) -> Bool {
        lhs.cgImage === rhs.cgImage && lhs.orientation == rhs.orientation
    }
}

extension CGImagePropertyOrientation {
    /// True for the quarter-turn orientations (EXIF 5–8), whose displayed width is the stored height.
    var swapsWidthAndHeight: Bool {
        switch self {
        case .left, .right, .leftMirrored, .rightMirrored: return true
        case .up, .upMirrored, .down, .downMirrored: return false
        @unknown default: return false
        }
    }
}

extension Image.Orientation {
    /// `CGImagePropertyOrientation` and `Image.Orientation` describe the same eight EXIF cases by the same names.
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Renders a `DisplayImage` upright, resizable, with the orientation applied at display time.
struct OrientedImage: View {
    let image: DisplayImage
    let interpolation: Image.Interpolation

    init(_ image: DisplayImage, interpolation: Image.Interpolation = .high) {
        self.image = image
        self.interpolation = interpolation
    }

    var body: some View {
        Image(decorative: image.cgImage, scale: 1, orientation: Image.Orientation(image.orientation))
            .resizable()
            .interpolation(interpolation)
    }
}
