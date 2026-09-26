import XCTest
import ImageIO
@testable import Phocasa

/// Files leaving sidecar mode (post-wave-3 task D). Builds from `2f2fe1b` on put the rating and keywords of files they
/// couldn't write into in a `.xmp` sidecar flagged `phocasa:OverridesEmbedded`. Once such a file can take them, the
/// next write puts them in the file and keeps the sidecar in step (same values, flag cleared), never deleting it. And
/// reading never lets a stale sidecar hide newer values in the file: a file on its own that holds a rating is read
/// from the file, while a pair's JPG still reads its RAW's sidecar first.
final class MetadataSidecarMigrationTests: XCTestCase {
    private let service = MetadataService.shared
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir {
            // A read-only sidecar in a writable folder can still be removed.
            try FileManager.default.removeItem(at: dir)
        }
    }

    private typealias T = MetadataJPEGPreservationTests

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The sidecar's value at `path`, or nil.
    private func sidecarValue(_ url: URL, _ path: String) -> String? {
        guard let data = try? Data(contentsOf: url.xmpSidecarURL),
              let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String?
    }

    private func sidecarKeywords(_ url: URL) -> [String] {
        (try? Data(contentsOf: url.xmpSidecarURL)).map { MetadataService.sidecarContents($0).keywords } ?? []
    }

    /// What the file itself holds, read by ImageIO with no sidecar in sight.
    private func inFile(_ url: URL) throws -> (rating: Int?, keywords: [String]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try Data(contentsOf: url) as CFData, nil))
        guard let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return (nil, []) }
        let rating = (CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?).flatMap { Int($0) }
        let subject = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString)
            .flatMap { CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] }?
            .compactMap { CGImageMetadataTagCopyValue($0) as? String } ?? []
        return (rating, subject)
    }

    /// A sidecar a build in sidecar mode left: these values, flagged as overriding the file.
    private func flaggedSidecar(for url: URL, rating: Int, keywords: [String]) {
        XCTAssertEqual(service.updateSidecar(of: url, MetadataService.SidecarUpdate(rating: rating, keywords: keywords,
                                                                                   overridesEmbedded: true)), .written)
        XCTAssertEqual(sidecarValue(url, "phocasa:OverridesEmbedded"), "True", "fixture: the sidecar overrides the file")
    }

    /// Everything but the XMP and APP13 segments: the parts a rating write may change.
    private func untouchable(_ d: Data) -> (segments: [T.Segment], tail: Data) {
        let (segments, sos) = T.header(d)
        return (segments.filter { !($0.marker == 0xE1 && $0.id.hasPrefix("http://ns.adobe.com/x")) && $0.marker != 0xED },
                Data(d[sos...]))
    }

    /// A JPEG whose XMP packet (from another app) is too big to take two more properties in one segment: the splice
    /// refuses it, so its values stay in the sidecar (the last resort).
    private func jpegWithFullXMPSegment() -> Data {
        let base = T.cameraStyleJPEG()
        let (segments, sos) = T.header(base)
        let filler = String(repeating: "x", count: 65_200)
        let packet = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:acme="http://example.com/acme/1.0/" acme:Blob="\(filler)"/>\
            </rdf:RDF></x:xmpmeta>
            """
        let xmp = T.segment(0xE1, Data(JPEGTestSegments.xmpID.utf8) + Data([0]) + Data(packet.utf8))
        precondition(xmp.bytes.count <= 0xFFFF + 2, "fixture fits one segment")
        var out: [T.Segment] = []
        for segment in segments {
            out.append(segment)
            if segment.id == "Exif" { out.append(xmp) }
        }
        return T.assemble(out, tail: base[sos...])
    }

    // MARK: - Leaving sidecar mode

    func testAfterTheMoveTheSidecarFollowsEveryWrite() throws {
        let original = T.cameraStyleJPEG()
        let jpg = try write(original, "follow.jpg")
        flaggedSidecar(for: jpg, rating: 2, keywords: ["x"])
        service.writeMetadata(rating: 5, keywords: ["y"], toImageAt: jpg.path)
        XCTAssertNil(sidecarValue(jpg, "phocasa:OverridesEmbedded"), "fixture: moved into the file")

        service.writeMetadata(rating: 0, keywords: [], toImageAt: jpg.path)

        XCTAssertEqual(try inFile(jpg).rating, 0)
        XCTAssertEqual(try inFile(jpg).keywords, [])
        XCTAssertEqual(sidecarValue(jpg, "xmp:Rating"), "0", "the sidecar keeps the file's values")
        XCTAssertEqual(sidecarKeywords(jpg), [])
        XCTAssertNil(sidecarValue(jpg, "phocasa:OverridesEmbedded"))
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 0)
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, [])
        XCTAssertEqual(untouchable(try Data(contentsOf: jpg)).segments, untouchable(original).segments)
    }

    func testAStaleSidecarNeverHidesNewerValuesInTheFile() throws {
        let jpg = try write(T.cameraStyleJPEG(), "stale.jpg")
        flaggedSidecar(for: jpg, rating: 2, keywords: ["x"])
        service.writeMetadata(rating: 5, keywords: ["y"], toImageAt: jpg.path)

        // Another app rates the file itself afterwards; the sidecar still says 5 and "y".
        let rerated = try XCTUnwrap(MetadataService.jpegWritingRatingAndKeywords(try Data(contentsOf: jpg), rating: 1,
                                                                                keywords: ["other app"]))
        try rerated.write(to: jpg)
        XCTAssertEqual(sidecarValue(jpg, "xmp:Rating"), "5", "fixture: the sidecar is stale")

        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 1, "the file's newer rating wins")
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, ["other app"])
    }

    func testAFlaggedSidecarThatCantBeUpdatedLeavesTheFileAsItIs() throws {
        let original = T.cameraStyleJPEG()
        let jpg = try write(original, "locked.jpg")
        flaggedSidecar(for: jpg, rating: 2, keywords: ["x"])
        let sidecarBytes = try Data(contentsOf: jpg.xmpSidecarURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: jpg.xmpSidecarURL.path)

        service.writeMetadata(rating: 5, keywords: ["y"], toImageAt: jpg.path)

        // Writing only the file would leave the flagged sidecar winning with the old values.
        XCTAssertEqual(try Data(contentsOf: jpg), original, "the file isn't written while its sidecar can't follow")
        XCTAssertEqual(try Data(contentsOf: jpg.xmpSidecarURL), sidecarBytes)
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 2)
    }

    func testAPairsFlaggedSidecarKeepsThePairsValuesAndLosesTheFlag() async throws {
        let jpg = try write(T.cameraStyleJPEG(), "pair.JPG")
        let raw = dir.appendingPathComponent("pair.ARW")
        let rawBytes = Data("fake raw bytes".utf8)
        try rawBytes.write(to: raw)
        let edits = EditParameters(exposure: 0.4)
        service.writeEditParameters(edits, forRAWAt: raw.path)
        flaggedSidecar(for: jpg, rating: 2, keywords: ["x"])

        let writer = MetadataWriter(service: .shared)
        writer.enqueue([MetadataWriteItem(path: jpg.path, rating: 4, keywords: ["people:ann"], pairedRAWPath: raw.path)])
        await writer.flush()

        XCTAssertEqual(try inFile(jpg).rating, 4, "the JPG holds its rating")
        XCTAssertEqual(try inFile(jpg).keywords, ["people:ann"])
        XCTAssertEqual(sidecarValue(raw, "xmp:Rating"), "4", "the RAW's sidecar still gets the pair's values")
        XCTAssertEqual(sidecarKeywords(raw), ["people:ann"])
        XCTAssertNil(sidecarValue(raw, "phocasa:OverridesEmbedded"))
        XCTAssertEqual(service.readEditParameters(forRAWAt: raw.path), edits, "the RAW's edits are kept")
        XCTAssertEqual(try Data(contentsOf: raw), rawBytes, "the RAW itself is never written")
        for path in [jpg.path, raw.path] {
            XCTAssertEqual(service.readMetadata(from: path).rating, 4, path)
            XCTAssertEqual(service.readMetadata(from: path).keywords, ["people:ann"], path)
        }
    }

    /// Every PNG was in sidecar mode before task D.
    func testAPNGInSidecarModeMovesIntoTheFile() throws {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(T.imageIOJPEG() as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let png = try write(out as Data, "shot.png")
        flaggedSidecar(for: png, rating: 2, keywords: ["x"])

        service.writeMetadata(rating: 4, keywords: ["y"], toImageAt: png.path)

        XCTAssertEqual(try inFile(png).rating, 4)
        XCTAssertEqual(try inFile(png).keywords, ["y"])
        XCTAssertEqual(sidecarValue(png, "xmp:Rating"), "4")
        XCTAssertNil(sidecarValue(png, "phocasa:OverridesEmbedded"))
        XCTAssertEqual(service.readMetadata(from: png.path).rating, 4)
    }

    func testAFileThatStillCantTakeItsValuesKeepsTheSidecar() throws {
        let original = jpegWithFullXMPSegment()
        let jpg = try write(original, "full.jpg")

        service.writeMetadata(rating: 3, keywords: ["k"], toImageAt: jpg.path)

        XCTAssertEqual(try Data(contentsOf: jpg), original, "the last resort: the file keeps its bytes")
        XCTAssertEqual(sidecarValue(jpg, "xmp:Rating"), "3")
        XCTAssertEqual(sidecarValue(jpg, "phocasa:OverridesEmbedded"), "True")
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 3)
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, ["k"])
    }

    // MARK: - Reading: which values win

    func testALoneFilesOwnRatingWinsOverAnUnflaggedSidecar() throws {
        // A sidecar another app (or a RAW that's gone) left next to a JPG that holds its own rating.
        let jpg = try write(T.cameraStyleJPEG(), "alone.jpg")
        service.writeMetadata(rating: 3, keywords: ["in file"], toImageAt: jpg.path)
        XCTAssertEqual(service.updateSidecar(of: jpg, MetadataService.SidecarUpdate(rating: 5, keywords: ["sidecar"])), .written)

        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 3)
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, ["in file"])
        XCTAssertEqual(service.readMetadata(from: jpg.path, pairedWithRAW: false).rating, 3)
    }

    func testALoneFileWithoutARatingStillReadsAnUnflaggedSidecar() throws {
        let jpg = try write(T.cameraStyleJPEG(), "norating.jpg")
        XCTAssertNil(try inFile(jpg).rating, "fixture: no rating in the file")
        XCTAssertEqual(service.updateSidecar(of: jpg, MetadataService.SidecarUpdate(rating: 4, keywords: ["sidecar"])), .written)

        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 4)
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, ["sidecar"])
    }

    func testAPairStillPrefersItsRAWsSidecar() throws {
        let jpg = try write(T.cameraStyleJPEG(), "twin.JPG")
        service.writeMetadata(rating: 3, keywords: ["jpg"], toImageAt: jpg.path)
        let raw = dir.appendingPathComponent("twin.CR3")
        try Data("fake raw bytes".utf8).write(to: raw)
        XCTAssertEqual(service.updateSidecar(of: raw, MetadataService.SidecarUpdate(rating: 5, keywords: ["raw"])), .written)

        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 5, "the RAW beside it is found")
        XCTAssertEqual(service.readMetadata(from: jpg.path).keywords, ["raw"])
        XCTAssertEqual(service.readMetadata(from: jpg.path, pairedWithRAW: true).rating, 5)
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 5)
        // The scanner says what the photo is; without the RAW it's a file on its own.
        XCTAssertEqual(service.readMetadata(from: jpg.path, pairedWithRAW: false).rating, 3)
    }

    func testWritingALoneFileKeepsAnotherAppsSidecarInStep() throws {
        let jpg = try write(T.cameraStyleJPEG(), "otherapp.jpg")
        try Data(SidecarFixtures.lightroom.utf8).write(to: jpg.xmpSidecarURL)
        let before = SidecarFixtures.unrelated(try SidecarFixtures.properties(ofXMPAt: jpg.xmpSidecarURL))

        service.writeMetadata(rating: 2, keywords: ["new"], toImageAt: jpg.path)

        XCTAssertEqual(try inFile(jpg).rating, 2)
        XCTAssertEqual(sidecarValue(jpg, "xmp:Rating"), "2", "the sidecar says what the file says")
        XCTAssertEqual(sidecarKeywords(jpg), ["new"])
        XCTAssertNil(sidecarValue(jpg, "phocasa:OverridesEmbedded"))
        XCTAssertEqual(SidecarFixtures.unrelated(try SidecarFixtures.properties(ofXMPAt: jpg.xmpSidecarURL)), before,
                       "everything else in it is kept")
    }

    func testTheScanReadsALoneFileAndAPairByTheirOwnRules() async throws {
        // A JPG on its own with a stale sidecar, and a pair whose RAW sidecar was rated elsewhere.
        let alone = try write(T.cameraStyleJPEG(), "alone.jpg")
        service.writeMetadata(rating: 1, keywords: ["file"], toImageAt: alone.path)
        XCTAssertEqual(service.updateSidecar(of: alone, MetadataService.SidecarUpdate(rating: 5)), .written)
        let pairJPG = try write(T.cameraStyleJPEG(), "pair.JPG")
        service.writeMetadata(rating: 1, keywords: ["file"], toImageAt: pairJPG.path)
        let raw = dir.appendingPathComponent("pair.NEF")
        try Data("fake raw bytes".utf8).write(to: raw)
        XCTAssertEqual(service.updateSidecar(of: raw, MetadataService.SidecarUpdate(rating: 5)), .written)

        let found = await FolderScanner().scan(folderURL: dir, knownKeys: [])
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.fileName, $0.metadata?.rating) })

        XCTAssertEqual(byName["alone"], 1)
        XCTAssertEqual(byName["pair"], 5)
    }
}
