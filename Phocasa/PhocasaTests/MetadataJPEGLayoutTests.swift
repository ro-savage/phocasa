import XCTest
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
@testable import Phocasa

/// Rating and keyword writes into JPEGs whose layout the splice refused before post-wave-3 task D: fill bytes between
/// header segments, extended XMP, an XMP or APP13 segment after the MPF segment (and the MPF's first-image size),
/// several XMP or APP13 segments, XMP packets ImageIO can't parse or can't rewrite without changing a value, and
/// non-ASCII keywords over IPTC text of unknown encoding. Each goes into the file itself now, changing only what a
/// rating write may change; what still can't be done safely keeps the file byte-identical and gets a flagged sidecar
/// (the named last-resort cases, tested at the end). Every fixture is a hand-built rich JPEG, parsed here with a walker
/// and an MPF reader written independently of the app's.
final class MetadataJPEGLayoutTests: XCTestCase {
    private typealias T = MetadataJPEGPreservationTests
    private let service = MetadataService.shared
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-jpeglayout-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Case 1: fill bytes

    /// T.81 B.1.1.2: any marker may be preceded by 0xFF fill bytes. They're kept byte for byte, where they were.
    func testFillBytesBetweenHeaderSegmentsAreKept() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(p.xmp), .bytes(Data([0xFF, 0xFF, 0xFF])), .bytes(p.icc), .bytes(p.app13()),
            .bytes(p.app9), .bytes(Data([0xFF])), .bytes(p.com), .mpf(.init(images: [p.preview])),
        ] + p.codec.map { .bytes($0) } + [.bytes(Data([0xFF, 0xFF]))], tail: p.tail)
        XCTAssertEqual(LayoutWalk(original)?.parts.filter(\.isFill).count, 3, "fixture: three runs of fill bytes")

        try assertRatingWrite(original, "fill.jpg", xmp: .updated(partIndex: 1, textual: true), iptcChanges: true)
    }

    /// With no XMP, the new packet goes right after the Exif segment, before any fill bytes: ImageIO's XMP reader
    /// stops at the first fill byte, so an XMP segment after one would be invisible to it.
    func testANewXMPGoesBeforeTheFillBytes() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(Data([0xFF, 0xFF])), .bytes(p.icc), .bytes(p.app13()), .bytes(p.com),
            .mpf(.init(images: [p.preview])),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)

        let after = try assertRatingWrite(original, "fillnew.jpg", xmp: .inserted, iptcChanges: true)

        let parts = try XCTUnwrap(LayoutWalk(after)).parts
        XCTAssertEqual(parts[1].id, JPEGTestSegments.xmpID, "the new XMP follows the Exif segment")
        XCTAssertTrue(parts[2].isFill)
    }

    // MARK: - Case 2: extended XMP

    /// Only the standard packet changes. `xmpNote:HasExtendedXMP` (the MD5 of the extension, which doesn't change)
    /// and every extension segment stay byte-identical, and ImageIO still merges the extension.
    func testExtendedXMPIsKeptAndOnlyTheStandardPacketChanges() throws {
        let p = try RichPieces.make()
        let (standard, extensions) = RichPieces.extendedXMP()
        let original = JPEGLayout.build([.bytes(p.exif), .bytes(standard)] + extensions.map { .bytes($0) } + [
            .bytes(p.icc), .bytes(p.app13()), .bytes(p.app9), .bytes(p.com), .mpf(.init(images: [p.preview])),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)
        XCTAssertEqual(fileXMP(original)["photoshop:History"], "a long history", "fixture: ImageIO merges the extension")

        let after = try assertRatingWrite(original, "extended.jpg", xmp: .updated(partIndex: 1, textual: true),
                                          iptcChanges: true)

        XCTAssertEqual(KeptMetadata.xmpValues(JPEGTestSegments.xmpPacket(after))["xmpNote:HasExtendedXMP"],
                       RichPieces.extendedGUID, "the standard packet still names the extension")
        XCTAssertEqual(fileXMP(after)["photoshop:History"], "a long history")
        XCTAssertEqual(fileXMP(after)["crs:Big"], String(repeating: "x", count: 300))
    }

    // MARK: - Case 3: MPF

    /// The rich JPEG's own layout: the XMP comes after the MPF segment, so the secondary images move by the XMP's
    /// growth. The MP entries' offsets (counted from the MPF header) and the first image's size are patched.
    func testAnXMPSegmentAfterTheMPFSegmentPatchesTheMPEntries() throws {
        let rich = try RichJPEG.make()
        let before = try XCTUnwrap(MPFTestReader(rich.data))
        XCTAssertLessThan(before.segment.lowerBound, try XCTUnwrap(LayoutWalk(rich.data)).range(ofID: JPEGTestSegments.xmpID)!.lowerBound,
                          "fixture: the MPF segment comes before the XMP")

        let after = try assertRatingWrite(rich.data, "rich.jpg", xmp: .updated(partIndex: 2, textual: true),
                                          iptcChanges: true)

        let now = try XCTUnwrap(MPFTestReader(after))
        XCTAssertEqual(after[now.imageRange(1)], rich.mpfPreview, "the MP entry points at the preview")
    }

    /// Little-endian MPF with an MP Attribute IFD and three secondary images with gaps between them, and the XMP and
    /// APP13 after it.
    func testALittleEndianMPFWithSeveralImagesIsPatched() throws {
        let p = try RichPieces.make()
        let second = T.imageIOJPEG(width: 40, height: 30), third = T.imageIOJPEG(width: 24, height: 18)
        let original = JPEGLayout.build([
            .bytes(p.exif),
            .mpf(.init(bigEndian: false, attributeIFD: true, images: [p.preview, second, third],
                       gap: Data(repeating: 0, count: 177), trailer: Data(repeating: 0, count: 40))),
            .bytes(p.xmp), .bytes(p.icc), .bytes(p.app13()), .bytes(p.app9), .bytes(p.com),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)
        let mpf = try XCTUnwrap(MPFTestReader(original))
        XCTAssertTrue(mpf.littleEndian)
        XCTAssertEqual(mpf.entries.count, 4)
        XCTAssertEqual(original[mpf.imageRange(3)], third, "fixture")

        let after = try assertRatingWrite(original, "le.jpg", xmp: .updated(partIndex: 2, textual: true), iptcChanges: true)

        let now = try XCTUnwrap(MPFTestReader(after))
        for (k, image) in [p.preview, second, third].enumerated() {
            XCTAssertEqual(after[now.imageRange(k + 1)], image, "image \(k + 2)")
        }
    }

    /// No XMP, and an APP13 after the MPF segment: the new XMP goes before the MPF segment (the first image grows)
    /// and the APP13 after it changes size (the secondary images move).
    func testAnAPP13AfterTheMPFSegmentPatchesTheMPEntries() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([
            .bytes(p.exif), .mpf(.init(images: [p.preview])), .bytes(p.icc), .bytes(p.app13()), .bytes(p.app9),
            .bytes(p.com),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)

        try assertRatingWrite(original, "app13.jpg", xmp: .inserted, iptcChanges: true)
    }

    /// A camera JPEG's usual layout (Exif, MPF, no XMP): the new XMP goes before the MPF segment, so the offsets hold,
    /// but the first image's size (CIPA DC-007 5.2.3.3.2: SOI to EOI) grows by the XMP segment's length. Before task D
    /// it was left stale.
    func testTheFirstImagesSizeInTheMPFFollowsTheHeader() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([.bytes(p.exif), .mpf(.init(images: [p.preview])), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        let before = try XCTUnwrap(MPFTestReader(original))
        XCTAssertEqual(before.entries[0].size, original.count - p.preview.count, "fixture: SOI to EOI")

        let after = try assertRatingWrite(original, "sony.jpg", xmp: .inserted, iptcChanges: false)

        let now = try XCTUnwrap(MPFTestReader(after))
        let eoi = try XCTUnwrap(after.range(of: p.preview)).lowerBound
        XCTAssertEqual(now.entries[0].size, eoi, "the first image's size is SOI to EOI again")
    }

    // MARK: - Case 4: several XMP or APP13 segments

    /// ImageIO and Adobe's XMP Toolkit both read only the last standard XMP segment. That one gets the values; the
    /// others stay byte-identical.
    func testWithSeveralXMPSegmentsTheLastOneIsUpdated() throws {
        let p = try RichPieces.make()
        let second = T.segment(0xE1, Data(JPEGTestSegments.xmpID.utf8) + Data([0]) + Data(RichPieces.secondPacket.utf8)).bytes
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(p.xmp), .bytes(second), .bytes(p.icc), .bytes(p.app13()), .bytes(p.com),
            .mpf(.init(images: [p.preview])),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)
        XCTAssertEqual(fileXMP(original)["xmp:Label"], "Second", "fixture: ImageIO reads the last packet")
        XCTAssertNil(fileXMP(original)["acme:Flag"], "fixture: not the first packet's")

        let after = try assertRatingWrite(original, "twoxmp.jpg", xmp: .updated(partIndex: 2, textual: true),
                                          iptcChanges: true)

        XCTAssertEqual(try XCTUnwrap(LayoutWalk(after)).parts[1].bytes, p.xmp, "the first packet is kept byte for byte")
    }

    /// Several APP13 segments are one Photoshop resource stream to ImageIO and Adobe (resources can span them), so
    /// none is patched: the keywords go to the XMP only, which wins while the IPTC digest matches (MWG 2.0 §4.2.3.2).
    func testWithSeveralAPP13SegmentsTheKeywordsGoToTheXMP() throws {
        let p = try RichPieces.make()
        let (first, second) = RichPieces.splitAPP13()
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(p.xmp), .bytes(p.icc), .bytes(first), .bytes(second), .bytes(p.com),
            .mpf(.init(images: [p.preview])),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)

        try assertRatingWrite(original, "twoapp13.jpg", xmp: .updated(partIndex: 1, textual: true), iptcChanges: false)
    }

    // MARK: - Case 5: XMP packets ImageIO can't parse or can't rewrite

    /// A packet ImageIO would change on a rewrite (it drops qualifiers, empty values, `rdf:nodeID`, datatypes and
    /// `parseType="Literal"` properties, and renames `exif:DateTimeOriginal`), with no rating or keywords: the two
    /// properties are added in their own `rdf:Description`, and every byte of the packet is kept.
    func testAPacketImageIOWouldChangeGetsTheValuesAdded() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(RichPieces.xmpSegment(RichPieces.awkwardPacket(rated: false))), .bytes(p.icc),
            .bytes(p.app13()), .bytes(p.com), .mpf(.init(images: [p.preview])),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)

        try assertRatingWrite(original, "awkward.jpg", xmp: .updated(partIndex: 1, textual: true), iptcChanges: true)
    }

    /// The same packet with another app's rating and keywords: they're changed where they are.
    func testAPacketImageIOWouldChangeGetsItsRatingAndKeywordsChangedInPlace() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(RichPieces.xmpSegment(RichPieces.awkwardPacket(rated: true))), .bytes(p.icc),
            .bytes(p.app13()), .bytes(p.com), .mpf(.init(images: [p.preview])),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)
        XCTAssertEqual(service.readMetadata(from: try write(original, "probe.jpg").path).rating, 2, "fixture")

        try assertRatingWrite(original, "awkward-rated.jpg", xmp: .updated(partIndex: 1, textual: true), iptcChanges: true)
    }

    /// Photoshop 7-era packets use `x:xapmeta`, and some writers leave out the wrapper. ImageIO's JPEG reader reads
    /// both, though `CGImageMetadataCreateFromXMPData` rejects them.
    func testOldXapmetaAndBareRDFPacketsAreEdited() throws {
        let p = try RichPieces.make()
        for (name, packet) in [("xapmeta.jpg", RichPieces.xapmetaPacket), ("bare.jpg", RichPieces.bareRDFPacket)] {
            XCTAssertNil(CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData), "fixture: \(name)")
            let original = JPEGLayout.build([
                .bytes(p.exif), .bytes(RichPieces.xmpSegment(packet)), .bytes(p.icc), .bytes(p.app13()), .bytes(p.com),
                .mpf(.init(images: [p.preview])),
            ] + p.codec.map { .bytes($0) }, tail: p.tail)
            XCTAssertEqual(fileXMP(original)["photoshop:City"], "Paris", "fixture: \(name) is read")

            try assertRatingWrite(original, name, xmp: .updated(partIndex: 1, textual: true), iptcChanges: true)
        }
    }

    /// A packet with padding before its trailer (as Adobe writes it) keeps its length: the edit takes its bytes from
    /// the padding, so the segment keeps its size and nothing after it moves.
    func testAPaddedPacketKeepsItsLength() throws {
        let p = try RichPieces.make()
        let packet = RichJPEG.xmp.replacingOccurrences(of: "<?xpacket end=\"w\"?>",
                                                       with: String(repeating: " ", count: 2000) + "\n<?xpacket end=\"w\"?>")
        let segment = RichPieces.xmpSegment(packet)
        let original = JPEGLayout.build([
            .bytes(p.exif), .mpf(.init(images: [p.preview])), .bytes(segment), .bytes(p.icc), .bytes(p.com),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)

        let after = try assertRatingWrite(original, "padded.jpg", xmp: .updated(partIndex: 2, textual: true),
                                          iptcChanges: false)

        XCTAssertEqual(after.count, original.count, "the packet kept its length")
        XCTAssertEqual(try XCTUnwrap(MPFTestReader(after)).segmentBytes(after), try XCTUnwrap(MPFTestReader(original)).segmentBytes(original),
                       "so the MPF segment needs no patch")
    }

    /// When the packet's rating isn't in a form the text edit handles (here a qualified element), ImageIO rewrites the
    /// packet, as before task D, once an independent XML reading shows the rewrite kept every other property.
    func testAPacketTheTextEditCantHandleIsRewrittenWhenNothingIsLost() throws {
        let p = try RichPieces.make()
        let packet = RichJPEG.xmp.replacingOccurrences(of: "xmp:Rating=\"2\"", with: "")
            .replacingOccurrences(of: "<dc:creator>", with: "<xmp:Rating xml:lang=\"en\">2</xmp:Rating><dc:creator>")
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(RichPieces.xmpSegment(packet)), .bytes(p.icc), .bytes(p.app13()), .bytes(p.com),
            .mpf(.init(images: [p.preview])),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)

        try assertRatingWrite(original, "qualified.jpg", xmp: .updated(partIndex: 1, textual: false), iptcChanges: true)
    }

    // MARK: - Case 6: IPTC text of unknown encoding

    /// Non-ASCII keywords can't be written into IPTC-IIM whose other text is non-ASCII with no 1:90 declaration: its
    /// encoding is unknown (ImageIO reads it as Mac Roman, exiftool as Windows Latin 1). The APP13 stays
    /// byte-identical, the keywords go to the XMP, and XMP wins because the IPTC digest matches (or is missing).
    func testNonASCIIKeywordsOverIPTCTextOfUnknownEncodingGoToTheXMP() throws {
        let p = try RichPieces.make()
        for digest in [RichPieces.Digest.matching, .none] {
            let original = JPEGLayout.build([
                .bytes(p.exif), .bytes(p.xmp), .bytes(p.icc), .bytes(p.app13(iim: RichPieces.latin1IIM, digest: digest)),
                .bytes(p.com), .mpf(.init(images: [p.preview])),
            ] + p.codec.map { .bytes($0) }, tail: p.tail)

            let after = try assertRatingWrite(original, "latin1-\(digest).jpg", xmp: .updated(partIndex: 1, textual: true),
                                              iptcChanges: false, keywords: ["café", "people:zoë"])

            let iptc = try XCTUnwrap(KeptMetadata.properties(after)["{IPTC}"] as? [String: Any])
            XCTAssertEqual(iptc["Keywords"] as? [String], ["café", "people:zoë"], "\(digest): ImageIO's IPTC view")
        }
    }

    // MARK: - Last resort: the file keeps its bytes and gets a flagged sidecar

    /// A standalone marker (TEM or RSTn) in the header: legal to skip, but ImageIO then reads neither the image nor its
    /// metadata, so nothing written could be checked.
    func testAStandaloneMarkerInTheHeaderIsALastResort() throws {
        let p = try RichPieces.make()
        for marker: UInt8 in [0x01, 0xD0] {
            let original = JPEGLayout.build([
                .bytes(p.exif), .bytes(p.xmp), .bytes(Data([0xFF, marker])), .bytes(p.icc), .bytes(p.com),
            ] + p.codec.map { .bytes($0) }, tail: p.tail)
            try assertLastResort(original, String(format: "standalone-%02x.jpg", marker))
        }
    }

    /// Fill bytes before the XMP segment: ImageIO's XMP reader stops at the first fill byte, so it couldn't read the
    /// values back.
    func testFillBytesBeforeTheXMPAreALastResort() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(Data([0xFF, 0xFF])), .bytes(p.xmp), .bytes(p.icc), .bytes(p.com),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "fill-first.jpg")
    }

    /// Bytes other than 0xFF between segments aren't JPEG.
    func testGarbageBetweenSegmentsIsALastResort() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(p.xmp), .bytes(Data([0x00, 0x42])), .bytes(p.icc), .bytes(p.com),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "garbage.jpg")
    }

    /// An MP entry that points past the end of the file can't be patched safely.
    func testAnMPFEntryOutsideTheFileIsALastResort() throws {
        let p = try RichPieces.make()
        var original = JPEGLayout.build([.bytes(p.exif), .mpf(.init(images: [p.preview])), .bytes(p.xmp), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        let mpf = try XCTUnwrap(MPFTestReader(original))
        mpf.setField(&original, at: mpf.entries[1].sizeAt, to: p.preview.count + 10)
        try assertLastResort(original, "mpf-outside.jpg")
    }

    /// An MPF segment whose IFD offset runs past the segment can't be parsed.
    func testAnMPFSegmentThatCantBeParsedIsALastResort() throws {
        let p = try RichPieces.make()
        var original = JPEGLayout.build([.bytes(p.exif), .mpf(.init(images: [p.preview])), .bytes(p.xmp), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        let mpf = try XCTUnwrap(MPFTestReader(original))
        mpf.setField(&original, at: mpf.header + 4, to: 0x7000)
        try assertLastResort(original, "mpf-broken.jpg")
    }

    /// An extension that holds `xmp:Rating` wins over the standard packet in ImageIO, so a new rating in the standard
    /// packet wouldn't be read.
    func testExtendedXMPHoldingARatingIsALastResort() throws {
        let p = try RichPieces.make()
        let (standard, extensions) = RichPieces.extendedXMP(extensionHoldsRating: true)
        let original = JPEGLayout.build([.bytes(p.exif), .bytes(standard)] + extensions.map { .bytes($0) } + [.bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "extended-rating.jpg")
    }

    /// A standard packet that would outgrow one segment (65,502 bytes, XMP Part 3 §1.1.3.1) with no padding to take
    /// the growth from, and no extended XMP Phocasa could move anything to.
    func testAPacketThatWouldOutgrowItsSegmentIsALastResort() throws {
        let p = try RichPieces.make()
        let filler = String(repeating: "y", count: 65_502 - RichJPEG.xmp.utf8.count - 40)
        let packet = RichJPEG.xmp.replacingOccurrences(of: "acme:Flag=\"keep-me\"", with: "acme:Flag=\"keep-me\" acme:Big=\"\(filler)\"")
        XCTAssertLessThanOrEqual(packet.utf8.count, 65_502, "fixture: the original fits")
        let original = JPEGLayout.build([.bytes(p.exif), .bytes(RichPieces.xmpSegment(packet)), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "big.jpg", keywords: (0..<10).map { "a-long-keyword-\($0)" })
    }

    /// XMP that isn't well-formed XML: ImageIO reads it leniently and silently drops what follows the error, so a
    /// rewrite would lose that; the text edit needs well-formed XML.
    func testAPacketThatIsntWellFormedIsALastResort() throws {
        let p = try RichPieces.make()
        let packet = RichJPEG.xmp.replacingOccurrences(of: "</dc:subject>", with: "</dc:subjct>")
        let original = JPEGLayout.build([.bytes(p.exif), .bytes(RichPieces.xmpSegment(packet)), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "malformed.jpg")
    }

    /// A packet with a DOCTYPE (entities could change what the text means) is left alone.
    func testAPacketWithADoctypeIsALastResort() throws {
        let p = try RichPieces.make()
        let packet = "<?xml version=\"1.0\"?><!DOCTYPE x:xmpmeta>" + RichJPEG.xmp
        let original = JPEGLayout.build([.bytes(p.exif), .bytes(RichPieces.xmpSegment(packet)), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "doctype.jpg")
    }

    /// The text edit can't handle this rating (a qualified element), and ImageIO's rewrite would drop an empty
    /// property (`photoshop:Headline=""`): nothing is written. Before task D the rewrite ran and lost it.
    func testARewriteThatWouldDropAPropertyIsALastResort() throws {
        let p = try RichPieces.make()
        let packet = RichJPEG.xmp.replacingOccurrences(of: "xmp:Rating=\"2\"", with: "photoshop:Headline=\"\"")
            .replacingOccurrences(of: "<dc:creator>", with: "<xmp:Rating xml:lang=\"en\">2</xmp:Rating><dc:creator>")
        let original = JPEGLayout.build([.bytes(p.exif), .bytes(RichPieces.xmpSegment(packet)), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "drops.jpg")
    }

    /// Several XMP segments whose last (the one ImageIO reads) isn't a packet: nothing to update safely.
    func testSeveralXMPSegmentsWhoseLastIsntAPacketAreALastResort() throws {
        let p = try RichPieces.make()
        let fragment = T.segment(0xE1, Data(JPEGTestSegments.xmpID.utf8) + Data([0]) + Data("<rdf:li>half a packet".utf8)).bytes
        let original = JPEGLayout.build([.bytes(p.exif), .bytes(p.xmp), .bytes(fragment), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "fragment.jpg")
    }

    /// Non-ASCII keywords over IPTC text of unknown encoding, and an IPTC digest that doesn't match: the IIM was
    /// changed after the XMP, so it wins over the XMP (MWG 2.0; ImageIO does the same) and the keywords couldn't be
    /// read back from the XMP.
    func testIPTCKeywordsThatCantBeWrittenUnderAStaleDigestAreALastResort() throws {
        let p = try RichPieces.make()
        let original = JPEGLayout.build([
            .bytes(p.exif), .bytes(p.xmp), .bytes(p.app13(iim: RichPieces.latin1IIM, digest: .stale)), .bytes(p.com),
        ] + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "stale-digest.jpg", keywords: ["café"])
    }

    /// An APP13 whose resources can't be parsed.
    func testAMalformedAPP13IsALastResort() throws {
        let p = try RichPieces.make()
        var payload = [UInt8](p.app13().dropFirst(4))
        payload[14 + 4 + 4 + 2] = 0x7F   // the first resource's size now runs past the segment
        let original = JPEGLayout.build([.bytes(p.exif), .bytes(p.xmp), .bytes(T.segment(0xED, Data(payload)).bytes), .bytes(p.com)]
                                        + p.codec.map { .bytes($0) }, tail: p.tail)
        try assertLastResort(original, "badapp13.jpg")
    }

    // MARK: - Real camera JPEG (gated)

    /// The camera JPEG next to `PHOCASA_TEST_RAW` (a copy), and copies of it modified per case: as it is (Exif, MPF,
    /// no XMP), with fill bytes after the MPF segment, with an XMP segment after the MPF segment, and with extended XMP.
    func testRealCameraJPEGLayouts() throws {
        guard let rawPath = ProcessInfo.processInfo.environment["PHOCASA_TEST_RAW"], !rawPath.isEmpty else {
            throw XCTSkip("set PHOCASA_TEST_RAW to a copy of a camera RAW with its JPG beside it")
        }
        let raw = URL(fileURLWithPath: rawPath)
        let source = try XCTUnwrap(["JPG", "jpg", "jpeg", "JPEG"].lazy.map { raw.deletingPathExtension().appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }, "needs the RAW's JPG beside it")
        let camera = try Data(contentsOf: source)
        let walk = try XCTUnwrap(LayoutWalk(camera))
        let mpfIndex = try XCTUnwrap(walk.parts.firstIndex { $0.id == "MPF" }, "a camera JPEG with an MPF preview")
        XCTAssertNil(walk.parts.firstIndex { $0.id == JPEGTestSegments.xmpID }, "straight from the camera: no XMP")

        try assertRatingWrite(camera, "camera.jpg", xmp: .inserted, iptcChanges: false)

        let fill = JPEGLayout.inserting(Data([0xFF, 0xFF, 0xFF]), atPart: mpfIndex + 1, in: camera)
        try assertRatingWrite(fill, "camera-fill.jpg", xmp: .inserted, iptcChanges: false)

        let xmp = RichPieces.xmpSegment(RichJPEG.xmp)
        let xmpAfterMPF = JPEGLayout.inserting(xmp, atPart: mpfIndex + 1, in: camera)
        try assertRatingWrite(xmpAfterMPF, "camera-xmp.jpg", xmp: .updated(partIndex: mpfIndex + 1, textual: true),
                              iptcChanges: false)

        let (standard, extensions) = RichPieces.extendedXMP()
        let extended = extensions.reversed().reduce(JPEGLayout.inserting(standard, atPart: mpfIndex + 1, in: camera)) {
            JPEGLayout.inserting($1, atPart: mpfIndex + 2, in: $0)
        }
        try assertRatingWrite(extended, "camera-extended.jpg", xmp: .updated(partIndex: mpfIndex + 1, textual: true),
                              iptcChanges: false)
    }

    // MARK: - The checks

    enum XMPChange {
        /// The file had no XMP; a new segment is inserted.
        case inserted
        /// The XMP segment at this index among the header's parts changes: by an edit of its text (every line of
        /// another app's packet that doesn't hold a rating or keywords is kept verbatim) or by ImageIO's rewrite.
        case updated(partIndex: Int, textual: Bool)
    }

    private func fileXMP(_ data: Data) -> [String: String] {
        KeptMetadata.xmpValues(CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) } ?? CGImageMetadataCreateMutable())
    }

    private static func isPhocasas(_ path: String) -> Bool {
        path.hasPrefix("xmp:Rating") || path.hasPrefix("dc:subject") || path.hasPrefix("iio:")
    }

    /// Writes a rating and keywords into `original` (as `name`, with no sidecar), and checks what changed: only the
    /// XMP segment `xmp` describes, the APP13 (if `iptcChanges`) and the MP entries' size and offset fields, by the
    /// amounts the header's size changes imply. Every other part of the header (fill bytes included), the image data,
    /// the secondary images and the decoded pixels stay the same; every ImageIO property and XMP value is kept; the
    /// values read back from the file itself; and repeated writes are stable. Returns the file after the first write.
    @discardableResult
    private func assertRatingWrite(_ original: Data, _ name: String, xmp change: XMPChange, iptcChanges: Bool,
                                   rating: Int = 4, keywords: [String] = ["people:ann", "beach"],
                                   file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let url = try write(original, name)
        service.writeMetadata(rating: rating, keywords: keywords, toImageAt: url.path)
        let after = try Data(contentsOf: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.xmpSidecarURL.path), "\(name): no sidecar", file: file, line: line)
        XCTAssertNotEqual(after, original, "\(name): written into the file", file: file, line: line)
        assertOnlyMetadataChanged(original, after, xmp: change, iptcChanges: iptcChanges, name, file: file, line: line)
        assertReadsBack(after, url: url, rating: rating, keywords: keywords, name, file: file, line: line)

        // Repeated writes: the same values give the same bytes, and a cycle comes back to them.
        service.writeMetadata(rating: rating, keywords: keywords, toImageAt: url.path)
        let again = try Data(contentsOf: url)
        for (r, k) in [(1, ["x"]), (5, ["y", "zed", "people:bob"]), (0, [String]()), (rating, keywords)] {
            service.writeMetadata(rating: r, keywords: k, toImageAt: url.path)
            assertReadsBack(try Data(contentsOf: url), url: url, rating: r, keywords: k, "\(name) (\(r))", file: file, line: line)
        }
        let cycled = try Data(contentsOf: url)
        service.writeMetadata(rating: rating, keywords: keywords, toImageAt: url.path)
        XCTAssertEqual(try Data(contentsOf: url), cycled, "\(name): the same values write the same bytes", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(cycled.count - again.count), 256, "\(name): no growth", file: file, line: line)
        let changeAfterCycle: XMPChange
        switch change {
        case .inserted: changeAfterCycle = .inserted
        case .updated(let index, _): changeAfterCycle = .updated(partIndex: index, textual: false)
        }
        // (The cycle's ASCII keywords can go into IPTC text that non-ASCII ones couldn't.)
        assertOnlyMetadataChanged(original, cycled, xmp: changeAfterCycle, iptcChanges: true, "\(name) after a cycle",
                                  file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.xmpSidecarURL.path), "\(name): still no sidecar", file: file, line: line)
        return after
    }

    private func assertReadsBack(_ data: Data, url: URL, rating: Int, keywords: [String], _ name: String,
                                 file: StaticString, line: UInt) {
        let values = fileXMP(data)
        let meta = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
        XCTAssertEqual(meta.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:Rating" as CFString) as String? },
                       "\(rating)", "\(name): ImageIO reads the rating from the file", file: file, line: line)
        let subject = (1...max(1, keywords.count)).compactMap { values["dc:subject[\($0)]"] }
        XCTAssertEqual(subject, keywords, "\(name): ImageIO reads the keywords from the file", file: file, line: line)
        let read = service.readMetadata(from: url.path)
        XCTAssertEqual(read.rating, rating, "\(name): readMetadata", file: file, line: line)
        XCTAssertEqual(read.keywords, keywords, "\(name): readMetadata", file: file, line: line)
    }

    private func assertOnlyMetadataChanged(_ original: Data, _ after: Data, xmp change: XMPChange, iptcChanges: Bool,
                                           _ name: String, file: StaticString, line: UInt) {
        guard let before = LayoutWalk(original), let now = LayoutWalk(after) else {
            return XCTFail("\(name): both parse", file: file, line: line)
        }
        // Line the parts up: a new XMP segment is taken out of `now`.
        var nowParts = now.parts
        var target: Int?
        switch change {
        case .inserted:
            guard let inserted = nowParts.firstIndex(where: { $0.id == JPEGTestSegments.xmpID }),
                  !before.parts.contains(where: { $0.id == JPEGTestSegments.xmpID }) else {
                return XCTFail("\(name): one XMP segment inserted", file: file, line: line)
            }
            let leading = before.parts.prefix { $0.marker == 0xE0 || $0.id == "Exif" || $0.isFill }
            let expected = (leading.lastIndex { $0.marker == 0xE0 || $0.id == "Exif" }).map { $0 + 1 } ?? 0
            XCTAssertEqual(inserted, expected, "\(name): the new XMP follows the JFIF and Exif segments", file: file, line: line)
            nowParts.remove(at: inserted)
        case .updated(let index, _):
            target = index
        }
        guard nowParts.count == before.parts.count else {
            return XCTFail("\(name): no part added or dropped: \(before.parts.map(\.label)) → \(now.parts.map(\.label))",
                           file: file, line: line)
        }
        for (index, (old, new)) in zip(before.parts, nowParts).enumerated() {
            if index == target {
                XCTAssertEqual(new.id, JPEGTestSegments.xmpID, "\(name): part \(index) is still the XMP", file: file, line: line)
            } else if old.marker == 0xED && iptcChanges {
                XCTAssertEqual(new.marker, 0xED, "\(name): part \(index) is still the APP13", file: file, line: line)
            } else if old.id == "MPF" {
                XCTAssertEqual(new.id, "MPF", file: file, line: line)
            } else {
                XCTAssertEqual(new, old, "\(name): part \(index) (\(old.label)) byte for byte", file: file, line: line)
            }
        }
        XCTAssertEqual(Data(after[now.sos...]), Data(original[before.sos...]),
                       "\(name): the image data and everything after it", file: file, line: line)

        // The MP entries: the first image's size follows the header, the others' offsets follow the parts after the
        // MPF segment; every other byte of the segment is kept, and each secondary image is where its entry says.
        if let oldMPF = MPFTestReader(original) {
            guard let newMPF = MPFTestReader(after) else { return XCTFail("\(name): MPF kept", file: file, line: line) }
            let growth = now.sos - before.sos
            let shift = (after.count - newMPF.segment.upperBound) - (original.count - oldMPF.segment.upperBound)
            XCTAssertEqual(newMPF.segmentWithoutEntryFields(after), oldMPF.segmentWithoutEntryFields(original),
                           "\(name): the MPF segment outside the MP entries' size and offset fields", file: file, line: line)
            XCTAssertEqual(newMPF.entries.map(\.attribute), oldMPF.entries.map(\.attribute), file: file, line: line)
            XCTAssertEqual(newMPF.entries.first?.size, oldMPF.entries.first.map { $0.size + growth },
                           "\(name): the first image's size grows with the header", file: file, line: line)
            for k in oldMPF.entries.indices.dropFirst() {
                XCTAssertEqual(newMPF.entries[k].offset, oldMPF.entries[k].offset + shift, "\(name): entry \(k + 1)'s offset",
                               file: file, line: line)
                XCTAssertEqual(newMPF.entries[k].size, oldMPF.entries[k].size, file: file, line: line)
                XCTAssertEqual(after[newMPF.imageRange(k)], original[oldMPF.imageRange(k)],
                               "\(name): image \(k + 1) byte-identical and reachable", file: file, line: line)
            }
        }

        // The packet: every value but Phocasa's; with a text edit, every other line of it verbatim.
        if let target, let oldPacket = before.parts[target].xmpPacket, let newPacket = nowParts[target].xmpPacket {
            for (path, value) in KeptMetadata.xmpValues(oldPacket) where !Self.isPhocasas(path) {
                XCTAssertEqual(KeptMetadata.xmpValues(newPacket)[path], value, "\(name): XMP \(path)", file: file, line: line)
            }
            if case .updated(_, true) = change {
                let newText = String(decoding: newPacket, as: UTF8.self)
                for oldLine in String(decoding: oldPacket, as: UTF8.self).split(separator: "\n")
                where !oldLine.contains("Rating") && !oldLine.contains("subject") && !oldLine.contains("<rdf:li>old")
                    && !oldLine.allSatisfy(\.isWhitespace) && !oldLine.hasPrefix("<?xpacket end") {
                    XCTAssertTrue(newText.contains(oldLine), "\(name): the packet keeps \(oldLine.prefix(60))", file: file, line: line)
                }
            }
        }

        // ImageIO's view: every property and every XMP value but Phocasa's.
        let oldProperties = KeptMetadata.properties(original), newProperties = KeptMetadata.properties(after)
        for (key, value) in oldProperties where key != "FileSize" {
            if let old = value as? [String: Any] {
                let new = newProperties[key] as? [String: Any] ?? [:]
                for (field, v) in old where !(key == "{IPTC}" && (field == "Keywords" || field == "StarRating")) {
                    XCTAssertEqual(new[field].map { "\($0)" }, "\(v)", "\(name): \(key).\(field)", file: file, line: line)
                }
            } else {
                XCTAssertEqual(newProperties[key].map { "\($0)" }, "\(value)", "\(name): \(key)", file: file, line: line)
            }
        }
        let newValues = fileXMP(after)
        for (path, value) in fileXMP(original) where !Self.isPhocasas(path) {
            XCTAssertEqual(newValues[path], value, "\(name): ImageIO's XMP \(path)", file: file, line: line)
        }
        XCTAssertEqual(Self.pixels(after), Self.pixels(original), "\(name): the decoded image", file: file, line: line)
    }

    /// `original` stays byte-identical, and the values go to a sidecar flagged `phocasa:OverridesEmbedded`.
    private func assertLastResort(_ original: Data, _ name: String, keywords: [String] = ["people:ann", "beach"],
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try write(original, name)
        service.writeMetadata(rating: 4, keywords: keywords, toImageAt: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original, "\(name): the file is untouched", file: file, line: line)
        let sidecar = try XCTUnwrap(try? Data(contentsOf: url.xmpSidecarURL), "\(name): a sidecar", file: file, line: line)
        let fields = MetadataService.sidecarFields(sidecar)
        XCTAssertTrue(fields.overridesEmbedded, "\(name): flagged", file: file, line: line)
        XCTAssertEqual(fields.contents.rating, 4, file: file, line: line)
        XCTAssertEqual(fields.contents.keywords, keywords, file: file, line: line)
    }

    static func pixels(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data else { return nil }
        return Data(bytes: bytes, count: image.width * image.height * 4)
    }
}

// MARK: - An independent JPEG header walker (tests only)

/// A JPEG header as these tests see it, parsed without the app's `JPEGStructure`: marker segments, runs of 0xFF fill
/// bytes and standalone markers, up to SOS. Nil for anything else between segments.
struct LayoutWalk {
    enum Part: Equatable {
        case segment(Data)
        case fill(Data)
        case standalone(Data)

        var bytes: Data {
            switch self { case .segment(let d), .fill(let d), .standalone(let d): return d }
        }
        var isFill: Bool { if case .fill = self { return true } else { return false } }
        var marker: UInt8? { if case .segment(let d) = self { return d[d.startIndex + 1] } else { return nil } }
        /// The signature at the start of an APPn payload ("Exif", "MPF", an XMP namespace), or "".
        var id: String {
            guard case .segment(let d) = self, (0xE0...0xEF).contains(d[d.startIndex + 1]) else { return "" }
            return String(decoding: d.dropFirst(4).prefix(40).prefix { $0 != 0 }, as: UTF8.self)
        }
        var label: String {
            switch self {
            case .segment(let d): return String(format: "FF%02X %@ %d", d[d.startIndex + 1], id, d.count)
            case .fill(let d): return "fill \(d.count)"
            case .standalone(let d): return String(format: "FF%02X", d[d.startIndex + 1])
            }
        }
        /// The packet of a standard XMP segment.
        var xmpPacket: Data? {
            id == JPEGTestSegments.xmpID ? Data(bytes.dropFirst(4 + JPEGTestSegments.xmpID.utf8.count + 1)) : nil
        }
    }

    let parts: [Part]
    /// Where each part starts.
    let offsets: [Int]
    let sos: Int

    init?(_ data: Data) {
        let d = [UInt8](data)
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return nil }
        var parts: [Part] = [], offsets: [Int] = []
        var i = 2
        while true {
            guard i + 1 < d.count, d[i] == 0xFF else { return nil }
            var j = i
            while j + 1 < d.count, d[j + 1] == 0xFF { j += 1 }
            if j > i { parts.append(.fill(Data(d[i..<j]))); offsets.append(i) }
            guard j + 1 < d.count else { return nil }
            let marker = d[j + 1]
            if marker == 0xDA { sos = j; break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                parts.append(.standalone(Data(d[j..<(j + 2)]))); offsets.append(j)
                i = j + 2
                continue
            }
            guard j + 4 <= d.count else { return nil }
            let length = Int(d[j + 2]) << 8 | Int(d[j + 3])
            guard length >= 2, j + 2 + length <= d.count else { return nil }
            parts.append(.segment(Data(d[j..<(j + 2 + length)]))); offsets.append(j)
            i = j + 2 + length
        }
        self.parts = parts
        self.offsets = offsets
    }

    func range(ofID id: String) -> Range<Int>? {
        parts.firstIndex { $0.id == id }.map { offsets[$0]..<(offsets[$0] + parts[$0].bytes.count) }
    }
}

// MARK: - An independent MPF reader (tests only)

/// The first MPF segment's MP entries (CIPA DC-007 5.2.3.3), read without the app's code.
struct MPFTestReader {
    struct Entry {
        let attribute: Int
        let size: Int
        let offset: Int
        /// Where the size and offset fields are in the file.
        let sizeAt: Int
        let offsetAt: Int
    }

    let segment: Range<Int>
    /// The MP header's endian field, which offsets count from.
    let header: Int
    let littleEndian: Bool
    let entries: [Entry]

    init?(_ data: Data) {
        guard let walk = LayoutWalk(data), let range = walk.range(ofID: "MPF") else { return nil }
        let d = [UInt8](data)
        let h = range.lowerBound + 8, end = range.upperBound
        guard h + 8 <= end else { return nil }
        let le = d[h] == 0x49
        func u(_ o: Int, _ n: Int) -> Int? {
            guard o >= 0, h + o + n <= end else { return nil }
            let bytes = (0..<n).map { Int(d[h + o + $0]) }
            return (le ? bytes.reversed() : bytes).reduce(0) { $0 << 8 | $1 }
        }
        guard let ifd = u(4, 4), let count = u(ifd, 2) else { return nil }
        var entries: [Entry] = []
        for k in 0..<count {
            let e = ifd + 2 + k * 12
            guard u(e, 2) == 0xB002, let bytes = u(e + 4, 4), let at = u(e + 8, 4) else { continue }
            for n in 0..<(bytes / 16) {
                let base = at + n * 16
                guard let attribute = u(base, 4), let size = u(base + 4, 4), let offset = u(base + 8, 4) else { return nil }
                entries.append(Entry(attribute: attribute, size: size, offset: offset, sizeAt: h + base + 4, offsetAt: h + base + 8))
            }
        }
        guard !entries.isEmpty else { return nil }
        segment = range
        header = h
        littleEndian = le
        self.entries = entries
    }

    /// Where image `k` (0 is the first) is in the file.
    func imageRange(_ k: Int) -> Range<Int> {
        let start = k == 0 ? 0 : header + entries[k].offset
        return start..<(start + entries[k].size)
    }

    func segmentBytes(_ data: Data) -> Data { Data(data[segment]) }

    /// The segment with every MP entry's size and offset fields zeroed, to compare the rest byte for byte.
    func segmentWithoutEntryFields(_ data: Data) -> Data {
        var d = [UInt8](data[segment])
        for entry in entries {
            for at in [entry.sizeAt, entry.offsetAt] { for i in 0..<4 { d[at - segment.lowerBound + i] = 0 } }
        }
        return Data(d)
    }

    /// Writes a 4-byte field in the segment's byte order.
    func setField(_ data: inout Data, at position: Int, to value: Int) {
        let be = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        data.replaceSubrange(position..<(position + 4), with: littleEndian ? be.reversed() : be)
    }
}

// MARK: - Building layouts

enum JPEGLayout {
    struct MPF {
        var bigEndian = true
        /// An MP Attribute IFD after the MP Index IFD (with an out-of-line value, which counts from the MP header too).
        var attributeIFD = false
        /// The secondary images, appended after the first one.
        var images: [Data]
        /// Bytes between one image's EOI and the next one's SOI (cameras pad).
        var gap = Data()
        /// Bytes after the last image.
        var trailer = Data()
    }

    enum Item {
        case bytes(Data)
        case mpf(MPF)
    }

    /// SOI, the items (an `.mpf` item becomes an MPF segment describing the images appended after the first one),
    /// then `tail` (SOS to the first image's EOI).
    static func build(_ items: [Item], tail: Data) -> Data {
        guard let spec = items.lazy.compactMap({ if case .mpf(let m) = $0 { return m } else { return nil } }).first else {
            return items.reduce(Data([0xFF, 0xD8])) { if case .bytes(let d) = $1 { return $0 + d } else { return $0 } } + tail
        }
        func assemble(_ mpf: Data) -> Data {
            items.reduce(Data([0xFF, 0xD8])) {
                switch $1 { case .bytes(let d): return $0 + d; case .mpf: return $0 + mpf }
            } + tail
        }
        let placeholder = assemble(segment(spec, primarySize: 0, offsets: spec.images.map { _ in 0 }))
        let mpfStart = items.prefix { if case .mpf = $0 { return false } else { return true } }
            .reduce(2) { if case .bytes(let d) = $1 { return $0 + d.count } else { return $0 } }
        let header = mpfStart + 8
        var offsets: [Int] = [], position = placeholder.count + spec.gap.count
        for image in spec.images {
            offsets.append(position - header)
            position += image.count + spec.gap.count
        }
        var out = assemble(segment(spec, primarySize: placeholder.count, offsets: offsets)) + spec.gap
        for image in spec.images { out += image + spec.gap }
        return out.dropLast(spec.gap.count) + spec.trailer
    }

    /// An MPF APP2 segment: MP Index IFD (version, number of images, MP entries), optionally an MP Attribute IFD.
    static func segment(_ spec: MPF, primarySize: Int, offsets: [Int]) -> Data {
        let be = spec.bigEndian
        func u16(_ v: Int) -> [UInt8] { be ? [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { be ? u16(v >> 16) + u16(v & 0xFFFF) : u16(v & 0xFFFF) + u16(v >> 16) }
        let n = offsets.count + 1
        let entriesAt = 8 + 2 + 3 * 12 + 4
        let attributeAt = entriesAt + 16 * n
        var t: [UInt8] = (be ? [0x4D, 0x4D, 0x00, 0x2A] : [0x49, 0x49, 0x2A, 0x00]) + u32(8)
        t += u16(3)
        t += u16(0xB000) + u16(7) + u32(4) + Array("0100".utf8)
        t += u16(0xB001) + u16(4) + u32(1) + u32(n)
        t += u16(0xB002) + u16(7) + u32(16 * n) + u32(entriesAt)
        t += u32(spec.attributeIFD ? attributeAt : 0)
        t += u32(0x2003_0000) + u32(primarySize) + u32(0) + u16(0) + u16(0)
        for offset in offsets {
            t += u32(0x0001_0001) + u32(0) + u32(offset) + u16(0) + u16(0)
        }
        // Sizes of the secondary images go in after the fact, once the offsets are known.
        if spec.attributeIFD {
            let rationalAt = attributeAt + 2 + 3 * 12 + 4
            t += u16(3)
            t += u16(0xB101) + u16(4) + u32(1) + u32(1)
            t += u16(0xB201) + u16(4) + u32(1) + u32(0)
            t += u16(0xB205) + u16(10) + u32(1) + u32(rationalAt)
            t += u32(0)
            t += u32(-5 & 0xFFFF_FFFF) + u32(10)
        }
        var segment = MetadataJPEGPreservationTests.segment(0xE2, Data("MPF".utf8) + Data([0]) + Data(t)).bytes
        for (k, image) in spec.images.enumerated() {
            let at = 4 + 4 + entriesAt + 16 * (k + 1) + 4
            segment.replaceSubrange(at..<(at + 4), with: u32(image.count))
        }
        return segment
    }

    /// `jpeg` with `bytes` inserted before header part `index`, its MPF entries fixed for the move (the first image
    /// grows; secondary images move if the insertion is after the MPF segment). The fixtures' own patch, not the app's.
    static func inserting(_ bytes: Data, atPart index: Int, in jpeg: Data) -> Data {
        guard let walk = LayoutWalk(jpeg) else { return jpeg }
        let at = index < walk.parts.count ? walk.offsets[index] : walk.sos
        var out = jpeg
        out.insert(contentsOf: bytes, at: at)
        guard let mpf = MPFTestReader(jpeg) else { return out }
        let moved = at > mpf.segment.lowerBound
        let shiftFields = moved ? 0 : bytes.count   // the fields themselves move when the insertion is before them
        mpf.setField(&out, at: mpf.entries[0].sizeAt + shiftFields, to: mpf.entries[0].size + bytes.count)
        if moved {
            for entry in mpf.entries.dropFirst() { mpf.setField(&out, at: entry.offsetAt, to: entry.offset + bytes.count) }
        }
        return out
    }
}

// MARK: - The rich pieces

/// The rich camera-style JPEG's segments (`RichJPEG`: Exif with MakerNote, GPS and thumbnail, another app's XMP, an
/// ICC profile, APP13 with custom IPTC datasets and resources, APP9, COM), its codec segments and image data, and its
/// MPF preview, to lay out in other orders, plus the packets and APP13s the cases need.
struct RichPieces {
    let exif: Data, xmp: Data, icc: Data, app9: Data, com: Data
    let codec: [Data]
    /// SOS to the first image's EOI.
    let tail: Data
    let preview: Data
    private let thumbnail: [UInt8]

    static func make() throws -> RichPieces {
        let rich = try RichJPEG.make()
        let walk = try XCTUnwrap(LayoutWalk(rich.data))
        func part(_ id: String) throws -> Data { try XCTUnwrap(walk.parts.first { $0.id == id }?.bytes, id) }
        let previewStart = try XCTUnwrap(MetadataJPEGPreservationTests.mpfSecondImage(rich.data)).lowerBound
        return RichPieces(
            exif: try part("Exif"), xmp: try part(JPEGTestSegments.xmpID), icc: try part("ICC_PROFILE"),
            app9: MetadataJPEGPreservationTests.vendorAPP9.bytes, com: MetadataJPEGPreservationTests.comment.bytes,
            codec: walk.parts.filter { $0.marker.map { !(0xE0...0xEF).contains($0) && $0 != 0xFE } ?? false }.map(\.bytes),
            tail: Data(rich.data[walk.sos..<previewStart]), preview: rich.mpfPreview, thumbnail: [UInt8](rich.irbThumbnail))
    }

    enum Digest: CustomStringConvertible {
        case matching, stale, none
        var description: String { switch self { case .matching: "matching"; case .stale: "stale"; case .none: "none" } }
    }

    /// A Photoshop APP13: resolution, IPTC-IIM (custom dataset 2:200 included), the IPTC digest, a custom resource and
    /// a thumbnail.
    func app13(iim: [UInt8] = RichJPEG.iim, digest: Digest = .matching) -> Data {
        var payload: [UInt8] = Array("Photoshop 3.0\u{0}".utf8)
        payload += IRBTestData.block(0x03ED, RichJPEG.resolutionResource)
        payload += IRBTestData.block(0x0404, iim)
        switch digest {
        case .matching: payload += IRBTestData.block(0x0425, Array(Insecure.MD5.hash(data: Data(iim))))
        case .stale: payload += IRBTestData.block(0x0425, [UInt8](repeating: 0xAB, count: 16))
        case .none: break
        }
        payload += IRBTestData.block(0x2710, RichJPEG.customResource)
        payload += IRBTestData.block(0x040C, thumbnail)
        return MetadataJPEGPreservationTests.segment(0xED, Data(payload)).bytes
    }

    /// IIM whose caption and keywords are Latin-1 bytes with no 1:90 declaration: text of unknown encoding.
    static let latin1IIM: [UInt8] = IRBTestData.dataset(2, 0, [0, 4]) + IRBTestData.dataset(2, 25, [0x63, 0x61, 0x66, 0xE9])
        + IRBTestData.dataset(2, 120, Array("Cr".utf8) + [0xE8] + Array("me br".utf8) + [0xFB] + Array("l".utf8) + [0xE9, 0x65])
        + IRBTestData.dataset(2, 200, [9, 8, 7, 6])

    /// A Photoshop resource stream split over two APP13 segments (each starting "Photoshop 3.0"), as ImageIO and
    /// Adobe read it: resolution and IPTC in the first, the digest (matching) and a custom resource in the second.
    static func splitAPP13() -> (Data, Data) {
        let header: [UInt8] = Array("Photoshop 3.0\u{0}".utf8)
        let first = header + IRBTestData.block(0x03ED, RichJPEG.resolutionResource) + IRBTestData.block(0x0404, RichJPEG.iim)
        let second = header + IRBTestData.block(0x0425, Array(Insecure.MD5.hash(data: Data(RichJPEG.iim))))
            + IRBTestData.block(0x2710, RichJPEG.customResource)
        return (MetadataJPEGPreservationTests.segment(0xED, Data(first)).bytes,
                MetadataJPEGPreservationTests.segment(0xED, Data(second)).bytes)
    }

    static func xmpSegment(_ packet: String) -> Data {
        MetadataJPEGPreservationTests.segment(0xE1, Data(JPEGTestSegments.xmpID.utf8) + Data([0]) + Data(packet.utf8)).bytes
    }

    /// A second, later packet from another app, with no rating or keywords.
    static let secondPacket = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:other="http://example.com/other/1.0/"
       xmp:Label="Second"
       other:Tool="SecondApp">
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    static let extendedGUID = Insecure.MD5.hash(data: Data(extensionText(rating: false).utf8)).map { String(format: "%02X", $0) }.joined()

    private static func extensionText(rating: Bool) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" \
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \
        photoshop:History="a long history" crs:Big="\(String(repeating: "x", count: 300))"\(rating ? " xmp:Rating=\"1\"" : "")/>\
        </rdf:RDF></x:xmpmeta>
        """
    }

    /// The rich JPEG's packet naming an extension (`xmpNote:HasExtendedXMP`), and the extension in two chunks
    /// (XMP Part 3 §1.1.3.1: signature, GUID, full length, offset, data).
    static func extendedXMP(extensionHoldsRating: Bool = false) -> (standard: Data, extensions: [Data]) {
        let text = Data(extensionText(rating: extensionHoldsRating).utf8)
        let guid = Insecure.MD5.hash(data: text).map { String(format: "%02X", $0) }.joined()
        let packet = RichJPEG.xmp.replacingOccurrences(
            of: "xmlns:acme=\"http://example.com/acme/1.0/\"",
            with: "xmlns:acme=\"http://example.com/acme/1.0/\"\n    xmlns:xmpNote=\"http://ns.adobe.com/xmp/note/\"\n   xmpNote:HasExtendedXMP=\"\(guid)\"")
        func be32(_ v: Int) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        let half = text.count / 2
        let chunks = [text[0..<half], text[half...]].enumerated().map { index, chunk in
            MetadataJPEGPreservationTests.segment(0xE1, Data("http://ns.adobe.com/xmp/extension/\u{0}".utf8) + Data(guid.utf8)
                + be32(text.count) + be32(index == 0 ? 0 : half) + Data(chunk)).bytes
        }
        return (xmpSegment(packet), chunks)
    }

    /// A packet ImageIO's rewrite would change: a qualified array item, an empty value, an `rdf:nodeID` property, a
    /// datatype, a `parseType="Literal"` property, `exif:DateTimeOriginal` (which it renames), a comment, and padding.
    static func awkwardPacket(rated: Bool) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Other Toolkit 1.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <!-- written by another app -->
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmlns:q="http://example.com/q/1.0/"
           photoshop:City="Paris"
           photoshop:Headline=""
           exif:DateTimeOriginal="2024-05-01T10:00:00"\(rated ? "\n       xmp:Rating=\"2\"" : "")>
           <dc:creator><rdf:Seq><rdf:li rdf:parseType="Resource"><rdf:value>Ann Example</rdf:value><q:role>photographer</q:role></rdf:li></rdf:Seq></dc:creator>
           <q:node rdf:nodeID="n1"/>
           <q:count rdf:datatype="http://www.w3.org/2001/XMLSchema#integer">5</q:count>
           <q:markup rdf:parseType="Literal"><b>bold</b></q:markup>\(rated ? "\n       <dc:subject><rdf:Bag><rdf:li>old</rdf:li></rdf:Bag></dc:subject>" : "")
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        \(String(repeating: " ", count: 64))
        <?xpacket end="w"?>
        """
    }

    static let xapmetaPacket = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xapmeta xmlns:x="adobe:ns:meta/" x:xaptk="3.1.1-111">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="uuid:faf5bdd5-ba3d-11da-ad31-d33d75182f1b"
        xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
       <photoshop:City>Paris</photoshop:City>
      </rdf:Description>
      <rdf:Description rdf:about="uuid:faf5bdd5-ba3d-11da-ad31-d33d75182f1b"
        xmlns:xapMM="http://ns.adobe.com/xap/1.0/mm/">
       <xapMM:DocumentID>adobe:docid:photoshop:1234</xapMM:DocumentID>
      </rdf:Description>
     </rdf:RDF>
    </x:xapmeta>
    <?xpacket end="w"?>
    """

    static let bareRDFPacket = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
     <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" photoshop:City="Paris"/>
    </rdf:RDF>
    <?xpacket end="w"?>
    """
}
