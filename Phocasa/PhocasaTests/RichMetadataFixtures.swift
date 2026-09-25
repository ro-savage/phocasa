import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

// Fixtures and checks for "never lose a photo's original metadata" (post-wave-3 task A): a camera-style JPEG with
// every kind of metadata Phocasa must keep, built by hand, and an Exif reader written independently of the app's.

// MARK: - TIFF (Exif) writer

/// One IFD entry, its value already encoded in the writer's byte order.
struct TIFFEntry {
    let tag: UInt16
    let type: UInt16
    let count: Int
    let data: [UInt8]
}

/// Builds a TIFF structure (an Exif APP1 payload after `Exif\0\0`) by hand, in either byte order.
final class TIFFWriter {
    let bigEndian: Bool
    private(set) var bytes: [UInt8]

    init(bigEndian: Bool = false) {
        self.bigEndian = bigEndian
        bytes = bigEndian ? [0x4D, 0x4D, 0x00, 0x2A] : [0x49, 0x49, 0x2A, 0x00]
        bytes += [0, 0, 0, 0]
        patch32(at: 4, 8)
    }

    func u16(_ v: UInt16) -> [UInt8] {
        bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    func u32(_ v: UInt32) -> [UInt8] {
        let b = [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return bigEndian ? b : b.reversed()
    }

    func ascii(_ tag: UInt16, _ s: String) -> TIFFEntry {
        let data = Array(s.utf8) + [0]
        return TIFFEntry(tag: tag, type: 2, count: data.count, data: data)
    }
    func short(_ tag: UInt16, _ values: UInt16...) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 3, count: values.count, data: values.flatMap(u16))
    }
    func long(_ tag: UInt16, _ values: UInt32...) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 4, count: values.count, data: values.flatMap(u32))
    }
    func rational(_ tag: UInt16, _ values: (UInt32, UInt32)...) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 5, count: values.count, data: values.flatMap { u32($0.0) + u32($0.1) })
    }
    func undefined(_ tag: UInt16, _ data: [UInt8]) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 7, count: data.count, data: data)
    }
    func byte(_ tag: UInt16, _ values: UInt8...) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 1, count: values.count, data: values)
    }

    struct WrittenIFD {
        let offset: Int
        /// Where each entry's value is: its inline value field, or its out-of-line data.
        let valueOffsets: [UInt16: Int]
        /// Each entry's 4-byte value field (for patching pointers).
        let valueFields: [UInt16: Int]
        let nextPointer: Int
    }

    /// Appends an IFD (entries sorted by tag) followed by its out-of-line values.
    func appendIFD(_ entries: [TIFFEntry]) -> WrittenIFD {
        if bytes.count % 2 == 1 { bytes.append(0) }
        let sorted = entries.sorted { $0.tag < $1.tag }
        let offset = bytes.count
        var dataOffset = offset + 2 + sorted.count * 12 + 4
        var valueOffsets: [UInt16: Int] = [:], valueFields: [UInt16: Int] = [:]
        var outOfLine: [UInt8] = []
        bytes += u16(UInt16(sorted.count))
        for entry in sorted {
            bytes += u16(entry.tag) + u16(entry.type) + u32(UInt32(entry.count))
            valueFields[entry.tag] = bytes.count
            if entry.data.count <= 4 {
                valueOffsets[entry.tag] = bytes.count
                bytes += entry.data + [UInt8](repeating: 0, count: 4 - entry.data.count)
            } else {
                valueOffsets[entry.tag] = dataOffset
                bytes += u32(UInt32(dataOffset))
                outOfLine += entry.data
                if entry.data.count % 2 == 1 { outOfLine.append(0) }
                dataOffset += entry.data.count + entry.data.count % 2
            }
        }
        let nextPointer = bytes.count
        bytes += [0, 0, 0, 0]
        bytes += outOfLine
        return WrittenIFD(offset: offset, valueOffsets: valueOffsets, valueFields: valueFields, nextPointer: nextPointer)
    }

    /// Appends raw bytes (word-aligned) and returns their offset.
    func append(_ data: [UInt8]) -> Int {
        if bytes.count % 2 == 1 { bytes.append(0) }
        let offset = bytes.count
        bytes += data
        return offset
    }

    func patch32(at offset: Int, _ value: Int) {
        let b = u32(UInt32(value))
        bytes.replaceSubrange(offset..<(offset + 4), with: b)
    }
}

