import XCTest
import ImageIO
@testable import Phocasa

/// RAW `.xmp` sidecars are updated in place (user decision 1, task 23): Phocasa changes only `xmp:Rating`,
/// `dc:subject` and `phocasa:EditParameters`, and keeps everything else another app put there.
final class MetadataSidecarUpdateTests: XCTestCase {

    private let service = MetadataService.shared
    private var dir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Helpers

    @discardableResult
    private func makeRAW(_ name: String, sidecar: String?) throws -> URL {
        let raw = dir.appendingPathComponent(name)
        try Data("fake raw bytes".utf8).write(to: raw)
        if let sidecar {
            try Data(sidecar.utf8).write(to: raw.xmpSidecarURL)
        }
        return raw
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func assertSidecar(_ raw: URL, rating: Int, keywords: [String], exposure: Double?,
                               unrelated expected: [String: String], _ step: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let read = service.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, rating, "\(step): rating", file: file, line: line)
        XCTAssertEqual(read.keywords, keywords, "\(step): keywords", file: file, line: line)
        XCTAssertEqual(service.readEditParameters(forRAWAt: raw.path)?.exposure, exposure, "\(step): edits", file: file, line: line)
        XCTAssertEqual(read.editParameters?.exposure, exposure, "\(step): readMetadata's edits", file: file, line: line)
        let now = SidecarFixtures.unrelated(try SidecarFixtures.properties(ofXMPAt: raw.xmpSidecarURL))
        XCTAssertEqual(now, expected, "\(step): every unrelated property must survive", file: file, line: line)
        XCTAssertEqual(try listing(), [raw.lastPathComponent, raw.xmpSidecarURL.lastPathComponent].sorted(),
                       "\(step): no temp files may be left", file: file, line: line)
    }

    /// Rating write, keyword write, edit write, clear, and `writeSidecar`: each keeps everything unrelated.
    private func runWriteSequence(sidecar: String, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let raw = try makeRAW(name, sidecar: sidecar)
        let unrelated = SidecarFixtures.unrelated(try SidecarFixtures.properties(ofXMPAt: raw.xmpSidecarURL))
        let original = service.readMetadata(from: raw.path)

        service.writeMetadata(rating: 5, keywords: original.keywords, toImageAt: raw.path)
        try assertSidecar(raw, rating: 5, keywords: original.keywords, exposure: original.editParameters?.exposure,
                          unrelated: unrelated, "rating write", file: file, line: line)

        service.writeMetadata(rating: 5, keywords: ["people:zoe", "a & b"], toImageAt: raw.path)
        try assertSidecar(raw, rating: 5, keywords: ["people:zoe", "a & b"], exposure: original.editParameters?.exposure,
                          unrelated: unrelated, "keyword write", file: file, line: line)

        service.writeEditParameters(EditParameters(exposure: 0.8), forRAWAt: raw.path)
        try assertSidecar(raw, rating: 5, keywords: ["people:zoe", "a & b"], exposure: 0.8,
                          unrelated: unrelated, "edit write", file: file, line: line)

        service.clearEditParameters(forRAWAt: raw.path)
        try assertSidecar(raw, rating: 5, keywords: ["people:zoe", "a & b"], exposure: nil,
                          unrelated: unrelated, "clear edits", file: file, line: line)

        service.writeSidecar(rating: 1, keywords: [], for: raw, editParameters: EditParameters(exposure: 2))
        try assertSidecar(raw, rating: 1, keywords: [], exposure: 2,
                          unrelated: unrelated, "writeSidecar with edits", file: file, line: line)

        service.writeSidecar(rating: 0, keywords: ["k"], for: raw, editParameters: nil)
        try assertSidecar(raw, rating: 0, keywords: ["k"], exposure: nil,
                          unrelated: unrelated, "writeSidecar clearing edits", file: file, line: line)
    }

    // MARK: - A1–A3: every Phocasa write keeps unrelated XMP

    func testOldPhocasaSidecarIsUpdatedInPlace() throws {
        let old = SidecarFixtures.oldPhocasa(rating: 3, keywords: ["people:ann", "beach"], edits: EditParameters(exposure: 1.5))
        let raw = try makeRAW("OLD_1.ARW", sidecar: old)
        let read = service.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, 3)
        XCTAssertEqual(read.keywords, ["people:ann", "beach"])
        XCTAssertEqual(read.editParameters?.exposure, 1.5)
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.removeItem(at: raw.xmpSidecarURL)

