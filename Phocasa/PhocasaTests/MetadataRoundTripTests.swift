import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Write → read round trips through `MetadataService`, on real files in a temp directory.
final class MetadataRoundTripTests: XCTestCase {

    private let service = MetadataService.shared
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dir = dir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        // A read-only file in a writable folder can still be deleted, so this removes everything.
        if let dir {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

    private func makeImage(width: Int = 64, height: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 8, width: width / 2, height: height / 3))
        return ctx.makeImage()!
    }

    @discardableResult
    private func makeJPEG(_ name: String, properties: [CFString: Any]? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, makeImage(), properties as CFDictionary?)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeFakeRAW(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("fake raw bytes".utf8).write(to: url)
        return url
    }

    private func directoryListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func decodedPixels(_ url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = try XCTUnwrap(image.dataProvider?.data)
        return data as Data
    }

    private func posixPermissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: - JPEG round trips (spec §F1)

    func testJPEGRatingRoundTrips() throws {
        let jpg = try makeJPEG("a.jpg")

        service.writeMetadata(rating: 4, keywords: [], toImageAt: jpg.path)

        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 4)
    }

    func testJPEGKeywordsRoundTrip() throws {
        let jpg = try makeJPEG("a.jpg")

        service.writeMetadata(rating: 2, keywords: ["cat:a", "b"], toImageAt: jpg.path)

        let read = service.readMetadata(from: jpg.path)
        XCTAssertEqual(Set(read.keywords), ["cat:a", "b"])
        XCTAssertEqual(read.rating, 2)
    }

    func testJPEGRatingAndKeywordsCanBeCleared() throws {
        let jpg = try makeJPEG("a.jpg")
        service.writeMetadata(rating: 5, keywords: ["x", "y"], toImageAt: jpg.path)

        service.writeMetadata(rating: 0, keywords: [], toImageAt: jpg.path)

        let read = service.readMetadata(from: jpg.path)
        XCTAssertEqual(read.rating, 0)
        XCTAssertEqual(read.keywords, [])
    }

    func testJPEGRatingOverwritesPreviousRating() throws {
        let jpg = try makeJPEG("a.jpg")
        for rating in [1, 5, 3] {
            service.writeMetadata(rating: rating, keywords: ["k"], toImageAt: jpg.path)
        }
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 3)
    }

    func testReadsKeywordsWrittenAsIPTCByOtherTools() throws {
        let jpg = try makeJPEG("iptc.jpg", properties: [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["people:ann", "beach"]]
        ])
        XCTAssertEqual(Set(service.readMetadata(from: jpg.path).keywords), ["people:ann", "beach"])
    }

    // MARK: Keywords from IPTC-IIM vs XMP

    /// JPEG marker segments before the image data: (marker, byte range including the FF xx header).
    private func jpegSegments(_ data: Data) -> [(marker: UInt8, range: Range<Int>)] {
        var segments: [(UInt8, Range<Int>)] = []
        var i = 2
        while i + 4 <= data.count, data[i] == 0xFF, data[i + 1] != 0xDA {
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            segments.append((data[i + 1], i..<(i + 2 + length)))
            i += 2 + length
        }
        return segments
    }

    private func xmpSegment(_ data: Data) throws -> Range<Int> {
        try XCTUnwrap(jpegSegments(data).first {
            $0.marker == 0xE1 && data[$0.range].range(of: Data("http://ns.adobe.com/xap/1.0/".utf8)) != nil
        }?.range)
    }

    private func iimSegment(_ data: Data) throws -> Range<Int> {
        try XCTUnwrap(jpegSegments(data).first { $0.marker == 0xED }?.range)
    }

    /// ImageIO writes keywords as both XMP and IPTC-IIM. Returns the file's bytes.
    private func jpegBytes(keywords: [String]) throws -> Data {
        try Data(contentsOf: makeJPEG("kw-\(UUID().uuidString).jpg", properties: [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: keywords]
        ]))
    }

    /// The keywords the pre-task read path used: IPTC Keywords from the properties dictionary.
    private func iptcDictionaryKeywords(_ url: URL) throws -> [String] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let iptc = properties?[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        return iptc?[kCGImagePropertyIPTCKeywords as String] as? [String] ?? []
    }

    func testKeywordsMatchIPTCDictionaryForIIMOnlyXMPOnlyAndConflictingFiles() throws {
        let iim = try jpegBytes(keywords: ["iim:a", "iim-b"])
        let xmp = try jpegBytes(keywords: ["xmp:a"])

        var iimOnly = iim
        iimOnly.removeSubrange(try xmpSegment(iim))
        var xmpOnly = xmp
        xmpOnly.removeSubrange(try iimSegment(xmp))
        var conflict = iim   // IIM says iim:a, iim-b; XMP says xmp:a
        conflict.replaceSubrange(try xmpSegment(iim), with: xmp[try xmpSegment(xmp)])

        let cases: [(String, Data, Set<String>)] = [
            ("iim-only.jpg", iimOnly, ["iim:a", "iim-b"]),
            ("xmp-only.jpg", xmpOnly, ["xmp:a"]),
            ("both.jpg", iim, ["iim:a", "iim-b"]),
            ("conflict.jpg", conflict, []),
        ]
        for (name, bytes, expected) in cases {
            let url = dir.appendingPathComponent(name)
            try bytes.write(to: url)
            let read = service.readMetadata(from: url.path).keywords
            XCTAssertEqual(read, try iptcDictionaryKeywords(url), "\(name): must match what ImageIO's IPTC dictionary reports")
            if !expected.isEmpty { XCTAssertEqual(Set(read), expected, name) }
        }
    }

    func testOutOfRangeXMPRatingReadsAsUnrated() throws {
        // Adobe tools write xmp:Rating="-1" for "rejected". The app only knows 0...5.
        let jpg = try makeJPEG("rejected.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        let out = CFDataCreateMutable(nil, 0)!
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 0, nil))
        let meta = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "-1" as CFString))
        XCTAssertTrue(CGImageDestinationCopyImageSource(dest, source, [
            kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true
        ] as CFDictionary, nil))
        try (out as Data).write(to: jpg)

        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 0)
    }

    func testSidecarRatingStillTakesPrecedenceOverEmbeddedRating() throws {
        // Today's precedence, kept on purpose: x.jpg also reads x.xmp (the paired RAW's sidecar),
        // and a non-zero sidecar rating wins. (Task D: only for a pair. The RAW is there now; a JPG on its own that
        // holds a rating is read from the file, MetadataSidecarMigrationTests.)
        let jpg = try makeJPEG("pair.jpg")
        service.writeMetadata(rating: 2, keywords: [], toImageAt: jpg.path)
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 2)

        _ = try makeFakeRAW("pair.cr3")
        service.writeSidecar(rating: 4, keywords: [], for: dir.appendingPathComponent("pair.cr3"), editParameters: nil)
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 4)

        service.writeSidecar(rating: 0, keywords: [], for: dir.appendingPathComponent("pair.cr3"), editParameters: nil)
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 2, "a zero sidecar rating falls back to the embedded one")
    }

    // MARK: - RAW sidecars (spec §F2)

    func testRAWOnlyRatingWritePreservesEditParameters() throws {
        let raw = try makeFakeRAW("IMG_1.CR3")
        service.writeEditParameters(EditParameters(exposure: 1.5), forRAWAt: raw.path)

        service.writeMetadata(rating: 3, keywords: ["x"], toImageAt: raw.path)

        XCTAssertEqual(service.readEditParameters(forRAWAt: raw.path)?.exposure, 1.5)
        let read = service.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, 3)
        XCTAssertEqual(read.keywords, ["x"])
    }

    func testRAWEditParameterWritePreservesRatingAndKeywords() throws {
        let raw = try makeFakeRAW("IMG_2.cr3")
        service.writeMetadata(rating: 5, keywords: ["cat:a", "b"], toImageAt: raw.path)

        service.writeEditParameters(EditParameters(contrast: 20), forRAWAt: raw.path)

        let read = service.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, 5)
        XCTAssertEqual(read.keywords, ["cat:a", "b"])
        XCTAssertEqual(read.editParameters?.contrast, 20)
    }

    func testWriteSidecarWithExplicitNilClearsEditParameters() throws {
        let raw = try makeFakeRAW("IMG_3.cr3")
        service.writeEditParameters(EditParameters(exposure: 1.5), forRAWAt: raw.path)
        XCTAssertNotNil(service.readEditParameters(forRAWAt: raw.path))

        // What the view model's clearRAWSidecarEdits does today.
        let existing = service.readMetadata(from: raw.path)
        service.writeSidecar(rating: existing.rating, keywords: existing.keywords, for: raw, editParameters: nil)

        XCTAssertNil(service.readEditParameters(forRAWAt: raw.path))
    }

    func testClearEditParametersKeepsRatingAndKeywords() throws {
        let raw = try makeFakeRAW("IMG_4.cr3")
        service.writeMetadata(rating: 4, keywords: ["k"], toImageAt: raw.path)
        service.writeEditParameters(EditParameters(exposure: -2), forRAWAt: raw.path)

        service.clearEditParameters(forRAWAt: raw.path)

        XCTAssertNil(service.readEditParameters(forRAWAt: raw.path))
        let read = service.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, 4)
        XCTAssertEqual(read.keywords, ["k"])
    }

    // MARK: - Safe image writes (spec §F4)

    func testFailedWriteLeavesOriginalUntouched() throws {
        let bogus = dir.appendingPathComponent("not-an-image.jpg")
        let bytes = Data("these bytes are not a JPEG".utf8)
        try bytes.write(to: bogus)

        service.writeMetadata(rating: 3, keywords: ["x"], toImageAt: bogus.path)

        XCTAssertEqual(try Data(contentsOf: bogus), bytes)
        XCTAssertEqual(try directoryListing(), ["not-an-image.jpg"], "no temp files may be left behind")
    }

    func testFailedWriteOnEmptyFileLeavesNoTempFiles() throws {
        let empty = dir.appendingPathComponent("empty.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: nil))

        service.writeMetadata(rating: 3, keywords: [], toImageAt: empty.path)

        XCTAssertEqual(try Data(contentsOf: empty), Data())
        XCTAssertEqual(try directoryListing(), ["empty.jpg"])
    }

    func testSuccessfulWriteLeavesNoTempFiles() throws {
        let jpg = try makeJPEG("a.jpg")

        service.writeMetadata(rating: 1, keywords: ["k"], toImageAt: jpg.path)

        XCTAssertEqual(try directoryListing(), ["a.jpg"])
    }

    func testWriteKeepsImageDataLossless() throws {
        let jpg = try makeJPEG("a.jpg")
        let before = try decodedPixels(jpg)

        service.writeMetadata(rating: 4, keywords: ["k"], toImageAt: jpg.path)

        XCTAssertEqual(try decodedPixels(jpg), before)
    }

    func testWritePreservesFileDates() throws {
        let jpg = try makeJPEG("a.jpg")
        let past = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.creationDate: past, .modificationDate: past], ofItemAtPath: jpg.path)

        service.writeMetadata(rating: 5, keywords: [], toImageAt: jpg.path)

        let attrs = try FileManager.default.attributesOfItem(atPath: jpg.path)
        let created = try XCTUnwrap(attrs[.creationDate] as? Date)
        let modified = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(created.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(modified.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 5)
    }

    func testWritePreservesPermissionsAndExtendedAttributes() throws {
        let jpg = try makeJPEG("a.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jpg.path)
        let set = jpg.withUnsafeFileSystemRepresentation { setxattr($0!, "com.phocasa.test", "v", 1, 0, 0) }
        XCTAssertEqual(set, 0)

        service.writeMetadata(rating: 2, keywords: [], toImageAt: jpg.path)

        XCTAssertEqual(try posixPermissions(jpg), 0o600)
        let size = jpg.withUnsafeFileSystemRepresentation { getxattr($0!, "com.phocasa.test", nil, 0, 0, 0) }
        XCTAssertEqual(size, 1, "extended attributes (e.g. Finder tags) must survive the write")
    }

    func testWriteThroughSymlinkUpdatesTargetAndKeepsLink() throws {
        let realDir = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let target = realDir.appendingPathComponent("t.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, makeImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let link = dir.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        service.writeMetadata(rating: 4, keywords: [], toImageAt: link.path)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path,
                       "the symlink must stay a symlink")
        XCTAssertEqual(service.readMetadata(from: target.path).rating, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realDir.path), ["t.jpg"])
    }

    func testReadOnlyFileIsNotModified() throws {
        let jpg = try makeJPEG("locked.jpg")
        let bytes = try Data(contentsOf: jpg)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: jpg.path)

        service.writeMetadata(rating: 3, keywords: ["x"], toImageAt: jpg.path)

        XCTAssertEqual(try Data(contentsOf: jpg), bytes)
        XCTAssertEqual(try posixPermissions(jpg), 0o444)
        XCTAssertEqual(try directoryListing(), ["locked.jpg"])
    }
}
