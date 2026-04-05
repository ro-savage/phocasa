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
        let uti = CGImageSourceGetType(source)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            uti ?? kUTTypeJPEG as CFString,
            CGImageSourceGetCount(source),
            nil
        ) else { return }

        // Build metadata to write
        var metadata: [String: Any] = [:]

        // Copy existing properties
        if let existingProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            metadata = existingProps
        }

        // Set IPTC keywords
        var iptc = metadata[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        iptc[kCGImagePropertyIPTCKeywords as String] = keywords
        metadata[kCGImagePropertyIPTCDictionary as String] = iptc

        // Set rating in TIFF dictionary
        var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff["Rating"] = rating
        metadata[kCGImagePropertyTIFFDictionary as String] = tiff

        for i in 0..<CGImageSourceGetCount(source) {
            if i == 0 {
                CGImageDestinationAddImageFromSource(destination, source, i, metadata as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, source, i, nil)
            }
        }

        CGImageDestinationFinalize(destination)
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
