import XCTest
import ImageIO
import UniformTypeIdentifiers
import zlib
@testable import Phocasa

// MARK: - Independent PNG reader and builders (tests only)

/// A PNG's chunks, read and CRC-checked without the app's parser: the CRC here is a hand-written table, the app uses
/// zlib's `crc32`.
struct TestPNG {
    struct Chunk: Equatable, CustomStringConvertible {
        let type: String
        let data: Data
        /// The whole chunk: length, type, data, CRC.
        let bytes: Data
        let crcIsValid: Bool
        var description: String { "\(type)(\(data.count))" }
    }

    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    static let xmpKeyword = "XML:com.adobe.xmp"

    let chunks: [Chunk]
    /// Whatever follows IEND.
    let trailing: Data

    /// Nil unless `png` is a signature and whole chunks up to IEND.
    init?(_ png: Data) {
        let p = [UInt8](png)
        guard p.count >= 8, Data(p[0..<8]) == Self.signature else { return nil }
        func u32(_ o: Int) -> Int { Int(p[o]) << 24 | Int(p[o + 1]) << 16 | Int(p[o + 2]) << 8 | Int(p[o + 3]) }
        var i = 8
        var chunks: [Chunk] = []
        while true {
            guard i + 12 <= p.count else { return nil }
            let length = u32(i)
            guard i + 12 + length <= p.count else { return nil }
            let type = String(decoding: p[(i + 4)..<(i + 8)], as: UTF8.self)
            let crc = Self.crc(p[(i + 4)..<(i + 8 + length)])
            chunks.append(Chunk(type: type, data: Data(p[(i + 8)..<(i + 8 + length)]), bytes: Data(p[i..<(i + 12 + length)]),
                                crcIsValid: UInt32(u32(i + 8 + length)) == crc))
            i += 12 + length
            if type == "IEND" { break }
        }
        self.chunks = chunks
        trailing = Data(p[i...])
    }

    var types: [String] { chunks.map(\.type) }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// The PNG CRC (ISO 3309 / ITU-T V.42, reflected 0xEDB88320, starts at all ones, inverted at the end).
    static func crc<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func be32(_ v: Int) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    static func chunk(_ type: String, _ data: Data) -> Data {
        let body = Data(type.utf8) + data
        return be32(data.count) + body + be32(Int(crc(body)))
    }

    static func assemble(_ chunks: [Data], trailing: Data = Data()) -> Data {
        chunks.reduce(signature, +) + trailing
    }

    /// `data` as a zlib stream (RFC 1950), the form of PNG's compressed text and profiles.
    static func zlibCompressed(_ data: Data) -> Data {
        var length = compressBound(uLong(data.count))
        var out = Data(count: Int(length))
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                compress2(o.bindMemory(to: Bytef.self).baseAddress, &length, i.bindMemory(to: Bytef.self).baseAddress,
                          uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        precondition(status == Z_OK)
        return out.prefix(Int(length))
    }

    static func zlibInflated(_ data: Data) -> Data? {
        var capacity = max(4096, data.count * 8)
        while capacity <= 1 << 28 {
            var length = uLong(capacity)
            var out = Data(count: capacity)
            let status = out.withUnsafeMutableBytes { o in
                data.withUnsafeBytes { i in
                    uncompress(o.bindMemory(to: Bytef.self).baseAddress, &length, i.bindMemory(to: Bytef.self).baseAddress,
                               uLong(data.count))
                }
            }
            if status == Z_OK { return out.prefix(Int(length)) }
            guard status == Z_BUF_ERROR else { return nil }
            capacity *= 4
        }
        return nil
    }

    static func iTXt(_ keyword: String, _ text: Data, compressed: Bool = false, method: UInt8 = 0,
                     language: String = "", translated: String = "") -> Data {
        var d = Data(keyword.utf8) + Data([0, compressed ? 1 : 0, method]) + Data(language.utf8) + Data([0])
        d += Data(translated.utf8) + Data([0])
        return chunk("iTXt", d + (compressed ? zlibCompressed(text) : text))
    }

    static func tEXt(_ keyword: String, _ text: String) -> Data {
        chunk("tEXt", Data(keyword.utf8) + Data([0]) + (text.data(using: .isoLatin1) ?? Data()))
    }

    static func zTXt(_ keyword: String, _ text: Data) -> Data {
        chunk("zTXt", Data(keyword.utf8) + Data([0, 0]) + zlibCompressed(text))
    }

    /// An iTXt chunk's fields.
    struct InternationalText {
        let keyword: String
        let compressed: Bool
        let method: UInt8
        let language: String
        let translated: String
        /// Everything before the text: keyword, separators, flags, language tag, translated keyword.
        let header: Data
        /// The text, inflated if it was compressed.
        let text: Data
    }

    static func internationalText(_ data: Data) -> InternationalText? {
        let d = [UInt8](data)
        guard let k = d.firstIndex(of: 0), k + 3 <= d.count,
              let l = d[(k + 3)...].firstIndex(of: 0), let t = d[(l + 1)...].firstIndex(of: 0) else { return nil }
        let compressed = d[k + 1] == 1
        let raw = Data(d[(t + 1)...])
        guard let text = compressed ? zlibInflated(raw) : raw else { return nil }
        return InternationalText(keyword: String(decoding: d[..<k], as: UTF8.self), compressed: compressed, method: d[k + 2],
                                 language: String(decoding: d[(k + 3)..<l], as: UTF8.self),
                                 translated: String(decoding: d[(l + 1)..<t], as: UTF8.self),
                                 header: Data(d[...t]), text: text)
    }

    /// The XMP chunks (iTXt, keyword `XML:com.adobe.xmp`) and where they are.
    var xmpChunks: [(index: Int, text: InternationalText)] {
        chunks.enumerated().compactMap { index, chunk in
            guard chunk.type == "iTXt", let text = Self.internationalText(chunk.data), text.keyword == Self.xmpKeyword
            else { return nil }
            return (index, text)
        }
    }

    /// ImageMagick's hex "raw profile" text.
    static func rawProfile(_ name: String, _ data: Data) -> Data {
        var s = "\n\(name)\n" + String(format: "%8d", data.count) + "\n"
        let hex = data.map { String(format: "%02x", $0) }.joined()
        var start = hex.startIndex
        while start < hex.endIndex {
            let end = hex.index(start, offsetBy: 72, limitedBy: hex.endIndex) ?? hex.endIndex
            s += hex[start..<end] + "\n"
            start = end
        }
        return Data(s.utf8)
    }
}

// MARK: - The rich PNG

/// A PNG as a camera app and then other editors leave it, built chunk by chunk: an Adobe RGB `iCCP`, `gAMA`, `pHYs`, an
/// `eXIf` (IFD0, Exif IFD with a MakerNote, Interop, GPS, IFD1 thumbnail), text chunks of every kind (`tEXt`, `zTXt`,
/// a translated `iTXt` and a compressed one), private chunks (safe- and unsafe-to-copy), real compressed pixels in
/// three `IDAT`s, and after them `tIME`, a `tEXt` and a private chunk. Optionally another app's XMP.
struct RichPNG {
    enum XMP {
        case none
        /// Another app's packet in an iTXt among the chunks before the image data (not next to it).
        case beforeImageData(compressed: Bool)
        /// Another app's packet in an iTXt after the image data, where exiftool before 11.63 put it.
        case afterImageData
    }

