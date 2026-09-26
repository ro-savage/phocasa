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
    }

    /// Reads the rating and keywords embedded in the file, then lets its `.xmp` sidecar override them.
    ///
    /// The sidecar is `<stem>.xmp`, so for a JPG+RAW pair `x.jpg` also reads `x.xmp`, the RAW's sidecar.
    /// A sidecar rating wins only when it is non-zero, and sidecar keywords only when there are some, unless the
    /// sidecar says it overrides the file (`phocasa:OverridesEmbedded`, written when the values couldn't go into the
    /// file itself): then its rating and keywords win as they are, 0 and none included.
    /// The capture date comes from the image file only (see `CaptureDate`).
    /// Stateless and thread-safe.
    func readMetadata(from path: String) -> PhotoMetadata {
        let url = URL(fileURLWithPath: path)
        var rating = 0
        var keywords: [String] = []
        var editParameters: EditParameters?
        var captureDate: Date?

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
            } else if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any],
                   let iptcKeywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] {
                    keywords = iptcKeywords
                }
                captureDate = CaptureDate.date(inProperties: properties)
            }
        }

        // The XMP sidecar (RAW files, the RAW half of a pair, and files whose rating and keywords couldn't be
        // written into them). It is only parsed when it exists.
        if let sidecar = try? Data(contentsOf: url.xmpSidecarURL) {
            let (parsed, overrides) = Self.sidecarFields(sidecar)
            if overrides {
                rating = parsed.rating
                keywords = parsed.keywords
            } else {
                if parsed.rating > 0 { rating = parsed.rating }
                if !parsed.keywords.isEmpty { keywords = parsed.keywords }
            }
            editParameters = parsed.editParameters
        }

        return PhotoMetadata(rating: rating, keywords: keywords, editParameters: editParameters,
                             captureDate: captureDate)
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

    /// Writes the rating and keywords back to the file: into a JPEG itself when that keeps everything else in it,
    /// otherwise into the `.xmp` sidecar (RAW files, other formats, JPEGs the splice can't handle). A sidecar is
    /// updated in place: saved RAW edit parameters and everything other apps wrote there are kept.
    func writeMetadata(rating: Int, keywords: [String], toImageAt path: String) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if FolderScanner.rawExtensions.contains(ext) {
            updateSidecar(of: url, SidecarUpdate(rating: rating, keywords: keywords))
        } else {
            writeToImageFile(rating: rating, keywords: keywords, at: url)
        }
    }

    /// Writes new XMP rating and keywords into a JPEG without re-encoding it or losing any of its metadata, or, when
    /// that can't be done, into its sidecar (the user's rule: never lose a photo's original metadata).
    ///
    /// - A JPEG gets `jpegWritingRatingAndKeywords`' bytes, which keep everything but the XMP and the IPTC keywords.
    ///   The new file is built in memory and only replaces the original once it is complete. Symlinks are written
    ///   through (the link stays a link). Permissions, extended attributes and file dates are kept.
    /// - Anything else (PNG, TIFF, HEIC, whose only writer is ImageIO's rewrite, which drops what it doesn't model), a
    ///   JPEG the splice refuses, and a file whose sidecar already overrides it keep their bytes. The rating and
    ///   keywords go to the sidecar, marked `phocasa:OverridesEmbedded` so they win on reading.
    /// - Read-only files, and files ImageIO doesn't read as an image, are left alone.
    private func writeToImageFile(rating: Int, keywords: [String], at url: URL) {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        guard fm.isWritableFile(atPath: target.path) else { return }
        // Something that isn't an image (empty, damaged) has no metadata to keep or to write into; it's left alone.
        guard let original = try? Data(contentsOf: target, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 else { return }
        guard !sidecarOverridesEmbedded(url),
              let bytes = Self.jpegWritingRatingAndKeywords(original, rating: rating, keywords: keywords) else {
            updateSidecar(of: url, SidecarUpdate(rating: rating, keywords: keywords, overridesEmbedded: true))
            return
        }

        let originalDates = Phocasa.captureFileDates(target)
        guard Self.replace(target, exists: true, writingTempWith: { try bytes.write(to: $0, options: .withoutOverwriting) })
        else { return }
        Phocasa.restoreFileDates(target, dates: originalDates)
    }

    /// Whether `imageURL`'s sidecar holds its rating and keywords in place of the file (`phocasa:OverridesEmbedded`).
    func sidecarOverridesEmbedded(_ imageURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: imageURL.xmpSidecarURL) else { return false }
        return Self.sidecarFields(data).overridesEmbedded
    }

    /// `original`, a JPEG, with this rating and these keywords, keeping every other byte of metadata; nil when that
    /// can't be done safely (then the values go to the sidecar).
    ///
    /// - The XMP: the last standard XMP segment (the one ImageIO and Adobe's XMP Toolkit read; any earlier ones stay
    ///   byte-identical) gets the new `xmp:Rating` and `dc:subject`, every other value unchanged (`xmpPacket`); a
    ///   file without one gets a new segment after its JFIF and Exif segments. Extended XMP stays byte-identical: its
    ///   GUID, the MD5 of the extension, doesn't change.
    /// - The IPTC keywords are patched into a single APP13 (`PhotoshopIRB`). When its IPTC text can't hold them
    ///   (non-ASCII keywords over text of unknown encoding), or the file has several APP13 segments (one resource
    ///   stream to ImageIO and Adobe, which a resource may span), every APP13 stays byte-identical and the keywords go
    ///   to the XMP only, where they win over the IIM while its digest matches or is missing (MWG 2.0 §4.2.3.2, which
    ///   ImageIO follows); no keywords are then an empty `dc:subject`, which also wins.
    /// - Both are spliced into the original bytes (`spliceJPEGMetadata`), MPF entries patched for the move.
    ///
    /// Nil (the last resort) when the header can't be parsed (bytes other than fill bytes between segments), when the
    /// XMP can't be updated safely or doesn't fit one segment, when the APP13 is malformed, when an MPF segment can't
    /// be patched, or when ImageIO doesn't read the result back with the new rating and keywords and every value it
    /// read before (an XMP segment after fill bytes or a standalone marker, which ImageIO's XMP reader stops at;
    /// extended XMP holding a rating or keywords, which wins over the standard packet; an IPTC digest that says the IIM
    /// is newer than the XMP).
    static func jpegWritingRatingAndKeywords(_ original: Data, rating: Int, keywords: [String]) -> Data? {
        guard JPEGStructure.isJPEG(original), let (segments, sos) = JPEGStructure.header(original),
              let iptc = iptcEdit(original, segments, keywords: keywords) else { return nil }
        let xmpIndex = segments.lastIndex { $0.kind == .xmp }
        let existing = xmpIndex.map { packetBytes(original, segments[$0]) }
        guard let update = updatedXMPPacket(rating: rating, keywords: keywords, updating: existing,
                                            emptyKeywords: iptc.xmpOnly ? .emptyBag : .leaveOut),
              let xmpBytes = JPEGStructure.xmpSegment(update.packet) else { return nil }
        var replacements = iptc.replacements
        var insertion: (index: Int, bytes: Data)?
        if let xmpIndex { replacements[xmpIndex] = xmpBytes } else { insertion = (xmpInsertionIndex(segments), xmpBytes) }
        guard let spliced = splice(original, segments, sos: sos, replacing: replacements, inserting: insertion),
              let meta = metadata(readBackFrom: spliced),
              xmpRating(in: meta) == rating, xmpSubject(in: meta) == keywords else { return nil }
        // A packet ImageIO couldn't parse on its own (`x:xapmeta`, a bare `rdf:RDF`) is checked through the file:
        // everything ImageIO read from the original, it reads from the new file.
        if !update.checkedByImageIO {
            guard let before = CGImageSourceCreateWithData(original as CFData, nil)
                    .flatMap({ CGImageSourceCopyMetadataAtIndex($0, 0, nil) }),
                  XMPProperties.keepsEverything(of: before, in: meta, changing: [XMPProperties.rating, XMPProperties.subject])
            else { return nil }
        }
        return spliced
    }

    /// An XMP packet with this rating and these keywords: `existing` with just `xmp:Rating` and `dc:subject` set and
    /// every other value kept, or a new packet. Nil when that can't be shown: see `updatedXMPPacket`. Format-neutral:
    /// the JPEG, PNG, TIFF and HEIC writers share it.
    static func xmpPacket(rating: Int, keywords: [String], updating existing: Data?) -> Data? {
        guard let update = updatedXMPPacket(rating: rating, keywords: keywords, updating: existing),
              update.checkedByImageIO else { return nil }
        return update.packet
    }

    struct UpdatedXMPPacket {
        let packet: Data
        /// Whether ImageIO parsed the new packet on its own and read the new values and every other value from it.
        /// When false (ImageIO's XMP parser rejects the packet's wrapper, `x:xapmeta` or a bare `rdf:RDF`, which its
        /// file readers accept) the caller must read the written file back.
        let checkedByImageIO: Bool
    }

    /// `existing` with this rating and these keywords, by the technique that changes the fewest bytes:
    /// 1. no packet: a new one, from ImageIO;
    /// 2. a text edit (`XMPTextEdit`): the values changed where they are, or added in an `rdf:Description` of their
    ///    own, every other byte kept (padding apart), checked by an independent reading of the XML and, when it can
    ///    parse the packet, by ImageIO;
    /// 3. else ImageIO's rewrite of the packet (`xmp:Rating` and `dc:subject` set on its model), accepted only when
    ///    both ImageIO and the independent reading of the XML (`XMPPacketScan`) find every other value in it:
    ///    ImageIO's model alone leaves out what it drops (empty values, `rdf:nodeID` and `parseType="Literal"`
    ///    properties, datatypes, renamed aliases, content after an XML error). (ImageIO's JPEG rewrite would also
    ///    mirror the Exif into the XMP, overwriting values that disagree with it, such as another app's
    ///    `xmp:CreatorTool`.)
    ///
    /// Nil when none of those can be shown to keep everything: XML that isn't well-formed, a DTD, a text edit it
    /// can't place (a rating or keywords in a form it doesn't edit in place, descriptions about different resources)
    /// together with a rewrite that would lose or change a value.
    static func updatedXMPPacket(rating: Int, keywords: [String], updating existing: Data?,
                                 emptyKeywords: XMPTextEdit.EmptyKeywords = .leaveOut) -> UpdatedXMPPacket? {
        guard let existing else {
            let meta = CGImageMetadataCreateMutable()
            guard setRating(rating, keywords: keywords, emptyKeywords: emptyKeywords, in: meta),
                  let packet = CGImageMetadataCreateXMPData(meta, nil) as Data? else { return nil }
            return UpdatedXMPPacket(packet: packet, checkedByImageIO: true)
        }
        let original = CGImageMetadataCreateFromXMPData(existing as CFData)
        // Some writers (ImageIO's JPEG writer among them) end the packet with NUL bytes; they're kept as they are.
        let body = existing.prefix(existing.count - existing.reversed().prefix { $0 == 0 }.count)
        if let edited = XMPTextEdit.setting(rating: rating, keywords: keywords, emptyKeywords: emptyKeywords, in: Data(body))
            .map({ $0 + existing[body.endIndex...] }) {
            guard let original else { return UpdatedXMPPacket(packet: edited, checkedByImageIO: false) }
            if let reparsed = CGImageMetadataCreateFromXMPData(edited as CFData),
               xmpRating(in: reparsed) == rating, xmpSubject(in: reparsed) == keywords,
               XMPProperties.keepsEverything(of: original, in: reparsed, changing: [XMPProperties.rating, XMPProperties.subject]) {
                return UpdatedXMPPacket(packet: edited, checkedByImageIO: true)
            }
        }
        guard let original, let before = XMPPacketScan(Data(body)),
              let meta = CGImageMetadataCreateMutableCopy(original),
              setRating(rating, keywords: keywords, emptyKeywords: emptyKeywords, in: meta),
              let packet = CGImageMetadataCreateXMPData(meta, nil) as Data?,
              let reparsed = CGImageMetadataCreateFromXMPData(packet as CFData),
              XMPProperties.keepsEverything(of: original, in: reparsed, changing: [XMPProperties.rating, XMPProperties.subject]),
              let after = XMPPacketScan(packet), before.isKept(in: after) else { return nil }
        return UpdatedXMPPacket(packet: packet, checkedByImageIO: true)
    }

    /// Sets `xmp:Rating` and `dc:subject` on ImageIO's model of a packet.
    private static func setRating(_ rating: Int, keywords: [String], emptyKeywords: XMPTextEdit.EmptyKeywords,
                                  in meta: CGMutableImageMetadata) -> Bool {
        guard CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "\(rating)" as CFString) else { return false }
        if keywords.isEmpty && emptyKeywords == .leaveOut {
            if CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString) != nil {
                return CGImageMetadataRemoveTagWithPath(meta, nil, "dc:subject" as CFString)
            }
            return true
        }
        guard let tag = CGImageMetadataTagCreate(XMPNamespace.dc as CFString, "dc" as CFString,
                                                 "subject" as CFString, .arrayUnordered, keywords as CFArray) else { return false }
        return CGImageMetadataSetTagWithPath(meta, nil, "dc:subject" as CFString, tag)
    }

    // MARK: - JPEG metadata splice

    /// `original` with its XMP replaced by `xmp` (the last standard XMP segment, or a new one after the JFIF and Exif
    /// segments) and the IPTC keywords in its Photoshop APP13 replaced by `keywords`. Every other byte of `original` is
    /// kept: Exif with the camera's MakerNote, MPF previews, ICC profiles, extended XMP, other APPn and COM segments,
    /// fill bytes, every other Photoshop resource and IPTC dataset, and the image data; the MPF entries' sizes and
    /// offsets follow the header's new size (`MPFIndex`). (ImageIO's own rewrite drops the MakerNote, and the
    /// resources and datasets it doesn't model.)
    ///
    /// A file without APP13 gets none: its keywords are in the XMP. When the APP13's IPTC text can't hold the keywords,
    /// or there are several APP13 segments, every APP13 is kept as it is. Returns nil, so the caller keeps the
    /// original, when that can't be done safely: the header isn't marker segments, fill bytes and standalone markers
    /// up to SOS; `xmp` doesn't fit one segment; the APP13 is malformed; or an MPF segment can't be patched.
    static func spliceJPEGMetadata(original: Data, xmp: Data, keywords: [String]) -> Data? {
        guard let (segments, sos) = JPEGStructure.header(original),
              let iptc = iptcEdit(original, segments, keywords: keywords),
              let xmpBytes = JPEGStructure.xmpSegment(xmp) else { return nil }
        var replacements = iptc.replacements
        var insertion: (index: Int, bytes: Data)?
        if let xmpIndex = segments.lastIndex(where: { $0.kind == .xmp }) {
            replacements[xmpIndex] = xmpBytes
        } else {
            insertion = (xmpInsertionIndex(segments), xmpBytes)
        }
        return splice(original, segments, sos: sos, replacing: replacements, inserting: insertion)
    }

    /// What a keyword write does to the APP13 segments: the patched segment, or none when the keywords go to the XMP
    /// only (`xmpOnly`). Nil for an APP13 that can't be parsed.
    private static func iptcEdit(_ original: Data, _ segments: [JPEGStructure.Segment],
                                 keywords: [String]) -> (replacements: [Int: Data], xmpOnly: Bool)? {
        let indices = segments.indices.filter { segments[$0].kind == .iptc }
        guard indices.count == 1, let index = indices.first else { return ([:], indices.count > 1) }
        switch PhotoshopIRB.keywordPatch(in: original[segments[index].payload], with: keywords) {
        case .patched(let payload):
            guard let segment = JPEGStructure.segment(0xED, payload: payload) else { return nil }
            return ([index: segment], false)
        case .noIPTC: return ([:], false)
        case .cantHold: return ([:], true)
        case .malformed: return nil
        }
    }

    private static func packetBytes(_ original: Data, _ segment: JPEGStructure.Segment) -> Data {
        Data(original[(segment.payload.lowerBound + JPEGStructure.xmpID.count)..<segment.payload.upperBound])
    }

    /// Where a new XMP segment goes: after the leading JFIF (APP0) and Exif segments (and not after fill bytes that
    /// follow them, which ImageIO's XMP reader stops at), or first.
    static func xmpInsertionIndex(_ segments: [JPEGStructure.Segment]) -> Int {
        let leading = segments.prefix { $0.marker == 0xE0 || $0.kind == .exif || !$0.hasPayload }
        return leading.lastIndex { $0.marker == 0xE0 || $0.kind == .exif }.map { $0 + 1 } ?? segments.startIndex
    }

    /// The header rebuilt with these segments replaced and one inserted (before the segment at `index`, or at the end),
    /// every other segment's bytes kept, each MPF segment's entries patched for the header's new size, then the
    /// original from SOS on. Nil when an MPF segment can't be patched.
    private static func splice(_ original: Data, _ segments: [JPEGStructure.Segment], sos: Int,
                               replacing replacements: [Int: Data], inserting insertion: (index: Int, bytes: Data)?) -> Data? {
        func change(_ index: Int) -> Int { replacements[index].map { $0.count - segments[index].range.count } ?? 0 }
        let growth = segments.indices.reduce(insertion?.bytes.count ?? 0) { $0 + change($1) }
        var out = Data(capacity: original.count + max(0, growth))
        out.append(contentsOf: [0xFF, 0xD8])
        for (index, segment) in segments.enumerated() {
            if let insertion, insertion.index == index { out.append(insertion.bytes) }
            if let replacement = replacements[index] {
                out.append(replacement)
            } else if segment.kind == .mpf {
                // The images after the primary move by what changes after this segment.
                let shift = segments.indices.filter { $0 > index }.reduce(0) { $0 + change($1) }
                    + ((insertion.map { $0.index > index } ?? false) ? insertion?.bytes.count ?? 0 : 0)
                if growth == 0 && shift == 0 {
                    out.append(original[segment.range])
                } else {
                    guard let patched = MPFIndex.patched(original, segment: segment.range, sos: sos, growth: growth,
                                                         shift: shift) else { return nil }
                    out.append(patched)
                }
            } else {
                out.append(original[segment.range])
            }
        }
        if let insertion, insertion.index >= segments.count { out.append(insertion.bytes) }
        out.append(original[sos...])
        return out
    }

    /// What ImageIO reads from `spliced`, when it reads it as a complete image: a check on the splice before it
    /// replaces anyone's photo. (Its frame and image data are the original's bytes, so the size needs no check;
    /// reading it would parse the whole Exif, MakerNote included, for about 1 ms.)
    private static func metadata(readBackFrom spliced: Data) -> CGImageMetadata? {
        guard let source = CGImageSourceCreateWithData(spliced as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        return CGImageSourceCopyMetadataAtIndex(source, 0, nil)
    }

    /// Writes a new version of `target` through a temp file in the same folder, then swaps it in.
    ///
    /// The temp file is hidden (so a concurrent scan skips it) and in the same folder (so the swap is a rename).
    /// An existing file is replaced with `replaceItemAt`, which keeps its permissions, extended attributes and
    /// creation date; a new one is moved into place, which fails rather than overwrite a file that appeared
    /// meanwhile. On any failure the temp file is removed and the original is untouched.
    static func replace(_ target: URL, exists: Bool, writingTempWith write: (URL) throws -> Void) -> Bool {
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
        /// `phocasa:OverridesEmbedded`: the rating and keywords here replace the ones in the image file, because they
        /// couldn't be written into it without losing its other metadata.
        var overridesEmbedded: Bool?

        init(rating: Int? = nil, keywords: [String]? = nil, editParameters: Edits = .keep,
             overridesEmbedded: Bool? = nil) {
            self.rating = rating
            self.keywords = keywords
            self.editParameters = editParameters
            self.overridesEmbedded = overridesEmbedded
        }
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
        var original: CGImageMetadata?
        if exists {
            guard fm.isWritableFile(atPath: sidecar.path) else { return .skippedReadOnly }
            guard let data = try? Data(contentsOf: sidecar) else { return .skippedUnparseable }
            switch Self.parseForUpdate(data) {
            case .xmp(let parsed):
                metadata = parsed
                original = CGImageMetadataCreateMutableCopy(parsed)
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
        // Everything else in the sidecar must come back from the serialised packet. (ImageIO can't parse a packet
        // with no properties left; that's fine when there was nothing else to keep.)
        if let original {
            guard XMPProperties.keepsEverything(of: original, in: CGImageMetadataCreateFromXMPData(xmp as CFData),
                                                changing: Self.phocasaSidecarProperties)
            else { return .failed }
        }
        let written = Self.replace(sidecar, exists: exists, writingTempWith: { try xmp.write(to: $0, options: .withoutOverwriting) })
        return written ? .written : .failed
    }

    /// The sidecar properties Phocasa writes.
    private static let phocasaSidecarProperties: Set<XMPProperties.Property> = [
        XMPProperties.rating, XMPProperties.subject,
        XMPProperties.Property(namespace: phocasaNamespace, prefix: "phocasa", name: "EditParameters"),
        XMPProperties.Property(namespace: phocasaNamespace, prefix: "phocasa", name: "OverridesEmbedded"),
    ]

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

        if let overrides = update.overridesEmbedded {
            let path = overridesEmbeddedPath as CFString
            let stored = CGImageMetadataCopyStringValueWithPath(meta, nil, path) as String?
            if overrides, stored != "True" {
                guard CGImageMetadataRegisterNamespaceForPrefix(meta, phocasaNamespace as CFString, "phocasa" as CFString, nil),
                      CGImageMetadataSetValueWithPath(meta, nil, path, "True" as CFString) else { return .failed }
                changed = true
            } else if !overrides, stored != nil {
                guard CGImageMetadataRemoveTagWithPath(meta, nil, path) else { return .failed }
                changed = true
            }
        }

        return changed ? .changed : .unchanged
    }

    private static let overridesEmbeddedPath = "phocasa:OverridesEmbedded"

    // MARK: - XMP Parsing

    /// `sidecarContents`, and whether the sidecar overrides the file's own rating and keywords
    /// (`phocasa:OverridesEmbedded`; only a real XMP packet can say so).
    static func sidecarFields(_ data: Data) -> (contents: PhotoMetadata, overridesEmbedded: Bool) {
        guard let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return (sidecarContents(data), false) }
        let overrides = CGImageMetadataCopyStringValueWithPath(meta, nil, overridesEmbeddedPath as CFString) as String? == "True"
        return (PhotoMetadata(rating: xmpRating(in: meta) ?? 0, keywords: xmpSubject(in: meta),
                              editParameters: editParameters(in: meta)), overrides)
    }

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
