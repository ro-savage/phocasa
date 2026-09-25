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

    /// Phocasa's own XMP namespace. `phocasa:EditParameters` holds a RAW file's saved edits (base64 JSON).
    static let phocasaNamespace = "http://phocasa.app/ns/1.0/"

    // The fallback parser, for text ImageIO can't read as an XMP packet (fragments, damaged files).
    private static let ratingRegex = try! NSRegularExpression(
        pattern: #"xmp:Rating\s*=\s*["'](\d+)["']|<xmp:Rating>\s*(\d+)\s*</xmp:Rating>"#)
    private static let subjectRegex = try! NSRegularExpression(
        pattern: #"<dc:subject\b[^>]*>(.*?)</dc:subject>"#, options: [.dotMatchesLineSeparators])
    private static let liRegex = try! NSRegularExpression(pattern: #"<rdf:li>([^<]+)</rdf:li>"#)
    private static let editParamsRegex = try! NSRegularExpression(
        pattern: #"<phocasa:EditParameters>([^<]+)</phocasa:EditParameters>|phocasa:EditParameters\s*=\s*["']([^"']+)["']"#)

    private init() {}

    // MARK: - Reading

    struct PhotoMetadata: Sendable {
        var rating: Int
        var keywords: [String]
        var editParameters: EditParameters?
        /// When the photo was taken (EXIF `DateTimeOriginal`, see `CaptureDate`), or nil if the file has none.
        var captureDate: Date?
        /// Whether ImageIO read the file as an image, so a nil `captureDate` means the file has none, rather than
        /// that it couldn't be read (missing, empty, not an image).
        var captureDateChecked = false
    }

    /// Reads the rating and keywords embedded in the file, then lets its `.xmp` sidecar override them.
    ///
    /// The sidecar is `<stem>.xmp`, so for a JPG+RAW pair `x.jpg` also reads `x.xmp`, the RAW's sidecar.
    /// A sidecar rating wins only when it is non-zero, and sidecar keywords only when there are some.
    /// The capture date comes from the image file only (see `CaptureDate`).
    /// Stateless and thread-safe.
    func readMetadata(from path: String) -> PhotoMetadata {
        let url = URL(fileURLWithPath: path)
        var rating = 0
        var keywords: [String] = []
        var editParameters: EditParameters?
        var captureDate: Date?
        var captureDateChecked = false

        // Try reading from image file directly
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                // The rating lives in XMP (xmp:Rating), which is where writeToImageFile puts it.
                if let r = Self.xmpRating(in: meta) { rating = r }
                // ImageIO merges XMP and IPTC-IIM here, so dc:subject holds exactly the keywords the
                // IPTC properties dictionary reports (XMP wins when they disagree, in both views).
                // Reading only this is cheaper than also copying the properties dictionary.
                keywords = Self.xmpSubject(in: meta)
                captureDate = CaptureDate.date(in: meta)
                captureDateChecked = true
            } else if CaptureDate.isImage(source) {
                captureDateChecked = true
                if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                    if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any],
                       let iptcKeywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] {
                        keywords = iptcKeywords
                    }
                    captureDate = CaptureDate.date(inProperties: properties)
                }
            }
        }

        // The XMP sidecar (RAW files, and the RAW half of a pair). It is only parsed when it exists.
        if let sidecar = try? Data(contentsOf: url.xmpSidecarURL) {
            let parsed = Self.sidecarContents(sidecar)
            if parsed.rating > 0 { rating = parsed.rating }
            if !parsed.keywords.isEmpty { keywords = parsed.keywords }
            editParameters = parsed.editParameters
        }

        return PhotoMetadata(rating: rating, keywords: keywords, editParameters: editParameters,
                             captureDate: captureDate, captureDateChecked: captureDateChecked)
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

    private static func editParameters(in meta: CGImageMetadata) -> EditParameters? {
        guard let value = CGImageMetadataCopyStringValueWithPath(meta, nil, "phocasa:EditParameters" as CFString) else {
            return nil
        }
        return decodeEditParameters(value as String)
    }

    private static func decodeEditParameters(_ base64: String) -> EditParameters? {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? JSONDecoder().decode(EditParameters.self, from: data)
    }

    // MARK: - Writing

    /// Writes the rating and keywords back to the file: into the image itself for JPG and other
    /// standard formats, or into the `.xmp` sidecar for RAW files. The sidecar is updated in place:
    /// saved RAW edit parameters and everything other apps wrote there are kept.
    func writeMetadata(rating: Int, keywords: [String], toImageAt path: String) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if FolderScanner.rawExtensions.contains(ext) {
            updateSidecar(of: url, SidecarUpdate(rating: rating, keywords: keywords))
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
    ///
    /// For a JPEG, only the XMP and IPTC-IIM segments of ImageIO's output are used: they are spliced into the
    /// original bytes (`spliceJPEGMetadata`), because ImageIO's rewrite drops what it doesn't model, such as the
    /// camera's MakerNote and other APPn segments.
    private func writeToImageFile(rating: Int, keywords: [String], at url: URL) {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        guard fm.isWritableFile(atPath: target.path),
              let original = try? Data(contentsOf: target, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(original as CFData, nil) else { return }
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

        var bytes = output as Data
        if uti as String == UTType.jpeg.identifier,
           let spliced = Self.spliceJPEGMetadata(original: original, rewritten: bytes),
           Self.jpeg(spliced, readsBack: rating, keywords) {
            bytes = spliced
        }

        let originalDates = Phocasa.captureFileDates(target)
        guard Self.replace(target, exists: true, writingTempWith: { try bytes.write(to: $0, options: .withoutOverwriting) })
        else { return }
        Phocasa.restoreFileDates(target, dates: originalDates)
    }

    // MARK: - JPEG metadata splice

    private struct JPEGSegment {
        enum Kind { case xmp, extendedXMP, iptc, mpf, exif, other }
        let marker: UInt8
        let range: Range<Int>
        let kind: Kind
    }

    private static let jpegSegmentIDs: [(marker: UInt8, id: Data, kind: JPEGSegment.Kind)] = [
        (0xE1, Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8), .xmp),
        (0xE1, Data("http://ns.adobe.com/xmp/extension/\u{0}".utf8), .extendedXMP),
        (0xE1, Data("Exif\u{0}".utf8), .exif),
        (0xED, Data("Photoshop 3.0\u{0}".utf8), .iptc),
        (0xE2, Data("MPF\u{0}".utf8), .mpf),
    ]

    /// The marker segments between SOI and SOS, and where SOS starts. Nil for anything unusual (no SOI, fill
    /// bytes, standalone markers, a length that runs past the end): those files are left to ImageIO.
    private static func jpegHeader(_ d: Data) -> (segments: [JPEGSegment], sos: Int)? {
        let start = d.startIndex
        guard d.count >= 4, d[start] == 0xFF, d[start + 1] == 0xD8 else { return nil }
        var segments: [JPEGSegment] = []
        var i = start + 2
        while true {
            guard i + 4 <= d.endIndex, d[i] == 0xFF else { return nil }
            let marker = d[i + 1]
            if marker == 0xDA { return (segments, i) }
            guard marker != 0xFF, marker != 0x00, marker != 0x01, !(0xD0...0xD9).contains(marker) else { return nil }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            guard length >= 2, i + 2 + length <= d.endIndex else { return nil }
            let payload = d[(i + 4)..<(i + 2 + length)]
            let kind = jpegSegmentIDs.first { $0.marker == marker && payload.starts(with: $0.id) }?.kind ?? .other
            segments.append(JPEGSegment(marker: marker, range: i..<(i + 2 + length), kind: kind))
            i += 2 + length
        }
    }

    /// `original` with its XMP (APP1) and IPTC-IIM (APP13) segments replaced by those of `rewritten`, ImageIO's
    /// rewrite of the same file with the new metadata merged in. Every other byte of `original` is kept: Exif with
    /// the camera's MakerNote, MPF previews, ICC profiles, other APPn and COM segments, and the image data.
    ///
    /// The new XMP goes where the old one was, or after the JFIF and Exif segments; new IPTC goes where the old
    /// one was, or right after the XMP. Returns nil, so the caller keeps `rewritten`, when that can't be done
    /// safely: either file isn't plain marker segments up to SOS; `rewritten` hasn't exactly one XMP segment, or
    /// has extended XMP; `original` has several XMP or IPTC segments, or extended XMP; `original` has IPTC but
    /// `rewritten` doesn't; or a change would land after an MPF segment, whose image offsets count from it.
    static func spliceJPEGMetadata(original: Data, rewritten: Data) -> Data? {
        guard let (old, sos) = jpegHeader(original), let (new, _) = jpegHeader(rewritten) else { return nil }
        let newXMP = new.filter { $0.kind == .xmp }
        let newIPTC = new.filter { $0.kind == .iptc }
        guard newXMP.count == 1, newIPTC.count <= 1, !new.contains(where: { $0.kind == .extendedXMP }),
              old.filter({ $0.kind == .xmp }).count <= 1, old.filter({ $0.kind == .iptc }).count <= 1,
              !old.contains(where: { $0.kind == .extendedXMP }) else { return nil }

        let oldXMPIndex = old.firstIndex { $0.kind == .xmp }
        let oldIPTCIndex = old.firstIndex { $0.kind == .iptc }
        if oldIPTCIndex != nil && newIPTC.isEmpty { return nil }
        // Without an old XMP segment, the new one goes before this index: after the leading JFIF/Exif segments.
        let insertXMPAt = old.firstIndex { !($0.marker == 0xE0 || $0.kind == .exif) } ?? old.count

        if let mpf = old.firstIndex(where: { $0.kind == .mpf }) {
            let xmpSafe = oldXMPIndex.map { $0 < mpf } ?? (insertXMPAt <= mpf)
            let iptcSafe = oldIPTCIndex.map { $0 < mpf } ?? true
            guard xmpSafe, iptcSafe else { return nil }
        }

        let xmpBytes = rewritten[newXMP[0].range]
        let iptcBytes = newIPTC.first.map { rewritten[$0.range] }
        let newIPTCFollowsXMP = oldIPTCIndex == nil
        var out = Data(capacity: original.count + xmpBytes.count + (iptcBytes?.count ?? 0))
        out.append(contentsOf: [0xFF, 0xD8])
        func appendXMP() {
            out.append(xmpBytes)
            if newIPTCFollowsXMP, let iptcBytes { out.append(iptcBytes) }
        }
        for (index, segment) in old.enumerated() {
            if oldXMPIndex == nil && index == insertXMPAt { appendXMP() }
            switch segment.kind {
            case .xmp: appendXMP()
            case .iptc: if let iptcBytes { out.append(iptcBytes) }
            default: out.append(original[segment.range])
            }
        }
        if oldXMPIndex == nil && insertXMPAt == old.count { appendXMP() }
        out.append(original[sos...])
        return out
    }

    /// Whether ImageIO reads `spliced` as a complete image with this rating and these keywords: a check on the
    /// splice before it replaces anyone's photo. (Its frame and image data are the original's bytes, so the size
    /// needs no check; reading it would parse the whole Exif, MakerNote included, for about 1 ms.)
    private static func jpeg(_ spliced: Data, readsBack rating: Int, _ keywords: [String]) -> Bool {
        guard let source = CGImageSourceCreateWithData(spliced as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return false }
        return xmpRating(in: meta) == rating && xmpSubject(in: meta) == keywords
    }

    /// Writes a new version of `target` through a temp file in the same folder, then swaps it in.
    ///
    /// The temp file is hidden (so a concurrent scan skips it) and in the same folder (so the swap is a rename).
    /// An existing file is replaced with `replaceItemAt`, which keeps its permissions, extended attributes and
    /// creation date; a new one is moved into place, which fails rather than overwrite a file that appeared
    /// meanwhile. On any failure the temp file is removed and the original is untouched.
    private static func replace(_ target: URL, exists: Bool, writingTempWith write: (URL) throws -> Void) -> Bool {
        let fm = FileManager.default
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension.isEmpty ? "" : ".\(target.pathExtension)"
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).phocasa-tmp-\(UUID().uuidString)\(ext)")
        do {
            try write(tmp)
            if exists {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
    }

    /// Sets the rating, keywords and edit parameters in the `.xmp` sidecar of `imageURL`, keeping
    /// everything else in it (see `updateSidecar(of:_:)`).
    ///
    /// - Important: `editParameters: nil` (the default) **removes** saved RAW edits. To change only the
    ///   rating and keywords, use `writeMetadata(rating:keywords:toImageAt:)`, which keeps them.
    func writeSidecar(rating: Int, keywords: [String], for imageURL: URL, editParameters: EditParameters? = nil) {
        updateSidecar(of: imageURL, SidecarUpdate(rating: rating, keywords: keywords, editParameters: .set(editParameters)))
    }

    /// Saves RAW edit parameters to the sidecar. Only `phocasa:EditParameters` changes.
    func writeEditParameters(_ params: EditParameters, forRAWAt path: String) {
        updateSidecar(of: URL(fileURLWithPath: path), SidecarUpdate(editParameters: .set(params)))
    }

    /// Removes saved RAW edit parameters from the sidecar. Only `phocasa:EditParameters` changes, and a
    /// missing sidecar isn't created.
    func clearEditParameters(forRAWAt path: String) {
        updateSidecar(of: URL(fileURLWithPath: path), SidecarUpdate(editParameters: .set(nil)))
    }

    func readEditParameters(forRAWAt path: String) -> EditParameters? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path).xmpSidecarURL) else { return nil }
        return Self.sidecarContents(data).editParameters
    }

    // MARK: - Sidecar updates

    /// A change to Phocasa's fields in a sidecar. A `nil` field is left as it is.
    struct SidecarUpdate: Sendable {
        enum Edits: Sendable {
            case keep
            /// Saves these edits. `nil`, or parameters that are all defaults, remove them.
            case set(EditParameters?)
        }

        /// `xmp:Rating`.
        var rating: Int?
        /// `dc:subject`, replaced as a whole. An empty list removes it.
        var keywords: [String]?
        /// `phocasa:EditParameters`.
        var editParameters: Edits = .keep
    }

    enum SidecarWriteResult: Sendable, Equatable {
        /// The sidecar was created or updated.
        case written
        /// It already held these values, or there was nothing to write, so it wasn't touched.
        case unchanged
        /// It exists but isn't XMP that can be parsed safely, so it was left byte-identical.
        case skippedUnparseable
        /// It exists but isn't writable, so it was left alone.
        case skippedReadOnly
        /// The write failed. The sidecar, if there was one, is unchanged.
        case failed
    }

    /// Updates the `.xmp` sidecar of `imageURL` in place: only the fields in `update` change, and everything
    /// else in the sidecar (another app's develop settings, labels, other namespaces) is kept.
    ///
    /// - The sidecar is parsed with ImageIO, changed, and serialised again with ImageIO. ImageIO normalises
    ///   the layout: simple properties become elements, comments are dropped.
    /// - A missing sidecar is created, unless there is nothing to put in it.
    /// - A sidecar that isn't well-formed XML, or that ImageIO can't read as XMP, is **never** overwritten.
    /// - If nothing would change, the file isn't touched.
    /// - The new file replaces the old one atomically. Symlinks are written through; permissions, extended
    ///   attributes and the creation date are kept. The modification date advances, as it always has for
    ///   sidecars, so other apps can see that the metadata changed. Read-only sidecars are left alone.
    ///
    /// Stateless and thread-safe; callers serialise writes to one file (`MetadataWriter`).
    @discardableResult
    func updateSidecar(of imageURL: URL, _ update: SidecarUpdate) -> SidecarWriteResult {
        let fm = FileManager.default
        let sidecar = imageURL.xmpSidecarURL.resolvingSymlinksInPath()
        let exists = fm.fileExists(atPath: sidecar.path)

        let metadata: CGMutableImageMetadata
        if exists {
            guard fm.isWritableFile(atPath: sidecar.path) else { return .skippedReadOnly }
            guard let data = try? Data(contentsOf: sidecar) else { return .skippedUnparseable }
            switch Self.parseForUpdate(data) {
            case .xmp(let parsed): metadata = parsed
            case .empty: metadata = CGImageMetadataCreateMutable()
            case .unparseable: return .skippedUnparseable
            }
        } else {
            metadata = CGImageMetadataCreateMutable()
        }

        switch Self.apply(update, to: metadata) {
        case .failed: return .failed
        case .unchanged: return .unchanged
        case .changed: break
        }

        // A mutable copy with every property removed still serialises (to an empty packet); a new, empty
        // metadata object doesn't, and then there is nothing to write.
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) as Data? else { return exists ? .failed : .unchanged }
        let written = Self.replace(sidecar, exists: exists, writingTempWith: { try xmp.write(to: $0, options: .withoutOverwriting) })
        return written ? .written : .failed
    }

    private enum ParsedSidecar {
        case xmp(CGMutableImageMetadata)
        /// A well-formed packet with no properties in it (ImageIO can't parse those).
        case empty
        case unparseable
    }

    /// ImageIO's XMP parser is lenient: it accepts XML that isn't well-formed and quietly drops what it can't
    /// make sense of. Rewriting such a file could lose content, so an update also requires well-formed XML.
    private static func parseForUpdate(_ data: Data) -> ParsedSidecar {
        let check = XMPPacketCheck()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = check
        guard parser.parse() else { return .unparseable }
        if let meta = CGImageMetadataCreateFromXMPData(data as CFData),
           let mutable = CGImageMetadataCreateMutableCopy(meta) {
            return .xmp(mutable)
        }
        return check.hasProperties ? .unparseable : .empty
    }

    private enum ApplyResult { case changed, unchanged, failed }

    /// Sorted keys, so the same edits always serialise to the same bytes (JSONEncoder's default order varies).
    private static var editParametersEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static func apply(_ update: SidecarUpdate, to meta: CGMutableImageMetadata) -> ApplyResult {
        var changed = false

        if let rating = update.rating {
            let value = "\(rating)"
            if CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String? != value {
                guard CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, value as CFString) else {
                    return .failed
                }
                changed = true
            }
        }

        if let keywords = update.keywords {
            let path = "dc:subject" as CFString
            let hasSubject = CGImageMetadataCopyTagWithPath(meta, nil, path) != nil
            if keywords.isEmpty {
                if hasSubject {
                    guard CGImageMetadataRemoveTagWithPath(meta, nil, path) else { return .failed }
                    changed = true
                }
            } else if !hasSubject || xmpSubject(in: meta) != keywords {
                guard let tag = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString,
                                                         "dc" as CFString, "subject" as CFString,
                                                         .arrayUnordered, keywords as CFArray),
                      CGImageMetadataSetTagWithPath(meta, nil, path, tag) else { return .failed }
                changed = true
            }
        }

        if case .set(let params) = update.editParameters {
            let path = "phocasa:EditParameters" as CFString
            if let params, !params.isDefault {
                // Compared as values: the same edits can be stored as differently ordered JSON.
                let stored = (CGImageMetadataCopyStringValueWithPath(meta, nil, path) as String?).flatMap(decodeEditParameters)
                if stored != params {
                    guard let json = try? editParametersEncoder.encode(params) else { return .failed }
                    // Fails if the sidecar already uses another prefix for this namespace; then nothing is written.
                    guard CGImageMetadataRegisterNamespaceForPrefix(meta, phocasaNamespace as CFString,
                                                                    "phocasa" as CFString, nil),
                          CGImageMetadataSetValueWithPath(meta, nil, path, json.base64EncodedString() as CFString)
                    else { return .failed }
                    changed = true
                }
            } else if CGImageMetadataCopyTagWithPath(meta, nil, path) != nil {
                guard CGImageMetadataRemoveTagWithPath(meta, nil, path) else { return .failed }
                changed = true
            }
        }

        return changed ? .changed : .unchanged
    }

    // MARK: - XMP Parsing

    /// Phocasa's fields in a sidecar. A real XMP packet is read with ImageIO, which handles every
    /// serialisation (attributes or elements, any prefix layout) and reads keywords only from `dc:subject`.
    /// Anything else goes to a text fallback that accepts both forms.
    static func sidecarContents(_ data: Data) -> PhotoMetadata {
        if let meta = CGImageMetadataCreateFromXMPData(data as CFData) {
            return PhotoMetadata(rating: xmpRating(in: meta) ?? 0,
                                 keywords: xmpSubject(in: meta),
                                 editParameters: editParameters(in: meta))
        }
        guard let text = String(data: data, encoding: .utf8) else { return PhotoMetadata(rating: 0, keywords: []) }
        return fallbackContents(text)
    }

    /// For text that isn't a whole XMP packet: `xmp:Rating` as an attribute or an element, the `rdf:li` items
    /// of `dc:subject`, and `phocasa:EditParameters` as an element or an attribute.
    private static func fallbackContents(_ text: String) -> PhotoMetadata {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        func firstGroup(_ match: NSTextCheckingResult) -> String? {
            (1..<match.numberOfRanges).lazy.map { match.range(at: $0) }
                .first { $0.location != NSNotFound }.map(ns.substring(with:))
        }

        var rating = 0
        if let match = ratingRegex.firstMatch(in: text, range: all), let value = firstGroup(match).flatMap({ Int($0) }) {
            rating = (0...5).contains(value) ? value : 0
        }

        var keywords: [String] = []
        if let subject = subjectRegex.firstMatch(in: text, range: all) {
            keywords = liRegex.matches(in: text, range: subject.range(at: 1)).map {
                decodeXMLEntities(ns.substring(with: $0.range(at: 1)))
            }
        }

        let edits = editParamsRegex.firstMatch(in: text, range: all).flatMap(firstGroup).flatMap(decodeEditParameters)
        return PhotoMetadata(rating: rating, keywords: keywords, editParameters: edits)
    }

    private static func decodeXMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        return string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The rating and keywords (and edit parameters) in sidecar text. See `sidecarContents(_:)`.
    func parseXMPSidecar(_ content: String) -> PhotoMetadata {
        Self.sidecarContents(Data(content.utf8))
    }

    func parseEditParameters(from content: String) -> EditParameters? {
        Self.sidecarContents(Data(content.utf8)).editParameters
    }

    func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Checks that XML is well-formed and notes whether it holds any XMP property, for `updateSidecar`.
private final class XMPPacketCheck: NSObject, XMLParserDelegate {
    private(set) var hasProperties = false

    private static let structuralElements: Set<String> = ["x:xmpmeta", "x:xapmeta", "rdf:RDF", "rdf:Description"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard Self.structuralElements.contains(elementName) else {
            hasProperties = true
            return
        }
        if attributes.keys.contains(where: { !($0.hasPrefix("xmlns") || $0 == "rdf:about" || $0 == "x:xmptk") }) {
            hasProperties = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if string.contains(where: { !$0.isWhitespace }) { hasProperties = true }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        hasProperties = true
    }
}