// MARK: - JPEG segments

enum JPEGTestSegments {
    typealias Segment = MetadataJPEGPreservationTests.Segment

    static let xmpID = "http://ns.adobe.com/xap/1.0/"

    /// The codec part of an encoded JPEG: its non-APPn, non-COM header segments and everything from SOS on.
    static func codec(_ jpeg: Data) -> (segments: [Segment], tail: Data) {
        let (segments, sos) = MetadataJPEGPreservationTests.header(jpeg)
        return (segments.filter { !(0xE0...0xEF).contains($0.marker) && $0.marker != 0xFE }, Data(jpeg[sos...]))
    }

    static func segments(_ jpeg: Data) -> [Segment] {
        MetadataJPEGPreservationTests.header(jpeg).segments
    }

    static func exifTIFF(_ jpeg: Data) -> Data? {
        segments(jpeg).first { $0.marker == 0xE1 && $0.id == "Exif" }.map { Data($0.bytes.dropFirst(10)) }
    }

    static func xmpPacket(_ jpeg: Data) -> Data? {
        segments(jpeg).first { $0.marker == 0xE1 && $0.id == xmpID }.map { Data($0.bytes.dropFirst(4 + xmpID.utf8.count + 1)) }
    }

    static func app13(_ jpeg: Data) -> Data? {
        segments(jpeg).first { $0.marker == 0xED }.map { Data($0.bytes.dropFirst(4)) }
    }

    static func iccSegments(_ jpeg: Data) -> [Segment] {
        segments(jpeg).filter { $0.marker == 0xE2 && $0.id == "ICC_PROFILE" }
    }

    /// An APP2 ICC segment (one chunk) holding `profile`.
    static func icc(_ profile: Data) -> Segment {
        MetadataJPEGPreservationTests.segment(0xE2, Data("ICC_PROFILE".utf8) + Data([0, 1, 1]) + profile)
    }
}

// MARK: - Independent Exif reader (tests only)

/// Reads the few things the tests check in a TIFF structure, without the app's parser.
struct TestExifReader {
    let d: [UInt8]
    let le: Bool

    init?(_ tiff: Data) {
        d = [UInt8](tiff)
        guard d.count >= 8 else { return nil }
        if d[0] == 0x49 && d[1] == 0x49 { le = true } else if d[0] == 0x4D && d[1] == 0x4D { le = false } else { return nil }
    }

    func u16(_ o: Int) -> Int { le ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1]) }
    func u32(_ o: Int) -> Int { le ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }

    var ifd0: Int { u32(4) }
    func nextIFD(after ifd: Int) -> Int { u32(ifd + 2 + u16(ifd) * 12) }

    struct Entry { let tag: Int; let type: Int; let count: Int; let valueField: Int }

    func entries(_ ifd: Int) -> [Entry] {
        (0..<u16(ifd)).map { k in
            let e = ifd + 2 + k * 12
            return Entry(tag: u16(e), type: u16(e + 2), count: u32(e + 4), valueField: e + 8)
        }
    }

    func entry(_ tag: Int, in ifd: Int) -> Entry? { entries(ifd).first { $0.tag == tag } }

    static let typeSizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8]

    func bytes(of e: Entry) -> Data {
        let size = (Self.typeSizes[e.type] ?? 1) * e.count
        let start = size <= 4 ? e.valueField : u32(e.valueField)
        return Data(d[start..<(start + size)])
    }

    func number(_ tag: Int, in ifd: Int) -> Int? {
        guard let e = entry(tag, in: ifd) else { return nil }
        return e.type == 3 ? u16(e.valueField) : u32(e.valueField)
    }

    var exifIFD: Int? { number(0x8769, in: ifd0) }
    var makerNote: Data? { exifIFD.flatMap { entry(0x927C, in: $0) }.map(bytes(of:)) }
    var orientation: Int? { number(0x0112, in: ifd0) }
}

// MARK: - Photoshop IRB / IPTC-IIM builders

