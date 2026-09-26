import XCTest
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
@testable import Phocasa

// Task D, TIFF: the rating and keywords go inside a TIFF (IFD0's XMP, tag 700, and its IPTC, tags 33723 and 34377),
// only ever added: no existing byte moves, and only the header's IFD0 offset, the old XMP's bytes and the IPTC bytes
// (when they're rewritten in place) change. Checked on a hand-built rich TIFF in both byte orders, with an independent
// IFD walker, ImageIO's view of the result, and the decoded pixels.

// MARK: - Independent TIFF walker (tests only)

/// Walks a classic TIFF by hand, without the app's parser: every IFD reachable from the header by its path, each
/// entry's value bytes, and each image's strips.
struct TIFFTestWalker {
    let d: [UInt8]
    let le: Bool

    init?(_ data: Data) {
        d = [UInt8](data)
        guard d.count >= 8 else { return nil }
        if d[0] == 0x49, d[1] == 0x49 { le = true } else if d[0] == 0x4D, d[1] == 0x4D { le = false } else { return nil }
    }

    func u16(_ o: Int) -> Int { le ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1]) }
    func u32(_ o: Int) -> Int { le ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }

    struct Entry { let tag: Int; let type: Int; let count: Int; let position: Int }

    static let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]

    var ifd0: Int { u32(4) }

    func entries(_ ifd: Int) -> [Entry] {
        (0..<u16(ifd)).map { k in
            let p = ifd + 2 + 12 * k
            return Entry(tag: u16(p), type: u16(p + 2), count: u32(p + 4), position: p)
        }
    }

    func next(_ ifd: Int) -> Int { u32(ifd + 2 + 12 * u16(ifd)) }
    func entry(_ tag: Int, in ifd: Int) -> Entry? { entries(ifd).first { $0.tag == tag } }

    /// Where the value is: its inline field, or the out-of-line bytes it points at.
    func range(_ e: Entry) -> Range<Int> {
        let size = (Self.sizes[e.type] ?? 1) * e.count
        let start = size <= 4 ? e.position + 8 : u32(e.position + 8)
        return start..<(start + size)
    }

    func value(_ e: Entry) -> Data { Data(d[range(e)]) }

    func numbers(_ e: Entry) -> [Int] {
        let r = range(e), size = Self.sizes[e.type] ?? 1
        return stride(from: r.lowerBound, to: r.upperBound, by: size).map { size == 2 ? u16($0) : u32($0) }
    }

    /// Every IFD reachable from the header, by path: pages `p0`, `p1`…, and below each `/sub0`…, `/exif`, `/gps`,
    /// `/interop`.
    func ifds() -> [String: Int] {
        var out: [String: Int] = [:]
        func visit(_ path: String, _ ifd: Int) {
            guard out.count < 100, ifd > 0, !out.values.contains(ifd) else { return }
            out[path] = ifd
            for e in entries(ifd) {
                switch e.tag {
                case 330: for (i, o) in numbers(e).enumerated() { visit("\(path)/sub\(i)", o) }
                case 34665: visit("\(path)/exif", numbers(e)[0])
                case 34853: visit("\(path)/gps", numbers(e)[0])
                case 40965: visit("\(path)/interop", numbers(e)[0])
                default: break
                }
            }
        }
        var page = ifd0, i = 0
        while page != 0, i < 100, !out.values.contains(page) {
            visit("p\(i)", page)
            page = next(page)
            i += 1
        }
        return out
    }

    /// Each IFD's values by tag, and its strips' bytes under the pseudo-tag -1.
    func contents() -> [String: [Int: Data]] {
        ifds().mapValues { ifd in
            var values: [Int: Data] = [:]
            for e in entries(ifd) { values[e.tag] = value(e) }
            if let offsets = entry(273, in: ifd), let counts = entry(279, in: ifd) {
                values[-1] = zip(numbers(offsets), numbers(counts)).reduce(into: Data()) { $0 += d[$1.0..<($1.0 + $1.1)] }
            }
            return values
        }
    }

    /// IFD0's value for `tag`, and where it is.
    func ifd0Value(_ tag: Int) -> (range: Range<Int>, data: Data, type: Int, count: Int)? {
        entry(tag, in: ifd0).map { (range($0), value($0), $0.type, $0.count) }
    }
}

// MARK: - The rich TIFF

/// A TIFF as a camera, a scanner and other apps leave one: IFD0 with three strips of uncompressed RGB pixels and the
/// descriptive tags (Make, Model, Software, DateTime, Artist, Copyright, ImageDescription), an Exif IFD with a
/// MakerNote whose data points at maker data elsewhere in the file by absolute offset, an Interop IFD, a GPS IFD, an
/// Adobe RGB ICC profile (34675), IPTC-IIM (33723, LONG, with custom datasets), Photoshop image resources (34377: the
/// IPTC, its digest, a custom resource), XMP from another app (700), a SubIFD preview and a second page.
struct RichTIFF {
    let data: Data
    let makerNote: Range<Int>
    let makerData: Data

    struct Options {
        var bigEndian = false
        /// IFD0's XMP packet, or nil for none.
        var xmp: String? = RichTIFF.otherAppXMP(padding: 0)
        var iim: [UInt8] = RichJPEG.iim
        var iptc = true
        var photoshop = true
        /// Zero bytes after the IIM in 33723 (beyond the LONG padding).
        var iptcSlack = 0
        /// Zero bytes after the IIM in 34377's IPTC resource.
        var photoshopIPTCSlack = 0
        /// 34377's IPTC resource holds 33723's bytes exactly (both copies identical).
        var mirroredIPTC = false
        /// Extra Photoshop resources, before the custom one.
        var extraResources: [UInt8] = []
        /// 34377 holds an IPTC resource (without one, its digest is 33723's).
        var photoshopIPTC = true
        /// The digest resource's data, in place of the MD5 of the IPTC.
        var digest: [UInt8]? = nil
        /// An empty GPS IFD (no entries).
        var emptyGPS = false
        var extraIFD0: (TIFFWriter) -> [TIFFEntry] = { _ in [] }
    }

    static let makerDataBytes: [UInt8] = (0..<40).map { UInt8(($0 * 29 + 3) & 0xFF) }

