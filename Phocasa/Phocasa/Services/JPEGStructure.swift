import Foundation

/// A JPEG's marker segments between SOI and SOS, for the code that carries metadata segments from one JPEG to another
/// (`MetadataService`'s rating splice, `ExportMetadata`'s transplant).
enum JPEGStructure {
    struct Segment {
        enum Kind {
            case xmp, extendedXMP, iptc, mpf, exif, icc, adobe, jfif, jfxx, arot, other
            /// A run of 0xFF fill bytes before a marker (ITU T.81 B.1.1.2: any marker may be preceded by them).
            case fill
            /// A marker without a length (TEM, RSTn), which readers skip.
            case standalone
        }
        /// The marker; 0xFF for a run of fill bytes.
        let marker: UInt8
        /// The whole segment: FF, marker, length, payload (or the fill bytes, or FF and the standalone marker).
        let range: Range<Int>
        let kind: Kind

        /// Whether this is a marker segment with a length and a payload (not fill bytes or a standalone marker).
        var hasPayload: Bool { kind != .fill && kind != .standalone }
        /// The payload's range: after the marker and the 2-byte length (empty for fill bytes and standalone markers).
        var payload: Range<Int> { hasPayload ? (range.lowerBound + 4)..<range.upperBound : range.upperBound..<range.upperBound }
        var isAPPn: Bool { hasPayload && (0xE0...0xEF).contains(marker) }
        var isComment: Bool { hasPayload && marker == 0xFE }
    }

    static let xmpID = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
    static let extendedXMPID = Data("http://ns.adobe.com/xmp/extension/\u{0}".utf8)
    static let exifID = Data("Exif\u{0}\u{0}".utf8)
    static let iptcID = Data("Photoshop 3.0\u{0}".utf8)
    static let mpfID = Data("MPF\u{0}".utf8)

    /// The most a standard XMP packet may hold in its APP1 segment: 65,535 bytes of segment less the marker, the
    /// length and the 29-byte namespace (XMP Specification Part 3, §1.1.3.1).
    static let xmpPacketLimit = 65_502

    private static let ids: [(marker: UInt8, id: Data, kind: Segment.Kind)] = [
        (0xE1, xmpID, .xmp),
        (0xE1, extendedXMPID, .extendedXMP),
        (0xE1, Data("Exif\u{0}".utf8), .exif),
        (0xED, iptcID, .iptc),
        (0xE2, mpfID, .mpf),
        (0xE2, Data("ICC_PROFILE\u{0}".utf8), .icc),
        (0xEE, Data("Adobe".utf8), .adobe),
        (0xE0, Data("JFIF\u{0}".utf8), .jfif),
        (0xE0, Data("JFXX\u{0}".utf8), .jfxx),
        // Apple's restart-offset table, which ImageIO writes: an index into the image data.
        (0xEA, Data("AROT\u{0}\u{0}".utf8), .arot),
    ]

    /// The segments between SOI and SOS, and where SOS starts (its marker, after any fill bytes before it). Runs of
    /// 0xFF fill bytes and standalone markers (TEM, RSTn) are kept as segments of their own, so a rewrite can keep
    /// them byte for byte. Nil for anything else: no SOI, other bytes between segments, a marker that can't be in a
    /// header (SOI, EOI, 0xFF00), a length that runs past the end. Code that rewrites metadata leaves those alone.
    static func header(_ d: Data) -> (segments: [Segment], sos: Int)? {
        let start = d.startIndex
        guard d.count >= 4, d[start] == 0xFF, d[start + 1] == 0xD8 else { return nil }
        var segments: [Segment] = []
        var i = start + 2
        while true {
            guard i + 1 < d.endIndex, d[i] == 0xFF else { return nil }
            // Fill bytes: every 0xFF but the one the marker follows.
            var j = i
            while j + 1 < d.endIndex, d[j + 1] == 0xFF { j += 1 }
            if j > i { segments.append(Segment(marker: 0xFF, range: i..<j, kind: .fill)) }
            guard j + 1 < d.endIndex else { return nil }
            let marker = d[j + 1]
            if marker == 0xDA { return (segments, j) }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                segments.append(Segment(marker: marker, range: j..<(j + 2), kind: .standalone))
                i = j + 2
                continue
            }
            guard marker != 0x00, marker != 0xD8, marker != 0xD9, j + 4 <= d.endIndex else { return nil }
            let length = Int(d[j + 2]) << 8 | Int(d[j + 3])
            guard length >= 2, j + 2 + length <= d.endIndex else { return nil }
            let payload = d[(j + 4)..<(j + 2 + length)]
            let kind = ids.first { $0.marker == marker && payload.starts(with: $0.id) }?.kind ?? .other
            segments.append(Segment(marker: marker, range: j..<(j + 2 + length), kind: kind))
            i = j + 2 + length
        }
    }

    /// A segment with this marker and payload, or nil if the payload is too long for one segment.
    static func segment(_ marker: UInt8, payload: Data) -> Data? {
        let length = payload.count + 2
        guard length <= 0xFFFF else { return nil }
        return Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload
    }

    /// A standard XMP APP1 segment holding `packet`, or nil if the packet is over `xmpPacketLimit`.
    static func xmpSegment(_ packet: Data) -> Data? {
        guard packet.count <= xmpPacketLimit else { return nil }
        return segment(0xE1, payload: xmpID + packet)
    }

    /// Whether `d` starts like a JPEG.
    static func isJPEG(_ d: Data) -> Bool {
        d.count >= 3 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xD8 && d[d.startIndex + 2] == 0xFF
    }
}
