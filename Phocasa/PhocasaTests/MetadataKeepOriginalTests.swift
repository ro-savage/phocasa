import XCTest
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
@testable import Phocasa

/// Rating and keyword writes never lose a file's original metadata (post-wave-3 task A; CLAUDE.md, "Metadata"). A
/// JPEG gets new XMP and IPTC keywords spliced in, keeping every other Photoshop resource and IPTC dataset; a file
/// that can't be written that way (a JPEG layout the splice refuses, or another format, which only ImageIO's lossy
/// rewrite could change) keeps its bytes, and its rating and keywords go to its `.xmp` sidecar, which then wins on
/// reading.
final class MetadataKeepOriginalTests: XCTestCase {
    private let service = MetadataService.shared
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-keeporiginal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    private typealias T = MetadataJPEGPreservationTests

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func sidecarValue(_ url: URL, _ path: String) -> String? {
        guard let data = try? Data(contentsOf: url.xmpSidecarURL),
              let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String?
    }

    /// A camera-style JPEG with an XMP packet from another app that rates it 2 and tags it "old".
    private func jpegWithOtherAppXMP(extraSegments: [T.Segment] = []) -> Data {
        let base = T.cameraStyleJPEG()
        let (segments, sos) = T.header(base)
        let xmp = T.segment(0xE1, Data(JPEGTestSegments.xmpID.utf8) + Data([0]) + Data(RichJPEG.xmp.utf8))
        var out: [T.Segment] = []
        for segment in segments {
            out.append(segment)
            if segment.id == "Exif" { out.append(xmp); out += extraSegments }
        }
        return T.assemble(out, tail: base[sos...])
    }

    // MARK: - JPEG: Photoshop resources and IPTC datasets

