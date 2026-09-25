import Foundation
import ImageIO

/// XMP as flat `{namespace}name[index]/field` → value strings, to check that a rewrite through ImageIO kept every
/// property, and the patch an export makes to the properties that describe the pixels.
enum XMPProperties {
    struct Property: Hashable, Sendable {
        let namespace: String
        let prefix: String
        let name: String

        var key: String { "{\(namespace)}\(name)" }
        var path: String { "\(prefix):\(name)" }
    }

    static let rating = Property(namespace: "http://ns.adobe.com/xap/1.0/", prefix: "xmp", name: "Rating")
    static let subject = Property(namespace: "http://purl.org/dc/elements/1.1/", prefix: "dc", name: "subject")
    static let thumbnails = Property(namespace: "http://ns.adobe.com/xap/1.0/", prefix: "xmp", name: "Thumbnails")
    static let orientation = Property(namespace: "http://ns.adobe.com/tiff/1.0/", prefix: "tiff", name: "Orientation")
    static let imageWidth = Property(namespace: "http://ns.adobe.com/tiff/1.0/", prefix: "tiff", name: "ImageWidth")
    static let imageLength = Property(namespace: "http://ns.adobe.com/tiff/1.0/", prefix: "tiff", name: "ImageLength")
    static let pixelXDimension = Property(namespace: "http://ns.adobe.com/exif/1.0/", prefix: "exif", name: "PixelXDimension")
    static let pixelYDimension = Property(namespace: "http://ns.adobe.com/exif/1.0/", prefix: "exif", name: "PixelYDimension")
    static let colorSpace = Property(namespace: "http://ns.adobe.com/exif/1.0/", prefix: "exif", name: "ColorSpace")
    static let iccProfile = Property(namespace: "http://ns.adobe.com/photoshop/1.0/", prefix: "photoshop", name: "ICCProfile")

    /// Every leaf value, keyed by namespace (not prefix, which a rewrite may change), with its qualifiers. ImageIO's
    /// own `iio:` properties are left out.
    static func values(_ meta: CGImageMetadata) -> [String: String] {
        var out: [String: String] = [:]
        func key(_ tag: CGImageMetadataTag) -> String {
            "{\((CGImageMetadataTagCopyNamespace(tag) as String?) ?? "")}\((CGImageMetadataTagCopyName(tag) as String?) ?? "")"
        }
        func visit(_ tag: CGImageMetadataTag, path: String) {
            let value = CGImageMetadataTagCopyValue(tag)
            if let children = value as? [CGImageMetadataTag] {
                if children.isEmpty { out[path] = "[]" }
                for (i, child) in children.enumerated() { visit(child, path: "\(path)[\(i + 1)]") }
            } else if let fields = value as? [String: CGImageMetadataTag] {
                for field in fields.values { visit(field, path: "\(path)/\(key(field))") }
            } else {
                let qualifiers = (CGImageMetadataTagCopyQualifiers(tag) as? [CGImageMetadataTag] ?? [])
                    .map { "\(key($0))=\(CGImageMetadataTagCopyValue($0).map { "\($0)" } ?? "")" }.sorted()
                out[path] = "\(value.map { "\($0)" } ?? "")" + (qualifiers.isEmpty ? "" : " \(qualifiers)")
            }
        }
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { _, tag in
            // ImageIO's own bookkeeping (`iio:hasXMP`), added when it parses a packet, isn't the file's.
            if CGImageMetadataTagCopyNamespace(tag) as String? != imageIONamespace { visit(tag, path: key(tag)) }
            return true
        }
        return out
    }

    private static let imageIONamespace = "http://ns.apple.com/ImageIO/1.0/"

    /// Whether `rewritten` (nil: no properties) holds every value of `original`, apart from `changing` (a property
    /// and everything under it). Added values don't matter.
    static func keepsEverything(of original: CGImageMetadata, in rewritten: CGImageMetadata?, changing: Set<Property>) -> Bool {
        let before = values(original), after = rewritten.map(values) ?? [:]
        let changed = changing.map(\.key)
        return before.allSatisfy { path, value in
            changed.contains { path == $0 || path.hasPrefix($0 + "[") || path.hasPrefix($0 + "/") } || after[path] == value
        }
    }

    /// The properties an export changes: they describe the pixels, which are new and upright.
    static let pixelProperties: Set<Property> = [
        orientation, imageWidth, imageLength, pixelXDimension, pixelYDimension, colorSpace, iccProfile, thumbnails,
    ]

    enum Patch {
        /// Nothing in the packet describes the pixels.
        case unchanged
        case patched(Data)
        /// The packet can't be patched without risking its other properties.
        case refused
    }

    /// An XMP packet with its pixel properties made to match new upright `width`×`height` pixels: orientation 1, the
    /// new size, the colour space; the old ICC profile's name and any XMP thumbnail removed. Only properties already
    /// present change. Refused when ImageIO can't parse the packet and it names one of those properties, or when the
    /// rewrite would lose any other value.
    static func patchForNewPixels(_ packet: Data, width: Int, height: Int, sRGB: Bool) -> Patch {
        guard let original = CGImageMetadataCreateFromXMPData(packet as CFData),
              let meta = CGImageMetadataCreateMutableCopy(original) else {
            let text = String(decoding: packet, as: UTF8.self)
            return pixelProperties.contains { text.contains($0.name) } ? .refused : .unchanged
        }
        let newValues: [Property: String?] = [
            orientation: "1", imageWidth: "\(width)", imageLength: "\(height)",
            pixelXDimension: "\(width)", pixelYDimension: "\(height)", colorSpace: sRGB ? "1" : "65535",
            iccProfile: nil, thumbnails: nil,
        ]
        var changed = false
        for (property, value) in newValues {
            let path = property.path as CFString
            guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, path) else { continue }
            if let value {
                if CGImageMetadataTagCopyValue(tag).map({ "\($0)" }) == value { continue }
                guard CGImageMetadataSetValueWithPath(meta, nil, path, value as CFString) else { return .refused }
            } else {
                guard CGImageMetadataRemoveTagWithPath(meta, nil, path) else { return .refused }
            }
            changed = true
        }
        guard changed else { return .unchanged }
        guard let data = CGImageMetadataCreateXMPData(meta, nil) as Data?,
              let reparsed = CGImageMetadataCreateFromXMPData(data as CFData),
              keepsEverything(of: original, in: reparsed, changing: pixelProperties) else { return .refused }
        return .patched(data)
    }
}
