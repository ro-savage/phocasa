import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// A rating or keyword write to a JPEG changes only its XMP (and, if it has one, its IPTC-IIM) segment. Everything
/// else a camera put in the file (Exif with its MakerNote, the MPF preview, other APPn and COM segments, the image
/// data) stays byte-identical (task 23, found by task 21). Built from generated JPEGs with hand-made segments.
final class MetadataJPEGPreservationTests: XCTestCase {

    private let service = MetadataService.shared
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-jpegkeep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    // MARK: - JPEG building blocks

    struct Segment: Equatable, CustomStringConvertible {
        let marker: UInt8
        let bytes: Data   // FF, marker, length, payload
        /// The identifier at the start of an APPn payload ("Exif", "MPF", an XMP namespace), or "" for others.
        var id: String {
            guard (0xE0...0xEF).contains(marker) else { return "" }
            return String(decoding: bytes.dropFirst(4).prefix(40).prefix { $0 != 0 }, as: UTF8.self)
        }
        var description: String { String(format: "FF%02X %@ %dB", marker, id, bytes.count) }
    }

    /// The marker segments between SOI and SOS, and the offset of SOS.
    static func header(_ d: Data) -> (segments: [Segment], sos: Int) {
        var segments: [Segment] = []
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF, d[i + 1] != 0xDA {
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            segments.append(Segment(marker: d[i + 1], bytes: Data(d[i..<(i + 2 + length)])))
            i += 2 + length
        }
        return (segments, i)
    }

    static func segment(_ marker: UInt8, _ payload: Data) -> Segment {
        let length = payload.count + 2
        return Segment(marker: marker, bytes: Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload)
    }

    static func assemble(_ segments: [Segment], tail: Data) -> Data {
        segments.reduce(Data([0xFF, 0xD8])) { $0 + $1.bytes } + tail
    }