enum IRBTestData {
    /// An IIM dataset: 0x1C, record, dataset, big-endian length, data.
    static func dataset(_ record: UInt8, _ number: UInt8, _ value: [UInt8]) -> [UInt8] {
        [0x1C, record, number, UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value
    }
    static func dataset(_ record: UInt8, _ number: UInt8, _ text: String) -> [UInt8] {
        dataset(record, number, Array(text.utf8))
    }

    /// A Photoshop image resource block (empty name).
    static func block(_ id: UInt16, _ data: [UInt8]) -> [UInt8] {
        var b: [UInt8] = Array("8BIM".utf8) + [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0]
        b += [UInt8(data.count >> 24), UInt8(data.count >> 16 & 0xFF), UInt8(data.count >> 8 & 0xFF), UInt8(data.count & 0xFF)]
        b += data
        if data.count % 2 == 1 { b.append(0) }
        return b
    }

    /// The resources in an APP13 payload (after its length), as (id, data) in file order.
    static func resources(_ app13: Data) -> [(id: Int, data: Data)] {
        let p = [UInt8](app13)
        let header = Array("Photoshop 3.0\u{0}".utf8)
        guard p.starts(with: header) else { return [] }
        var i = header.count, out: [(Int, Data)] = []
        while i + 12 <= p.count, p[i..<(i + 4)].elementsEqual("8BIM".utf8) {
            let id = Int(p[i + 4]) << 8 | Int(p[i + 5])
            let nameLength = Int(p[i + 6])
            var j = i + 6 + 1 + nameLength
            if (1 + nameLength) % 2 == 1 { j += 1 }
            let size = Int(p[j]) << 24 | Int(p[j + 1]) << 16 | Int(p[j + 2]) << 8 | Int(p[j + 3])
            guard j + 4 + size <= p.count else { break }
            out.append((id, Data(p[(j + 4)..<(j + 4 + size)])))
            j += 4 + size + size % 2
            i = j
        }
        return out
    }

    /// The datasets in IIM data, as (record, number, value) in order.
    static func datasets(_ iim: Data) -> [(record: Int, number: Int, value: Data)] {
        let p = [UInt8](iim)
        var i = 0, out: [(Int, Int, Data)] = []
        while i + 5 <= p.count, p[i] == 0x1C {
            let length = Int(p[i + 3]) << 8 | Int(p[i + 4])
            guard i + 5 + length <= p.count else { break }
            out.append((Int(p[i + 1]), Int(p[i + 2]), Data(p[(i + 5)..<(i + 5 + length)])))
            i += 5 + length
        }
        return out
    }
}

// MARK: - The rich camera-style JPEG

/// A JPEG as a camera and then other apps leave it: a hand-built Exif (IFD0, Exif IFD with a MakerNote, GPS, Interop,
/// and IFD1 with a thumbnail), XMP from another app, an Adobe RGB ICC profile, a Photoshop APP13 (IPTC-IIM with a
/// custom dataset, a digest, a thumbnail resource and a custom resource), a vendor APP9, a COM segment, and an MPF
/// preview after the image.
struct RichJPEG {
    let data: Data
    let makerNote: Data
    let exifThumbnail: Data
    let mpfPreview: Data
    let irbThumbnail: Data
    /// The stored (unrotated) pixel size.
    let storedSize: CGSize

    static let xmp = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
        xmlns:exif="http://ns.adobe.com/exif/1.0/"
        xmlns:acme="http://example.com/acme/1.0/"
       xmp:CreatorTool="OtherApp 2.0"
       xmp:Rating="2"
       xmp:Label="Blue"
       photoshop:City="Paris"
       photoshop:ICCProfile="Adobe RGB (1998)"
       tiff:Orientation="6"
       exif:PixelXDimension="240"
       exif:PixelYDimension="160"
       acme:Flag="keep-me">
       <dc:creator><rdf:Seq><rdf:li>Ann Example</rdf:li></rdf:Seq></dc:creator>
       <dc:description><rdf:Alt><rdf:li xml:lang="x-default">A caption</rdf:li></rdf:Alt></dc:description>
       <dc:subject><rdf:Bag><rdf:li>old</rdf:li></rdf:Bag></dc:subject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    static let makerNoteBytes: [UInt8] = Array("TESTMAKER\u{0}".utf8) + (0..<190).map { UInt8(($0 * 37 + 11) & 0xFF) }