    let data: Data
    let makerNote: Data
    let width: Int
    let height: Int

    static let otherAppXMP = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 9.1">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
        xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
        xmlns:stEvt="http://ns.adobe.com/xap/1.0/sType/ResourceEvent#"
        xmlns:acme="http://example.com/acme/1.0/"
       xmp:CreatorTool="OtherApp 2.0"
       xmp:Rating="2"
       xmp:Label="Blue"
       xmp:CreateDate="2024-05-01T10:00:00+02:00"
       photoshop:City="Paris"
       xmpMM:DocumentID="xmp.did:0123456789"
       acme:Flag="keep-me">
       <dc:creator><rdf:Seq><rdf:li>Ann Example</rdf:li></rdf:Seq></dc:creator>
       <dc:description><rdf:Alt><rdf:li xml:lang="x-default">A caption</rdf:li><rdf:li xml:lang="fr">Une légende</rdf:li></rdf:Alt></dc:description>
       <dc:subject><rdf:Bag><rdf:li>old</rdf:li><rdf:li>older</rdf:li></rdf:Bag></dc:subject>
       <xmpMM:History><rdf:Seq><rdf:li rdf:parseType="Resource"><stEvt:action>created</stEvt:action><stEvt:softwareAgent>OtherApp 2.0</stEvt:softwareAgent></rdf:li></rdf:Seq></xmpMM:History>
       <acme:Tags><rdf:Bag><rdf:li>x</rdf:li><rdf:li>y</rdf:li></rdf:Bag></acme:Tags>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>