    private static func makeImage(width: Int = 64, height: Int = 48) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 4, y: 4, width: width / 3, height: height / 2))
        return ctx.makeImage()!
    }

    static func imageIOJPEG(properties: [CFString: Any]? = nil, width: Int = 64, height: Int = 48) -> Data {
        let out = CFDataCreateMutable(nil, 0)!
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeImage(width: width, height: height), properties as CFDictionary?)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// A little-endian Exif APP1 with Make, DateTimeOriginal and a 64-byte MakerNote, as a camera writes one.
    static func exifWithMakerNote() -> Segment {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16) }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) -> [UInt8] { u16(tag) + u16(type) + u32(count) + u32(value) }
        var tiff: [UInt8] = [0x49, 0x49, 0x2A, 0x00] + u32(8)
        tiff += u16(2) + entry(0x010F, 2, 8, 38) + entry(0x8769, 4, 1, 46) + u32(0)           // IFD0 at 8, ends at 38
        tiff += Array("TestCam\u{0}".utf8)                                                      // 38..46
        tiff += u16(2) + entry(0x9003, 2, 20, 76) + entry(0x927C, 7, 64, 96) + u32(0)          // Exif IFD at 46, ends 76
        tiff += Array("2024:05:01 10:00:00\u{0}".utf8)                                          // 76..96
        tiff += (0..<64).map { UInt8(($0 * 37 + 11) & 0xFF) }                                   // MakerNote 96..160
        precondition(tiff.count == 160)
        return segment(0xE1, Data("Exif".utf8) + Data([0, 0]) + Data(tiff))
    }

    static let comment = segment(0xFE, Data("made by a test; keep me".utf8))
    static let vendorAPP9 = segment(0xE9, Data("AcmeCam".utf8) + Data([0]) + Data((0..<40).map { UInt8($0) }))

    /// A generated JPEG whose Exif is replaced by a camera-style one, plus a COM and an APP9 segment.
    static func cameraStyleJPEG(properties: [CFString: Any]? = nil) -> Data {
        let base = imageIOJPEG(properties: properties)
        let (segments, sos) = header(base)
        var out: [Segment] = []
        for s in segments where !(s.marker == 0xE1 && s.id == "Exif") {
            out.append(s)
            if s.marker == 0xE0 { out += [exifWithMakerNote(), comment, vendorAPP9] }
        }
        if !out.contains(exifWithMakerNote()) { out.insert(contentsOf: [exifWithMakerNote(), comment, vendorAPP9], at: 0) }
        return assemble(out, tail: base[sos...])
    }

    /// The byte range of the second image an MPF segment points at (offsets are relative to the MP header's endian
    /// field). Nil if there is no MPF segment or its entry doesn't fit the file.
    static func mpfSecondImage(_ d: Data) -> Range<Int>? {
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF, d[i + 1] != 0xDA {
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            if d[i + 1] == 0xE2, i + 8 <= d.count, d[(i + 4)..<(i + 8)] == Data("MPF".utf8) + Data([0]) {
                let h = i + 8, end = i + 2 + length
                guard h + 8 <= end else { return nil }
                let le = d[h] == 0x49
                func u(_ o: Int, _ n: Int) -> Int? {
                    guard h + o + n <= end else { return nil }
                    let bytes = (0..<n).map { Int(d[h + o + $0]) }
                    return (le ? bytes.reversed() : bytes).reduce(0) { $0 << 8 | $1 }
                }
                guard let ifd = u(4, 4), let count = u(ifd, 2) else { return nil }
                for k in 0..<count {
                    let e = ifd + 2 + k * 12
                    guard u(e, 2) == 0xB002, let entries = u(e + 8, 4),
                          let size = u(entries + 16 + 4, 4), let offset = u(entries + 16 + 8, 4) else { continue }
                    let start = h + offset
                    return start + size <= d.count ? start..<(start + size) : nil
                }
                return nil
            }
            i += 2 + length
        }
        return nil
    }

    /// Adds an MPF APP2 (big-endian, two entries) after the Exif segment and appends `second` after the primary image.
    static func withMPF(_ primary: Data, second: Data, xmpAfterMPF: Data? = nil) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v >> 16) + u16(v & 0xFFFF) }
        func mpf(primarySize: Int, secondOffset: Int) -> Segment {
            var t: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A] + u32(8)
            t += u16(3)
            t += u16(0xB000) + u16(7) + u32(4) + Array("0100".utf8)
            t += u16(0xB001) + u16(4) + u32(1) + u32(2)
            t += u16(0xB002) + u16(7) + u32(32) + u32(50)
            t += u32(0)
            t += u32(0x2003_0000) + u32(primarySize) + u32(0) + u16(0) + u16(0)
            t += u32(0x0001_0002) + u32(second.count) + u32(secondOffset) + u16(0) + u16(0)
            precondition(t.count == 82)
            return segment(0xE2, Data("MPF".utf8) + Data([0]) + Data(t))
        }
        let (segments, sos) = header(primary)
        func build(_ m: Segment) -> Data {
            var out: [Segment] = []
            for s in segments {
                out.append(s)
                if s.marker == 0xE1 && s.id == "Exif" {
                    out.append(m)
                    if let xmpAfterMPF { out.append(segment(0xE1, xmpAfterMPF)) }
                }
            }
            return assemble(out, tail: primary[sos...])
        }
        let placeholder = build(mpf(primarySize: 0, secondOffset: 0))
        let mpfStart = header(placeholder).segments.prefix { !($0.marker == 0xE2) }.reduce(2) { $0 + $1.bytes.count }
        let final = build(mpf(primarySize: placeholder.count, secondOffset: placeholder.count - (mpfStart + 8)))
        return final + second
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func readBack(_ url: URL) -> (rating: Int, keywords: [String]) {
        let m = service.readMetadata(from: url.path)
        return (m.rating, m.keywords)
    }

    /// Everything but the XMP and IPTC-IIM segments, which are the ones a metadata write may change.
    private func untouchable(_ d: Data) -> (segments: [Segment], tail: Data) {
        let (segments, sos) = Self.header(d)
        return (segments.filter { !($0.marker == 0xE1 && $0.id.hasPrefix("http://ns.adobe.com/x")) && $0.marker != 0xED },
                Data(d[sos...]))
    }

    // MARK: - Tests

    func testRatingWriteKeepsCameraExifMakerNoteAndOtherSegmentsByteIdentical() throws {
        let original = Self.cameraStyleJPEG()
        let jpg = try write(original, "cam.jpg")
        XCTAssertTrue(Self.header(original).segments.contains(Self.exifWithMakerNote()))

        service.writeMetadata(rating: 4, keywords: ["people:ann", "beach"], toImageAt: jpg.path)

        let after = try Data(contentsOf: jpg)
        let before = untouchable(original), now = untouchable(after)
        XCTAssertEqual(now.segments.map(\.id), before.segments.map(\.id), "no segment may be dropped or reordered")
        XCTAssertEqual(now.segments.first { $0.id == "Exif" }, Self.exifWithMakerNote(),
                       "the Exif segment, with its MakerNote, must stay byte-identical")
        XCTAssertTrue(now.segments.contains(Self.comment), "COM segment")
        XCTAssertTrue(now.segments.contains(Self.vendorAPP9), "vendor APP9 segment")
        XCTAssertEqual(now.segments, before.segments)
        XCTAssertEqual(now.tail, before.tail, "the image data is copied as is")
        XCTAssertEqual(readBack(jpg).rating, 4)
        XCTAssertEqual(Set(readBack(jpg).keywords), ["people:ann", "beach"])
    }

    func testRepeatedWritesKeepEverythingButTheXMP() throws {
        let original = Self.cameraStyleJPEG()
        let jpg = try write(original, "cam.jpg")

        for rating in [1, 5, 3, 3] {
            service.writeMetadata(rating: rating, keywords: ["k\(rating)"], toImageAt: jpg.path)
        }

        let after = try Data(contentsOf: jpg)
        XCTAssertEqual(untouchable(after).segments, untouchable(original).segments)
        XCTAssertEqual(untouchable(after).tail, untouchable(original).tail)
        XCTAssertEqual(Self.header(after).segments.filter { $0.id == "http://ns.adobe.com/xap/1.0/" }.count, 1)
        XCTAssertEqual(readBack(jpg).rating, 3)
        XCTAssertEqual(readBack(jpg).keywords, ["k3"])
    }

    func testIPTCKeywordsAreStillWrittenAndOtherIPTCDataKept() throws {
        let original = Self.cameraStyleJPEG(properties: [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["old"],
                                             kCGImagePropertyIPTCCaptionAbstract: "a caption kept in IIM"],
        ])
        XCTAssertTrue(Self.header(original).segments.contains { $0.marker == 0xED }, "fixture has an IPTC-IIM segment")
        let jpg = try write(original, "iptc.jpg")

        service.writeMetadata(rating: 2, keywords: ["x-new", "y"], toImageAt: jpg.path)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let iptc = try XCTUnwrap(props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords] as? [String], ["x-new", "y"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String, "a caption kept in IIM")
        let after = try Data(contentsOf: jpg)
        let app13 = try XCTUnwrap(Self.header(after).segments.first { $0.marker == 0xED })
        XCTAssertNotNil(app13.bytes.range(of: Data("x-new".utf8)), "the IIM keywords themselves are updated")
        XCTAssertEqual(untouchable(after).segments, untouchable(original).segments)
        XCTAssertEqual(readBack(jpg).rating, 2)
    }

    func testMPFPreviewStaysReachable() throws {
        let second = Self.imageIOJPEG(width: 32, height: 24)
        let original = Self.withMPF(Self.cameraStyleJPEG(), second: second)
        let range = try XCTUnwrap(Self.mpfSecondImage(original))
        XCTAssertEqual(original[range], second, "fixture: the MP entry points at the second image")
        let jpg = try write(original, "mpf.jpg")

        service.writeMetadata(rating: 5, keywords: ["k"], toImageAt: jpg.path)

        let after = try Data(contentsOf: jpg)
        let moved = try XCTUnwrap(Self.mpfSecondImage(after), "the MPF segment must survive")
        XCTAssertEqual(after[moved], second, "the MP entry must still point at the preview")
        XCTAssertEqual(untouchable(after).segments, untouchable(original).segments)
        XCTAssertEqual(readBack(jpg).rating, 5)
    }

    func testWriteToAJPEGThatAlreadyHasXMPUpdatesItInPlace() throws {
        let jpg = try write(Self.cameraStyleJPEG(), "twice.jpg")
        service.writeMetadata(rating: 1, keywords: ["a"], toImageAt: jpg.path)
        let first = try Data(contentsOf: jpg)
        let xmpIndex = try XCTUnwrap(Self.header(first).segments.firstIndex { $0.id == "http://ns.adobe.com/xap/1.0/" })

        service.writeMetadata(rating: 4, keywords: ["b"], toImageAt: jpg.path)

        let second = try Data(contentsOf: jpg)
        XCTAssertEqual(Self.header(second).segments.firstIndex { $0.id == "http://ns.adobe.com/xap/1.0/" }, xmpIndex,
                       "the XMP segment is replaced where it is")
        XCTAssertEqual(readBack(jpg).rating, 4)
        XCTAssertEqual(readBack(jpg).keywords, ["b"])
    }

    // MARK: - The splice itself

    private func packet(rating: Int = 3, keywords: [String] = ["k"]) throws -> Data {
        try XCTUnwrap(MetadataService.xmpPacket(rating: rating, keywords: keywords, updating: nil))
    }

    func testSpliceKeepsTheOriginalOutsideTheMetadataSegments() throws {
        let original = Self.cameraStyleJPEG()
        let spliced = try XCTUnwrap(MetadataService.spliceJPEGMetadata(original: original, xmp: try packet(), keywords: ["k"]))
        XCTAssertEqual(untouchable(spliced).segments, untouchable(original).segments)
        XCTAssertEqual(untouchable(spliced).tail, untouchable(original).tail)
    }

    func testSpliceRefusesLayoutsItCantHandleSafely() throws {
        let original = Self.cameraStyleJPEG()
        let good = try packet()

        // An XMP segment after the MPF one: replacing it would move the preview the MP offsets point at.
        let xmpPayload = Data("http://ns.adobe.com/xap/1.0/".utf8) + Data([0]) + Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="1"/></rdf:RDF></x:xmpmeta>
            """.utf8)
        let xmpAfterMPF = Self.withMPF(original, second: Self.imageIOJPEG(width: 16, height: 16), xmpAfterMPF: xmpPayload)
        XCTAssertNil(MetadataService.spliceJPEGMetadata(original: xmpAfterMPF, xmp: good, keywords: ["k"]))

        // Not a JPEG, a truncated segment, and an XMP packet too big for one segment.
        XCTAssertNil(MetadataService.spliceJPEGMetadata(original: Data("not a jpeg".utf8), xmp: good, keywords: ["k"]))
        XCTAssertNil(MetadataService.spliceJPEGMetadata(original: original.prefix(30), xmp: good, keywords: ["k"]))
        XCTAssertNil(MetadataService.spliceJPEGMetadata(original: original, xmp: Data(repeating: 0x20, count: 70_000),
                                                        keywords: ["k"]))

        // Extended XMP in the original.
        let (segments, sos) = Self.header(original)
        let extended = Self.segment(0xE1, Data("http://ns.adobe.com/xmp/extension/".utf8) + Data([0]) + Data(repeating: 0x41, count: 80))
        let withExtended = Self.assemble(segments + [extended], tail: original[sos...])
        XCTAssertNil(MetadataService.spliceJPEGMetadata(original: withExtended, xmp: good, keywords: ["k"]))
    }
}
