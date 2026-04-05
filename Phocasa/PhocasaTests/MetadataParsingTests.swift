import XCTest
@testable import Phocasa

final class MetadataParsingTests: XCTestCase {

    private let service = MetadataService.shared

    // MARK: - XMP Rating Parsing

    func testParseXMPRating() {
        let xmp = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description
                    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                    xmp:Rating="4">
                </rdf:Description>
            </rdf:RDF>
        </x:xmpmeta>
        """
        let result = service.parseXMPSidecar(xmp)
        XCTAssertEqual(result.rating, 4)
        XCTAssertTrue(result.keywords.isEmpty)
    }

    func testParseXMPRatingZero() {
        let xmp = """
        <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="0">
        </rdf:Description>
        """
        let result = service.parseXMPSidecar(xmp)
        XCTAssertEqual(result.rating, 0)
    }

    func testParseXMPNoRating() {
        let xmp = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/">
                </rdf:Description>
            </rdf:RDF>
        </x:xmpmeta>
        """
        let result = service.parseXMPSidecar(xmp)
        XCTAssertEqual(result.rating, 0)
        XCTAssertTrue(result.keywords.isEmpty)
    }

    // MARK: - XMP Keyword Parsing

    func testParseXMPKeywords() {
        let xmp = """
        <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"
                         xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                         xmp:Rating="3">
            <dc:subject>
                <rdf:Bag>
                    <rdf:li>landscape</rdf:li>
                    <rdf:li>time:golden hour</rdf:li>
                    <rdf:li>location:beach</rdf:li>
                </rdf:Bag>
            </dc:subject>
        </rdf:Description>
        """
        let result = service.parseXMPSidecar(xmp)
        XCTAssertEqual(result.rating, 3)
        XCTAssertEqual(result.keywords, ["landscape", "time:golden hour", "location:beach"])
    }

    func testParseXMPEmptyKeywords() {
        let xmp = """
        <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"
                         xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                         xmp:Rating="1">
            <dc:subject>
                <rdf:Bag>
                </rdf:Bag>
            </dc:subject>
        </rdf:Description>
        """
        let result = service.parseXMPSidecar(xmp)
        XCTAssertEqual(result.rating, 1)
        XCTAssertTrue(result.keywords.isEmpty)
    }

    // MARK: - Edit Parameters Parsing

    func testParseEditParameters() throws {
        var params = EditParameters()
        params.exposure = 1.5
        params.contrast = 20
        params.saturation = -10
        let data = try JSONEncoder().encode(params)
        let base64 = data.base64EncodedString()

        let xmp = "<phocasa:EditParameters>\(base64)</phocasa:EditParameters>"

        let result = service.parseEditParameters(from: xmp)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.exposure, 1.5)
        XCTAssertEqual(result?.contrast, 20)
        XCTAssertEqual(result?.saturation, -10)
    }

    func testParseEditParametersWithWhitespace() throws {
        var params = EditParameters()
        params.brightness = 50
        let data = try JSONEncoder().encode(params)
        let base64 = data.base64EncodedString()

        let xmp = "<phocasa:EditParameters>\n  \(base64)  \n</phocasa:EditParameters>"

        let result = service.parseEditParameters(from: xmp)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.brightness, 50)
    }

    func testParseEditParametersNotPresent() {
        let xmp = "no edit parameters here"
        let result = service.parseEditParameters(from: xmp)
        XCTAssertNil(result)
    }

    func testParseEditParametersInvalidBase64() {
        let xmp = "<phocasa:EditParameters>not-valid-base64!!!</phocasa:EditParameters>"
        let result = service.parseEditParameters(from: xmp)
        XCTAssertNil(result)
    }

    func testParseEditParametersInvalidJSON() {
        let base64 = Data("not json".utf8).base64EncodedString()
        let xmp = "<phocasa:EditParameters>\(base64)</phocasa:EditParameters>"
        let result = service.parseEditParameters(from: xmp)
        XCTAssertNil(result)
    }

    // MARK: - XML Escaping

    func testEscapeXMLPlainText() {
        XCTAssertEqual(service.escapeXML("hello world"), "hello world")
    }

    func testEscapeXMLAmpersand() {
        XCTAssertEqual(service.escapeXML("a&b"), "a&amp;b")
    }

    func testEscapeXMLAngleBrackets() {
        XCTAssertEqual(service.escapeXML("<tag>"), "&lt;tag&gt;")
    }

    func testEscapeXMLQuotes() {
        XCTAssertEqual(service.escapeXML("a\"b"), "a&quot;b")
    }

    func testEscapeXMLMultipleSpecialChars() {
        XCTAssertEqual(service.escapeXML("a&<>\"b"), "a&amp;&lt;&gt;&quot;b")
    }

    func testEscapeXMLEmpty() {
        XCTAssertEqual(service.escapeXML(""), "")
    }

    // MARK: - Full Sidecar Write/Read Roundtrip

    func testSidecarWriteReadRoundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeRAW = tempDir.appendingPathComponent("test.cr2")
        try Data("fake raw".utf8).write(to: fakeRAW)

        // Write sidecar
        service.writeSidecar(
            rating: 4,
            keywords: ["landscape", "time:sunset"],
            for: fakeRAW
        )

        // Read it back
        let sidecarURL = tempDir.appendingPathComponent("test.xmp")
        let content = try String(contentsOf: sidecarURL, encoding: .utf8)

        let parsed = service.parseXMPSidecar(content)
        XCTAssertEqual(parsed.rating, 4)
        XCTAssertEqual(parsed.keywords, ["landscape", "time:sunset"])
    }

    func testEditParametersWriteReadRoundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeRAW = tempDir.appendingPathComponent("test.cr2")
        try Data("fake raw".utf8).write(to: fakeRAW)

        var params = EditParameters()
        params.exposure = 1.5
        params.highlights = -30
        params.saturation = 20

        service.writeEditParameters(params, forRAWAt: fakeRAW.path)

        let readBack = service.readEditParameters(forRAWAt: fakeRAW.path)
        XCTAssertNotNil(readBack)
        XCTAssertEqual(readBack?.exposure, 1.5)
        XCTAssertEqual(readBack?.highlights, -30)
        XCTAssertEqual(readBack?.saturation, 20)
    }
}