    static let iim: [UInt8] = IRBTestData.dataset(2, 0, [0, 4]) + IRBTestData.dataset(2, 5, "Title")
        + IRBTestData.dataset(2, 25, "old") + IRBTestData.dataset(2, 25, "older")
        + IRBTestData.dataset(2, 90, "Paris") + IRBTestData.dataset(2, 116, "(c) Ann")
        + IRBTestData.dataset(2, 120, "A caption") + IRBTestData.dataset(2, 200, [9, 8, 7, 6])

    static let resolutionResource: [UInt8] = [0, 0x48, 0, 0, 0, 1, 0, 1, 0, 0x48, 0, 0, 0, 1, 0, 1]
    static let customResource: [UInt8] = [1, 2, 3, 4, 5]

    static func app13(iim: [UInt8] = RichJPEG.iim, thumbnail: [UInt8]) -> MetadataJPEGPreservationTests.Segment {
        var payload: [UInt8] = Array("Photoshop 3.0\u{0}".utf8)
        payload += IRBTestData.block(0x03ED, resolutionResource)
        payload += IRBTestData.block(0x0404, iim)
        payload += IRBTestData.block(0x0425, [UInt8](repeating: 0xAB, count: 16))
        payload += IRBTestData.block(0x2710, customResource)
        payload += IRBTestData.block(0x040C, thumbnail)
        return MetadataJPEGPreservationTests.segment(0xED, Data(payload))
    }

    /// A hand-built Exif TIFF: orientation `orientation`, stored size `width`×`height` (as LONG, or SHORT with
    /// `shortDimensions`), and an IFD1 thumbnail.
    static func exifTIFF(width: Int, height: Int, orientation: UInt16, bigEndian: Bool, shortDimensions: Bool = false,
                         thumbnail: [UInt8]) -> (tiff: [UInt8], makerNote: Range<Int>) {
        let w = TIFFWriter(bigEndian: bigEndian)
        let ifd0 = w.appendIFD([
            w.ascii(0x010F, "TestCam"), w.ascii(0x0110, "Model X"), w.short(0x0112, orientation),
            w.rational(0x011A, (300, 1)), w.rational(0x011B, (300, 1)), w.short(0x0128, 2),
            w.ascii(0x0131, "FW 1.0"), w.ascii(0x0132, "2024:05:01 10:00:00"), w.ascii(0x013B, "Ann Example"),
            w.short(0x0213, 2), w.ascii(0x8298, "(c) Ann"), w.long(0x8769, 0), w.long(0x8825, 0),
        ])
        let dimensions = shortDimensions
            ? [w.short(0xA002, UInt16(width)), w.short(0xA003, UInt16(height))]
            : [w.long(0xA002, UInt32(width)), w.long(0xA003, UInt32(height))]
        let exif = w.appendIFD([
            w.rational(0x829A, (1, 250)), w.rational(0x829D, (28, 10)), w.short(0x8827, 200),
            w.undefined(0x9000, Array("0231".utf8)), w.ascii(0x9003, "2024:05:01 10:00:00"),
            w.ascii(0x9004, "2024:05:01 10:00:00"), w.ascii(0x9011, "+02:00"), w.ascii(0x9291, "123"),
            w.rational(0x920A, (50, 1)), w.undefined(0x927C, makerNoteBytes),
            w.undefined(0x9286, Array("ASCII\u{0}\u{0}\u{0}hello".utf8)), w.short(0xA001, 1),
            w.long(0xA005, 0), w.ascii(0xA431, "12345"), w.ascii(0xA434, "50mm F1.8"),
        ] + dimensions)
        w.patch32(at: ifd0.valueFields[0x8769]!, exif.offset)
        let interop = w.appendIFD([w.ascii(0x0001, "R98"), w.undefined(0x0002, Array("0100".utf8))])
        w.patch32(at: exif.valueFields[0xA005]!, interop.offset)
        let gps = w.appendIFD([
            w.byte(0x0000, 2, 3, 0, 0), w.ascii(0x0001, "N"), w.rational(0x0002, (48, 1), (51, 1), (2436, 100)),
            w.ascii(0x0003, "E"), w.rational(0x0004, (2, 1), (21, 1), (360, 100)), w.rational(0x0006, (35, 1)),
        ])
        w.patch32(at: ifd0.valueFields[0x8825]!, gps.offset)
        let ifd1 = w.appendIFD([
            w.short(0x0103, 6), w.rational(0x011A, (72, 1)), w.rational(0x011B, (72, 1)), w.short(0x0128, 2),
            w.long(0x0201, 0), w.long(0x0202, UInt32(thumbnail.count)),
        ])
        w.patch32(at: ifd0.nextPointer, ifd1.offset)
        let thumbnailOffset = w.append(thumbnail)
        w.patch32(at: ifd1.valueFields[0x0201]!, thumbnailOffset)
        let makerNoteStart = exif.valueOffsets[0x927C]!
        return (w.bytes, makerNoteStart..<(makerNoteStart + makerNoteBytes.count))
    }