    func testRatingWriteKeepsEveryPhotoshopResourceAndIPTCDataset() throws {
        let base = T.cameraStyleJPEG()
        let (segments, sos) = T.header(base)
        let thumbnail = [UInt8](repeating: 0x5A, count: 40)
        var out: [T.Segment] = []
        for segment in segments {
            out.append(segment)
            if segment.id == "Exif" { out.append(RichJPEG.app13(thumbnail: thumbnail)) }
        }
        let original = T.assemble(out, tail: base[sos...])
        let jpg = try write(original, "irb.jpg")

        service.writeMetadata(rating: 3, keywords: ["new", "people:ann"], toImageAt: jpg.path)

        let after = try Data(contentsOf: jpg)
        let before = IRBTestData.resources(try XCTUnwrap(JPEGTestSegments.app13(original)))
        let now = IRBTestData.resources(try XCTUnwrap(JPEGTestSegments.app13(after), "the APP13 segment is kept"))
        XCTAssertEqual(now.map(\.id), before.map(\.id), "every resource, in order")
        for resource in before where ![0x0404, 0x0425].contains(resource.id) {
            XCTAssertEqual(now.first { $0.id == resource.id }?.data, resource.data, "resource \(resource.id), byte for byte")
        }
        let iim = try XCTUnwrap(now.first { $0.id == 0x0404 }?.data)
        let datasets = IRBTestData.datasets(iim)
        let originalOthers = IRBTestData.datasets(Data(RichJPEG.iim)).filter { !($0.record == 2 && $0.number == 25) }
        XCTAssertEqual(datasets.filter { !($0.record == 2 && $0.number == 25) }.map { "\($0.record):\($0.number)=\($0.value as NSData)" },
                       originalOthers.map { "\($0.record):\($0.number)=\($0.value as NSData)" },
                       "every other IPTC dataset, custom ones included, byte for byte and in order")
        XCTAssertEqual(datasets.filter { $0.record == 2 && $0.number == 25 }.map { String(decoding: $0.value, as: UTF8.self) },
                       ["new", "people:ann"])
        XCTAssertEqual(now.first { $0.id == 0x0425 }?.data, Data(Insecure.MD5.hash(data: iim)),
                       "the IPTC digest describes the new IPTC data")
        // Everything outside the XMP and APP13 segments, byte for byte.
        let untouched = { (d: Data) in T.header(d).segments.filter { $0.marker != 0xED && $0.id != JPEGTestSegments.xmpID } }
        XCTAssertEqual(untouched(after), untouched(original))
        XCTAssertEqual(Data(after[T.header(after).sos...]), Data(base[sos...]))
        let props = KeptMetadata.properties(after)
        let iptc = try XCTUnwrap(props["{IPTC}"] as? [String: Any])
        XCTAssertEqual(iptc["Keywords"] as? [String], ["new", "people:ann"])
        XCTAssertEqual(iptc["City"] as? String, "Paris")
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 3)
    }

    func testNonASCIIKeywordsDeclareUTF8InTheIPTCData() throws {
        let base = T.cameraStyleJPEG()
        let (segments, sos) = T.header(base)
        var out: [T.Segment] = []
        for segment in segments {
            out.append(segment)
            if segment.id == "Exif" { out.append(RichJPEG.app13(thumbnail: [1, 2, 3, 4])) }
        }
        let jpg = try write(T.assemble(out, tail: base[sos...]), "utf8.jpg")

        service.writeMetadata(rating: 1, keywords: ["café", "people:zoë"], toImageAt: jpg.path)

        let iptc = try XCTUnwrap(KeptMetadata.properties(try Data(contentsOf: jpg))["{IPTC}"] as? [String: Any])
        XCTAssertEqual(iptc["Keywords"] as? [String], ["café", "people:zoë"])
        let iim = try XCTUnwrap(IRBTestData.resources(try XCTUnwrap(JPEGTestSegments.app13(try Data(contentsOf: jpg))))
            .first { $0.id == 0x0404 }?.data)
        XCTAssertTrue(IRBTestData.datasets(iim).contains { $0.record == 1 && $0.number == 90 && $0.value == Data([0x1B, 0x25, 0x47]) },
                      "1:90 says the IPTC text is UTF-8")
    }

    func testRatingWriteKeepsXMPFromOtherApps() throws {
        let original = jpegWithOtherAppXMP()
        let jpg = try write(original, "xmp.jpg")

        service.writeMetadata(rating: 5, keywords: ["k"], toImageAt: jpg.path)

        let before = KeptMetadata.xmpValues(JPEGTestSegments.xmpPacket(original))
        let after = KeptMetadata.xmpValues(JPEGTestSegments.xmpPacket(try Data(contentsOf: jpg)))
        for (path, value) in before where !path.hasPrefix("xmp:Rating") && !path.hasPrefix("dc:subject") {
            XCTAssertEqual(after[path], value, "XMP \(path)")
        }
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.xmpSidecarURL.path))
    }

    // MARK: - Files that can't be written without losing something get a sidecar

    func testAJPEGTheSpliceRefusesKeepsItsBytesAndGetsASidecar() throws {
        // XMP that isn't well-formed XML (a mistyped end tag after the rating): ImageIO reads it leniently, but a
        // rewrite could lose what it skips, so it is still refused. (Before task D: extended XMP, now written in-file.)
        let base = T.cameraStyleJPEG()
        let (segments, sos) = T.header(base)
        let packet = RichJPEG.xmp.replacingOccurrences(of: "</dc:subject>", with: "</dc:subjct>")
        let xmp = T.segment(0xE1, Data(JPEGTestSegments.xmpID.utf8) + Data([0]) + Data(packet.utf8))
        let original = T.assemble(segments.flatMap { $0.id == "Exif" ? [$0, xmp] : [$0] }, tail: base[sos...])
        let jpg = try write(original, "malformed-xmp.jpg")
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 2, "fixture: rated 2 inside the file")

        service.writeMetadata(rating: 4, keywords: ["a", "b"], toImageAt: jpg.path)

        XCTAssertEqual(try Data(contentsOf: jpg), original, "the JPEG is untouched")
        XCTAssertEqual(sidecarValue(jpg, "xmp:Rating"), "4")
        XCTAssertEqual(sidecarValue(jpg, "phocasa:OverridesEmbedded"), "True")
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 4)
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, ["a", "b"])

        // Clearing wins over the file's own rating and keywords too.
        service.writeMetadata(rating: 0, keywords: [], toImageAt: jpg.path)

        XCTAssertEqual(try Data(contentsOf: jpg), original)
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 0)
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, [])
    }

    /// Task D: a file in sidecar mode moves into the file on its next write (it used to stay in the sidecar).
    func testAJPEGWhoseRatingIsInASidecarGetsItInTheFileOnTheNextWrite() throws {
        let original = T.cameraStyleJPEG()
        let jpg = try write(original, "sticky.jpg")
        // A sidecar a refused write left (say, before the file's layout could be written in place).
        XCTAssertEqual(service.updateSidecar(of: jpg, MetadataService.SidecarUpdate(rating: 2, keywords: ["x"],
                                                                                   overridesEmbedded: true)), .written)

        service.writeMetadata(rating: 5, keywords: ["y"], toImageAt: jpg.path)

        let after = try Data(contentsOf: jpg)
        let inFile = try XCTUnwrap(CGImageSourceCreateWithData(after as CFData, nil)
            .flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(inFile, nil, "xmp:Rating" as CFString) as String?, "5",
                       "the rating is in the file, where other apps read it")
        XCTAssertEqual(CGImageMetadataCopyTagWithPath(inFile, nil, "dc:subject" as CFString)
            .flatMap { CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] }?
            .compactMap { CGImageMetadataTagCopyValue($0) as? String }, ["y"])
        // Everything outside the XMP and APP13 segments is the original's.
        let untouched = { (d: Data) in T.header(d).segments.filter { $0.marker != 0xED && $0.id != JPEGTestSegments.xmpID } }
        XCTAssertEqual(untouched(after), untouched(original))
        XCTAssertEqual(Data(after[T.header(after).sos...]), Data(original[T.header(original).sos...]))
        // The sidecar stays, in step with the file: same values, no longer overriding it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpg.xmpSidecarURL.path), "a user's sidecar is never deleted")
        XCTAssertEqual(sidecarValue(jpg, "xmp:Rating"), "5")
        XCTAssertNil(sidecarValue(jpg, "phocasa:OverridesEmbedded"))
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 5)
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, ["y"])
    }

    /// Task D: PNG takes its values in the file (`PNGMetadataTests` has the byte-level checks). This checks that
    /// `writeMetadata` puts them there, keeping every other property, with no sidecar.
    func testAPNGGetsItsValuesInTheFile() throws {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(T.imageIOJPEG() as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                                             kCGImagePropertyExifUserComment: "keep me"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = out as Data
        let url = try write(original, "p.png")

        service.writeMetadata(rating: 3, keywords: ["k"], toImageAt: url.path)

        let after = try Data(contentsOf: url)
        XCTAssertNotEqual(after, original, "the values are in the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.xmpSidecarURL.path), "no sidecar")
        let meta = try XCTUnwrap(CGImageSourceCreateWithData(after as CFData, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?, "3")
        let before = KeptMetadata.properties(original), now = KeptMetadata.properties(after)
        for dictionary in ["{Exif}", "{TIFF}", "{PNG}"] {
            let old = before[dictionary] as? [String: Any] ?? [:], new = now[dictionary] as? [String: Any] ?? [:]
            for (key, value) in old { XCTAssertEqual(new[key].map { "\($0)" }, "\(value)", "\(dictionary).\(key)") }
        }
        XCTAssertEqual(service.readMetadata(from: url.path).rating, 3)
        XCTAssertEqual(service.readMetadata(from: url.path).keywords, ["k"])
    }

    /// The check every container edit (PNG, TIFF, HEIC) passes before it replaces a file: a result that lost a property,
    /// or doesn't hold the new values, is refused.
    /// Task D: TIFF takes its values in the file (`TIFFMetadataTests` has the byte-level checks).
    func testATIFFGetsItsValuesInTheFile() throws {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(T.imageIOJPEG() as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                                             kCGImagePropertyExifUserComment: "keep me"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = out as Data
        let url = try write(original, "t.tiff")

        service.writeMetadata(rating: 4, keywords: ["k", "people:ann"], toImageAt: url.path)

        let after = try Data(contentsOf: url)
        XCTAssertNotEqual(after, original, "the values are in the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.xmpSidecarURL.path), "no sidecar")
        let meta = try XCTUnwrap(CGImageSourceCreateWithData(after as CFData, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?, "4")
        let before = KeptMetadata.properties(original), now = KeptMetadata.properties(after)
        for dictionary in ["{Exif}", "{TIFF}"] {
            let old = before[dictionary] as? [String: Any] ?? [:], new = now[dictionary] as? [String: Any] ?? [:]
            for (key, value) in old { XCTAssertEqual(new[key].map { "\($0)" }, "\(value)", "\(dictionary).\(key)") }
        }
        XCTAssertEqual(service.readMetadata(from: url.path).rating, 4)
        XCTAssertEqual(service.readMetadata(from: url.path).keywords, ["k", "people:ann"])
    }

    func testTheContainerCheckRefusesAFileThatLostAProperty() throws {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(T.imageIOJPEG() as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        func png(exif: Bool, rating: Int?) throws -> Data {
            let out = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil))
            let meta = CGImageMetadataCreateMutable()
            if let rating {
                XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "\(rating)" as CFString))
            }
            if exif {
                XCTAssertTrue(CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyExifDictionary,
                                                                           kCGImagePropertyExifUserComment, "keep me" as CFString))
            }
            CGImageDestinationAddImageAndMetadata(destination, image, meta, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return out as Data
        }
        let original = try png(exif: true, rating: nil)
        XCTAssertTrue(MetadataService.image(try png(exif: true, rating: 3), keepsEverythingIn: original, reading: 3, []))
        XCTAssertFalse(MetadataService.image(try png(exif: false, rating: 3), keepsEverythingIn: original, reading: 3, []),
                       "the Exif comment is gone")
        XCTAssertFalse(MetadataService.image(try png(exif: true, rating: 2), keepsEverythingIn: original, reading: 3, []),
                       "the new rating isn't there")
        // (ImageIO calls a cut-short PNG complete; the PNG path walks its output's chunks and CRCs as well.)
    }

    /// Task D: HEIC takes its values in the file too (`HEIFMetadataTests` has the proof), so no format is left in
    /// sidecar mode (this test used to check that PNG, TIFF and HEIC kept their bytes and got a sidecar).
    func testAHEICGetsItsValuesInTheFile() throws {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(T.imageIOJPEG() as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                                             kCGImagePropertyExifUserComment: "keep me"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = out as Data
        let url = try write(original, "h.heic")

        service.writeMetadata(rating: 3, keywords: ["k"], toImageAt: url.path)

        let after = try Data(contentsOf: url)
        XCTAssertNotEqual(after, original, "the values are in the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.xmpSidecarURL.path), "no sidecar")
        let meta = try XCTUnwrap(CGImageSourceCreateWithData(after as CFData, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?, "3")
        let before = KeptMetadata.properties(original), now = KeptMetadata.properties(after)
        for dictionary in ["{Exif}", "{TIFF}"] {
            let old = before[dictionary] as? [String: Any] ?? [:], new = now[dictionary] as? [String: Any] ?? [:]
            for (key, value) in old { XCTAssertEqual(new[key].map { "\($0)" }, "\(value)", "\(dictionary).\(key)") }
        }
        XCTAssertEqual(service.readMetadata(from: url.path).rating, 3)
        XCTAssertEqual(service.readMetadata(from: url.path).keywords, ["k"])
    }

    /// A pair's JPG and RAW share `<stem>.xmp`. Once it holds the JPG's values, it wins for the RAW too, so the two
    /// never disagree, even about a rating of 0.
    func testASidecarThatOverridesTheFileWinsForThePairsRAW() throws {
        // A TIFF-based RAW rated 4 with keyword "embedded" inside the file.
        let raw = dir.appendingPathComponent("pair.dng")
        let image = try XCTUnwrap(CGImageSourceCreateWithData(T.imageIOJPEG() as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let meta = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "4" as CFString))
        let subject = try XCTUnwrap(CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString,
                                                             "subject" as CFString, .arrayUnordered, ["embedded"] as CFArray))
        XCTAssertTrue(CGImageMetadataSetTagWithPath(meta, nil, "dc:subject" as CFString, subject))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(raw as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, image, meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 4, "fixture: rated inside the file")

        XCTAssertEqual(service.updateSidecar(of: raw, MetadataService.SidecarUpdate(rating: 0, keywords: [],
                                                                                   overridesEmbedded: true)), .written)

        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 0)
        XCTAssertEqual(service.readMetadata(from: raw.path).keywords, [])
    }
}
