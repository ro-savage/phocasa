import Foundation

/// A JPEG's marker segments between SOI and SOS, for the code that carries metadata segments from one JPEG to another
/// (`MetadataService`'s rating splice, `ExportMetadata`'s transplant).
enum JPEGStructure {
    struct Segment {
        enum Kind { case xmp, extendedXMP, iptc, mpf, exif, icc, adobe, jfif, jfxx, other }
        let marker: UInt8
        /// The whole segment: FF, marker, length, payload.
        let range: Range<Int>
        let kind: Kind

        /// The payload's range: after the marker and the 2-byte length.
        var payload: Range<Int> { (range.lowerBound + 4)..<range.upperBound }
        var isAPPn: Bool { (0xE0...0xEF).contains(marker) }
        var isComment: Bool { marker == 0xFE }
    }

    static let xmpID = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
    static let exifID = Data("Exif\u{0}\u{0}".utf8)
    static let iptcID = Data("Photoshop 3.0\u{0}".utf8)

    private static let ids: [(marker: UInt8, id: Data, kind: Segment.Kind)] = [
        (0xE1, xmpID, .xmp),
        (0xE1, Data("http://ns.adobe.com/xmp/extension/\u{0}".utf8), .extendedXMP),
        (0xE1, Data("Exif\u{0}".utf8), .exif),
        (0xED, iptcID, .iptc),
        (0xE2, Data("MPF\u{0}".utf8), .mpf),
        (0xE2, Data("ICC_PROFILE\u{0}".utf8), .icc),
        (0xEE, Data("Adobe".utf8), .adobe),
        (0xE0, Data("JFIF\u{0}".utf8), .jfif),
        (0xE0, Data("JFXX\u{0}".utf8), .jfxx),
    ]

    /// The segments between SOI and SOS, and where SOS starts. Nil for anything unusual (no SOI, fill bytes,
    /// standalone markers, a length that runs past the end): code that rewrites metadata leaves those files alone.
    static func header(_ d: Data) -> (segments: [Segment], sos: Int)? {
        let start = d.startIndex
        guard d.count >= 4, d[start] == 0xFF, d[start + 1] == 0xD8 else { return nil }
        var segments: [Segment] = []
        var i = start + 2
        while true {
            guard i + 4 <= d.endIndex, d[i] == 0xFF else { return nil }
            let marker = d[i + 1]
            if marker == 0xDA { return (segments, i) }
            guard marker != 0xFF, marker != 0x00, marker != 0x01, !(0xD0...0xD9).contains(marker) else { return nil }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            guard length >= 2, i + 2 + length <= d.endIndex else { return nil }
            let payload = d[(i + 4)..<(i + 2 + length)]
            let kind = ids.first { $0.marker == marker && payload.starts(with: $0.id) }?.kind ?? .other
            segments.append(Segment(marker: marker, range: i..<(i + 2 + length), kind: kind))
            i += 2 + length
        }
    }

    /// A segment with this marker and payload, or nil if the payload is too long for one segment.
    static func segment(_ marker: UInt8, payload: Data) -> Data? {
        let length = payload.count + 2
        guard length <= 0xFFFF else { return nil }
        return Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload
    }

    /// Whether `d` starts like a JPEG.
    static func isJPEG(_ d: Data) -> Bool {
        d.count >= 3 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xD8 && d[d.startIndex + 2] == 0xFF
    }
}