    /// Pixels to encode: `EditTestImages`' test pattern at `width`×`height`.
    static func encodedPixels(width: Int, height: Int) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phocasa-rich-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try EditTestImages.writeJPEG(to: url, width: width, height: height, orientation: 1, detail: false)
        return try Data(contentsOf: url)
    }

    static func make(width: Int = 240, height: Int = 160, orientation: UInt16 = 6, bigEndian: Bool = false,
                     shortDimensions: Bool = false) throws -> RichJPEG {
        typealias T = MetadataJPEGPreservationTests
        let thumbnail = [UInt8](T.imageIOJPEG(width: 32, height: 24))
        let (tiff, makerNote) = exifTIFF(width: width, height: height, orientation: orientation, bigEndian: bigEndian,
                                         shortDimensions: shortDimensions, thumbnail: thumbnail)
        let exif = T.segment(0xE1, Data("Exif".utf8) + Data([0, 0]) + Data(tiff))
        let xmp = T.segment(0xE1, Data(JPEGTestSegments.xmpID.utf8) + Data([0]) + Data(Self.xmp.utf8))
        let adobeRGB = CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData()! as Data
        let irbThumbnail = [UInt8](repeating: 0x5A, count: 28) + [UInt8](T.imageIOJPEG(width: 20, height: 16))
        let codec = JPEGTestSegments.codec(try encodedPixels(width: width, height: height))
        let primary = T.assemble([exif, xmp, JPEGTestSegments.icc(adobeRGB), app13(thumbnail: irbThumbnail),
                                  T.vendorAPP9, T.comment] + codec.segments, tail: codec.tail)
        let preview = T.imageIOJPEG(width: 48, height: 32)
        let data = T.withMPF(primary, second: preview)
        return RichJPEG(data: data, makerNote: Data(tiff[makerNote]), exifThumbnail: Data(thumbnail),
                        mpfPreview: preview, irbThumbnail: Data(irbThumbnail),
                        storedSize: CGSize(width: width, height: height))
    }
}

// MARK: - The check: every original property kept

enum KeptMetadata {
    /// ImageIO properties that describe the pixels, so an export may change them.
    static let pixelProperties: [String: Set<String>] = [
        "{TIFF}": ["Orientation"],
        "{Exif}": ["PixelXDimension", "PixelYDimension", "ColorSpace"],
    ]
    /// Phocasa's own values, written from the photo's rating and tags.
    static let phocasaProperties: [String: Set<String>] = [
        "{IPTC}": ["Keywords", "StarRating"],
    ]
    /// XMP properties that describe the pixels, or are Phocasa's.
    static let changeableXMP: Set<String> = [
        "tiff:Orientation", "exif:PixelXDimension", "exif:PixelYDimension", "exif:ColorSpace", "photoshop:ICCProfile",
        "xmp:Rating", "dc:subject",
    ]

    static func properties(_ data: Data) -> [String: Any] {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
    }

    /// XMP property paths and values, recursively (`dc:creator[1]`, qualifiers included).
    static func xmpValues(_ packet: Data?) -> [String: String] {
        guard let packet, let meta = CGImageMetadataCreateFromXMPData(packet as CFData) else { return [:] }
        return xmpValues(meta)
    }