        try runWriteSequence(sidecar: old, name: "OLD_2.ARW")
    }

    func testLightroomSidecarKeepsItsDevelopSettingsAndUnrelatedNamespaces() throws {
        try runWriteSequence(sidecar: SidecarFixtures.lightroom, name: "LR_1.ARW")

        // Spot-check a few values by name, as a reader would.
        let props = try SidecarFixtures.properties(ofXMPAt: dir.appendingPathComponent("LR_1.xmp"))
        XCTAssertEqual(props["crs:Exposure2012"]?.hasSuffix("=+0.35"), true)
        XCTAssertEqual(props["crs:ToneCurvePV2012[1]"]?.hasSuffix("=255, 255"), true)
        XCTAssertEqual(props["crs:Look.Parameters.Version"]?.hasSuffix("=16.0"), true)
        XCTAssertEqual(props["lr:hierarchicalSubject[0]"]?.hasSuffix("=places|beach"), true)
        XCTAssertEqual(props["acme:Flag"]?.hasSuffix("=keep-me"), true)
        XCTAssertEqual(props["xmpMM:History[0].softwareAgent"]?.hasSuffix("=Adobe Lightroom"), true)
    }

    func testImageIOWrittenSidecarIsReadAndUpdatedInPlace() throws {
        let raw = try makeRAW("IIO_1.ARW", sidecar: try SidecarFixtures.imageIO())
        let read = service.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, 4, "xmp:Rating written as an element must be read")
        XCTAssertEqual(read.keywords, ["people:ann", "a & b"])
        XCTAssertEqual(read.editParameters?.exposure, -0.5)
        XCTAssertEqual(service.readEditParameters(forRAWAt: raw.path)?.exposure, -0.5)
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.removeItem(at: raw.xmpSidecarURL)

        try runWriteSequence(sidecar: try SidecarFixtures.imageIO(), name: "IIO_2.ARW")
    }

    // MARK: - Reading every format

    func testLightroomSidecarKeywordsComeOnlyFromDCSubject() throws {
        let raw = try makeRAW("LR_2.NEF", sidecar: SidecarFixtures.lightroom)

        let read = service.readMetadata(from: raw.path)

        XCTAssertEqual(read.keywords, ["landscape", "time:golden hour"],
                       "tone-curve points, hierarchical keywords and rights are not keywords")
        XCTAssertEqual(read.rating, 2)
        XCTAssertEqual(service.parseXMPSidecar(SidecarFixtures.lightroom).keywords, ["landscape", "time:golden hour"])
    }

    func testParsersAcceptTheElementForm() throws {
        let xmp = try SidecarFixtures.imageIO()
        XCTAssertEqual(service.parseXMPSidecar(xmp).rating, 4)
        XCTAssertEqual(service.parseXMPSidecar(xmp).keywords, ["people:ann", "a & b"])
        XCTAssertEqual(service.parseEditParameters(from: xmp)?.exposure, -0.5)
    }

    func testParsersAcceptTheAttributeFormOfEditParameters() {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:phocasa="http://phocasa.app/ns/1.0/"
          xmp:Rating="2" phocasa:EditParameters="\(SidecarFixtures.base64(EditParameters(contrast: 30)))"/>
        </rdf:RDF></x:xmpmeta>
        """
        XCTAssertEqual(service.parseEditParameters(from: xmp)?.contrast, 30)
        XCTAssertEqual(service.parseXMPSidecar(xmp).rating, 2)
    }

    func testFragmentsStillParseWithoutAnXMPPacket() {
        // Not a valid XMP packet (no x:xmpmeta or rdf:RDF), so ImageIO can't read it; the fallback still does.
        let fragment = """
        <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
            <xmp:Rating>5</xmp:Rating>
            <dc:subject><rdf:Bag><rdf:li>a &amp; b</rdf:li></rdf:Bag></dc:subject>
        </rdf:Description>
        """
        XCTAssertEqual(service.parseXMPSidecar(fragment).rating, 5)
        XCTAssertEqual(service.parseXMPSidecar(fragment).keywords, ["a & b"])
    }

    func testKeywordsWithXMLSpecialCharactersRoundTripThroughTheSidecar() throws {
        let raw = try makeRAW("ESC.CR3", sidecar: nil)

        service.writeMetadata(rating: 2, keywords: ["a & b", "<x>", "say \"hi\""], toImageAt: raw.path)

        XCTAssertEqual(service.readMetadata(from: raw.path).keywords, ["a & b", "<x>", "say \"hi\""])
    }

    // MARK: - Never lose a sidecar that can't be parsed

    /// Sidecars that exist but can't be read as XMP.
    private static var unparseableSidecars: [(name: String, bytes: Data)] {
        [
            ("garbage", Data("these bytes are not XMP".utf8)),
            ("truncated", Data(SidecarFixtures.lightroom.prefix(900).utf8)),
            // ImageIO's parser is lenient and would accept this; it isn't well-formed XML.
            ("mismatched", Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="4"><xmp:Foo>unclosed</rdf:Description>
            </rdf:RDF></x:xmpmeta>
            """.utf8)),
            ("utf16", SidecarFixtures.lightroom.data(using: .utf16)!),
            ("empty", Data()),
        ]
    }

    func testUnparseableSidecarIsLeftByteIdentical() throws {
        for (index, sidecar) in Self.unparseableSidecars.enumerated() {
            let raw = dir.appendingPathComponent("BAD_\(index).ARW")
            try Data("fake raw bytes".utf8).write(to: raw)
            try sidecar.bytes.write(to: raw.xmpSidecarURL)

            service.writeMetadata(rating: 4, keywords: ["k"], toImageAt: raw.path)
            service.writeEditParameters(EditParameters(exposure: 1), forRAWAt: raw.path)
            service.clearEditParameters(forRAWAt: raw.path)
            service.writeSidecar(rating: 1, keywords: [], for: raw, editParameters: nil)

            XCTAssertEqual(try Data(contentsOf: raw.xmpSidecarURL), sidecar.bytes,
                           "\(sidecar.name): a sidecar that can't be parsed must never be overwritten")
        }
        XCTAssertEqual(try listing().filter { $0.contains("phocasa-tmp") }, [], "no temp files may be left")
    }

    func testSkippedWritesAreReported() throws {
        let update = MetadataService.SidecarUpdate(rating: 4, keywords: ["k"], editParameters: .set(EditParameters(exposure: 1)))
        for (index, sidecar) in Self.unparseableSidecars.enumerated() {
            let raw = dir.appendingPathComponent("SKIP_\(index).ARW")
            try sidecar.bytes.write(to: raw.xmpSidecarURL)
            XCTAssertEqual(service.updateSidecar(of: raw, update), .skippedUnparseable, sidecar.name)
        }

        let locked = try makeRAW("RO.ARW", sidecar: SidecarFixtures.lightroom)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.xmpSidecarURL.path)
        XCTAssertEqual(service.updateSidecar(of: locked, update), .skippedReadOnly)

        let fresh = try makeRAW("NEW.ARW", sidecar: nil)
        XCTAssertEqual(service.updateSidecar(of: fresh, update), .written)
        // JSONEncoder's key order varies between calls, so this repeats enough to catch a byte comparison.
        for attempt in 0..<30 {
            XCTAssertEqual(service.updateSidecar(of: fresh, update), .unchanged, "the same values again change nothing (\(attempt))")
        }
        XCTAssertEqual(service.updateSidecar(of: try makeRAW("NONE.ARW", sidecar: nil),
                                             .init(editParameters: .set(nil))), .unchanged)
    }

    func testSameEditsEncodedDifferentlyCountAsUnchanged() throws {
        // JSONEncoder doesn't promise a key order, so the same edits can be stored as different JSON (and a
        // repeat write once came back `.written`). Equal values must not rewrite the file.
        let params = EditParameters(exposure: 1, contrast: 12, cropRect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let base64 = try encoder.encode(params).base64EncodedString()
        let raw = try makeRAW("ORDER.ARW", sidecar: """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:phocasa="http://phocasa.app/ns/1.0/">
        <phocasa:EditParameters>\(base64)</phocasa:EditParameters>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """)
        let before = try Data(contentsOf: raw.xmpSidecarURL)

        XCTAssertEqual(service.updateSidecar(of: raw, .init(editParameters: .set(params))), .unchanged)
        XCTAssertEqual(try Data(contentsOf: raw.xmpSidecarURL), before)
    }

    func testSidecarUsingAnotherPrefixForPhocasasNamespaceIsLeftAlone() throws {
        // Registering "phocasa" fails when the file already binds the namespace to another prefix.
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:ph="http://phocasa.app/ns/1.0/"
          xmp:Rating="2" ph:Other="x"/>
        </rdf:RDF></x:xmpmeta>
        """
        let raw = try makeRAW("PREFIX.ARW", sidecar: xmp)

        guard case .failed = service.updateSidecar(of: raw, .init(editParameters: .set(EditParameters(exposure: 1)))) else {
            return XCTFail("a sidecar that binds Phocasa's namespace to another prefix can't take its values")
        }
        XCTAssertEqual(try String(contentsOf: raw.xmpSidecarURL, encoding: .utf8), xmp)
        XCTAssertEqual(try listing(), ["PREFIX.ARW", "PREFIX.xmp"])

        // A rating write doesn't need the prefix.
        XCTAssertEqual(service.updateSidecar(of: raw, .init(rating: 5)), .written)
        XCTAssertEqual(try SidecarFixtures.properties(ofXMPAt: raw.xmpSidecarURL)["ph:Other"]?.hasSuffix("=x"), true)
    }

    // MARK: - Write safety and minimal writes

    func testWriteThatChangesNothingLeavesTheSidecarUntouched() throws {
        let raw = try makeRAW("SAME.ARW", sidecar: SidecarFixtures.lightroom)
        let before = try Data(contentsOf: raw.xmpSidecarURL)

        service.writeMetadata(rating: 2, keywords: ["landscape", "time:golden hour"], toImageAt: raw.path)
        service.clearEditParameters(forRAWAt: raw.path)

        XCTAssertEqual(try Data(contentsOf: raw.xmpSidecarURL), before,
                       "rewriting another app's sidecar with identical values would only reformat it")
    }

    func testClearingEditsWithoutASidecarCreatesNone() throws {
        let raw = try makeRAW("NONE.ARW", sidecar: nil)

        service.clearEditParameters(forRAWAt: raw.path)

        XCTAssertEqual(try listing(), ["NONE.ARW"])
    }

    func testEditWriteWithoutASidecarWritesOnlyTheEdits() throws {
        let raw = try makeRAW("EDIT.ARW", sidecar: nil)

        service.writeEditParameters(EditParameters(exposure: 1.25), forRAWAt: raw.path)

        let props = try SidecarFixtures.properties(ofXMPAt: raw.xmpSidecarURL)
        XCTAssertEqual(Set(props.keys).subtracting(["iio:hasXMP"]), ["phocasa:EditParameters"],
                       "an edit write doesn't invent a rating or keywords")
        XCTAssertEqual(service.readEditParameters(forRAWAt: raw.path)?.exposure, 1.25)

        // Clearing those edits again leaves a sidecar that can still be read and updated.
        service.clearEditParameters(forRAWAt: raw.path)
        XCTAssertNil(service.readEditParameters(forRAWAt: raw.path))
        service.writeMetadata(rating: 3, keywords: [], toImageAt: raw.path)
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 3)
    }

    func testReadOnlySidecarIsNotModified() throws {
        let raw = try makeRAW("LOCKED.ARW", sidecar: SidecarFixtures.lightroom)
        let before = try Data(contentsOf: raw.xmpSidecarURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: raw.xmpSidecarURL.path)

        service.writeMetadata(rating: 5, keywords: [], toImageAt: raw.path)

        XCTAssertEqual(try Data(contentsOf: raw.xmpSidecarURL), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: raw.xmpSidecarURL.path)[.posixPermissions] as? Int, 0o444)
        XCTAssertEqual(try listing(), ["LOCKED.ARW", "LOCKED.xmp"])
    }

    func testSymlinkedSidecarIsWrittenThroughAndStaysALink() throws {
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("shared.xmp")
        try Data(SidecarFixtures.lightroom.utf8).write(to: target)
        let raw = try makeRAW("LINK.ARW", sidecar: nil)
        try FileManager.default.createSymbolicLink(at: raw.xmpSidecarURL, withDestinationURL: target)

        service.writeMetadata(rating: 4, keywords: ["k"], toImageAt: raw.path)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: raw.xmpSidecarURL.path), target.path)
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 4)
        XCTAssertEqual(try SidecarFixtures.properties(ofXMPAt: target)["crs:Exposure2012"]?.hasSuffix("=+0.35"), true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["shared.xmp"])
    }

    func testUpdateKeepsTheSidecarCreationDateAndExtendedAttributes() throws {
        let raw = try makeRAW("DATES.ARW", sidecar: SidecarFixtures.lightroom)
        let past = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: raw.xmpSidecarURL.path)
        let set = raw.xmpSidecarURL.withUnsafeFileSystemRepresentation { setxattr($0!, "com.phocasa.test", "v", 1, 0, 0) }
        XCTAssertEqual(set, 0)

        service.writeMetadata(rating: 4, keywords: [], toImageAt: raw.path)

        let attrs = try FileManager.default.attributesOfItem(atPath: raw.xmpSidecarURL.path)
        XCTAssertEqual(try XCTUnwrap(attrs[.creationDate] as? Date).timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 1)
        let size = raw.xmpSidecarURL.withUnsafeFileSystemRepresentation { getxattr($0!, "com.phocasa.test", nil, 0, 0, 0) }
        XCTAssertEqual(size, 1)
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 4)
    }
}
