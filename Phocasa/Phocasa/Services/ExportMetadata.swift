import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Carries a photo's original metadata into an export or a baked edit: a JPEG of new, upright pixels (the user's rule:
/// never lose a photo's original metadata; CLAUDE.md, "Metadata").
///
/// - **From a JPEG** (the file a baked edit or "Replace existing JPG" overwrites, or a pair's camera JPG): its APPn
///   and COM segments are carried over byte for byte, in order, around the new image data. Only what describes the
///   old pixels changes: in the Exif, orientation 1, the new size, the colour space, and the IFD1 thumbnail unlinked
///   and zeroed (`ExifPatch`; the MakerNote is never touched); the same properties in the XMP; the old ICC profile,
///   MPF preview images, Adobe APP14 segment, JFIF thumbnail, JFXX thumbnails and Photoshop thumbnail resources go.
///   The encoder's own colour profile and codec segments describe the new pixels.
/// - **From anything else** (a RAW): ImageIO's metadata tree of the source, with orientation 1, the new size and the
///   colour space, and without the tags that describe the source's own pixel encoding, is merged onto the new JPEG
///   without re-encoding it. ImageIO has no MakerNote to write, so that stays in the RAW.
///
/// Phocasa's rating and keywords aren't written here: the export then writes them like any rating write.
enum ExportMetadata {
    /// `encoded`, a JPEG ImageIO just encoded from the new pixels (with no metadata of its own), with the metadata of
    /// the photo at `source`. Nil when that can't be done without losing some of it; the caller must then not
    /// replace anyone's photo with the export.
    static func jpeg(encoded: Data, metadataFrom source: URL) -> Data? {
        guard let encodedSource = CGImageSourceCreateWithData(encoded as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(encodedSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // No embedded profile means sRGB.
        let sRGB = (properties[kCGImagePropertyProfileName] as? String).map { $0.contains("sRGB") } ?? true

        let composed: Data?
        if let data = try? Data(contentsOf: source, options: .mappedIfSafe), JPEGStructure.isJPEG(data) {
            composed = transplant(from: data, onto: encoded, width: width, height: height, sRGB: sRGB)
        } else {
            composed = merge(from: source, onto: encodedSource, width: width, height: height, sRGB: sRGB)
        }
        guard let composed, reads(composed, width: width, height: height) else { return nil }
        return composed
    }

    /// Whether ImageIO reads `data` as a complete, upright image of this size.
    private static func reads(_ data: Data, width: Int, height: Int) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyPixelWidth] as? Int == width
            && properties[kCGImagePropertyPixelHeight] as? Int == height
            && (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    }

    // MARK: - From a JPEG

    private static func transplant(from original: Data, onto encoded: Data, width: Int, height: Int, sRGB: Bool) -> Data? {
        guard let (segments, _) = JPEGStructure.header(original),
              let (encodedSegments, encodedSOS) = JPEGStructure.header(encoded) else { return nil }
        // What describes the new pixels comes from the encoder.
        let encodedICC = encodedSegments.filter { $0.kind == .icc }.map { encoded[$0.range] }
        let encodedAdobe = encodedSegments.filter { $0.kind == .adobe }.map { encoded[$0.range] }
        let codec = encodedSegments.filter { !$0.isAPPn && !$0.isComment }.map { encoded[$0.range] }

        var out = Data([0xFF, 0xD8])
        var placedICC = false
        func placeICC() {
            guard !placedICC else { return }
            placedICC = true
            encodedICC.forEach { out += $0 }
        }
        for (index, segment) in segments.enumerated() {
            guard segment.isAPPn || segment.isComment else { continue }   // the old pixels' codec segments
            // Without an ICC segment of its own, the encoder's goes after the leading APP0/APP1 segments.
            if !placedICC, segment.marker != 0xE0, segment.marker != 0xE1,
               !segments[index...].contains(where: { $0.kind == .icc }) {
                placeICC()
            }
            switch segment.kind {
            case .exif:
                let header = JPEGStructure.exifID.count
                guard segment.payload.count > header,
                      let tiff = ExifPatch.patched(original[(segment.payload.lowerBound + header)..<segment.payload.upperBound],
                                                   pixelWidth: width, pixelHeight: height, sRGB: sRGB),
                      let patched = JPEGStructure.segment(0xE1, payload: JPEGStructure.exifID + tiff) else { return nil }
                out += patched
            case .xmp:
                let header = JPEGStructure.xmpID.count
                let packet = original[(segment.payload.lowerBound + header)..<segment.payload.upperBound]
                switch XMPProperties.patchForNewPixels(Data(packet), width: width, height: height, sRGB: sRGB) {
                case .unchanged:
                    out += original[segment.range]
                case .patched(let xmp):
                    guard let patched = JPEGStructure.segment(0xE1, payload: JPEGStructure.xmpID + xmp) else { return nil }
                    out += patched
                case .refused:
                    return nil
                }
            case .iptc:
                guard let payload = PhotoshopIRB.removingThumbnails(from: original[segment.payload]),
                      let patched = JPEGStructure.segment(0xED, payload: payload) else { return nil }
                out += patched
            case .jfif:
                out += jfifWithoutThumbnail(original[segment.range])
            case .icc:
                placeICC()
            case .mpf, .adobe, .jfxx:
                break
            case .extendedXMP, .other:
                out += original[segment.range]
            }
        }
        placeICC()
        encodedAdobe.forEach { out += $0 }
        codec.forEach { out += $0 }
        out += encoded[encodedSOS...]
        return out
    }

    /// A JFIF APP0 segment without its thumbnail (JFIF 1.02: 2-byte version, units, 2-byte densities, then the
    /// thumbnail's size and RGB pixels).
    private static func jfifWithoutThumbnail(_ segment: Data) -> Data {
        let s = Data(segment)
        let fixed = 4 + 5 + 7   // marker and length, "JFIF\0", version to densities
        guard s.count >= fixed + 2, s[fixed] != 0 || s[fixed + 1] != 0 || s.count > fixed + 2 else { return s }
        return JPEGStructure.segment(0xE0, payload: s[4..<fixed] + Data([0, 0])) ?? s
    }

    // MARK: - From a RAW or another format

    /// Tags describing how the source's own pixels are stored, which don't apply to the new JPEG.
    private static let sourceEncodingTags = [
        "tiff:Compression", "tiff:PhotometricInterpretation", "tiff:BitsPerSample", "tiff:SamplesPerPixel",
        "tiff:PlanarConfiguration", "tiff:ImageWidth", "tiff:ImageLength", "tiff:YCbCrSubSampling",
        "tiff:YCbCrPositioning", "exif:CompressedBitsPerPixel", "exif:CFAPattern", "xmp:Thumbnails",
    ]

    private static func merge(from source: URL, onto encodedSource: CGImageSource, width: Int, height: Int,
                              sRGB: Bool) -> Data? {
        guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let meta = CGImageSourceCopyMetadataAtIndex(sourceImage, 0, nil).flatMap(CGImageMetadataCreateMutableCopy)
            ?? CGImageMetadataCreateMutable()
        for path in sourceEncodingTags where CGImageMetadataCopyTagWithPath(meta, nil, path as CFString) != nil {
            guard CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString) else { return nil }
        }
        let values: [(CFString, CFString, Any)] = [
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, width),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, height),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifColorSpace, sRGB ? 1 : 0xFFFF),
        ]
        for (dictionary, key, value) in values {
            guard CGImageMetadataSetValueMatchingImageProperty(meta, dictionary, key, value as CFTypeRef) else { return nil }
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 0, nil),
              CGImageDestinationCopyImageSource(destination, encodedSource, [
                  kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false,
              ] as CFDictionary, nil) else { return nil }
        return output as Data
    }
}
