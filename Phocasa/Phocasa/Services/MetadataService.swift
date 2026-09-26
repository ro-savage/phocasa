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
    /// - A sidecar that says it overrides the file (`phocasa:OverridesEmbedded`, written when the values couldn't go
    ///   into the file itself) wins as it is: its rating and keywords, 0 and none included.
    /// - A non-RAW file on its own (no RAW beside it) that holds an `xmp:Rating` is read from the file: its values are
    ///   the newest. Phocasa keeps such a file's sidecar in step with it, so a difference means another app changed the
    ///   file since, or the sidecar is left over (task D).
    /// - Otherwise (a RAW, a pair's JPG, a file without a rating of its own) a sidecar rating wins when it is non-zero,
    ///   and sidecar keywords when there are some.
    ///
    /// `pairedWithRAW` says whether `path` is a pair's JPG (the scanner knows); nil looks for a RAW beside it, only when
    /// that matters. The capture date comes from the image file only (see `CaptureDate`).
    /// Stateless and thread-safe.
    func readMetadata(from path: String, pairedWithRAW: Bool? = nil) -> PhotoMetadata {
        let url = URL(fileURLWithPath: path)
        var rating = 0
        var keywords: [String] = []
        var editParameters: EditParameters?
        var captureDate: Date?
        var fileHasRating = false

        // Try reading from image file directly
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                // The rating lives in XMP (xmp:Rating), which is where writeToImageFile puts it.
                if let r = Self.xmpRating(in: meta) {
                    rating = r
                    fileHasRating = true
                }
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
            } else if fileHasRating, !FolderScanner.rawExtensions.contains(url.pathExtension.lowercased()),
                      !(pairedWithRAW ?? Self.hasRAWBeside(url)) {
                // A file on its own that holds its own values: they stand.
            } else {
                if parsed.rating > 0 { rating = parsed.rating }
                if !parsed.keywords.isEmpty { keywords = parsed.keywords }
            }
            editParameters = parsed.editParameters
        }

        return PhotoMetadata(rating: rating, keywords: keywords, editParameters: editParameters,
                             captureDate: captureDate)
    }

    /// Whether a RAW file with `url`'s stem is in its folder (so `url` is a pair's JPG, and its sidecar the RAW's).
    /// Up to two lookups per RAW extension; only asked when a file on its own and a sidecar disagree.
    static func hasRAWBeside(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension()
        let fm = FileManager.default
        return FolderScanner.rawExtensions.contains { ext in
            fm.fileExists(atPath: stem.appendingPathExtension(ext).path)
                || fm.fileExists(atPath: stem.appendingPathExtension(ext.uppercased()).path)
        }
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

    /// Writes the rating and keywords into the file itself, adding them without re-encoding it or losing any of its
    /// metadata, or, when that can't be done, into its sidecar (the user's rules: never lose a photo's original
    /// metadata; ratings inside every non-RAW file, so other apps can read them).
    ///
    /// - The new file is `fileWritingRatingAndKeywords`' bytes, built in memory; it only replaces the original once it
    ///   is complete. Symlinks are written through (the link stays a link). Permissions, extended attributes and file
    ///   dates are kept.
    /// - A file that already has a sidecar keeps it, in step: the same rating and keywords, and no
    ///   `phocasa:OverridesEmbedded` (task D: files leave sidecar mode on their next write). A file leaving sidecar
    ///   mode gets its sidecar's values updated before the file is written and the flag cleared after, so a reader
    ///   never sees an older value win; if its sidecar can't be updated, neither is written.
    /// - The last resort, a file that can't take the values without losing something, keeps its bytes, and they go to
    ///   its sidecar, marked `phocasa:OverridesEmbedded` so they win on reading.
    /// - Read-only files, and files ImageIO doesn't read as an image, are left alone.
    private func writeToImageFile(rating: Int, keywords: [String], at url: URL) {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        guard fm.isWritableFile(atPath: target.path) else { return }
        // Something that isn't an image (empty, damaged) has no metadata to keep or to write into; it's left alone.
        guard let original = try? Data(contentsOf: target, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 else { return }
        let values = SidecarUpdate(rating: rating, keywords: keywords)
        guard let bytes = Self.fileWritingRatingAndKeywords(original, rating: rating, keywords: keywords) else {
            updateSidecar(of: url, SidecarUpdate(rating: rating, keywords: keywords, overridesEmbedded: true))
            return
        }

        let sidecar = sidecarState(url)
        if sidecar == .overridesFile {
            // Leaving sidecar mode: the sidecar takes the new values first, still overriding the file, so they win
            // whether or not the file write below succeeds.
            guard [.written, .unchanged].contains(updateSidecar(of: url, values)) else { return }
        }
        if bytes != original {
            let originalDates = Phocasa.captureFileDates(target)
            guard Self.replace(target, exists: true, writingTempWith: { try bytes.write(to: $0, options: .withoutOverwriting) })
            else { return }
            Phocasa.restoreFileDates(target, dates: originalDates)
        }
        if sidecar != .none {
            // In step with the file: the same values, no longer overriding it.
            updateSidecar(of: url, SidecarUpdate(rating: rating, keywords: keywords, overridesEmbedded: false))
        }
    }

    /// `original` with this rating and these keywords inside it, keeping every other byte of metadata, by its format
    /// (detected from its bytes, not its name); nil when it can't take them that way (the last resort, a sidecar).
    static func fileWritingRatingAndKeywords(_ original: Data, rating: Int, keywords: [String]) -> Data? {
        if JPEGStructure.isJPEG(original) {
            return jpegWritingRatingAndKeywords(original, rating: rating, keywords: keywords)
        }
        let packet = { (existing: Data?) in xmpPacket(rating: rating, keywords: keywords, updating: existing) }
        let written: Data?
        if PNGMetadata.isPNG(original) {
            // ImageIO calls a cut-short PNG complete, so the output's chunks are walked again, CRCs included.
            written = PNGMetadata.replacingXMP(in: original, update: packet)
                .flatMap { (try? PNGMetadata.walk($0).get()) != nil ? $0 : nil }
        } else if TIFFMetadata.isTIFF(original) {
            // Checks its own output: every original byte outside the parts it may change, and IFD0's other entries.
            written = TIFFMetadata.replacingXMP(in: original, update: packet, keywords: keywords)
        } else {
            return nil
        }
        guard let written, image(written, keepsEverythingIn: original, reading: rating, keywords) else { return nil }
        return written
    }

    /// Whether ImageIO reads `written` as a complete image with this rating and these keywords, and with every property
    /// `original` has, at the same value, apart from the ones that are Phocasa's (IPTC keywords and star rating): a check
    /// on a container edit before it replaces anyone's photo. (ImageIO's view may gain keys, e.g. IPTC fields it
    /// derives from the Exif once a file has XMP.)
    static func image(_ written: Data, keepsEverythingIn original: Data, reading rating: Int,
                              _ keywords: [String]) -> Bool {
        guard let source = CGImageSourceCreateWithData(written as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              xmpRating(in: meta) == rating, xmpSubject(in: meta) == keywords,
              let after = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let before = CGImageSourceCreateWithData(original as CFData, nil)
                .flatMap({ CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }) else { return false }
        let phocasas: Set<String> = [kCGImagePropertyIPTCKeywords as String, kCGImagePropertyIPTCStarRating as String]
        for (key, value) in before {
            guard let now = after[key] else { return false }
            if key == kCGImagePropertyIPTCDictionary as String,
               let old = value as? [String: Any], let new = now as? [String: Any] {
                for (field, oldValue) in old where !phocasas.contains(field) {
                    guard let newValue = new[field], (oldValue as AnyObject).isEqual(newValue) else { return false }
                }
            } else if !(value as AnyObject).isEqual(now) {
                return false
            }
        }
        return CGImageSourceGetCount(source) == CGImageSourceCreateWithData(original as CFData, nil).map(CGImageSourceGetCount)
    }

    private enum SidecarState { case none, inStep, overridesFile }

    private func sidecarState(_ imageURL: URL) -> SidecarState {
        guard let data = try? Data(contentsOf: imageURL.xmpSidecarURL) else { return .none }
        return Self.sidecarFields(data).overridesEmbedded ? .overridesFile : .inStep
    }

    /// Whether `imageURL`'s sidecar holds its rating and keywords in place of the file (`phocasa:OverridesEmbedded`).
    func sidecarOverridesEmbedded(_ imageURL: URL) -> Bool {
        sidecarState(imageURL) == .overridesFile
    }

    /// `original`, a JPEG, with this rating and these keywords, keeping every other byte of metadata; nil when that
    /// can't be done safely (then the values go to the sidecar).
    ///
    /// Its XMP packet gets the new `xmp:Rating` and `dc:subject`, every other value unchanged (`xmpPacket`); the IPTC
    /// keywords are patched into its APP13 (`PhotoshopIRB`); both are spliced into the original bytes
    /// (`spliceJPEGMetadata`). Nil when the splice refuses the layout, when the XMP can't be updated safely, or when
    /// the result doesn't read back with the new rating and keywords.
    static func jpegWritingRatingAndKeywords(_ original: Data, rating: Int, keywords: [String]) -> Data? {
        guard JPEGStructure.isJPEG(original), let (segments, _) = JPEGStructure.header(original) else { return nil }
        let existing = segments.filter { $0.kind == .xmp }
        guard existing.count <= 1 else { return nil }
        let existingPacket = existing.first.map {
            Data(original[($0.payload.lowerBound + JPEGStructure.xmpID.count)..<$0.payload.upperBound])
        }
        guard let packet = xmpPacket(rating: rating, keywords: keywords, updating: existingPacket),
              let spliced = spliceJPEGMetadata(original: original, xmp: packet, keywords: keywords),
              jpeg(spliced, readsBack: rating, keywords) else { return nil }
        return spliced
    }

    /// An XMP packet with this rating and these keywords: `existing` with just `xmp:Rating` and `dc:subject` set and
    /// every other value kept, or a new packet. Nil when `existing` can't be parsed, or its serialisation would lose
    /// or change any other value. (ImageIO's JPEG rewrite would also mirror the Exif into the XMP, overwriting values
    /// that disagree with it, such as another app's `xmp:CreatorTool`.)
    static func xmpPacket(rating: Int, keywords: [String], updating existing: Data?) -> Data? {
        let original = existing.flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
        if existing != nil && original == nil { return nil }
        let meta = original.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        guard CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, "\(rating)" as CFString) else { return nil }
        if keywords.isEmpty {
            if CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString) != nil {
                guard CGImageMetadataRemoveTagWithPath(meta, nil, "dc:subject" as CFString) else { return nil }
            }
        } else {
            guard let tag = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString,
                                                     "subject" as CFString, .arrayUnordered, keywords as CFArray),
                  CGImageMetadataSetTagWithPath(meta, nil, "dc:subject" as CFString, tag) else { return nil }
        }
        guard let packet = CGImageMetadataCreateXMPData(meta, nil) as Data? else { return nil }
        if let original {
            guard let reparsed = CGImageMetadataCreateFromXMPData(packet as CFData),
                  XMPProperties.keepsEverything(of: original, in: reparsed,
                                                changing: [XMPProperties.rating, XMPProperties.subject]) else { return nil }
        }
        return packet
    }

    // MARK: - JPEG metadata splice

    /// `original` with its XMP (APP1) segment replaced by one holding `xmp`, and the IPTC keywords in its Photoshop
    /// APP13 segment replaced by `keywords`. Every other byte of `original` is kept: Exif with the camera's MakerNote,
    /// MPF previews, ICC profiles, other APPn and COM segments, every other Photoshop resource and IPTC dataset, and
    /// the image data. (ImageIO's own rewrite drops the MakerNote, and the resources and datasets it doesn't model.)
    ///
    /// The new XMP goes where the old one was, or after the JFIF and Exif segments. A file without APP13 gets none:
    /// its keywords are in the XMP. Returns nil, so the caller keeps the original, when that can't be done safely:
    /// the file isn't plain marker segments up to SOS; it has several XMP or APP13 segments, or extended XMP; `xmp`
    /// doesn't fit one segment; the APP13 can't be patched (`PhotoshopIRB.replacingKeywords`); or a change would land
    /// after an MPF segment, whose image offsets count from it.
    static func spliceJPEGMetadata(original: Data, xmp: Data, keywords: [String]) -> Data? {
        guard let (old, sos) = JPEGStructure.header(original),
              old.filter({ $0.kind == .xmp }).count <= 1, old.filter({ $0.kind == .iptc }).count <= 1,
              !old.contains(where: { $0.kind == .extendedXMP }),
              let xmpBytes = JPEGStructure.segment(0xE1, payload: JPEGStructure.xmpID + xmp) else { return nil }

        let oldXMPIndex = old.firstIndex { $0.kind == .xmp }
        let oldIPTCIndex = old.firstIndex { $0.kind == .iptc }
        // Without an old XMP segment, the new one goes before this index: after the leading JFIF/Exif segments.
        let insertXMPAt = old.firstIndex { !($0.marker == 0xE0 || $0.kind == .exif) } ?? old.count

        if let mpf = old.firstIndex(where: { $0.kind == .mpf }) {
            let xmpSafe = oldXMPIndex.map { $0 < mpf } ?? (insertXMPAt <= mpf)
            let iptcSafe = oldIPTCIndex.map { $0 < mpf } ?? true
            guard xmpSafe, iptcSafe else { return nil }
        }

        var iptcBytes: Data?
        if let oldIPTCIndex {
            guard let payload = PhotoshopIRB.replacingKeywords(in: original[old[oldIPTCIndex].payload], with: keywords),
                  let segment = JPEGStructure.segment(0xED, payload: payload) else { return nil }
            iptcBytes = segment
        }
        var out = Data(capacity: original.count + xmpBytes.count)
        out.append(contentsOf: [0xFF, 0xD8])
        for (index, segment) in old.enumerated() {
            if oldXMPIndex == nil && index == insertXMPAt { out.append(xmpBytes) }
            switch segment.kind {
            case .xmp: out.append(xmpBytes)
            case .iptc: if let iptcBytes { out.append(iptcBytes) }
            default: out.append(original[segment.range])
            }
        }
        if oldXMPIndex == nil && insertXMPAt == old.count { out.append(xmpBytes) }
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