    <?xpacket end="w"?>
    """

    /// A test pattern with gradients and detail, encoded by ImageIO: its IHDR and its compressed image data.
    static func encodedPixels(width: Int, height: Int) throws -> (header: Data, imageData: Data) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.05, green: 0.10, blue: 0.35, alpha: 1), CGColor(srgbRed: 0.95, green: 0.60, blue: 0.20, alpha: 1),
        ] as CFArray, locations: [0, 1]))
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for k in 0..<40 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(k % 5) / 4, green: CGFloat(k % 3) / 2, blue: 0.5, alpha: 0.5 + CGFloat(k % 2) / 2))
            ctx.fill(CGRect(x: (k * 37) % width, y: (k * 23) % height, width: 3 + k % 7, height: 2 + k % 5))
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let png = try XCTUnwrap(TestPNG(out as Data))
        let header = try XCTUnwrap(png.chunks.first { $0.type == "IHDR" }).bytes
        return (header, png.chunks.filter { $0.type == "IDAT" }.reduce(Data()) { $0 + $1.data })
    }

    static func make(xmp: XMP = .none, trailing: Data = Data(), width: Int = 120, height: Int = 80) throws -> RichPNG {
        let (header, imageData) = try encodedPixels(width: width, height: height)
        let third = imageData.count / 3
        let idats = [imageData.prefix(third), imageData.dropFirst(third).prefix(third), imageData.dropFirst(2 * third)]
            .map { TestPNG.chunk("IDAT", Data($0)) }

        let thumbnail = [UInt8](MetadataJPEGPreservationTests.imageIOJPEG(width: 32, height: 24))
        let (tiff, makerNote) = RichJPEG.exifTIFF(width: width, height: height, orientation: 1, bigEndian: false,
                                                  thumbnail: thumbnail)
        let adobeRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998)?.copyICCData() as Data?)
        let packet = Data(otherAppXMP.utf8)

        var chunks: [Data] = [header]
        chunks.append(TestPNG.chunk("iCCP", Data("Adobe RGB (1998)".utf8) + Data([0, 0]) + TestPNG.zlibCompressed(adobeRGB)))
        chunks.append(TestPNG.chunk("gAMA", TestPNG.be32(45455)))
        chunks.append(TestPNG.chunk("pHYs", TestPNG.be32(11811) + TestPNG.be32(11811) + Data([1])))
        chunks.append(TestPNG.chunk("eXIf", Data(tiff)))
        if case .beforeImageData(let compressed) = xmp {
            chunks.append(TestPNG.iTXt(TestPNG.xmpKeyword, packet, compressed: compressed))
        }
        chunks.append(TestPNG.tEXt("Title", "Harbour at dawn"))
        chunks.append(TestPNG.tEXt("Author", "Ann Example"))
        chunks.append(TestPNG.tEXt("Acme Key", "custom value, café"))
        chunks.append(TestPNG.zTXt("Description", Data("A long description of the harbour, kept compressed.".utf8)))
        chunks.append(TestPNG.iTXt("Copyright", Data("© Ann Exemple".utf8), language: "fr", translated: "Droits d'auteur"))
        chunks.append(TestPNG.iTXt("Disclaimer", Data("Compressed international text.".utf8), compressed: true, language: "en"))
        chunks.append(TestPNG.chunk("prVt", Data((0..<64).map { UInt8($0 * 7 & 0xFF) })))
        chunks.append(TestPNG.chunk("prVT", Data("unsafe-to-copy private data".utf8)))
        chunks += idats
        if case .afterImageData = xmp {
            chunks.append(TestPNG.iTXt(TestPNG.xmpKeyword, packet))
        }
        chunks.append(TestPNG.chunk("tIME", Data([0x07, 0xE8, 5, 1, 10, 0, 0])))
        chunks.append(TestPNG.tEXt("Comment", "written after the image data"))
        chunks.append(TestPNG.chunk("prVt", Data("second private chunk".utf8)))
        chunks.append(TestPNG.chunk("IEND", Data()))
        return RichPNG(data: TestPNG.assemble(chunks, trailing: trailing), makerNote: Data(tiff[makerNote]),
                       width: width, height: height)
    }
}

// MARK: - Tests

/// `PNGMetadata` puts the XMP packet, and so Phocasa's rating and keywords, inside a PNG and changes nothing else:
/// every other chunk stays byte for byte and in order (post-wave-3 task D).
final class PNGMetadataTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-png-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    // MARK: Helpers

    private func file(_ data: Data, _ name: String = "photo.png") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// What the coordinator's writer does: the new bytes, checked to read back through ImageIO, then written through a
    /// temp file. Returns the new bytes, or nil (the file is then unchanged).
    @discardableResult
    private func writeRating(_ rating: Int, _ keywords: [String], to url: URL,
                             file: StaticString = #filePath, line: UInt = #line) throws -> Data? {
        let original = try Data(contentsOf: url)
        guard let bytes = PNGMetadata.replacingXMP(in: original, update: {
            MetadataService.xmpPacket(rating: rating, keywords: keywords, updating: $0)
        }) else { return nil }
        XCTAssertTrue(readsBack(bytes, rating, keywords), "the new bytes read back through ImageIO", file: file, line: line)
        XCTAssertTrue(MetadataService.replace(url, exists: true) { try bytes.write(to: $0, options: .withoutOverwriting) },
                      file: file, line: line)
        return bytes
    }

    private func readsBack(_ png: Data, _ rating: Int, _ keywords: [String]) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return false }
        return CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String? == "\(rating)"
            && subject(meta) == keywords
    }

    private func subject(_ meta: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString),
              let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    /// The rating and keywords as ImageIO and Phocasa read them from the file itself, with no sidecar.
    private func assertFileReads(_ url: URL, rating: Int, keywords: [String],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.xmpSidecarURL.path), "no sidecar", file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), file: file, line: line)
        let meta = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?, "\(rating)",
                       "ImageIO reads the rating from the file", file: file, line: line)
        XCTAssertEqual(subject(meta), keywords, "ImageIO reads the keywords from the file", file: file, line: line)
        let iptc = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])?["{IPTC}"] as? [String: Any]
        XCTAssertEqual(iptc?["StarRating"] as? Int, rating, "ImageIO's IPTC view", file: file, line: line)
        XCTAssertEqual(iptc?["Keywords"] as? [String] ?? [], keywords, "ImageIO's IPTC view", file: file, line: line)
        let read = MetadataService.shared.readMetadata(from: url.path)
        XCTAssertEqual(read.rating, rating, "Phocasa reads the rating", file: file, line: line)
        XCTAssertEqual(read.keywords, keywords, "Phocasa reads the keywords", file: file, line: line)
    }

    private static let phocasaXMP = ["xmp:Rating", "dc:subject"]
    private static func isPhocasas(_ path: String) -> Bool {
        phocasaXMP.contains { path == $0 || path.hasPrefix($0 + "[") }
    }

    private static func properties(_ png: Data, frame: Int = 0) -> [String: Any] {
        CGImageSourceCreateWithData(png as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, frame, nil) as? [String: Any] } ?? [:]
    }

    private static func mergedXMP(_ png: Data) -> [String: String] {
        guard let meta = CGImageSourceCreateWithData(png as CFData, nil).flatMap({ CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        else { return [:] }
        return KeptMetadata.xmpValues(meta)
    }

    /// Every string and number in a property tree.
    private static func leafValues(_ value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] { return dictionary.values.reduce(into: []) { $0.formUnion(leafValues($1)) } }
        if let array = value as? [Any] { return array.reduce(into: []) { $0.formUnion(leafValues($1)) } }
        return ["\(value)"]
    }

    /// The decoded pixels of `frame`, as ImageIO's decode buffer.
    private static func pixels(_ png: Data, frame: Int = 0) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, frame, nil),
              let data = image.dataProvider?.data else { return nil }
        return Data([UInt8(image.width & 0xFF), UInt8(image.height & 0xFF)]) + (data as Data)
    }

    /// Every original ImageIO property (each frame's dictionaries, every key), every value in ImageIO's merged XMP view
    /// and the decoded pixels are the same in `output`; only Phocasa's rating and keywords may differ or be new.
    private func assertKeepsEverything(original: Data, output: Data, frames: Int = 1,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let phocasaIPTC: Set<String> = ["Keywords", "StarRating"]
        for frame in 0..<frames {
            let before = Self.properties(original, frame: frame), after = Self.properties(output, frame: frame)
            XCTAssertFalse(before.isEmpty, "fixture: the original reads", file: file, line: line)
            for (key, value) in before where key != "{IPTC}" {
                XCTAssertEqual(after[key] as? NSObject, value as? NSObject, "frame \(frame): \(key) must be kept", file: file, line: line)
            }
            for key in after.keys where before[key] == nil {
                XCTAssertEqual(key, "{IPTC}", "frame \(frame): only Phocasa's IPTC view is new", file: file, line: line)
            }
            let iptcBefore = (before["{IPTC}"] as? [String: Any] ?? [:]).filter { !phocasaIPTC.contains($0.key) }
            let iptcAfter = (after["{IPTC}"] as? [String: Any] ?? [:]).filter { !phocasaIPTC.contains($0.key) }
            for (key, value) in iptcBefore {
                XCTAssertEqual(iptcAfter[key] as? NSObject, value as? NSObject, "frame \(frame): {IPTC}.\(key) must be kept",
                               file: file, line: line)
            }
            // Once a PNG has an XMP packet, ImageIO's IPTC view also shows values it builds from the eXIf and text
            // chunks (Byline from Artist/Author, CopyrightNotice from Copyright). Those must be values already there.
            let known = Self.leafValues(before)
            for (key, value) in iptcAfter where iptcBefore[key] == nil {
                XCTAssertTrue(Self.leafValues(value).isSubset(of: known), "frame \(frame): {IPTC}.\(key) = \(value) is invented",
                              file: file, line: line)
            }
            XCTAssertEqual(Self.pixels(output, frame: frame), Self.pixels(original, frame: frame),
                           "frame \(frame): the decode is identical", file: file, line: line)
            XCTAssertNotNil(Self.pixels(output, frame: frame), file: file, line: line)
        }
        let xmpBefore = Self.mergedXMP(original), xmpAfter = Self.mergedXMP(output)
        for (path, value) in xmpBefore where !Self.isPhocasas(path) {
            XCTAssertEqual(xmpAfter[path], value, "ImageIO's merged XMP \(path) must be kept", file: file, line: line)
        }
        for path in xmpAfter.keys where xmpBefore[path] == nil {
            XCTAssertTrue(Self.isPhocasas(path) || path == "iio:hasXMP", "\(path) is new", file: file, line: line)
        }
    }

    /// Every chunk but the XMP one, byte for byte and in the same order, the bytes after IEND too, and every CRC valid.
    private func assertOnlyXMPChanged(original: Data, output: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try XCTUnwrap(TestPNG(original), file: file, line: line)
        let after = try XCTUnwrap(TestPNG(output), "the output is whole chunks up to IEND", file: file, line: line)
        XCTAssertTrue(after.chunks.allSatisfy(\.crcIsValid), "every CRC is valid: \(after.chunks.filter { !$0.crcIsValid })",
                      file: file, line: line)
        XCTAssertEqual(after.xmpChunks.count, 1, "one XMP chunk", file: file, line: line)
        let beforeXMP = Set(before.xmpChunks.map(\.index)), afterXMP = Set(after.xmpChunks.map(\.index))
        let keptBefore = before.chunks.enumerated().filter { !beforeXMP.contains($0.offset) }.map(\.element.bytes)
        let keptAfter = after.chunks.enumerated().filter { !afterXMP.contains($0.offset) }.map(\.element.bytes)
        XCTAssertEqual(keptAfter.count, keptBefore.count, "no chunk added or lost", file: file, line: line)
        XCTAssertTrue(keptAfter == keptBefore, "every other chunk byte for byte, in order", file: file, line: line)
        XCTAssertEqual(after.trailing, before.trailing, "the bytes after IEND", file: file, line: line)
        XCTAssertEqual(Data(output.prefix(8)), TestPNG.signature, file: file, line: line)
        // The XMP chunk sits before the image data (ImageIO reads XMP only there), and before an APNG's first frame.
        let xmpIndex = try XCTUnwrap(after.xmpChunks.first?.index, file: file, line: line)
        let firstImage = try XCTUnwrap(after.types.firstIndex { $0 == "IDAT" || $0 == "fcTL" }, file: file, line: line)
        XCTAssertLessThan(xmpIndex, firstImage, "the XMP comes before the image data", file: file, line: line)
    }

    /// Every value of the XMP packet in `png`'s XMP chunk.
    private func packetValues(_ png: Data) throws -> [String: String] {
        KeptMetadata.xmpValues(try XCTUnwrap(TestPNG(png)?.xmpChunks.first?.text.text))
    }

    // MARK: isPNG

    func testIsPNGChecksTheSignature() throws {
        XCTAssertTrue(PNGMetadata.isPNG(try RichPNG.make().data))
        XCTAssertTrue(PNGMetadata.isPNG(TestPNG.signature))
        XCTAssertFalse(PNGMetadata.isPNG(MetadataJPEGPreservationTests.imageIOJPEG()))
        XCTAssertFalse(PNGMetadata.isPNG(Data()))
        XCTAssertFalse(PNGMetadata.isPNG(TestPNG.signature.prefix(7)))
        var wrong = TestPNG.signature
        wrong[4] = 0x0A
        XCTAssertFalse(PNGMetadata.isPNG(wrong))
        // A slice whose indices don't start at 0.
        let padded = Data([1, 2, 3]) + TestPNG.signature
        XCTAssertTrue(PNGMetadata.isPNG(padded.dropFirst(3)))
    }

    // MARK: Writes

    func testAPNGWithoutXMPGetsItsOwnChunkBeforeTheImageData() throws {
        let rich = try RichPNG.make(trailing: Data("bytes after IEND".utf8))
        let url = try file(rich.data)
        XCTAssertTrue(TestPNG(rich.data)!.xmpChunks.isEmpty, "fixture: no XMP")
        var handed: Data?? = .none
        let output = try XCTUnwrap(PNGMetadata.replacingXMP(in: rich.data) {
            handed = .some($0)
            return MetadataService.xmpPacket(rating: 4, keywords: ["people:ann", "beach"], updating: $0)
        })
        XCTAssertEqual(handed, .some(nil), "update is told there is no packet")

        try writeRating(4, ["people:ann", "beach"], to: url)

        XCTAssertEqual(try Data(contentsOf: url), output)
        try assertOnlyXMPChanged(original: rich.data, output: output)
        let before = TestPNG(rich.data)!, after = TestPNG(output)!
        let firstIDAT = try XCTUnwrap(before.types.firstIndex(of: "IDAT"))
        XCTAssertEqual(after.xmpChunks.first?.index, firstIDAT, "inserted right before the first IDAT, as ImageIO writes it")
        let text = try XCTUnwrap(after.xmpChunks.first?.text)
        XCTAssertEqual(text.header, Data("XML:com.adobe.xmp".utf8) + Data([0, 0, 0, 0, 0]),
                       "XMP spec part 3: uncompressed, no language tag or translated keyword")
        XCTAssertEqual(output.count, rich.data.count + 12 + text.header.count + text.text.count, "only the new chunk is added")
        XCTAssertEqual(TestExifReader(after.chunks.first { $0.type == "eXIf" }!.data)?.makerNote, rich.makerNote)
        try assertFileReads(url, rating: 4, keywords: ["people:ann", "beach"])
        assertKeepsEverything(original: rich.data, output: output)
    }

    func testAnExistingXMPChunkIsUpdatedInPlace() throws {
        let rich = try RichPNG.make(xmp: .beforeImageData(compressed: false))
        let url = try file(rich.data)
        let before = TestPNG(rich.data)!
        XCTAssertEqual(MetadataService.shared.readMetadata(from: url.path).rating, 2, "fixture: rated 2 by another app")
        var handed: Data?
        _ = PNGMetadata.replacingXMP(in: rich.data) { handed = $0; return $0 }
        XCTAssertEqual(handed, Data(RichPNG.otherAppXMP.utf8), "update gets the file's packet")

        let output = try XCTUnwrap(try writeRating(5, ["new", "people:zoë"], to: url))

        try assertOnlyXMPChanged(original: rich.data, output: output)
        let after = TestPNG(output)!
        XCTAssertEqual(after.types, before.types, "same chunks, same order")
        XCTAssertEqual(after.xmpChunks.first?.index, before.xmpChunks.first?.index, "in place")
        XCTAssertEqual(after.xmpChunks.first?.text.header, before.xmpChunks.first?.text.header, "the chunk's header is kept")
        let old = KeptMetadata.xmpValues(Data(RichPNG.otherAppXMP.utf8))
        let new = try packetValues(output)
        XCTAssertGreaterThan(old.count, 12, "fixture: a rich packet")
        for (path, value) in old where !Self.isPhocasas(path) {
            XCTAssertEqual(new[path], value, "the other app's XMP \(path) is kept")
        }
        try assertFileReads(url, rating: 5, keywords: ["new", "people:zoë"])
        assertKeepsEverything(original: rich.data, output: output)
    }

    func testAnXMPChunksLanguageTagAndTranslatedKeywordAreKept() throws {
        // Unusual (XMP spec part 3 leaves both empty), but ImageIO reads it, and the chunk's header isn't Phocasa's.
        var chunks = try richChunks()
        chunks.insert(TestPNG.iTXt(TestPNG.xmpKeyword, Data(RichPNG.otherAppXMP.utf8), language: "en", translated: "Metadata"),
                      at: 2)
        let original = TestPNG.assemble(chunks)
        let url = try file(original)
        XCTAssertEqual(MetadataService.shared.readMetadata(from: url.path).rating, 2, "fixture: ImageIO reads it")

        let output = try XCTUnwrap(try writeRating(1, ["tagged"], to: url))

        try assertOnlyXMPChanged(original: original, output: output)
        let text = try XCTUnwrap(TestPNG(output)?.xmpChunks.first?.text)
        XCTAssertEqual(text.language, "en")
        XCTAssertEqual(text.translated, "Metadata")
        XCTAssertEqual(text.header, TestPNG(original)?.xmpChunks.first?.text.header)
        try assertFileReads(url, rating: 1, keywords: ["tagged"])
        assertKeepsEverything(original: original, output: output)
    }

    func testRepeatedWritesAreStableAndDontGrowTheFile() throws {
        for xmp in [RichPNG.XMP.none, .beforeImageData(compressed: false), .beforeImageData(compressed: true)] {
            let rich = try RichPNG.make(xmp: xmp)
            let url = try file(rich.data, "repeat.png")
            let steps: [(Int, [String])] = [(1, ["a"]), (5, ["a", "b", "people:ann"]), (3, ["c"]), (0, ["c"]), (0, [])]
            var previous = rich.data
            for (rating, keywords) in steps {
                let output = try XCTUnwrap(try writeRating(rating, keywords, to: url), "\(xmp) \(rating)")
                try assertOnlyXMPChanged(original: rich.data, output: output)
                try assertOnlyXMPChanged(original: previous, output: output)
                try assertFileReads(url, rating: rating, keywords: keywords)
                assertKeepsEverything(original: rich.data, output: output)
                let old = TestPNG(previous)!.xmpChunks.first.map { TestPNG(previous)!.chunks[$0.index].bytes.count } ?? 0
                let new = TestPNG(output)!.chunks[TestPNG(output)!.xmpChunks[0].index].bytes.count
                XCTAssertEqual(output.count, previous.count - old + new, "\(xmp): only the XMP chunk changes size")
                previous = output
            }
            // The same values again: the same bytes.
            let again = try XCTUnwrap(try writeRating(0, [], to: url))
            XCTAssertEqual(again, previous, "\(xmp): a repeated write is stable")
            XCTAssertLessThan(again.count, rich.data.count + 1024, "\(xmp): the file doesn't grow")
            try FileManager.default.removeItem(at: url)
        }
    }

    func testAnXMPChunkAfterTheImageDataMovesBeforeIt() throws {
        let rich = try RichPNG.make(xmp: .afterImageData)
        XCTAssertEqual(MetadataService.shared.readMetadata(from: try file(rich.data, "probe.png").path).rating, 0,
                       "fixture: ImageIO doesn't read XMP after the image data")
        let url = try file(rich.data)
        var handed: Data?
        _ = PNGMetadata.replacingXMP(in: rich.data) { handed = $0; return $0 }
        XCTAssertEqual(handed, Data(RichPNG.otherAppXMP.utf8), "update gets the file's packet")

        let output = try XCTUnwrap(try writeRating(3, ["moved"], to: url))

        try assertOnlyXMPChanged(original: rich.data, output: output)
        let before = TestPNG(rich.data)!, after = TestPNG(output)!
        XCTAssertEqual(after.xmpChunks.first?.index, before.types.firstIndex(of: "IDAT"), "right before the first IDAT")
        XCTAssertEqual(after.xmpChunks.first?.text.header, before.xmpChunks.first?.text.header, "the chunk's header is kept")
        for (path, value) in KeptMetadata.xmpValues(Data(RichPNG.otherAppXMP.utf8)) where !Self.isPhocasas(path) {
            XCTAssertEqual(try packetValues(output)[path], value, "the other app's XMP \(path) is kept")
        }
        try assertFileReads(url, rating: 3, keywords: ["moved"])
        // ImageIO didn't see the packet before, so its view now has the packet's values too. Against the same file
        // with the packet moved by hand, only Phocasa's values differ.
        var moved = before.chunks.map(\.bytes)
        let packetChunk = moved.remove(at: try XCTUnwrap(before.xmpChunks.first?.index))
        moved.insert(packetChunk, at: try XCTUnwrap(before.types.firstIndex(of: "IDAT")))
        assertKeepsEverything(original: TestPNG.assemble(moved, trailing: before.trailing), output: output)
        XCTAssertEqual(Self.pixels(output), Self.pixels(rich.data))
    }

    func testACompressedXMPChunkStaysCompressed() throws {
        let rich = try RichPNG.make(xmp: .beforeImageData(compressed: true))
        let url = try file(rich.data)
        XCTAssertEqual(MetadataService.shared.readMetadata(from: url.path).rating, 2, "fixture: ImageIO reads compressed XMP")
        var handed: Data?
        _ = PNGMetadata.replacingXMP(in: rich.data) { handed = $0; return $0 }
        XCTAssertEqual(handed, Data(RichPNG.otherAppXMP.utf8), "update gets the inflated packet")

        let output = try XCTUnwrap(try writeRating(4, ["zipped"], to: url))

        try assertOnlyXMPChanged(original: rich.data, output: output)
        let before = TestPNG(rich.data)!, after = TestPNG(output)!
        XCTAssertEqual(after.xmpChunks.first?.index, before.xmpChunks.first?.index, "in place")
        let text = try XCTUnwrap(after.xmpChunks.first?.text)
        XCTAssertTrue(text.compressed, "still compressed")
        XCTAssertEqual(text.method, 0)
        XCTAssertEqual(text.header, before.xmpChunks.first?.text.header, "the chunk's header is kept")
        for (path, value) in KeptMetadata.xmpValues(Data(RichPNG.otherAppXMP.utf8)) where !Self.isPhocasas(path) {
            XCTAssertEqual(try packetValues(output)[path], value, "the other app's XMP \(path) is kept")
        }
        try assertFileReads(url, rating: 4, keywords: ["zipped"])
        assertKeepsEverything(original: rich.data, output: output)
    }

    func testAPalettePNGGetsItsXMPAfterThePaletteChunks() throws {
        let header = Data([0, 0, 0, 4, 0, 0, 0, 4, 8, 3, 0, 0, 0])
        let rows = (0..<4).reduce(Data()) { d, y in d + Data([0] + (0..<4).map { UInt8(($0 + y) % 4) }) }
        let original = TestPNG.assemble([
            TestPNG.chunk("IHDR", header),
            TestPNG.chunk("PLTE", Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])),
            TestPNG.chunk("tRNS", Data([0, 128])),
            TestPNG.chunk("bKGD", Data([1])),
            TestPNG.chunk("IDAT", TestPNG.zlibCompressed(rows)),
            TestPNG.chunk("IEND", Data()),
        ])
        XCTAssertNotNil(Self.pixels(original), "fixture: decodes")
        let url = try file(original)

        let output = try XCTUnwrap(try writeRating(2, ["palette"], to: url))

        try assertOnlyXMPChanged(original: original, output: output)
        XCTAssertEqual(TestPNG(output)?.types, ["IHDR", "PLTE", "tRNS", "bKGD", "iTXt", "IDAT", "IEND"])
        try assertFileReads(url, rating: 2, keywords: ["palette"])
        assertKeepsEverything(original: original, output: output)
    }

    /// An animated PNG (as ImageIO writes one): the XMP goes before the first frame's `fcTL`, where ImageIO puts it,
    /// and every frame decodes as before.
    func testAnAnimatedPNGKeepsEveryFrame() throws {
        for withXMP in [false, true] {
            let out = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 2, nil))
            CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
            let pattern = try RichPNG.encodedPixels(width: 40, height: 30)
            let frames = try [
                TestPNG.assemble([pattern.header, TestPNG.chunk("IDAT", pattern.imageData), TestPNG.chunk("IEND", Data())]),
                MetadataJPEGPreservationTests.imageIOJPEG(width: 40, height: 30),
            ].map { data in
                try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            }
            let delay = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.25]] as CFDictionary
            if withXMP {
                let meta = CGImageMetadataCreateMutable()
                XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "xmp:CreatorTool" as CFString, "Animator" as CFString))
                CGImageDestinationAddImageAndMetadata(destination, frames[0], meta, delay)
            } else {
                CGImageDestinationAddImage(destination, frames[0], delay)
            }
            CGImageDestinationAddImage(destination, frames[1], delay)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = out as Data
            let types = try XCTUnwrap(TestPNG(original)).types
            XCTAssertTrue(types.contains("acTL") && types.contains("fdAT"), "fixture: an APNG \(types)")
            let url = try file(original, "anim.png")

            let output = try XCTUnwrap(try writeRating(3, ["anim"], to: url), "withXMP \(withXMP)")

            try assertOnlyXMPChanged(original: original, output: output)
            let after = TestPNG(output)!
            XCTAssertEqual(after.xmpChunks.first?.index, after.types.firstIndex(of: "fcTL").map { $0 - 1 },
                           "right before the first fcTL")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 2)
            try assertFileReads(url, rating: 3, keywords: ["anim"])
            assertKeepsEverything(original: original, output: output, frames: 2)
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Last resorts: the file is kept and the caller writes a sidecar

    private func assertRefused(_ png: Data, _ refusal: PNGMetadata.Refusal, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        var called = false
        let result = PNGMetadata.rewritingXMP(in: png) { called = true; return MetadataService.xmpPacket(rating: 1, keywords: ["k"], updating: $0) }
        switch result {
        case .success: XCTFail("\(message): refused as \(refusal), but written", file: file, line: line)
        case .failure(let reason): XCTAssertEqual(reason, refusal, message, file: file, line: line)
        }
        XCTAssertNil(PNGMetadata.replacingXMP(in: png) { MetadataService.xmpPacket(rating: 1, keywords: ["k"], updating: $0) },
                     message, file: file, line: line)
        if refusal != .updateRefused, refusal != .packetNotUTF8 {
            XCTAssertFalse(called, "\(message): refused before the packet is built", file: file, line: line)
        }
    }

    /// The rich PNG's chunks, to rearrange.
    private func richChunks(xmp: RichPNG.XMP = .none) throws -> [Data] {
        try XCTUnwrap(TestPNG(try RichPNG.make(xmp: xmp).data)).chunks.map(\.bytes)
    }

    private func index(of type: String, in chunks: [Data]) -> Int {
        chunks.firstIndex { String(decoding: $0[4..<8], as: UTF8.self) == type }!
    }

    func testSomethingThatIsntAPNGIsRefused() throws {
        assertRefused(Data(), .notPNG, "empty")
        assertRefused(MetadataJPEGPreservationTests.imageIOJPEG(), .notPNG, "a JPEG")
        var wrong = try RichPNG.make().data
        wrong[1] = 0x51
        assertRefused(wrong, .notPNG, "a wrong signature")
    }

    func testADamagedPNGIsRefused() throws {
        let rich = try RichPNG.make().data
        let chunks = try richChunks()
        let firstIDAT = index(of: "IDAT", in: chunks)

        assertRefused(TestPNG.signature, .damaged(.truncated), "just the signature")
        assertRefused(rich.prefix(rich.count - 6), .damaged(.truncated), "cut inside IEND")
        assertRefused(rich.prefix(chunks[..<(firstIDAT + 1)].reduce(8) { $0 + $1.count }), .damaged(.truncated),
                      "ends after an IDAT, no IEND")
        assertRefused(rich.prefix(rich.count / 2), .damaged(.truncated), "cut in the image data")

        var huge = chunks
        huge[3].replaceSubrange(0..<4, with: [0x80, 0, 0, 0])
        assertRefused(TestPNG.assemble(huge), .damaged(.badLength), "a length over 2^31 - 1")

        var badType = chunks
        badType.insert(TestPNG.chunk("t3Xt", Data("x".utf8)), at: 2)
        assertRefused(TestPNG.assemble(badType), .damaged(.badType), "a type byte that isn't a letter")

        for (name, at) in [("tEXt", index(of: "tEXt", in: chunks)), ("IDAT", firstIDAT + 1), ("tIME", index(of: "tIME", in: chunks)),
                           ("IEND", chunks.count - 1)] {
            var badCRC = chunks
            badCRC[at][badCRC[at].count - 1] ^= 0x01
            assertRefused(TestPNG.assemble(badCRC), .damaged(.badCRC), "a bad CRC on \(name)")
        }
        var badData = chunks
        badData[firstIDAT][10] ^= 0x40
        assertRefused(TestPNG.assemble(badData), .damaged(.badCRC), "a damaged IDAT")

        var headerLate = chunks
        headerLate.swapAt(0, 1)
        assertRefused(TestPNG.assemble(headerLate), .damaged(.misplacedHeader), "IHDR not first")
        var twoHeaders = chunks
        twoHeaders.insert(chunks[0], at: 2)
        assertRefused(TestPNG.assemble(twoHeaders), .damaged(.misplacedHeader), "a second IHDR")

        assertRefused(TestPNG.assemble(chunks.filter { !$0[4..<8].elementsEqual("IDAT".utf8) }), .damaged(.noImageData), "no IDAT")
        var split = chunks
        split.insert(TestPNG.tEXt("Between", "the IDATs"), at: firstIDAT + 1)
        assertRefused(TestPNG.assemble(split), .damaged(.splitImageData), "IDATs not consecutive")
    }

    func testAnAppleCrushedPNGIsRefused() throws {
        // Xcode's pngcrush for iOS bundles: a CgBI chunk before IHDR, then non-standard image data.
        var chunks = try richChunks()
        chunks.insert(TestPNG.chunk("CgBI", Data([0x50, 0x00, 0x20, 0x06])), at: 0)
        assertRefused(TestPNG.assemble(chunks), .appleCrushed)
    }

    func testAnUnknownCriticalChunkIsRefused() throws {
        let chunks = try richChunks()
        for at in [2, index(of: "IDAT", in: chunks), chunks.count - 1] {
            var withUnknown = chunks
            withUnknown.insert(TestPNG.chunk("ABCD", Data([1, 2])), at: at)
            assertRefused(TestPNG.assemble(withUnknown), .unknownCriticalChunk("ABCD"), "at \(at)")
        }
    }

    func testSeveralXMPChunksAreRefused() throws {
        let chunks = try richChunks(xmp: .beforeImageData(compressed: false))
        let second = TestPNG.iTXt(TestPNG.xmpKeyword, Data(SidecarFixtures.lightroom.utf8))
        for at in [1, index(of: "IDAT", in: chunks), chunks.count - 1] {
            var two = chunks
            two.insert(second, at: at)
            assertRefused(TestPNG.assemble(two), .severalXMPChunks, "a second one at \(at)")
        }
    }

    func testAnXMPChunkThatCantBeReadIsRefused() throws {
        let chunks = try richChunks()
        let at = index(of: "IDAT", in: chunks)
        let packet = Data(RichPNG.otherAppXMP.utf8)
        func with(_ chunk: Data) -> Data {
            var c = chunks
            c.insert(chunk, at: at)
            return TestPNG.assemble(c)
        }
        let keyword = Data(TestPNG.xmpKeyword.utf8)
        assertRefused(with(TestPNG.chunk("iTXt", keyword + Data([0, 2, 0, 0, 0]) + packet)), .unreadableXMPChunk,
                      "an unknown compression flag")
        assertRefused(with(TestPNG.iTXt(TestPNG.xmpKeyword, packet, compressed: true, method: 1)), .unreadableXMPChunk,
                      "an unknown compression method")
        assertRefused(with(TestPNG.chunk("iTXt", keyword + Data([0, 1, 0, 0, 0]) + Data("not zlib at all".utf8))),
                      .unreadableXMPChunk, "damaged compressed text")
        assertRefused(with(TestPNG.chunk("iTXt", keyword + Data([0, 1, 0, 0, 0]) + TestPNG.zlibCompressed(packet).dropLast(3))),
                      .unreadableXMPChunk, "cut compressed text")
        assertRefused(with(TestPNG.chunk("iTXt", keyword + Data([0, 1, 0, 0, 0]) + TestPNG.zlibCompressed(packet) + Data([1, 2]))),
                      .unreadableXMPChunk, "bytes after the compressed text")
        assertRefused(with(TestPNG.chunk("iTXt", keyword + Data([0, 0, 0]) + Data("en".utf8))), .unreadableXMPChunk,
                      "no language tag terminator")
        assertRefused(with(TestPNG.chunk("iTXt", keyword + Data([0, 0]))), .unreadableXMPChunk, "no compression method")
        assertRefused(with(TestPNG.chunk("iTXt", keyword)), .unreadableXMPChunk, "just the keyword")
        // Inflating past the limit (a packet of 64 MiB and more) isn't attempted.
        let bomb = Data(repeating: 0x20, count: PNGMetadata.maxPacketSize + 1)
        assertRefused(with(TestPNG.iTXt(TestPNG.xmpKeyword, bomb, compressed: true)), .unreadableXMPChunk, "too large once inflated")
    }

    func testXMPInATextChunkIsRefused() throws {
        // ImageIO ignores these, exiftool reads them: a second XMP that would disagree with the new one.
        let chunks = try richChunks()
        let packet = Data(RichPNG.otherAppXMP.utf8)
        for chunk in [TestPNG.chunk("tEXt", Data(TestPNG.xmpKeyword.utf8) + Data([0]) + packet),
                      TestPNG.zTXt(TestPNG.xmpKeyword, packet)] {
            for at in [1, chunks.count - 1] {
                var c = chunks
                c.insert(chunk, at: at)
                assertRefused(TestPNG.assemble(c), .xmpInTextChunk, "at \(at)")
            }
        }
    }

    func testXMPInARawProfileIsRefused() throws {
        // ImageMagick's hex profile, which ImageIO reads as XMP (the first XMP it finds wins).
        let chunks = try richChunks(xmp: .none)
        let profile = TestPNG.rawProfile("xmp", Data(RichPNG.otherAppXMP.utf8))
        let variants: [(String, Data)] = [
            ("zTXt", TestPNG.zTXt("Raw profile type xmp", profile)),
            ("tEXt", TestPNG.chunk("tEXt", Data("Raw profile type xmp".utf8) + Data([0]) + profile)),
            ("iTXt", TestPNG.iTXt("Raw profile type xmp", profile)),
            ("upper case", TestPNG.zTXt("Raw profile type XMP", profile)),
        ]
        for (name, chunk) in variants {
            for at in [1, chunks.count - 1] {
                var c = chunks
                c.insert(chunk, at: at)
                assertRefused(TestPNG.assemble(c), .xmpInRawProfile, "\(name) at \(at)")
            }
        }
        // Other raw profiles (Exif, IPTC) aren't XMP: kept byte for byte like any chunk.
        var exif = chunks
        exif.insert(TestPNG.zTXt("Raw profile type iptc", TestPNG.rawProfile("iptc", Data([0x1C, 2, 25, 0, 1, 0x41]))), at: 1)
        let original = TestPNG.assemble(exif)
        let output = try XCTUnwrap(PNGMetadata.replacingXMP(in: original) { MetadataService.xmpPacket(rating: 1, keywords: [], updating: $0) })
        try assertOnlyXMPChanged(original: original, output: output)
    }

    func testARefusedUpdateIsRefused() throws {
        let rich = try RichPNG.make(xmp: .beforeImageData(compressed: false)).data
        XCTAssertEqual(PNGMetadata.rewritingXMP(in: rich) { _ in nil }, .failure(.updateRefused))
        // A packet ImageIO can't parse: `xmpPacket` refuses it, so nothing is written.
        var chunks = try richChunks()
        chunks.insert(TestPNG.iTXt(TestPNG.xmpKeyword, Data("<x:xmpmeta><rdf:RDF><broken".utf8)), at: 2)
        assertRefused(TestPNG.assemble(chunks), .updateRefused, "an unparseable packet")
    }

    func testANewPacketThatIsntUTF8IsRefused() throws {
        let rich = try RichPNG.make().data
        XCTAssertEqual(PNGMetadata.rewritingXMP(in: rich) { _ in Data([0x3C, 0xFF, 0xFE, 0x3E]) }, .failure(.packetNotUTF8))
    }

    func testAPacketTooLargeIsRefused() throws {
        let rich = try RichPNG.make().data
        XCTAssertEqual(PNGMetadata.rewritingXMP(in: rich) { _ in Data(repeating: 0x20, count: PNGMetadata.maxPacketSize + 1) },
                       .failure(.packetTooLarge))
    }

    // MARK: A real camera photo

    /// A PNG ImageIO makes from the real camera JPG next to `PHOCASA_TEST_RAW` (a copy), with its Exif, GPS and TIFF
    /// properties: rated, everything kept.
    func testARealCameraPhotoAsAPNGKeepsEverything() throws {
        guard let raw = ProcessInfo.processInfo.environment["PHOCASA_TEST_RAW"], !raw.isEmpty else {
            throw XCTSkip("set PHOCASA_TEST_RAW to a copy of a camera RAW with its JPG beside it")
        }
        let jpgSource = try XCTUnwrap(["JPG", "jpg", "jpeg", "JPEG"]
            .map { URL(fileURLWithPath: raw).deletingPathExtension().appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }, "no JPG beside PHOCASA_TEST_RAW")
        let jpg = dir.appendingPathComponent(jpgSource.lastPathComponent)
        try FileManager.default.copyItem(at: jpgSource, to: jpg)
        let url = dir.appendingPathComponent("camera.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)
        let props = Self.properties(original)
        XCTAssertNotNil(props["{Exif}"], "fixture: Exif carried into the PNG")
        XCTAssertNotNil(props["{GPS}"] ?? props["{TIFF}"], "fixture: GPS or TIFF carried into the PNG")

        let output = try XCTUnwrap(try writeRating(4, ["people:ann", "beach"], to: url))

        try assertOnlyXMPChanged(original: original, output: output)
        try assertFileReads(url, rating: 4, keywords: ["people:ann", "beach"])
        assertKeepsEverything(original: original, output: output)
        // What the edit costs on a 16 MP PNG (the whole file's CRCs, then the copy), best of 5.
        let times = (0..<5).map { _ -> Double in
            let start = CFAbsoluteTimeGetCurrent()
            _ = PNGMetadata.replacingXMP(in: original) { MetadataService.xmpPacket(rating: 2, keywords: ["x"], updating: $0) }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        let walk = (0..<5).map { _ -> Double in
            let start = CFAbsoluteTimeGetCurrent()
            _ = PNGMetadata.walk(original)
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        print("BENCH|png-real|bytes=\(original.count)|chunks=\(TestPNG(original)!.types.count)"
              + "|types=\(Set(TestPNG(original)!.types).sorted().joined(separator: ","))"
              + String(format: "|edit_ms=%.2f|walk_ms=%.2f", times.min() ?? 0, walk.min() ?? 0))
    }
}
