import XCTest
import ImageIO
@testable import Phocasa

/// XMP sidecar fixtures and ImageIO helpers shared by the metadata tests (task 23).
enum SidecarFixtures {

    static func base64(_ params: EditParameters) -> String {
        (try? JSONEncoder().encode(params))?.base64EncodedString() ?? ""
    }

    /// Byte for byte what Phocasa wrote before task 23 (`writeSidecarToURL`'s template), with edits.
    static func oldPhocasa(rating: Int, keywords: [String], edits: EditParameters?) -> String {
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
    static let lightroom = """
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
    static func imageIO() throws -> String {
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
}
