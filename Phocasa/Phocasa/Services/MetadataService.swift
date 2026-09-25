import Foundation
import ImageIO
import AppKit
import UniformTypeIdentifiers

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

    struct PhotoMetadata: Sendable {
        var rating: Int
        var keywords: [String]
        var editParameters: EditParameters?
    }

    /// Reads the rating and keywords embedded in the file, then lets its `.xmp` sidecar override them.
    ///
    /// The sidecar is `<stem>.xmp`, so for a JPG+RAW pair `x.jpg` also reads `x.xmp`, the RAW's sidecar.
    /// A sidecar rating wins only when it is non-zero, and sidecar keywords only when there are some.
    func readMetadata(from path: String) -> PhotoMetadata {
        let url = URL(fileURLWithPath: path)
        var rating = 0
        var keywords: [String] = []
        var editParameters: EditParameters?

        // Try reading from image file directly
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            // IPTC keywords. ImageIO fills these from XMP dc:subject too.
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
               let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any],
               let iptcKeywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] {
                keywords = iptcKeywords
            }

            // The rating lives in XMP (xmp:Rating), which is where writeToImageFile puts it.
            if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                if let r = Self.xmpRating(in: meta) { rating = r }
                if keywords.isEmpty { keywords = Self.xmpSubject(in: meta) }
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

    /// `xmp:Rating` as a star count. Values outside 0...5 (Adobe's -1 means "rejected") read as unrated.
    private static func xmpRating(in meta: CGImageMetadata) -> Int? {
        guard let value = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?,
              let r = Int(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (0...5).contains(r) ? r : 0
    }

    /// `dc:subject`, an XMP array whose elements are tags holding one string each.
    private static func xmpSubject(in meta: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString),
              let elements = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return [] }
        return elements.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    // MARK: - Writing

    /// Writes the rating and keywords back to the file: into the image itself for JPG and other
    /// standard formats, or into the `.xmp` sidecar for RAW files. Saved RAW edit parameters in the
    /// sidecar are kept.
    func writeMetadata(rating: Int, keywords: [String], toImageAt path: String) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if FolderScanner.rawExtensions.contains(ext) {
            // writeSidecar treats nil as "clear", so pass the saved edits through explicitly.
            writeSidecar(rating: rating, keywords: keywords, for: url,
                         editParameters: readEditParameters(forRAWAt: path))
        } else {
            writeToImageFile(rating: rating, keywords: keywords, at: url)
        }
    }

    /// Rewrites the image with new XMP rating and keywords, without re-encoding the image data.
    ///
    /// The new file is built in memory and only replaces the original once it is complete:
    /// if ImageIO can't copy the source, nothing on disk changes and no temp file is left.
    /// Symlinks are written through (the link stays a link). Permissions, extended attributes and
    /// file dates are kept. Read-only files are left alone.
    private func writeToImageFile(rating: Int, keywords: [String], at url: URL) {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        guard fm.isWritableFile(atPath: target.path),
              let source = CGImageSourceCreateWithURL(target as CFURL, nil) else { return }
        let uti = CGImageSourceGetType(source) ?? (UTType.jpeg.identifier as CFString)

        // A data destination, not a URL one: ImageIO leaves its own temp file behind when a
        // URL destination fails.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, uti, 0, nil) else { return }

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

        // Lossless: copies the image data as is and merges in the new metadata.
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { return }

        let originalDates = Phocasa.captureFileDates(target)
        // Same folder (so the replace is a rename), hidden (so a concurrent scan skips it).
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension.isEmpty ? "" : ".\(target.pathExtension)"
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).phocasa-tmp-\(UUID().uuidString)\(ext)")
        do {
            try output.write(to: tmp, options: .withoutOverwriting)
            // Keeps the original's permissions, extended attributes and creation date.
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            return
        }
        Phocasa.restoreFileDates(target, dates: originalDates)
    }

    /// Rewrites the `.xmp` sidecar of `imageURL` with exactly these values.
    ///
    /// - Important: `editParameters: nil` (the default) writes a sidecar **without** edit parameters,
    ///   which clears any saved RAW edits. To change only the rating and keywords, use
    ///   `writeMetadata(rating:keywords:toImageAt:)`, which keeps them.
    func writeSidecar(rating: Int, keywords: [String], for imageURL: URL, editParameters: EditParameters? = nil) {
        writeSidecarToURL(imageURL.xmpSidecarURL, rating: rating, keywords: keywords, editParameters: editParameters)
    }

    /// Saves RAW edit parameters to the sidecar, keeping its rating and keywords.
    func writeEditParameters(_ params: EditParameters, forRAWAt path: String) {
        let url = URL(fileURLWithPath: path)
        let existing = readMetadata(from: path)
        writeSidecarToURL(url.xmpSidecarURL, rating: existing.rating, keywords: existing.keywords, editParameters: params)
    }

    /// Removes saved RAW edit parameters from the sidecar, keeping its rating and keywords.
    func clearEditParameters(forRAWAt path: String) {
        let existing = readMetadata(from: path)
        writeSidecar(rating: existing.rating, keywords: existing.keywords,
                     for: URL(fileURLWithPath: path), editParameters: nil)
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