    /// XMP another app wrote, with `padding` bytes of whitespace before the trailer.
    static func otherAppXMP(padding: Int, rating: Int = 2, keywords: [String] = ["old", "older"]) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:acme="http://example.com/acme/1.0/"
           xmp:CreatorTool="OtherApp 2.0"
           xmp:Rating="\(rating)"
           xmp:Label="Blue"
           photoshop:City="Paris"
           acme:Flag="keep-me">
           <dc:creator><rdf:Seq><rdf:li>Ann Example</rdf:li></rdf:Seq></dc:creator>
           <dc:description><rdf:Alt><rdf:li xml:lang="x-default">A caption</rdf:li></rdf:Alt></dc:description>
           <dc:subject><rdf:Bag>\(keywords.map { "<rdf:li>\($0)</rdf:li>" }.joined())</rdf:Bag></dc:subject>
           <acme:Nested rdf:parseType="Resource"><acme:Inner>deep</acme:Inner></acme:Nested>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        \(String(repeating: " ", count: padding))<?xpacket end="w"?>
        """
    }

    static func pixels(_ width: Int, _ height: Int, seed: Int) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<(width * height) {
            let r: Int = (i * 7 + seed) & 0xFF, g: Int = (i * 13 + seed * 3) & 0xFF, b: Int = (i * 3 + seed * 50) & 0xFF
            out += [UInt8(r), UInt8(g), UInt8(b)]
        }
        return out
    }

    static func make(_ o: Options = Options()) -> RichTIFF {
        let w = TIFFWriter(bigEndian: o.bigEndian)
        let page1 = pixels(24, 16, seed: 1), preview = pixels(6, 4, seed: 2), page2 = pixels(12, 8, seed: 3)
        let stripLength = 24 * 3 * 6
        let stripCounts = stride(from: 0, to: page1.count, by: stripLength).map { UInt32(min(stripLength, page1.count - $0)) }

        var iim33723 = o.iim + [UInt8](repeating: 0, count: o.iptcSlack)
        iim33723 += [UInt8](repeating: 0, count: (4 - iim33723.count % 4) % 4)
        let iim0404 = o.mirroredIPTC ? iim33723 : o.iim + [UInt8](repeating: 0, count: o.photoshopIPTCSlack)
        let digest = o.digest ?? Array(Insecure.MD5.hash(data: Data(o.photoshopIPTC ? iim0404 : iim33723)))
        let irb = IRBTestData.block(0x03ED, RichJPEG.resolutionResource) + IRBTestData.block(0x040A, [1])
            + (o.photoshopIPTC ? IRBTestData.block(0x0404, iim0404) : []) + IRBTestData.block(0x0425, digest)
            + o.extraResources + IRBTestData.block(0x2710, RichJPEG.customResource)
        let icc = [UInt8](CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData()! as Data)

        var entries: [TIFFEntry] = [
            w.long(0x00FE, 0), w.long(0x0100, 24), w.long(0x0101, 16), w.short(0x0102, 8, 8, 8), w.short(0x0103, 1),
            w.short(0x0106, 2), w.ascii(0x010E, "A rich test TIFF"), w.ascii(0x010F, "TestCam"), w.ascii(0x0110, "Model X"),
            TIFFEntry(tag: 0x0111, type: 4, count: stripCounts.count, data: [UInt8](repeating: 0, count: 4 * stripCounts.count)),
            w.short(0x0112, 1), w.short(0x0115, 3), w.short(0x0116, 6),
            TIFFEntry(tag: 0x0117, type: 4, count: stripCounts.count, data: stripCounts.flatMap(w.u32)),
            w.rational(0x011A, (300, 1)), w.rational(0x011B, (300, 1)), w.short(0x011C, 1), w.short(0x0128, 2),
            w.short(0x0129, 0, 2), w.ascii(0x0131, "OtherApp 2.0"), w.ascii(0x0132, "2024:05:01 10:00:00"),
            w.ascii(0x013B, "Ann Example"), w.long(0x014A, 0), w.ascii(0x8298, "(c) Ann"),
            w.long(0x8769, 0), w.undefined(0x8773, icc), w.long(0x8825, 0),
        ]
        if let xmp = o.xmp { entries.append(TIFFEntry(tag: 700, type: 1, count: xmp.utf8.count, data: Array(xmp.utf8))) }
        if o.iptc { entries.append(TIFFEntry(tag: 0x83BB, type: 4, count: iim33723.count / 4, data: iim33723)) }
        if o.photoshop { entries.append(TIFFEntry(tag: 0x8649, type: 7, count: irb.count, data: irb)) }
        entries += o.extraIFD0(w)
        let ifd0 = w.appendIFD(entries)
        w.patch32(at: 4, ifd0.offset)

        // A MakerNote that points at its maker data by absolute file offset (patched below), as many cameras' do.
        let makerNoteBytes = Array("TESTMAKER\u{0}".utf8) + [UInt8](repeating: 0, count: 8) + (0..<60).map { UInt8(($0 * 37 + 11) & 0xFF) }
        let exif = w.appendIFD([
            w.rational(0x829A, (1, 250)), w.rational(0x829D, (28, 10)), w.short(0x8827, 200),
            w.undefined(0x9000, Array("0231".utf8)), w.ascii(0x9003, "2024:05:01 10:00:00"),
            w.ascii(0x9004, "2024:05:01 10:00:00"), w.ascii(0x9011, "+02:00"), w.undefined(0x927C, makerNoteBytes),
            w.undefined(0x9286, Array("ASCII\u{0}\u{0}\u{0}hello".utf8)), w.short(0xA001, 0xFFFF),
            w.long(0xA002, 24), w.long(0xA003, 16), w.long(0xA005, 0), w.ascii(0xA434, "50mm F1.8"),
        ])
        w.patch32(at: ifd0.valueFields[0x8769]!, exif.offset)
        let interop = w.appendIFD([w.ascii(0x0001, "R03"), w.undefined(0x0002, Array("0100".utf8))])
        w.patch32(at: exif.valueFields[0xA005]!, interop.offset)
        let gps = w.appendIFD(o.emptyGPS ? [] : [
            w.byte(0x0000, 2, 3, 0, 0), w.ascii(0x0001, "N"), w.rational(0x0002, (48, 1), (51, 1), (2436, 100)),
            w.ascii(0x0003, "E"), w.rational(0x0004, (2, 1), (21, 1), (360, 100)), w.rational(0x0006, (35, 1)),
        ])
        w.patch32(at: ifd0.valueFields[0x8825]!, gps.offset)
        let sub = w.appendIFD([
            w.long(0x00FE, 1), w.long(0x0100, 6), w.long(0x0101, 4), w.short(0x0102, 8, 8, 8), w.short(0x0103, 1),
            w.short(0x0106, 2), w.long(0x0111, 0), w.short(0x0115, 3), w.short(0x0116, 4), w.long(0x0117, UInt32(preview.count)),
        ])
        w.patch32(at: ifd0.valueFields[0x014A]!, sub.offset)
        let second = w.appendIFD([
            w.long(0x00FE, 2), w.long(0x0100, 12), w.long(0x0101, 8), w.short(0x0102, 8, 8, 8), w.short(0x0103, 1),
            w.short(0x0106, 2), w.ascii(0x010F, "TestCam"), w.long(0x0111, 0), w.short(0x0115, 3), w.short(0x0116, 8),
            w.long(0x0117, UInt32(page2.count)), w.short(0x0129, 1, 2),
        ])
        w.patch32(at: ifd0.nextPointer, second.offset)

        let makerDataOffset = w.append(makerDataBytes)
        let makerNoteStart = exif.valueOffsets[0x927C]!
        w.patch32(at: makerNoteStart + 10, makerDataOffset)
        w.patch32(at: makerNoteStart + 14, makerDataBytes.count)
        let page1Offset = w.append(page1)
        for (i, _) in stripCounts.enumerated() {
            w.patch32(at: ifd0.valueOffsets[0x0111]! + 4 * i, page1Offset + i * stripLength)
        }
        w.patch32(at: sub.valueFields[0x0111]!, w.append(preview))
        w.patch32(at: second.valueFields[0x0111]!, w.append(page2))
        return RichTIFF(data: Data(w.bytes), makerNote: makerNoteStart..<(makerNoteStart + makerNoteBytes.count),
                        makerData: Data(makerDataBytes))
    }
}

// MARK: - Tests

final class TIFFMetadataTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-tiffmeta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    // MARK: Helpers

    private static func xmpRating(_ meta: CGImageMetadata) -> String? {
        CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?
    }

    private static func xmpSubject(_ meta: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString),
              let elements = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return elements.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    private static func metadata(_ data: Data, _ index: Int = 0) -> CGImageMetadata? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, index, nil) }
    }

    /// What `MetadataService` does with a TIFF: `TIFFMetadata` with the JPEG path's XMP updater, kept only if ImageIO
    /// reads the result back complete, with this rating and these keywords.
    static func written(_ tiff: Data, rating: Int, keywords: [String]) -> Data? {
        guard let out = TIFFMetadata.replacingXMP(in: tiff, update: {
            MetadataService.xmpPacket(rating: rating, keywords: keywords, updating: $0)
        }, keywords: keywords),
              let source = CGImageSourceCreateWithData(out as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              xmpRating(meta) == "\(rating)", xmpSubject(meta) == keywords else { return nil }
        return out
    }

    private func rewrite(_ tiff: Data, rating: Int = 3, keywords: [String] = ["new", "people:ann"],
                         offsetLimit: Int = Int(UInt32.max)) -> Result<Data, TIFFMetadata.Refusal> {
        TIFFMetadata.rewrite(tiff, update: { MetadataService.xmpPacket(rating: rating, keywords: keywords, updating: $0) },
                             keywords: keywords, offsetLimit: offsetLimit)
    }

    private func refusal(_ result: Result<Data, TIFFMetadata.Refusal>) -> TIFFMetadata.Refusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    /// Writes `tiff` to a file, writes the rating and keywords into it as `MetadataService` will (through a temp file),
    /// and returns the file's new bytes.
    private func writeThroughFile(_ tiff: Data, rating: Int, keywords: [String],
                                  file: StaticString = #filePath, line: UInt = #line) throws -> (URL, Data) {
        let url = dir.appendingPathComponent("photo-\(UUID().uuidString).tif")
        try tiff.write(to: url)
        let out = try XCTUnwrap(Self.written(tiff, rating: rating, keywords: keywords), "written in the file", file: file, line: line)
        XCTAssertTrue(MetadataService.replace(url, exists: true) { try out.write(to: $0, options: .withoutOverwriting) },
                      file: file, line: line)
        return (url, try Data(contentsOf: url))
    }

    private static func properties(_ data: Data, _ index: Int) -> [String: String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in props {
            if let dictionary = value as? [String: Any] {
                for (k, v) in dictionary { out["\(key).\(k)"] = "\(v)" }
            } else {
                out[key] = "\(value)"
            }
        }
        return out
    }

    private static func pixels(_ data: Data, _ index: Int) -> Data? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, index, nil) }?
            .dataProvider?.data as Data?
    }

    private static func iimKeywords(_ iim: Data) -> [String] {
        IRBTestData.datasets(iim).filter { $0.record == 2 && $0.number == 25 }.map { String(decoding: $0.value, as: UTF8.self) }
    }

    private static func iimOthers(_ iim: Data) -> [String] {
        IRBTestData.datasets(iim).filter { !($0.record == 2 && $0.number == 25) }.map { "\($0.record):\($0.number)=\($0.value as NSData)" }
    }

    private static let photoshopHeader = Data("Photoshop 3.0\u{0}".utf8)

    private static func resources(_ irb: Data) -> [(id: Int, data: Data)] {
        IRBTestData.resources(photoshopHeader + irb)
    }

    /// `data` with IFD0's `tag` renamed to `newTag` (which must sort in the same place), so ImageIO no longer sees it.
    private static func renaming(_ tag: Int, to newTag: Int, in data: Data) -> Data {
        let walker = TIFFTestWalker(data)!
        var out = data
        guard let entry = walker.entry(tag, in: walker.ifd0) else { return data }
        let bytes: [UInt8] = walker.le ? [UInt8(newTag & 0xFF), UInt8(newTag >> 8)] : [UInt8(newTag >> 8), UInt8(newTag & 0xFF)]
        out.replaceSubrange(entry.position..<(entry.position + 2), with: bytes)
        return out
    }

    /// Asserts that `output`, written from `original` with this rating and these keywords, keeps everything:
    /// - every byte of `original` outside `changeable` (and nothing but appended bytes after it);
    /// - every value of every IFD, and every strip, by the independent walker (IFD0's XMP and IPTC checked apart);
    /// - the MakerNote's maker data, reached through its absolute offset;
    /// - every ImageIO property of both pages, and both pages' decoded pixels;
    /// - every XMP value other than Phocasa's, and every IPTC dataset and Photoshop resource other than the keywords
    ///   and their digest;
    /// and that ImageIO reads the new rating and keywords, from the XMP and from each IPTC copy on its own.
    private func assertKeeps(original: Data, output: Data, changeable: [Range<Int>], rating: Int, keywords: [String],
                             file: StaticString = #filePath, line: UInt = #line) {
        // Bytes.
        XCTAssertGreaterThanOrEqual(output.count, original.count, "nothing is removed", file: file, line: line)
        var i = 0
        while i < original.count {
            if let range = changeable.first(where: { $0.contains(i) }) { i = range.upperBound; continue }
            if output[i] != original[i] {
                XCTFail("byte \(i) changed, outside the parts that may change (\(changeable))", file: file, line: line)
                break
            }
            i += 1
        }

        // Structure, by the independent walker.
        guard let before = TIFFTestWalker(original), let after = TIFFTestWalker(output) else {
            return XCTFail("walkable", file: file, line: line)
        }
        let valuesBefore = before.contents(), valuesAfter = after.contents()
        XCTAssertEqual(Set(valuesAfter.keys), Set(valuesBefore.keys), "every IFD still reachable", file: file, line: line)
        for (path, values) in valuesBefore {
            for (tag, value) in values where !(path == "p0" && [700, 33723, 34377].contains(tag)) {
                XCTAssertEqual(valuesAfter[path]?[tag], value, "\(path) tag \(tag) resolves to the same bytes", file: file, line: line)
            }
        }
        let makerNote = after.entry(0x927C, in: after.ifds()["p0/exif"] ?? 0).map { after.range($0) }
        XCTAssertEqual(makerNote, before.entry(0x927C, in: before.ifds()["p0/exif"] ?? 0).map { before.range($0) },
                       "the MakerNote hasn't moved", file: file, line: line)
        if let makerNote {
            let offset = after.u32(makerNote.lowerBound + 10), length = after.u32(makerNote.lowerBound + 14)
            XCTAssertEqual(Data(after.d[offset..<(offset + length)]), Data(RichTIFF.makerDataBytes),
                           "the MakerNote's absolute offset still finds its maker data", file: file, line: line)
        }

        // ImageIO: every property of both pages, and the pixels.
        for index in 0..<2 {
            let a = Self.properties(original, index), b = Self.properties(output, index)
            XCTAssertFalse(a.isEmpty, "fixture: page \(index) has properties", file: file, line: line)
            for (key, value) in a where !["{IPTC}.Keywords", "{IPTC}.StarRating"].contains(key) {
                XCTAssertEqual(b[key], value, "page \(index) \(key) must be kept", file: file, line: line)
            }
            XCTAssertNotNil(Self.pixels(original, index), "fixture: page \(index) decodes", file: file, line: line)
            XCTAssertEqual(Self.pixels(output, index), Self.pixels(original, index), "page \(index)'s pixels", file: file, line: line)
        }
        XCTAssertEqual(Self.properties(output, 1)["{IPTC}.Keywords"], Self.properties(original, 1)["{IPTC}.Keywords"],
                       "the second page's metadata is its own", file: file, line: line)

        // XMP: Phocasa's values, and every other value.
        guard let meta = Self.metadata(output) else { return XCTFail("ImageIO reads the metadata", file: file, line: line) }
        XCTAssertEqual(Self.xmpRating(meta), "\(rating)", "ImageIO reads the rating", file: file, line: line)
        XCTAssertEqual(Self.xmpSubject(meta), keywords, "ImageIO reads the keywords", file: file, line: line)
        let packetBefore = before.ifd0Value(700)?.data, packetAfter = after.ifd0Value(700)?.data
        let xmpBefore = KeptMetadata.xmpValues(packetBefore), xmpAfter = KeptMetadata.xmpValues(packetAfter)
        for (path, value) in xmpBefore where !(path.hasPrefix("xmp:Rating") || path.hasPrefix("dc:subject")) {
            XCTAssertEqual(xmpAfter[path], value, "XMP \(path) must be kept", file: file, line: line)
        }

        // IPTC: the keywords in each copy, everything else kept; ImageIO reads each copy on its own.
        if let iimBefore = before.ifd0Value(33723)?.data {
            guard let iimAfter = after.ifd0Value(33723)?.data else { return XCTFail("33723 kept", file: file, line: line) }
            XCTAssertEqual(Self.iimKeywords(iimAfter), keywords, "33723's keywords", file: file, line: line)
            XCTAssertEqual(Self.iimOthers(iimAfter), Self.iimOthers(iimBefore), "33723's other datasets", file: file, line: line)
            XCTAssertEqual(after.ifd0Value(33723)?.type, before.ifd0Value(33723)?.type, file: file, line: line)
            let iimOnly = Self.renaming(700, to: 701, in: output)
            XCTAssertEqual(Self.metadata(iimOnly).map(Self.xmpSubject), keywords,
                           "ImageIO reads the keywords from 33723 alone", file: file, line: line)
        }
        if let irbBefore = before.ifd0Value(34377)?.data {
            guard let irbAfter = after.ifd0Value(34377)?.data else { return XCTFail("34377 kept", file: file, line: line) }
            let a = Self.resources(irbBefore), b = Self.resources(irbAfter)
            XCTAssertEqual(b.map(\.id), a.map(\.id), "every Photoshop resource, in order", file: file, line: line)
            for resource in a where ![0x0404, 0x0425].contains(resource.id) {
                XCTAssertEqual(b.first { $0.id == resource.id }?.data, resource.data, "resource \(resource.id)", file: file, line: line)
            }
            if let iim = b.first(where: { $0.id == 0x0404 })?.data, let old = a.first(where: { $0.id == 0x0404 })?.data {
                XCTAssertEqual(Self.iimKeywords(iim), keywords, "34377's keywords", file: file, line: line)
                XCTAssertEqual(Self.iimOthers(iim), Self.iimOthers(old), "34377's other datasets", file: file, line: line)
                let digest = b.first { $0.id == 0x0425 }?.data
                XCTAssertEqual(digest, Data(Insecure.MD5.hash(data: iim)), "the digest describes the new IPTC", file: file, line: line)
                let photoshopOnly = Self.renaming(33723, to: 33724, in: Self.renaming(700, to: 701, in: output))
                XCTAssertEqual(Self.metadata(photoshopOnly).map(Self.xmpSubject), keywords,
                               "ImageIO reads the keywords from 34377 alone", file: file, line: line)
            }
        }

        // No sidecar anywhere near.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".xmp") }, [],
                       file: file, line: line)
    }

    private func ranges(_ data: Data, _ tags: [Int]) -> [Range<Int>] {
        let walker = TIFFTestWalker(data)!
        return tags.compactMap { walker.ifd0Value($0)?.range }
    }

    private static let headerOffset = 4..<8

    // MARK: - isTIFF

    func testIsTIFFRecognisesBothByteOrdersOnly() {
        XCTAssertTrue(TIFFMetadata.isTIFF(Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])))
        XCTAssertTrue(TIFFMetadata.isTIFF(Data([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8])))
        XCTAssertFalse(TIFFMetadata.isTIFF(Data([0x49, 0x49, 0x2B, 0x00, 8, 0, 0, 0])), "BigTIFF isn't classic TIFF")
        XCTAssertFalse(TIFFMetadata.isTIFF(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertFalse(TIFFMetadata.isTIFF(Data([0x49, 0x49])))
        let slice = (Data([0, 0]) + RichTIFF.make().data).dropFirst(2)
        XCTAssertTrue(TIFFMetadata.isTIFF(slice), "a slice with a non-zero start index")
    }

    // MARK: - In place

    func testAPacketThatFitsIsRewrittenInPlaceAndOnlyItsBytesAndTheIPTCChange() throws {
        for bigEndian in [false, true] {
            let original = RichTIFF.make(.init(bigEndian: bigEndian, xmp: RichTIFF.otherAppXMP(padding: 2048),
                                               iptcSlack: 64, photoshopIPTCSlack: 64)).data
            let (url, output) = try writeThroughFile(original, rating: 3, keywords: ["new", "people:ann"])

            XCTAssertEqual(output.count, original.count, "nothing appended (\(bigEndian ? "MM" : "II"))")
            let before = TIFFTestWalker(original)!, after = TIFFTestWalker(output)!
            XCTAssertEqual(after.ifd0, before.ifd0, "IFD0 stays where it was")
            for tag in [700, 33723, 34377] {
                XCTAssertEqual(after.ifd0Value(tag)?.range, before.ifd0Value(tag)?.range, "tag \(tag): same offset and size")
                XCTAssertEqual(after.ifd0Value(tag)?.type, before.ifd0Value(tag)?.type, "tag \(tag): same type")
            }
            let packet = String(decoding: try XCTUnwrap(after.ifd0Value(700)?.data), as: UTF8.self)
            XCTAssertTrue(packet.hasPrefix("<?xpacket begin="), "a wrapped packet")
            XCTAssertTrue(packet.hasSuffix("<?xpacket end=\"w\"?>"), "padding then the trailer")
            assertKeeps(original: original, output: output, changeable: ranges(original, [700, 33723, 34377]),
                        rating: 3, keywords: ["new", "people:ann"])

            let read = MetadataService.shared.readMetadata(from: url.path)
            XCTAssertEqual(read.rating, 3)
            XCTAssertEqual(read.keywords, ["new", "people:ann"])
            XCTAssertNotNil(read.captureDate, "the capture date is still read")
        }
    }

    func testTheUpdaterGetsTheExistingPacket() throws {
        let packet = RichTIFF.otherAppXMP(padding: 10)
        var seen: [Data?] = []
        let original = RichTIFF.make(.init(xmp: packet)).data
        _ = TIFFMetadata.replacingXMP(in: original, update: { seen.append($0); return nil }, keywords: [])
        XCTAssertEqual(seen, [Data(packet.utf8)])

        seen = []
        let withNULs = RichTIFF.make(.init(xmp: packet + "\u{0}\u{0}")).data
        _ = TIFFMetadata.replacingXMP(in: withNULs, update: { seen.append($0); return nil }, keywords: [])
        XCTAssertEqual(seen, [Data(packet.utf8)], "trailing NULs aren't part of the packet")

        seen = []
        let none = RichTIFF.make(.init(xmp: nil)).data
        _ = TIFFMetadata.replacingXMP(in: none, update: { seen.append($0); return nil }, keywords: [])
        XCTAssertEqual(seen, [nil], "no packet")
    }

    // MARK: - Appended

    func testAPacketThatGrowsIsAppendedWithACopyOfIFD0() throws {
        for bigEndian in [false, true] {
            let original = RichTIFF.make(.init(bigEndian: bigEndian, iptcSlack: 1024, photoshopIPTCSlack: 1024)).data
            let keywords = (1...12).map { "place:somewhere far away \($0)" }
            let (url, output) = try writeThroughFile(original, rating: 5, keywords: keywords)

            let before = TIFFTestWalker(original)!, after = TIFFTestWalker(output)!
            XCTAssertGreaterThanOrEqual(after.ifd0, original.count, "the new IFD0 is appended")
            XCTAssertEqual(after.ifd0 % 2, 0, "on a word boundary")
            let packet = try XCTUnwrap(after.ifd0Value(700))
            XCTAssertGreaterThanOrEqual(packet.range.lowerBound, original.count, "the new packet is appended")
            XCTAssertEqual(packet.range.lowerBound % 2, 0)
            XCTAssertEqual(packet.type, 1)
            XCTAssertGreaterThanOrEqual(packet.count - Int(before.ifd0Value(700)!.count), 2048,
                                        "the appended packet is padded for later writes")
            XCTAssertEqual(after.next(after.ifd0), before.next(before.ifd0), "the page chain is kept")
            // The copy of IFD0: the same entries, byte for byte, but the XMP's.
            let old = before.entries(before.ifd0), new = after.entries(after.ifd0)
            XCTAssertEqual(new.map(\.tag), old.map(\.tag))
            for (a, b) in zip(old, new) where a.tag != 700 {
                XCTAssertEqual(Data(after.d[b.position..<(b.position + 12)]), Data(before.d[a.position..<(a.position + 12)]),
                               "IFD0 entry \(a.tag) copied verbatim: it points at the same data")
            }
            // The old IFD0 and packet are still there, unreferenced.
            XCTAssertEqual(Data(output[before.ifd0Value(700)!.range]), Data(original[before.ifd0Value(700)!.range]))
            assertKeeps(original: original, output: output,
                        changeable: [Self.headerOffset] + ranges(original, [33723, 34377]), rating: 5, keywords: keywords)
            XCTAssertEqual(MetadataService.shared.readMetadata(from: url.path).keywords, keywords)
        }
    }

    func testAFileWithoutXMPGetsATag700InsertedInSortedOrder() throws {
        for bigEndian in [false, true] {
            let original = RichTIFF.make(.init(bigEndian: bigEndian, xmp: nil, iptcSlack: 64, photoshopIPTCSlack: 64)).data
            XCTAssertEqual(Self.metadata(original).flatMap(Self.xmpRating), nil, "fixture: no XMP rating")
            let (url, output) = try writeThroughFile(original, rating: 4, keywords: ["new"])

            let before = TIFFTestWalker(original)!, after = TIFFTestWalker(output)!
            let tags = after.entries(after.ifd0).map(\.tag)
            XCTAssertEqual(tags, tags.sorted(), "entries stay in ascending order")
            XCTAssertEqual(tags.filter { $0 != 700 }, before.entries(before.ifd0).map(\.tag))
            XCTAssertEqual(after.ifd0Value(700)?.type, 1, "BYTE, as Adobe's specification says")
            assertKeeps(original: original, output: output,
                        changeable: [Self.headerOffset] + ranges(original, [33723, 34377]), rating: 4, keywords: ["new"])
            XCTAssertEqual(MetadataService.shared.readMetadata(from: url.path).rating, 4)
        }
    }

    // MARK: - IPTC

    func testIPTCThatGrowsIsAppendedAndThatShrinksStaysInPlace() throws {
        for bigEndian in [false, true] {
            let original = RichTIFF.make(.init(bigEndian: bigEndian, xmp: RichTIFF.otherAppXMP(padding: 4096))).data
            let keywords = (1...6).map { "subject:keyword number \($0)" }
            let (_, grown) = try writeThroughFile(original, rating: 1, keywords: keywords)

            let before = TIFFTestWalker(original)!, after = TIFFTestWalker(grown)!
            for tag in [33723, 34377] {
                let value = try XCTUnwrap(after.ifd0Value(tag))
                XCTAssertGreaterThanOrEqual(value.range.lowerBound, original.count, "tag \(tag) appended")
                XCTAssertEqual(value.type, before.ifd0Value(tag)?.type, "tag \(tag) keeps its type")
            }
            XCTAssertEqual(after.ifd0Value(33723)!.data.count % 4, 0, "33723 is LONG: whole LONGs")
            XCTAssertEqual(after.ifd0Value(700)?.range, before.ifd0Value(700)?.range, "the XMP fitted in place")
            assertKeeps(original: original, output: grown,
                        changeable: [Self.headerOffset] + ranges(original, [700]), rating: 1, keywords: keywords)

            // Fewer keywords: everything fits where the last write put it, padded with zeros.
            let (_, shrunk) = try writeThroughFile(grown, rating: 2, keywords: ["one"])
            XCTAssertEqual(shrunk.count, grown.count, "nothing appended")
            XCTAssertEqual(TIFFTestWalker(shrunk)!.ifd0, after.ifd0)
            assertKeeps(original: grown, output: shrunk, changeable: ranges(grown, [700, 33723, 34377]),
                        rating: 2, keywords: ["one"])
            let iim = TIFFTestWalker(shrunk)!.ifd0Value(33723)!.data
            XCTAssertEqual(iim.count, after.ifd0Value(33723)!.data.count, "same size")
            XCTAssertTrue(iim.suffix(8).allSatisfy { $0 == 0 }, "zero padding after the datasets")
        }
    }

    func testMirroredIPTCCopiesStayIdentical() throws {
        for bigEndian in [false, true] {
            let original = RichTIFF.make(.init(bigEndian: bigEndian, xmp: RichTIFF.otherAppXMP(padding: 2048),
                                               iptcSlack: 32, mirroredIPTC: true)).data
            let before = TIFFTestWalker(original)!
            XCTAssertEqual(Self.resources(before.ifd0Value(34377)!.data).first { $0.id == 0x0404 }?.data,
                           before.ifd0Value(33723)?.data, "fixture: both copies identical")
            let output = try XCTUnwrap(Self.written(original, rating: 2, keywords: ["a", "b", "c"]))
            let after = TIFFTestWalker(output)!
            let iim = try XCTUnwrap(after.ifd0Value(33723)?.data)
            let resources = Self.resources(try XCTUnwrap(after.ifd0Value(34377)?.data))
            XCTAssertEqual(resources.first { $0.id == 0x0404 }?.data, iim, "the copies stay identical")
            XCTAssertEqual(resources.first { $0.id == 0x0425 }?.data, Data(Insecure.MD5.hash(data: iim)),
                           "the digest describes both")
            XCTAssertEqual(output.count, original.count, "both fitted in place")
            assertKeeps(original: original, output: output, changeable: ranges(original, [700, 33723, 34377]),
                        rating: 2, keywords: ["a", "b", "c"])
        }
    }

    func testADigestOf33723StaysADigestOf33723() throws {
        // Photoshop pads 33723 (LONG) to whole LONGs; a digest written over those bytes stays over them.
        var iim = RichJPEG.iim
        iim += [UInt8](repeating: 0, count: (4 - iim.count % 4) % 4 + 4)
        let original = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 2048), iim: iim, iptcSlack: 16)).data
        // Point the digest at 33723's bytes.
        let walker = TIFFTestWalker(original)!
        let irbRange = walker.ifd0Value(34377)!.range
        let stored33723 = walker.ifd0Value(33723)!.data
        var patched = original
        let irb = [UInt8](original[irbRange])
        let digestAt = irbRange.lowerBound + (0..<irb.count).first { irb[$0..<($0 + 6)].elementsEqual(Array("8BIM".utf8) + [0x04, 0x25]) }! + 12
        patched.replaceSubrange(digestAt..<(digestAt + 16), with: Data(Insecure.MD5.hash(data: stored33723)))

        let output = try XCTUnwrap(Self.written(patched, rating: 1, keywords: ["x"]))
        let after = TIFFTestWalker(output)!
        let digest = Self.resources(after.ifd0Value(34377)!.data).first { $0.id == 0x0425 }?.data
        XCTAssertEqual(digest, Data(Insecure.MD5.hash(data: after.ifd0Value(33723)!.data)), "still 33723's digest")
    }

    func testADigestOf33723WithoutAnIPTCResourceFollows33723() throws {
        let original = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 2048), iptcSlack: 64, photoshopIPTC: false)).data
        let before = TIFFTestWalker(original)!
        XCTAssertEqual(Self.resources(before.ifd0Value(34377)!.data).first { $0.id == 0x0425 }?.data,
                       Data(Insecure.MD5.hash(data: before.ifd0Value(33723)!.data)), "fixture: the digest is 33723's")
        let output = try XCTUnwrap(Self.written(original, rating: 2, keywords: ["x", "y"]))
        let after = TIFFTestWalker(output)!
        XCTAssertEqual(Self.resources(after.ifd0Value(34377)!.data).first { $0.id == 0x0425 }?.data,
                       Data(Insecure.MD5.hash(data: after.ifd0Value(33723)!.data)), "still 33723's digest")
        XCTAssertEqual(output.count, original.count, "in place")
        assertKeeps(original: original, output: output, changeable: ranges(original, [700, 33723, 34377]),
                    rating: 2, keywords: ["x", "y"])
    }

    func testAStaleDigestIsLeftAloneWhileTheKeywordsDontChange() throws {
        let original = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 2048), digest: [UInt8](repeating: 0xAB, count: 16))).data
        let output = try XCTUnwrap(Self.written(original, rating: 5, keywords: ["old", "older"]))
        XCTAssertEqual(output.count, original.count)
        let xmp = TIFFTestWalker(original)!.ifd0Value(700)!.range
        XCTAssertEqual(output[..<xmp.lowerBound], original[..<xmp.lowerBound], "only the XMP changed")
        XCTAssertEqual(output[xmp.upperBound...], original[xmp.upperBound...], "only the XMP changed")
    }

    func testIPTCOnlyInPhotoshopResourcesIsPatchedThere() throws {
        let original = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 2048), iptc: false)).data
        let (_, output) = try writeThroughFile(original, rating: 3, keywords: ["only", "photoshop", "resources"])
        assertKeeps(original: original, output: output, changeable: [Self.headerOffset] + ranges(original, [700, 34377]),
                    rating: 3, keywords: ["only", "photoshop", "resources"])
    }

    func testATIFFWithoutIPTCGetsOnlyXMP() throws {
        let original = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 2048), iptc: false, photoshop: false)).data
        let (_, output) = try writeThroughFile(original, rating: 3, keywords: ["k"])
        XCTAssertEqual(output.count, original.count)
        XCTAssertNil(TIFFTestWalker(output)!.ifd0Value(33723), "no IPTC added")
        assertKeeps(original: original, output: output, changeable: ranges(original, [700]), rating: 3, keywords: ["k"])
    }

    // MARK: - Repeated writes

    func testRepeatedWritesAreStableAndTheFileStaysBounded() throws {
        for bigEndian in [false, true] {
            let original = RichTIFF.make(.init(bigEndian: bigEndian)).data
            var current = original
            var ifd0Offsets: Set<Int> = []
            let steps: [(Int, [String])] = [(1, ["a"]), (5, ["a", "b"]), (3, (1...20).map { "keyword \($0)" }),
                                            (0, (1...80).map { "a much longer keyword, number \($0)" }), (4, []), (2, ["z"])]
            for (rating, keywords) in steps {
                current = try XCTUnwrap(Self.written(current, rating: rating, keywords: keywords), "rating \(rating)")
                ifd0Offsets.insert(TIFFTestWalker(current)!.ifd0)
                XCTAssertEqual(Self.metadata(current).flatMap(Self.xmpRating), "\(rating)")
                XCTAssertEqual(Self.metadata(current).map(Self.xmpSubject), keywords)
            }
            assertKeeps(original: original, output: current, changeable: [Self.headerOffset] + ranges(original, [700, 33723, 34377]),
                        rating: 2, keywords: ["z"])

            // The same values again: the same bytes.
            XCTAssertEqual(Self.written(current, rating: 2, keywords: ["z"]), current, "a repeated write changes nothing")

            // Back and forth between the largest and the smallest: nothing more is appended.
            let settled = current.count
            for _ in 0..<5 {
                current = try XCTUnwrap(Self.written(current, rating: 5, keywords: (1...80).map { "a much longer keyword, number \($0)" }))
                current = try XCTUnwrap(Self.written(current, rating: 0, keywords: []))
            }
            XCTAssertEqual(current.count, settled, "cycling doesn't grow the file")

            // Adding keywords one at a time appends rarely: each appended value has room to grow by half (at least
            // 2 KB of XMP, 256 B of IPTC), so capacities grow geometrically, and everything appended adds up to at most
            // 3× the final capacities, plus one IFD0 copy per append.
            var oneByOne = original
            var appends = 0
            for n in 1...60 {
                let size = oneByOne.count
                oneByOne = try XCTUnwrap(Self.written(oneByOne, rating: 3, keywords: (1...n).map { "tag \($0) of many" }))
                if oneByOne.count != size { appends += 1 }
            }
            let walker = TIFFTestWalker(oneByOne)!
            let capacities = [700, 33723, 34377].compactMap { walker.ifd0Value($0)?.range.count }.reduce(0, +)
            let ifd0Size = 2 + 12 * walker.entries(walker.ifd0).count + 4
            XCTAssertLessThanOrEqual(appends, 8, "appends are rare")
            XCTAssertLessThanOrEqual(oneByOne.count - original.count, 3 * capacities + appends * (ifd0Size + 3 * 4),
                                     "bounded growth for 60 keywords")
            print("TIFF growth (\(bigEndian ? "MM" : "II")): steps \(current.count - original.count) B, 60 keywords one by one \(oneByOne.count - original.count) B in \(appends) appends, IFD0 offsets \(ifd0Offsets.count)")
        }
    }

    // MARK: - Shared storage, multi-page

    func testAPacketWhoseBytesAnotherTagSharesIsAppendedNotOverwritten() throws {
        // A private tag (50000) pointing into the middle of the XMP packet: writing the packet in place would change it.
        var original = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 2048), iptcSlack: 64, photoshopIPTCSlack: 64,
                                           extraIFD0: { w in [w.undefined(50000, [UInt8](repeating: 0, count: 16))] })).data
        let walker = TIFFTestWalker(original)!
        let xmp = walker.ifd0Value(700)!.range
        let shared = walker.entry(50000, in: walker.ifd0)!
        let pointer: [UInt8] = walker.le ? (0..<4).map { UInt8((xmp.lowerBound + 100) >> (8 * $0) & 0xFF) }
                                         : (0..<4).reversed().map { UInt8((xmp.lowerBound + 100) >> (8 * $0) & 0xFF) }
        original.replaceSubrange((shared.position + 8)..<(shared.position + 12), with: pointer)
        let sharedBytes = TIFFTestWalker(original)!.value(TIFFTestWalker(original)!.entry(50000, in: walker.ifd0)!)

        let output = try XCTUnwrap(Self.written(original, rating: 3, keywords: ["k"]))
        let after = TIFFTestWalker(output)!
        XCTAssertGreaterThanOrEqual(after.ifd0Value(700)!.range.lowerBound, original.count, "appended instead")
        XCTAssertEqual(after.value(after.entry(50000, in: after.ifd0)!), sharedBytes, "the other tag's bytes are intact")
        assertKeeps(original: original, output: output, changeable: [Self.headerOffset] + ranges(original, [33723, 34377]),
                    rating: 3, keywords: ["k"])
    }

    func testUnsortedIFD0WithAPacketIsStillWrittenInPlace() throws {
        // Entries out of order (tolerated by readers) are fine as long as nothing has to be inserted.
        var original = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 2048), iptcSlack: 64, photoshopIPTCSlack: 64)).data
        let walker = TIFFTestWalker(original)!
        let entries = walker.entries(walker.ifd0)
        let a = entries[1].position, b = entries[2].position
        let first = original[a..<(a + 12)], second = original[b..<(b + 12)]
        original.replaceSubrange(a..<(a + 12), with: second)
        original.replaceSubrange(b..<(b + 12), with: first)
        let output = try XCTUnwrap(Self.written(original, rating: 3, keywords: ["k"]))
        XCTAssertEqual(output.count, original.count)
        assertKeeps(original: original, output: output, changeable: ranges(original, [700, 33723, 34377]), rating: 3, keywords: ["k"])
    }

    // MARK: - Last resorts: each refused, the file left to the caller (who keeps it byte-identical)

    func testLastResortNotATIFF() {
        XCTAssertEqual(refusal(rewrite(MetadataJPEGPreservationTests.imageIOJPEG())), .notTIFF)
        XCTAssertEqual(refusal(rewrite(Data())), .notTIFF)
        XCTAssertNil(TIFFMetadata.replacingXMP(in: Data([1, 2, 3]), update: { _ in Data() }, keywords: []))
    }

    func testLastResortBigTIFF() {
        // ImageIO decodes a BigTIFF's pixels but reads none of its metadata, so a rating written there couldn't be read.
        var big = Data([0x49, 0x49, 0x2B, 0x00, 0x08, 0x00, 0x00, 0x00]) + Data(repeating: 0, count: 8)
        big[8] = 16
        XCTAssertEqual(refusal(rewrite(big)), .bigTIFF)
        XCTAssertEqual(refusal(rewrite(Data([0x4D, 0x4D, 0x00, 0x2B, 0x00, 0x08, 0x00, 0x00]))), .bigTIFF)
    }

    func testLastResortTruncatedOrOutOfBounds() {
        let tiff = RichTIFF.make().data
        let walker = TIFFTestWalker(tiff)!
        func patched32(_ at: Int, _ value: Int) -> Data {
            var d = tiff
            let bytes = (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) }
            d.replaceSubrange(at..<(at + 4), with: walker.le ? bytes : bytes.reversed())
            return d
        }
        XCTAssertEqual(refusal(rewrite(tiff.prefix(6))), .outOfBounds, "a truncated header")
        XCTAssertEqual(refusal(rewrite(tiff.prefix(tiff.count - 10))), .outOfBounds, "the last strip runs past the end")
        XCTAssertEqual(refusal(rewrite(patched32(4, tiff.count + 100))), .outOfBounds, "IFD0 past the end")
        XCTAssertEqual(refusal(rewrite(patched32(4, 2))), .outOfBounds, "IFD0 inside the header")
        let make = walker.entry(0x010F, in: walker.ifd0)!
        XCTAssertEqual(refusal(rewrite(patched32(make.position + 8, tiff.count - 2))), .outOfBounds, "a value past the end")
        let exif = walker.ifds()["p0/exif"]!
        let makerNote = walker.entry(0x927C, in: exif)!
        XCTAssertEqual(refusal(rewrite(patched32(makerNote.position + 8, tiff.count))), .outOfBounds,
                       "a value past the end in the Exif IFD")
        var entryCount = tiff
        entryCount.replaceSubrange(walker.ifd0..<(walker.ifd0 + 2), with: walker.le ? [0xFF, 0x7F] : [0x7F, 0xFF])
        XCTAssertEqual(refusal(rewrite(entryCount)), .outOfBounds, "an entry table past the end")
    }

    func testLastResortIFDLoops() {
        let tiff = RichTIFF.make().data
        let walker = TIFFTestWalker(tiff)!
        func patched32(_ at: Int, _ value: Int) -> Data {
            var d = tiff
            let bytes = (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) }
            d.replaceSubrange(at..<(at + 4), with: walker.le ? bytes : bytes.reversed())
            return d
        }
        let page2 = walker.ifds()["p1"]!
        XCTAssertEqual(refusal(rewrite(patched32(page2 + 2 + 12 * walker.u16(page2), walker.ifd0))), .ifdLoop,
                       "the second page links back to the first")
        let exifPointer = walker.entry(34665, in: walker.ifd0)!
        XCTAssertEqual(refusal(rewrite(patched32(exifPointer.position + 8, walker.ifd0))), .ifdLoop, "Exif points at IFD0")
    }

    func testAnEmptySubIFDIsFine() throws {
        let original = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 2048), iptcSlack: 64, photoshopIPTCSlack: 64,
                                           emptyGPS: true)).data
        let output = try XCTUnwrap(Self.written(original, rating: 1, keywords: ["k"]))
        XCTAssertEqual(output.count, original.count)
    }

    func testLastResortMalformedIFDs() {
        XCTAssertEqual(refusal(rewrite(Data([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0]))), .malformedIFD,
                       "an IFD0 without entries")
        let oldJPEG = RichTIFF.make(.init(extraIFD0: { w in [w.long(0x0201, 8)] })).data
        XCTAssertEqual(refusal(rewrite(oldJPEG)), .malformedIFD, "a JPEG offset without its length")
        var shortPointer = RichTIFF.make().data
        let walker = TIFFTestWalker(shortPointer)!
        let subIFDs = walker.entry(330, in: walker.ifd0)!
        shortPointer.replaceSubrange((subIFDs.position + 2)..<(subIFDs.position + 4), with: walker.le ? [3, 0] : [0, 3])
        XCTAssertEqual(refusal(rewrite(shortPointer)), .malformedIFD, "a SubIFD pointer as SHORT")
    }

    func testLastResortUnknownFieldType() {
        var tiff = RichTIFF.make().data
        let walker = TIFFTestWalker(tiff)!
        let entry = walker.entry(0xA434, in: walker.ifds()["p0/exif"]!)!
        tiff.replaceSubrange((entry.position + 2)..<(entry.position + 4), with: walker.le ? [99, 0] : [0, 99])
        XCTAssertEqual(refusal(rewrite(tiff)), .unknownFieldType)
    }

    func testLastResortUnexpectedTypes() {
        // ImageIO doesn't read tag 700 as SHORT or LONG; ASCII needs a terminating NUL a padded rewrite can't promise.
        for type in [2, 3, 4] {
            var tiff = RichTIFF.make(.init(xmp: RichTIFF.otherAppXMP(padding: 3))).data
            let walker = TIFFTestWalker(tiff)!
            let entry = walker.entry(700, in: walker.ifd0)!
            let count = type == 3 ? entry.count / 2 : type == 4 ? entry.count / 4 : entry.count
            let t: [UInt8] = walker.le ? [UInt8(type), 0] : [0, UInt8(type)]
            let c = (0..<4).map { UInt8(count >> (8 * $0) & 0xFF) }
            tiff.replaceSubrange((entry.position + 2)..<(entry.position + 8), with: t + (walker.le ? c : c.reversed()))
            XCTAssertEqual(refusal(rewrite(tiff)), .unexpectedFieldType(700), "tag 700 of type \(type)")
        }
        var iptc = RichTIFF.make().data
        let walker = TIFFTestWalker(iptc)!
        let entry = walker.entry(33723, in: walker.ifd0)!
        let count = entry.count * 2
        let c = (0..<4).map { UInt8(count >> (8 * $0) & 0xFF) }
        iptc.replaceSubrange((entry.position + 2)..<(entry.position + 8), with: (walker.le ? [3, 0] : [0, 3]) + (walker.le ? c : c.reversed()))
        XCTAssertEqual(refusal(rewrite(iptc)), .unexpectedFieldType(33723), "IPTC-NAA as SHORT")
    }

    func testLastResortDuplicateMetadataTags() {
        let tiff = RichTIFF.make(.init(extraIFD0: { _ in [TIFFEntry(tag: 700, type: 1, count: 40, data: Array(RichTIFF.otherAppXMP(padding: 0).utf8.prefix(40)))] })).data
        XCTAssertEqual(refusal(rewrite(tiff)), .duplicateMetadataTag)
    }

    func testLastResortInsertingIntoAnUnsortedIFD0() {
        var tiff = RichTIFF.make(.init(xmp: nil)).data
        let walker = TIFFTestWalker(tiff)!
        let entries = walker.entries(walker.ifd0)
        let a = entries[1].position, b = entries[2].position
        let first = tiff[a..<(a + 12)], second = tiff[b..<(b + 12)]
        tiff.replaceSubrange(a..<(a + 12), with: second)
        tiff.replaceSubrange(b..<(b + 12), with: first)
        XCTAssertEqual(refusal(rewrite(tiff)), .unsortedIFD0)
    }

    func testLastResortIPTCThatCantBePatched() {
        // Non-ASCII keywords over IPTC text in an unknown encoding (Latin-1 é, no 1:90).
        let latin1 = IRBTestData.dataset(2, 0, [0, 4]) + IRBTestData.dataset(2, 120, [0x43, 0x61, 0x66, 0xE9])
        XCTAssertEqual(refusal(rewrite(RichTIFF.make(.init(iim: latin1)).data, keywords: ["café"])), .iptcNotPatchable)
        XCTAssertEqual(refusal(rewrite(RichTIFF.make(.init(iim: latin1, photoshop: false)).data, keywords: ["café"])),
                       .iptcNotPatchable, "33723 alone")
        XCTAssertEqual(refusal(rewrite(RichTIFF.make(.init(iim: latin1, iptc: false)).data, keywords: ["café"])),
                       .iptcNotPatchable, "34377 alone")
        // Malformed IIM, and malformed Photoshop resources.
        XCTAssertEqual(refusal(rewrite(RichTIFF.make(.init(iim: [0x1D, 2, 0, 0, 2, 0, 4])).data)), .iptcNotPatchable)
        let badResources = RichTIFF.make(.init(iptc: false, extraResources: Array("XXXX".utf8) + [0, 1, 0, 0, 0, 0, 0, 2, 1, 2])).data
        XCTAssertEqual(refusal(rewrite(badResources)), .iptcNotPatchable)
    }

    func testLastResortXMPInPhotoshopResources() {
        // ImageIO ignores XMP in a TIFF's Photoshop resources (1060), and Adobe's specification says a TIFF shouldn't
        // have it, but other readers read it: two packets that would disagree.
        let tiff = RichTIFF.make(.init(extraResources: IRBTestData.block(0x0424, Array(RichTIFF.otherAppXMP(padding: 0).utf8)))).data
        XCTAssertEqual(refusal(rewrite(tiff)), .xmpInPhotoshopResources)
    }

    func testLastResortXMPThatCantBeUpdated() {
        XCTAssertEqual(refusal(TIFFMetadata.rewrite(RichTIFF.make().data, update: { _ in nil }, keywords: [])), .xmpNotUpdatable)
        // A packet ImageIO can't parse: MetadataService's updater refuses it.
        let broken = RichTIFF.make(.init(xmp: "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF")).data
        XCTAssertEqual(refusal(rewrite(broken)), .xmpNotUpdatable)
    }

    func testLastResortOffsetsBeyond4GB() {
        let tiff = RichTIFF.make().data
        XCTAssertEqual(refusal(rewrite(tiff, keywords: (1...30).map { "k\($0)" }, offsetLimit: tiff.count + 100)),
                       .offsetsBeyond4GB)
        XCTAssertNotNil(try? rewrite(tiff, keywords: (1...30).map { "k\($0)" }).get(), "fine within 4 GB")
    }

    // MARK: - ImageIO-written TIFFs

    func testAnImageIOWrittenTIFF() throws {
        for compression in [1, 5] {
            let image = try XCTUnwrap(CGImageSourceCreateWithData(MetadataJPEGPreservationTests.imageIOJPEG(width: 40, height: 30) as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let out = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                                                 kCGImagePropertyExifUserComment: "keep me"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFCompression: compression],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N"],
                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Paris", kCGImagePropertyIPTCKeywords: ["old"]],
            ] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = out as Data
            let (url, output) = try writeThroughFile(original, rating: 4, keywords: ["new", "people:ann"])
            for (key, value) in Self.properties(original, 0) where !["{IPTC}.Keywords", "{IPTC}.StarRating"].contains(key) {
                XCTAssertEqual(Self.properties(output, 0)[key], value, "\(key) (compression \(compression))")
            }
            XCTAssertEqual(Self.pixels(output, 0), Self.pixels(original, 0))
            let read = MetadataService.shared.readMetadata(from: url.path)
            XCTAssertEqual(read.rating, 4)
            XCTAssertEqual(read.keywords, ["new", "people:ann"])
            let walker = TIFFTestWalker(output)!
            XCTAssertEqual(walker.ifd0Value(33723).map { Self.iimKeywords($0.data) }, ["new", "people:ann"])
        }
    }

    // MARK: - A real camera JPG's metadata in a TIFF (gated)

    /// A TIFF made with ImageIO from the camera JPG next to `PHOCASA_TEST_RAW` (a copy), with the JPG's Exif, GPS
    /// and TIFF properties, then written. Skipped unless `PHOCASA_TEST_RAW` is set.
    func testARealCameraTIFF() throws {
        guard let raw = ProcessInfo.processInfo.environment["PHOCASA_TEST_RAW"], !raw.isEmpty else {
            throw XCTSkip("set PHOCASA_TEST_RAW to a copy of a camera RAW with its JPG beside it")
        }
        let base = URL(fileURLWithPath: raw).deletingPathExtension()
        guard let jpgSource = ["JPG", "jpg", "jpeg", "JPEG"].map({ base.appendingPathExtension($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("no JPG beside PHOCASA_TEST_RAW") }
        let jpg = dir.appendingPathComponent(jpgSource.lastPathComponent)
        try FileManager.default.copyItem(at: jpgSource, to: jpg)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        for compression in [1, 5] {
            let out = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImageFromSource(destination, source, 0, [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: compression],
            ] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = out as Data
            XCTAssertNotNil(Self.properties(original, 0)["{Exif}.DateTimeOriginal"], "fixture: the camera's Exif")

            let (url, output) = try writeThroughFile(original, rating: 5, keywords: ["real", "people:ann"])
            for (key, value) in Self.properties(original, 0) where !["{IPTC}.Keywords", "{IPTC}.StarRating"].contains(key) {
                XCTAssertEqual(Self.properties(output, 0)[key], value, "\(key) (compression \(compression))")
            }
            XCTAssertEqual(Self.pixels(output, 0), Self.pixels(original, 0), "decoded pixels (compression \(compression))")
            let xmpBefore = KeptMetadata.xmpValues(TIFFTestWalker(original)!.ifd0Value(700)?.data)
            let xmpAfter = KeptMetadata.xmpValues(TIFFTestWalker(output)!.ifd0Value(700)?.data)
            for (path, value) in xmpBefore where !(path.hasPrefix("xmp:Rating") || path.hasPrefix("dc:subject")) {
                XCTAssertEqual(xmpAfter[path], value, "XMP \(path)")
            }
            let read = MetadataService.shared.readMetadata(from: url.path)
            XCTAssertEqual(read.rating, 5)
            XCTAssertEqual(read.keywords, ["real", "people:ann"])
            XCTAssertEqual(read.captureDate, MetadataService.shared.readMetadata(from: jpg.path).captureDate)
            let before = TIFFTestWalker(original)!.contents(), after = TIFFTestWalker(output)!.contents()
            for (path, values) in before {
                for (tag, value) in values where !(path == "p0" && [700, 33723, 34377].contains(tag)) {
                    XCTAssertEqual(after[path]?[tag], value, "\(path) tag \(tag)")
                }
            }
            print("TIFF real file (compression \(compression)): \(original.count) → \(output.count) B")
        }
    }
}