    static func xmpValues(_ meta: CGImageMetadata) -> [String: String] {
        var out: [String: String] = [:]
        func visit(_ tag: CGImageMetadataTag, path: String) {
            let qualifiers = (CGImageMetadataTagCopyQualifiers(tag) as? [CGImageMetadataTag] ?? [])
                .map { "\((CGImageMetadataTagCopyName($0) as String?) ?? "")=\(CGImageMetadataTagCopyValue($0).map { "\($0)" } ?? "")" }
            let value = CGImageMetadataTagCopyValue(tag)
            if let children = value as? [CGImageMetadataTag] {
                for (i, child) in children.enumerated() { visit(child, path: "\(path)[\(i + 1)]") }
            } else if let fields = value as? [String: CGImageMetadataTag] {
                for (name, child) in fields { visit(child, path: "\(path)/\(name)") }
            } else {
                out[path] = "\(value.map { "\($0)" } ?? "nil")\(qualifiers.isEmpty ? "" : " \(qualifiers.sorted())")"
            }
        }
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { path, tag in
            visit(tag, path: path as String)
            return true
        }
        return out
    }

    static func comparedDictionaries(_ properties: [String: Any]) -> [String] {
        properties.keys.filter { $0.hasPrefix("{") && $0 != "{JFIF}" && properties[$0] is [String: Any] }.sorted()
    }

