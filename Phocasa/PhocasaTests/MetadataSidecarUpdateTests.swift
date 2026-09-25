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

    // MARK: - Fixtures

    private static func base64(_ params: EditParameters) -> String {
        (try? JSONEncoder().encode(params))?.base64EncodedString() ?? ""
    }

    /// Byte for byte what Phocasa wrote before task 23 (`writeSidecarToURL`'s template), with edits.
    static func oldPhocasaSidecar(rating: Int, keywords: [String], edits: EditParameters?) -> String {
        let keywordsXML = keywords.isEmpty ? "" : """
                <dc:subject>
                    <rdf:Bag>
        \(keywords.map { "                        <rdf:li>\($0)</rdf:li>" }.joined(separator: "\n"))
                    </rdf:Bag>
                </dc:subject>
        """
        let editsXML = edits.map { "            <phocasa:EditParameters>\(base64($0))</phocasa:EditParameters>" } ?? ""
        let ns = edits == nil ? "" : "\n                xmlns:phocasa=\"http://phocasa.app/ns/1.0/\""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description
                    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                    xmlns:dc="http://purl.org/dc/elements/1.1/"\(ns)
                    xmp:Rating="\(rating)">
        \(keywordsXML)
        \(editsXML)
                </rdf:Description>
            </rdf:RDF>
        </x:xmpmeta>
        """
    }

    /// A sidecar in the style Lightroom Classic writes: simple properties as attributes, develop settings (`crs:`),
    /// hierarchical keywords, a tone curve and history (arrays of `rdf:li` that are not keywords), a language
    /// alternative, and an unrelated namespace.
    static let lightroomSidecar = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
        xmlns:stEvt="http://ns.adobe.com/xap/1.0/sType/ResourceEvent#"
        xmlns:acme="http://example.com/acme/1.0/"
       xmp:ModifyDate="2024-05-01T10:00:00+01:00"
       xmp:Rating="2"
       xmp:Label="Red"
       tiff:Make="SONY"
       crs:Version="16.0"
       crs:ProcessVersion="11.0"
       crs:WhiteBalance="As Shot"
       crs:Exposure2012="+0.35"
       crs:Contrast2012="+12"
       crs:HasSettings="True"
       acme:Flag="keep-me">
       <dc:subject>
        <rdf:Bag>
         <rdf:li>landscape</rdf:li>
         <rdf:li>time:golden hour</rdf:li>
        </rdf:Bag>
       </dc:subject>
       <dc:rights>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">(c) Someone</rdf:li>
        </rdf:Alt>
       </dc:rights>
       <lr:hierarchicalSubject>
        <rdf:Bag>
         <rdf:li>places|beach</rdf:li>
        </rdf:Bag>
       </lr:hierarchicalSubject>
       <crs:ToneCurvePV2012>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012>
       <crs:Look>
        <rdf:Description crs:Name="Adobe Color" crs:Amount="1">
         <crs:Parameters><rdf:Description crs:Version="16.0" crs:ProcessVersion="11.0"/></crs:Parameters>
        </rdf:Description>
       </crs:Look>
       <xmpMM:History>
        <rdf:Seq>
         <rdf:li stEvt:action="saved" stEvt:softwareAgent="Adobe Lightroom"/>
        </rdf:Seq>
       </xmpMM:History>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """

    /// A sidecar serialised by ImageIO (`CGImageMetadataCreateXMPData`), which writes simple properties as
    /// elements (`<xmp:Rating>4</xmp:Rating>`), with Phocasa's edits and two unrelated properties.
    static func imageIOSidecar() throws -> String {
        let meta = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(meta, "http://phocasa.app/ns/1.0/" as CFString,
                                                                "phocasa" as CFString, nil))
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(meta, "http://example.com/acme/1.0/" as CFString,
                                                                "acme" as CFString, nil))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "4" as CFString))
        let subject = try XCTUnwrap(CGImageMetadataTagCreate(
            "http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString, "subject" as CFString,
            .arrayUnordered, ["people:ann", "a & b"] as CFArray))
        XCTAssertTrue(CGImageMetadataSetTagWithPath(meta, nil, "dc:subject" as CFString, subject))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "phocasa:EditParameters" as CFString,
                                                      base64(EditParameters(exposure: -0.5)) as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "acme:Flag" as CFString, "keep-me" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "photoshop:City" as CFString, "Lisbon" as CFString))
        let data = try XCTUnwrap(CGImageMetadataCreateXMPData(meta, nil))
        let xmp = try XCTUnwrap(String(data: data as Data, encoding: .utf8))
        XCTAssertTrue(xmp.contains("<xmp:Rating>4</xmp:Rating>"), "the fixture must use the element form")
        return xmp
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

    /// Every property in an XMP file as ImageIO sees it: path → type and (for leaves) value.
    static func properties(ofXMPAt url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let meta = try XCTUnwrap(CGImageMetadataCreateFromXMPData(data as CFData), "ImageIO must parse \(url.lastPathComponent)")
        var result: [String: String] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            let ns = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            let type = CGImageMetadataTagGetType(tag).rawValue
            let value = (CGImageMetadataTagCopyValue(tag) as? String).map { "=\($0)" } ?? ""
            result[path as String] = "\(ns) type=\(type)\(value)"
            return true
        }
        return result
    }

    /// The properties Phocasa doesn't own.
    static func unrelated(_ properties: [String: String]) -> [String: String] {
        properties.filter { key, _ in
            !(key == "xmp:Rating" || key.hasPrefix("dc:subject") || key.hasPrefix("phocasa:"))
        }
    }

    private func assertSidecar(_ raw: URL, rating: Int, keywords: [String], exposure: Double?,
                               unrelated expected: [String: String], _ step: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let read = service.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, rating, "\(step): rating", file: file, line: line)
        XCTAssertEqual(read.keywords, keywords, "\(step): keywords", file: file, line: line)
        XCTAssertEqual(service.readEditParameters(forRAWAt: raw.path)?.exposure, exposure, "\(step): edits", file: file, line: line)
        XCTAssertEqual(read.editParameters?.exposure, exposure, "\(step): readMetadata's edits", file: file, line: line)
        let now = Self.unrelated(try Self.properties(ofXMPAt: raw.xmpSidecarURL))
        XCTAssertEqual(now, expected, "\(step): every unrelated property must survive", file: file, line: line)
        XCTAssertEqual(try listing(), [raw.lastPathComponent, raw.xmpSidecarURL.lastPathComponent].sorted(),
                       "\(step): no temp files may be left", file: file, line: line)
    }

    /// Rating write, keyword write, edit write, clear, and `writeSidecar`: each keeps everything unrelated.
    private func runWriteSequence(sidecar: String, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let raw = try makeRAW(name, sidecar: sidecar)
        let unrelated = Self.unrelated(try Self.properties(ofXMPAt: raw.xmpSidecarURL))
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
        let old = Self.oldPhocasaSidecar(rating: 3, keywords: ["people:ann", "beach"], edits: EditParameters(exposure: 1.5))
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
        try runWriteSequence(sidecar: Self.lightroomSidecar, name: "LR_1.ARW")

        // Spot-check a few values by name, as a reader would.
        let props = try Self.properties(ofXMPAt: dir.appendingPathComponent("LR_1.xmp"))
        XCTAssertEqual(props["crs:Exposure2012"]?.hasSuffix("=+0.35"), true)
        XCTAssertEqual(props["crs:ToneCurvePV2012[1]"]?.hasSuffix("=255, 255"), true)
        XCTAssertEqual(props["crs:Look.Parameters.Version"]?.hasSuffix("=16.0"), true)
        XCTAssertEqual(props["lr:hierarchicalSubject[0]"]?.hasSuffix("=places|beach"), true)
        XCTAssertEqual(props["acme:Flag"]?.hasSuffix("=keep-me"), true)
        XCTAssertEqual(props["xmpMM:History[0].softwareAgent"]?.hasSuffix("=Adobe Lightroom"), true)
    }

    func testImageIOWrittenSidecarIsReadAndUpdatedInPlace() throws {
        let raw = try makeRAW("IIO_1.ARW", sidecar: try Self.imageIOSidecar())
        let read = service.readMetadata(from: raw.path)
        XCTAssertEqual(read.rating, 4, "xmp:Rating written as an element must be read")
        XCTAssertEqual(read.keywords, ["people:ann", "a & b"])
        XCTAssertEqual(read.editParameters?.exposure, -0.5)
        XCTAssertEqual(service.readEditParameters(forRAWAt: raw.path)?.exposure, -0.5)
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.removeItem(at: raw.xmpSidecarURL)

        try runWriteSequence(sidecar: try Self.imageIOSidecar(), name: "IIO_2.ARW")
    }

    // MARK: - Reading every format

    func testLightroomSidecarKeywordsComeOnlyFromDCSubject() throws {
        let raw = try makeRAW("LR_2.NEF", sidecar: Self.lightroomSidecar)

        let read = service.readMetadata(from: raw.path)

        XCTAssertEqual(read.keywords, ["landscape", "time:golden hour"],
                       "tone-curve points, hierarchical keywords and rights are not keywords")
        XCTAssertEqual(read.rating, 2)
        XCTAssertEqual(service.parseXMPSidecar(Self.lightroomSidecar).keywords, ["landscape", "time:golden hour"])
    }

    func testParsersAcceptTheElementForm() throws {
        let xmp = try Self.imageIOSidecar()
        XCTAssertEqual(service.parseXMPSidecar(xmp).rating, 4)
        XCTAssertEqual(service.parseXMPSidecar(xmp).keywords, ["people:ann", "a & b"])
        XCTAssertEqual(service.parseEditParameters(from: xmp)?.exposure, -0.5)
    }

    func testParsersAcceptTheAttributeFormOfEditParameters() {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:phocasa="http://phocasa.app/ns/1.0/"
          xmp:Rating="2" phocasa:EditParameters="\(Self.base64(EditParameters(contrast: 30)))"/>
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
            ("truncated", Data(lightroomSidecar.prefix(900).utf8)),
            // ImageIO's parser is lenient and would accept this; it isn't well-formed XML.
            ("mismatched", Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="4"><xmp:Foo>unclosed</rdf:Description>
            </rdf:RDF></x:xmpmeta>
            """.utf8)),
            ("utf16", lightroomSidecar.data(using: .utf16)!),
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

        let locked = try makeRAW("RO.ARW", sidecar: Self.lightroomSidecar)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.xmpSidecarURL.path)
        XCTAssertEqual(service.updateSidecar(of: locked, update), .skippedReadOnly)

        let fresh = try makeRAW("NEW.ARW", sidecar: nil)
        XCTAssertEqual(service.updateSidecar(of: fresh, update), .written)
        XCTAssertEqual(service.updateSidecar(of: fresh, update), .unchanged, "the same values again change nothing")
        XCTAssertEqual(service.updateSidecar(of: try makeRAW("NONE.ARW", sidecar: nil),
                                             .init(editParameters: .set(nil))), .unchanged)
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

        XCTAssertEqual(service.updateSidecar(of: raw, .init(editParameters: .set(EditParameters(exposure: 1)))), .failed)
        XCTAssertEqual(try String(contentsOf: raw.xmpSidecarURL, encoding: .utf8), xmp)
        XCTAssertEqual(try listing(), ["PREFIX.ARW", "PREFIX.xmp"])

        // A rating write doesn't need the prefix.
        XCTAssertEqual(service.updateSidecar(of: raw, .init(rating: 5)), .written)
        XCTAssertEqual(try Self.properties(ofXMPAt: raw.xmpSidecarURL)["ph:Other"]?.hasSuffix("=x"), true)
    }

    // MARK: - Write safety and minimal writes

    func testWriteThatChangesNothingLeavesTheSidecarUntouched() throws {
        let raw = try makeRAW("SAME.ARW", sidecar: Self.lightroomSidecar)
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

        let props = try Self.properties(ofXMPAt: raw.xmpSidecarURL)
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
        let raw = try makeRAW("LOCKED.ARW", sidecar: Self.lightroomSidecar)
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
        try Data(Self.lightroomSidecar.utf8).write(to: target)
        let raw = try makeRAW("LINK.ARW", sidecar: nil)
        try FileManager.default.createSymbolicLink(at: raw.xmpSidecarURL, withDestinationURL: target)

        service.writeMetadata(rating: 4, keywords: ["k"], toImageAt: raw.path)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: raw.xmpSidecarURL.path), target.path)
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 4)
        XCTAssertEqual(try Self.properties(ofXMPAt: target)["crs:Exposure2012"]?.hasSuffix("=+0.35"), true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["shared.xmp"])
    }

    func testUpdateKeepsTheSidecarCreationDateAndExtendedAttributes() throws {
        let raw = try makeRAW("DATES.ARW", sidecar: Self.lightroomSidecar)
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
