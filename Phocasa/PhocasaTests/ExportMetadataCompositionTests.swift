import XCTest
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
@testable import Phocasa

/// The pieces that carry a photo's metadata into an export (`ExportMetadata`) and keep a Photoshop APP13 intact
/// through a keyword write (`PhotoshopIRB`), on hand-built inputs.
final class ExportMetadataCompositionTests: XCTestCase {
    private typealias T = MetadataJPEGPreservationTests
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-exportcompose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// New upright pixels, as the export encodes them: no metadata of their own.
    private func encoded(width: Int = 160, height: Int = 240) throws -> Data {
        try RichJPEG.encodedPixels(width: width, height: height)
    }

    // MARK: - Transplant from a JPEG

    func testBigEndianExifWithShortDimensionsIsPatchedInPlace() throws {
        let rich = try RichJPEG.make(bigEndian: true, shortDimensions: true)
        let source = try write(rich.data, "be.jpg")

        let output = try XCTUnwrap(ExportMetadata.jpeg(encoded: try encoded(), metadataFrom: source))

        KeptMetadata.assertKeeps(original: rich.data, output: output, pixelSize: CGSize(width: 160, height: 240),
                                 rating: 2, keywords: ["old", "older"], readBack: nil)
        let exif = try XCTUnwrap(JPEGTestSegments.exifTIFF(output))
        XCTAssertEqual(exif.count, try XCTUnwrap(JPEGTestSegments.exifTIFF(rich.data)).count, "patched in place")
    }

    func testTheImageDataIsTheNewPixelsAndTheCodecSegmentsAreTheEncoders() throws {
        let rich = try RichJPEG.make()
        let new = try encoded()
        let output = try XCTUnwrap(ExportMetadata.jpeg(encoded: new, metadataFrom: try write(rich.data, "r.jpg")))
        XCTAssertEqual(JPEGTestSegments.codec(output).segments, JPEGTestSegments.codec(new).segments)
        XCTAssertEqual(JPEGTestSegments.codec(output).tail, JPEGTestSegments.codec(new).tail)
    }

    func testAnExifStructureThatCantBeWalkedIsRefused() throws {
        let rich = try RichJPEG.make()
        var (segments, sos) = T.header(rich.data)
        let exifIndex = try XCTUnwrap(segments.firstIndex { $0.id == "Exif" })
        var payload = [UInt8](segments[exifIndex].bytes.dropFirst(4))
        payload[10 + 4] = 0xF0; payload[10 + 5] = 0xFF     // IFD0 offset far past the end
        segments[exifIndex] = T.segment(0xE1, Data(payload))
        let broken = T.assemble(segments, tail: rich.data[sos...])

        XCTAssertNil(ExportMetadata.jpeg(encoded: try encoded(), metadataFrom: try write(broken, "broken.jpg")))
    }

    func testAJPEGWithoutMetadataGivesTheEncodedImage() throws {
        let plain = try encoded(width: 240, height: 160)
        let new = try encoded()
        let output = try XCTUnwrap(ExportMetadata.jpeg(encoded: new, metadataFrom: try write(plain, "plain.jpg")))
        XCTAssertEqual(JPEGTestSegments.codec(output).tail, JPEGTestSegments.codec(new).tail)
        XCTAssertEqual(KeptMetadata.properties(output)[kCGImagePropertyPixelWidth as String] as? Int, 160)
    }

    func testAJFIFThumbnailOfTheOldPixelsIsDropped() throws {
        let rich = try RichJPEG.make()
        let (segments, sos) = T.header(rich.data)
        // JFIF 1.02, density 300×300 dpi, and a 2×1 RGB thumbnail.
        let jfif = T.segment(0xE0, Data("JFIF".utf8) + Data([0, 1, 2, 1, 0x01, 0x2C, 0x01, 0x2C, 2, 1, 9, 9, 9, 8, 8, 8]))
        let withJFIF = T.assemble([jfif] + segments, tail: rich.data[sos...])

        let output = try XCTUnwrap(ExportMetadata.jpeg(encoded: try encoded(), metadataFrom: try write(withJFIF, "jfif.jpg")))

        let app0 = try XCTUnwrap(JPEGTestSegments.segments(output).first { $0.marker == 0xE0 })
        XCTAssertEqual(app0.bytes, T.segment(0xE0, Data("JFIF".utf8) + Data([0, 1, 2, 1, 0x01, 0x2C, 0x01, 0x2C, 0, 0])).bytes,
                       "the density is kept, the thumbnail goes")
    }

    // MARK: - Exif patch

    func testAThumbnailInsideTheMakerNoteIsUnlinkedButNotZeroed() throws {
        let w = TIFFWriter()
        let makerNote = [UInt8](repeating: 0x77, count: 64)
        let ifd0 = w.appendIFD([w.short(0x0112, 8), w.long(0x8769, 0)])
        let exif = w.appendIFD([w.undefined(0x927C, makerNote)])
        w.patch32(at: ifd0.valueFields[0x8769]!, exif.offset)
        let ifd1 = w.appendIFD([w.long(0x0201, UInt32(exif.valueOffsets[0x927C]! + 8)), w.long(0x0202, 16)])
        w.patch32(at: ifd0.nextPointer, ifd1.offset)

        let patched = try XCTUnwrap(ExifPatch.patched(Data(w.bytes), pixelWidth: 10, pixelHeight: 20, sRGB: true))

        let reader = try XCTUnwrap(TestExifReader(patched))
        XCTAssertEqual(reader.orientation, 1)
        XCTAssertEqual(reader.nextIFD(after: reader.ifd0), 0)
        XCTAssertEqual(reader.makerNote, Data(makerNote), "a MakerNote is never changed")
    }

    // MARK: - Photoshop IRB keywords

    func testKeywordsCantBeWrittenOverIPTCTextOfUnknownEncoding() throws {
        let iim = IRBTestData.dataset(2, 0, [0, 4]) + IRBTestData.dataset(2, 120, [0x63, 0x61, 0x66, 0xE9])   // "café" in Latin-1
        let payload = Data(Array("Photoshop 3.0\u{0}".utf8) + IRBTestData.block(0x0404, iim))
        XCTAssertNil(PhotoshopIRB.replacingKeywords(in: payload, with: ["zoë"]),
                     "declaring UTF-8 would misread the caption, and not declaring it would misread the keyword")
        XCTAssertNotNil(PhotoshopIRB.replacingKeywords(in: payload, with: ["zoe"]), "ASCII keywords are fine")
    }

    func testAMalformedResourceBlockIsNotRewritten() throws {
        var payload = Array("Photoshop 3.0\u{0}".utf8) + IRBTestData.block(0x0404, IRBTestData.dataset(2, 25, "a"))
        payload[payload.count - 3] = 0x7F   // the IIM dataset's length now runs past the resource
        XCTAssertNil(PhotoshopIRB.replacingKeywords(in: Data(payload), with: ["b"]))
    }
}