    /// Asserts that `output`, written from `original` (a JPEG), keeps every original property with the same value,
    /// apart from those describing the pixels and Phocasa's rating and keywords, and that those match.
    static func assertKeeps(original: Data, output: Data, pixelSize: CGSize, rating: Int, keywords: [String],
                            readBack: MetadataService.PhotoMetadata?,
                            file: StaticString = #filePath, line: UInt = #line) {
        let before = properties(original), after = properties(output)
        XCTAssertFalse(after.isEmpty, "the output reads", file: file, line: line)

        // ImageIO's view: every dictionary, every key.
        for dictionary in comparedDictionaries(before) {
            let a = before[dictionary] as? [String: Any] ?? [:], b = after[dictionary] as? [String: Any] ?? [:]
            let allowed = (pixelProperties[dictionary] ?? []).union(phocasaProperties[dictionary] ?? [])
            for (key, value) in a where !allowed.contains(key) {
                XCTAssertEqual(b[key].map { "\($0)" }, "\(value)", "\(dictionary).\(key) must be kept",
                               file: file, line: line)
            }
        }

        // The pixel description matches the new pixels.
        XCTAssertEqual(after[kCGImagePropertyPixelWidth as String] as? Int, Int(pixelSize.width), file: file, line: line)
        XCTAssertEqual(after[kCGImagePropertyPixelHeight as String] as? Int, Int(pixelSize.height), file: file, line: line)
        XCTAssertEqual(after[kCGImagePropertyOrientation as String] as? Int ?? 1, 1, "the pixels are upright",
                       file: file, line: line)
        if let exif = after["{Exif}"] as? [String: Any], exif["PixelXDimension"] != nil {
            XCTAssertEqual(exif["PixelXDimension"] as? Int, Int(pixelSize.width), file: file, line: line)
            XCTAssertEqual(exif["PixelYDimension"] as? Int, Int(pixelSize.height), file: file, line: line)
        }

        // The MakerNote, byte for byte, and no Exif thumbnail of the old pixels.
        let originalExif = JPEGTestSegments.exifTIFF(original).flatMap(TestExifReader.init)
        let outputExif = JPEGTestSegments.exifTIFF(output).flatMap(TestExifReader.init)
        if let makerNote = originalExif?.makerNote {
            XCTAssertEqual(outputExif?.makerNote, makerNote, "MakerNote bytes", file: file, line: line)
        }
        if let exif = outputExif {
            XCTAssertEqual(exif.nextIFD(after: exif.ifd0), 0, "no IFD1 thumbnail of the old pixels", file: file, line: line)
        }
        if let exif = originalExif, exif.nextIFD(after: exif.ifd0) != 0,
           let offset = exif.number(0x0201, in: exif.nextIFD(after: exif.ifd0)),
           let length = exif.number(0x0202, in: exif.nextIFD(after: exif.ifd0)) {
            let thumbnail = Data(exif.d[offset..<(offset + length)])
            XCTAssertNil(output.range(of: thumbnail), "the old Exif thumbnail's bytes are gone", file: file, line: line)
        }
        XCTAssertFalse(JPEGTestSegments.segments(output).contains { $0.marker == 0xE2 && $0.id == "MPF" },
                       "no MPF preview of the old pixels", file: file, line: line)
        if let preview = MetadataJPEGPreservationTests.mpfSecondImage(original) {
            XCTAssertNil(output.range(of: original[preview]), "the old MPF preview's bytes are gone", file: file, line: line)
        }
        let originalICC = JPEGTestSegments.iccSegments(original)
        if !originalICC.isEmpty {
            XCTAssertNotEqual(JPEGTestSegments.iccSegments(output), originalICC, "the old pixels' colour profile is gone",
                              file: file, line: line)
        }

        // Every other APPn and COM segment, byte for byte.
        let handled: Set<String> = ["Exif", JPEGTestSegments.xmpID, "ICC_PROFILE", "MPF", "Adobe"]
        let outputSegments = JPEGTestSegments.segments(output)
        for segment in JPEGTestSegments.segments(original)
        where ((0xE0...0xEF).contains(segment.marker) || segment.marker == 0xFE) && segment.marker != 0xED
            && !handled.contains(segment.id) && !(segment.marker == 0xE0) {
            XCTAssertTrue(outputSegments.contains(segment), "\(segment) must be kept", file: file, line: line)
        }

        // Photoshop resources: every one but the IPTC data, its digest and thumbnails, byte for byte; in the IPTC
        // data, every dataset but the keywords.
        if let app13 = JPEGTestSegments.app13(original) {
            let outputResources = JPEGTestSegments.app13(output).map(IRBTestData.resources) ?? []
            for resource in IRBTestData.resources(app13) where ![0x0404, 0x0425, 0x0409, 0x040C].contains(resource.id) {
                XCTAssertTrue(outputResources.contains { $0.id == resource.id && $0.data == resource.data },
                              "Photoshop resource \(resource.id) must be kept", file: file, line: line)
            }
            XCTAssertFalse(outputResources.contains { [0x0409, 0x040C].contains($0.id) },
                           "no Photoshop thumbnail of the old pixels", file: file, line: line)
            if let iim = IRBTestData.resources(app13).first(where: { $0.id == 0x0404 })?.data {
                let kept = IRBTestData.datasets(iim).filter { !($0.record == 2 && $0.number == 25) }
                let now = (outputResources.first { $0.id == 0x0404 }?.data).map(IRBTestData.datasets) ?? []
                XCTAssertEqual(now.filter { !($0.record == 2 && $0.number == 25) }.map { "\($0.record):\($0.number)=\($0.value as NSData)" },
                               kept.map { "\($0.record):\($0.number)=\($0.value as NSData)" },
                               "IPTC datasets other than the keywords", file: file, line: line)
                XCTAssertEqual(Set(now.filter { $0.record == 2 && $0.number == 25 }.map { String(decoding: $0.value, as: UTF8.self) }),
                               Set(keywords), "the IPTC keywords are Phocasa's", file: file, line: line)
            }
        }

        // XMP from other apps: every property but the pixel ones and Phocasa's.
        let xmpBefore = xmpValues(JPEGTestSegments.xmpPacket(original))
        let xmpAfter = xmpValues(JPEGTestSegments.xmpPacket(output))
        for (path, value) in xmpBefore where !changeableXMP.contains(where: { path == $0 || path.hasPrefix($0 + "[") }) {
            XCTAssertEqual(xmpAfter[path], value, "XMP \(path) must be kept", file: file, line: line)
        }
        if xmpAfter["tiff:Orientation"] != nil {
            XCTAssertEqual(xmpAfter["tiff:Orientation"], "1", "XMP orientation", file: file, line: line)
        }

        // The capture date, and Phocasa's rating and keywords.
        let service = MetadataService.shared
        let dates = (try? [original, output].map { data -> Date? in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("phocasa-kept-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
            return service.readMetadata(from: url.path).captureDate
        }) ?? []
        XCTAssertNotNil(dates.first ?? nil, "fixture: the original has a capture date", file: file, line: line)
        XCTAssertEqual(dates.last ?? nil, dates.first ?? nil, "DateTimeOriginal is kept", file: file, line: line)
        if let readBack {
            XCTAssertEqual(readBack.rating, rating, "rating", file: file, line: line)
            XCTAssertEqual(Set(readBack.keywords), Set(keywords), "keywords", file: file, line: line)
        }
    }
}
