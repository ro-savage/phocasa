import Foundation
import ImageIO
import AppKit

// MARK: - File Date Preservation

func captureFileDates(_ url: URL) -> (creation: Date?, modification: Date?)? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    guard let attrs else { return nil }
    return (attrs[.creationDate] as? Date, attrs[.modificationDate] as? Date)
}

func restoreFileDates(_ url: URL, dates: (creation: Date?, modification: Date?)?) {
    guard let dates else { return }
    var attrs: [FileAttributeKey: Any] = [:]
    if let creation = dates.creation { attrs[.creationDate] = creation }
    if let modification = dates.modification { attrs[.modificationDate] = modification }
    if !attrs.isEmpty {
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }
}

// MARK: - URL Extensions

extension URL {
    var xmpSidecarURL: URL {
        deletingPathExtension().appendingPathExtension("xmp")
    }
}

final class MetadataService: Sendable {
    static let shared = MetadataService()

    private static let liRegex = try! NSRegularExpression(pattern: #"<rdf:li>([^<]+)</rdf:li>"#)
    private static let editParamsRegex = try! NSRegularExpression(pattern: #"<phocasa:EditParameters>([^<]+)</phocasa:EditParameters>"#)

    private init() {}

    // MARK: - Reading

    struct PhotoMetadata {
        var rating: Int
        var keywords: [String]
        var editParameters: EditParameters?
    }

    func readMetadata(from path: String) -> PhotoMetadata {
        let url = URL(fileURLWithPath: path)
        var rating = 0
        var keywords: [String] = []
        var editParameters: EditParameters?

        // Try reading from image file directly
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {

            // Read IPTC keywords
            if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any],
               let iptcKeywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] {
                keywords = iptcKeywords
            }

            // Read XMP rating (stored in TIFF metadata sometimes)
            if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
               let ratingValue = tiff["Rating"] as? Int {
                rating = ratingValue
            }
        }

        // Try XMP sidecar for RAW files
        let sidecarURL = url.xmpSidecarURL
        if let sidecarData = try? String(contentsOf: sidecarURL, encoding: .utf8) {
            let parsed = parseXMPSidecar(sidecarData)
            if parsed.rating > 0 { rating = parsed.rating }
            if !parsed.keywords.isEmpty { keywords = parsed.keywords }
            editParameters = parseEditParameters(from: sidecarData)
        }

        return PhotoMetadata(rating: rating, keywords: keywords, editParameters: editParameters)
    }

    // MARK: - Writing

    func writeMetadata(rating: Int, keywords: [String], toImageAt path: String) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if FolderScanner.rawExtensions.contains(ext) {
            writeSidecar(rating: rating, keywords: keywords, for: url)
        } else {
            writeToImageFile(rating: rating, keywords: keywords, at: url)
        }
    }

    private func writeToImageFile(rating: Int, keywords: [String], at url: URL) {
        let originalDates = Phocasa.captureFileDates(url)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let uti = CGImageSourceGetType(source) ?? (kUTTypeJPEG as CFString)

        // Use CGImageDestinationCopyImageSource for lossless metadata-only write
        // (patches metadata in-place without re-encoding image data)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 0, nil) else { return }

        let metadata = CGImageMetadataCreateMutable()

        // Keywords as dc:subject (ImageIO syncs to IPTC Keywords automatically)
        if let tag = CGImageMetadataTagCreate(
            "http://purl.org/dc/elements/1.1/" as CFString,
            "dc" as CFString,
            "subject" as CFString,
            .arrayUnordered,
            keywords as CFTypeRef
        ) {
            CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag)
        }

        // Rating as xmp:Rating (syncs to TIFF Rating)
        if let tag = CGImageMetadataTagCreate(
            "http://ns.adobe.com/xap/1.0/" as CFString,
            "xmp" as CFString,
            "Rating" as CFString,
            .default,
            "\(rating)" as CFTypeRef
        ) {
            CGImageMetadataSetTagWithPath(metadata, nil, "xmp:Rating" as CFString, tag)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true
        ]

        var error: Unmanaged<CFError>?
        CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)

        Phocasa.restoreFileDates(url, dates: originalDates)
    }

    func writeSidecar(rating: Int, keywords: [String], for imageURL: URL, editParameters: EditParameters? = nil) {
        writeSidecarToURL(imageURL.xmpSidecarURL, rating: rating, keywords: keywords, editParameters: editParameters)
    }

    func writeEditParameters(_ params: EditParameters, forRAWAt path: String) {
        let url = URL(fileURLWithPath: path)
        let existing = readMetadata(from: path)
        writeSidecarToURL(url.xmpSidecarURL, rating: existing.rating, keywords: existing.keywords, editParameters: params)
    }

    func readEditParameters(forRAWAt path: String) -> EditParameters? {
        let sidecarURL = URL(fileURLWithPath: path).xmpSidecarURL
        guard let content = try? String(contentsOf: sidecarURL, encoding: .utf8) else { return nil }
        return parseEditParameters(from: content)
    }

    private func writeSidecarToURL(_ sidecarURL: URL, rating: Int, keywords: [String], editParameters: EditParameters?) {
        var keywordsXML = ""
        if !keywords.isEmpty {
            keywordsXML = """
                    <dc:subject>
                        <rdf:Bag>
            \(keywords.map { "                        <rdf:li>\(escapeXML($0))</rdf:li>" }.joined(separator: "\n"))
                        </rdf:Bag>
                    </dc:subject>
            """
        }

        var editParamsXML = ""
        if let params = editParameters, !params.isDefault,
           let jsonData = try? JSONEncoder().encode(params) {
            let base64 = jsonData.base64EncodedString()
            editParamsXML = "            <phocasa:EditParameters>\(base64)</phocasa:EditParameters>"
        }

        let phocasa_ns = editParamsXML.isEmpty ? "" : "\n                xmlns:phocasa=\"http://phocasa.app/ns/1.0/\""

        let xmp = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description
                    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                    xmlns:dc="http://purl.org/dc/elements/1.1/"\(phocasa_ns)
                    xmp:Rating="\(rating)">
        \(keywordsXML)
        \(editParamsXML)
                </rdf:Description>
            </rdf:RDF>
        </x:xmpmeta>
        """

        try? xmp.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }

    // MARK: - XMP Parsing

    func parseXMPSidecar(_ content: String) -> PhotoMetadata {
        var rating = 0
        var keywords: [String] = []

        // Parse rating from xmp:Rating="N"
        if let ratingRange = content.range(of: #"xmp:Rating="(\d+)""#, options: .regularExpression) {
            let match = content[ratingRange]
            if let digitRange = match.range(of: #"\d+"#, options: .regularExpression) {
                rating = Int(match[digitRange]) ?? 0
            }
        }

        // Parse keywords from rdf:li elements within dc:subject
        let nsContent = content as NSString
        let matches = Self.liRegex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        keywords = matches.compactMap { match in
            match.numberOfRanges > 1 ? nsContent.substring(with: match.range(at: 1)) : nil
        }

        return PhotoMetadata(rating: rating, keywords: keywords)
    }

    func parseEditParameters(from content: String) -> EditParameters? {
        guard let match = Self.editParamsRegex.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        let base64String = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: base64String) else { return nil }
        return try? JSONDecoder().decode(EditParameters.self, from: data)
    }

    func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
