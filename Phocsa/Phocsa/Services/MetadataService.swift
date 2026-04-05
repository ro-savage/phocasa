import Foundation
import ImageIO
import AppKit

final class MetadataService: @unchecked Sendable {
    static let shared = MetadataService()

    private init() {}

    // MARK: - Reading

    struct PhotoMetadata {
        var rating: Int
        var keywords: [String]
    }

    func readMetadata(from path: String) -> PhotoMetadata {
        let url = URL(fileURLWithPath: path)
        var rating = 0
        var keywords: [String] = []

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
        let sidecarURL = url.deletingPathExtension().appendingPathExtension("xmp")
        if let sidecarData = try? String(contentsOf: sidecarURL, encoding: .utf8) {
            let parsed = parseXMPSidecar(sidecarData)
            if parsed.rating > 0 { rating = parsed.rating }
            if !parsed.keywords.isEmpty { keywords = parsed.keywords }
        }

        return PhotoMetadata(rating: rating, keywords: keywords)
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
    }

    func writeSidecar(rating: Int, keywords: [String], for imageURL: URL) {
        let sidecarURL = imageURL.deletingPathExtension().appendingPathExtension("xmp")

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

        let xmp = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description
                    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                    xmlns:dc="http://purl.org/dc/elements/1.1/"
                    xmp:Rating="\(rating)">
        \(keywordsXML)
                </rdf:Description>
            </rdf:RDF>
        </x:xmpmeta>
        """

        try? xmp.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }

    // MARK: - XMP Parsing

    private func parseXMPSidecar(_ content: String) -> PhotoMetadata {
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
        let liPattern = #"<rdf:li>([^<]+)</rdf:li>"#
        if let regex = try? NSRegularExpression(pattern: liPattern) {
            let nsContent = content as NSString
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            keywords = matches.compactMap { match in
                if match.numberOfRanges > 1 {
                    return nsContent.substring(with: match.range(at: 1))
                }
                return nil
            }
        }

        return PhotoMetadata(rating: rating, keywords: keywords)
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
