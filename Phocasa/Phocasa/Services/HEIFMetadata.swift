import Foundation
import ImageIO

/// Phocasa's rating and keywords inside a HEIF file (`.heic`, `.heif`): the XMP item's packet replaced, and every
/// other byte of the file kept, moved at most.
///
/// HEIF (ISO/IEC 23008-12) is ISO BMFF (ISO/IEC 14496-12). Its images, their Exif and their XMP are *items* of the
/// file-level `meta` box: `iinf` names each item (XMP is an item of type `mime` with content type
/// `application/rdf+xml`), `iref` links them (a `cdsc` reference from a metadata item to the image it describes),
/// `iprp` gives images their properties, and `iloc` says where each item's bytes are: at absolute file offsets
/// (construction method 0, usually into the `mdat` after `meta`) or at offsets into `meta`'s own `idat` (method 1). A
/// HEIF has no IPTC-IIM: ImageIO shows its XMP `dc:subject` as the IPTC keywords.
///
/// The packet is replaced in the first of these ways that applies (fewest changed bytes first):
/// 1. **In place:** the new packet fits the old one's bytes, which no other item shares. It's written over them,
///    padded with spaces to the same length (XMP's padding). Nothing else changes.
/// 2. **The file's tail:** the old packet is the last bytes of the file, in its last `mdat`. The file is cut there and
///    the new packet appended; the item's `iloc` extent length and that `mdat`'s size change.
/// 3. **Appended:** otherwise the new packet goes at the end of the file, in a new `mdat` box (or at the end of a last
///    `mdat` that runs to the end of the file). Only the item's `iloc` entry changes (its extent offset and length,
///    its construction method if it was in `idat`); the old packet's bytes stay where they were, unreferenced. The
///    next write finds the packet at the tail (1 or 2), so repeated writes don't grow the file.
/// 4. **A new item**, when the primary image has no XMP item: a new `infe` at the end of `iinf`, a new `cdsc`
///    reference at the end of `iref` (or a new `iref` after `iinf`), a new entry at the end of `iloc`, and the packet
///    appended as in (3). `meta` grows, which moves every box after it by as much, so each `iloc` offset that points
///    past `meta` grows by as much too. Nothing else in the file holds an absolute offset: only `ftyp`, `meta`,
///    `mdat`, `free` and `skip` boxes are accepted at the top level.
///
/// Every other `iinf` entry, `iref` reference and `iloc` field, every other `meta` child (`hdlr`, `dinf`, `pitm`,
/// `iprp` with every property and association, `idat`, `grpl`) and every top-level box are kept byte for byte. Before
/// the result is returned it's parsed again and checked (`verify`): every original item's bytes identical and
/// reachable through the new `iloc`, every original item entry, reference, `meta` child and top-level box kept, and
/// ImageIO reading as many images as before.
///
/// Anything this can't prove safe is refused (`Refusal`, every case named), and the caller keeps the file
/// byte-identical and writes a sidecar.
enum HEIFMetadata {
    /// Why a HEIF's XMP can't be replaced without risk: the last resort, where the caller keeps the file and writes a
    /// sidecar.
    enum Refusal: Error, Equatable, Sendable {
        /// Not an ISO BMFF file with a HEIF brand.
        case notHEIF
        /// Box sizes, counts or tables that don't add up, or data outside the file.
        case malformed
        /// A top-level box other than `ftyp`, `meta`, `mdat`, `free`, `skip`: a `moov` (an image sequence: its sample
        /// tables hold absolute offsets), Samsung's `mpvd` (a motion photo's video, found from the end of the file),
        /// `uuid` and others, which may hold offsets this doesn't know about.
        case unsupportedTopLevelBox(String)
        /// A `meta` child other than `hdlr`, `dinf`, `pitm`, `iinf`, `iref`, `iprp`, `idat`, `iloc`, `grpl`, `free`,
        /// `skip` (item protection `ipro`, `fiin`, `xml `, …), or a `meta` whose handler isn't `pict`.
        case unsupportedMetaBox(String)
        /// A box version this doesn't know: `meta` ≠ 0, `iloc` > 2, `iinf`, `iref`, `pitm` or `ipma` > 1, `infe` < 2
        /// or > 3.
        case unsupportedVersion(String)
        /// An item stored in another file (`data_reference_index` ≠ 0).
        case externalData
        /// An item located inside another item (`iloc` construction method 2), or by a method this doesn't know.
        case unsupportedConstruction
        /// An extent of length 0 ("to the end of its container").
        case unboundedExtent
        /// Item data inside the `meta` box (at a file offset), which would move unevenly when `meta` grows.
        case itemDataInsideMeta
        /// Several XMP items describe the primary image, or an XMP item describes nothing: which one a reader takes
        /// isn't defined.
        case ambiguousXMP
        /// The XMP item is compressed (`content_encoding`) or protected.
        case encodedXMP
        /// The XMP item is split into several extents.
        case xmpInSeveralExtents
        /// The XMP describes data found by its distance from the end of the file (a Google or Samsung motion photo's
        /// video), which appending would break.
        case appendedData
        /// A new offset, length, size, count or item ID doesn't fit its field.
        case fieldTooSmall
        /// `update` refused the packet.
        case updateRefused
        /// ImageIO doesn't read the original as a complete image (for example an `iloc` with extent indexes), so the
        /// result couldn't be checked.
        case unreadable
        /// The rewritten file failed its own check. (A bug; nothing is written.)
        case selfCheckFailed
    }

    /// How the packet was written (see the type's documentation).
    enum Change: Equatable, Sendable {
        case inPlace, tail, appended, newItem
    }

    struct Written {
        let data: Data
        let change: Change
        /// The XMP item's bytes in `data`: the packet, padded when written in place.
        let xmpData: Data
    }

    /// Whether `data` is an ISO BMFF file whose `ftyp` names a HEIF brand (HEVC, AVC or AV1 images; sequences too).
    static func isHEIF(_ data: Data) -> Bool {
        let b = Bytes(data)
        guard let size = b.uint(0, 4), size >= 16, size <= UInt64(b.count), b.fourCC(4) == "ftyp" else { return false }
        let brands = stride(from: 8, to: Int(size) - 3, by: 4).filter { $0 != 12 }.map(b.fourCC)
        return brands.contains(where: heifBrands.contains)
    }

    private static let heifBrands: Set<String> = [
        "mif1", "mif2", "msf1", "heic", "heix", "heim", "heis", "hevc", "hevx", "avci", "avcs", "avif", "avis",
    ]

    /// `heif` with its XMP item's packet replaced by `update(existing)` (nil existing: none; nil result: refuse), or
    /// nil when that can't be done provably losslessly (the caller keeps the file and writes a sidecar).
    static func replacingXMP(in heif: Data, update: (Data?) -> Data?) -> Data? {
        try? writingXMP(in: heif, update: update).get().data
    }

    /// `replacingXMP`, saying how the packet was written, or why it wasn't.
    static func writingXMP(in heif: Data, update: (Data?) -> Data?) -> Result<Written, Refusal> {
        do {
            let file = try File(heif)
            let xmp = try file.primaryXMP()
            let existing = try xmp.map { file.bytes.slice(try file.range(of: $0.location.extents[0], in: $0.location)) }
            if let existing, mentionsAppendedData(existing) { throw Refusal.appendedData }
            guard let before = CGImageSourceCreateWithData(heif as CFData, nil),
                  CGImageSourceGetStatus(before) == .statusComplete, CGImageSourceGetCount(before) > 0
            else { throw Refusal.unreadable }
            guard let packet = update(existing), !packet.isEmpty else { throw Refusal.updateRefused }

            let written = try xmp.map { try file.replacing($0, with: packet) } ?? file.adding(packet)
            try verify(written, against: file, xmp: xmp, imageIO: before)
            return .success(written)
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(.malformed)
        }
    }

    /// Google's motion-photo container and Samsung's and Google's motion-photo properties locate a video by its
    /// distance from the end of the file.
    private static func mentionsAppendedData(_ packet: Data) -> Bool {
        ["http://ns.google.com/photos/1.0/container/", "MicroVideo", "MotionPhoto"]
            .contains { packet.range(of: Data($0.utf8)) != nil }
    }

    /// `packet` padded with spaces to `length` bytes: before its `<?xpacket end` trailer if it has one (XMP's padding),
    /// otherwise after the root element.
    static func padded(_ packet: Data, to length: Int) -> Data {
        guard packet.count < length else { return packet }
        let padding = Data(repeating: 0x20, count: length - packet.count)
        guard let trailer = packet.range(of: Data("<?xpacket end".utf8), options: .backwards) else { return packet + padding }
        return packet[..<trailer.lowerBound] + padding + packet[trailer.lowerBound...]
    }

    // MARK: - Bytes

    /// `Data` addressed by file offset from 0, whatever its `startIndex`.
    struct Bytes {
        let data: Data
        init(_ data: Data) { self.data = data }

        var count: Int { data.count }

        /// A big-endian unsigned integer of `size` bytes (0, 2, 4 or 8; a size of 0 reads as 0), or nil past the end.
        func uint(_ at: Int, _ size: Int) -> UInt64? {
            guard size >= 0, size <= 8, at >= 0, at <= count - size else { return nil }
            var value: UInt64 = 0
            for i in 0..<size { value = value << 8 | UInt64(data[data.startIndex + at + i]) }
            return value
        }

        func fourCC(_ at: Int) -> String {
            guard at >= 0, at <= count - 4 else { return "" }
            return String(decoding: data[(data.startIndex + at)..<(data.startIndex + at + 4)].map { $0 < 0x80 ? $0 : 0x3F },
                          as: UTF8.self)
        }

        func slice(_ r: Range<Int>) -> Data { data[(data.startIndex + r.lowerBound)..<(data.startIndex + r.upperBound)] }

        /// The null-terminated string at `at`, before `end`, and the offset after its terminator.
        func cString(_ at: Int, end: Int) -> (String, Int)? {
            var i = at
            while i < end, i < count, data[data.startIndex + i] != 0 { i += 1 }
            guard i < end, i < count else { return nil }
            return (String(decoding: slice(at..<i), as: UTF8.self), i + 1)
        }
    }

    // MARK: - Boxes

    struct Box {
        enum SizeField { case compact, large, toEnd }
        let type: String
        let range: Range<Int>
        let headerSize: Int
        let sizeField: SizeField
        var payload: Range<Int> { (range.lowerBound + headerSize)..<range.upperBound }
    }

    /// The boxes filling `range` exactly. A size of 0 ("to the end of the file") is accepted at the top level only.
    static func boxes(in range: Range<Int>, of b: Bytes, topLevel: Bool = false) throws -> [Box] {
        var out: [Box] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard i + 8 <= range.upperBound, let size32 = b.uint(i, 4) else { throw Refusal.malformed }
            let type = b.fourCC(i + 4)
            var header = 8
            let size: Int
            let field: Box.SizeField
            switch size32 {
            case 1:
                guard i + 16 <= range.upperBound, let large = b.uint(i + 8, 8), large <= UInt64(range.upperBound - i)
                else { throw Refusal.malformed }
                header = 16
                size = Int(large)
                field = .large
            case 0:
                guard topLevel else { throw Refusal.malformed }
                size = range.upperBound - i
                field = .toEnd
            default:
                guard size32 <= UInt64(range.upperBound - i) else { throw Refusal.malformed }
                size = Int(size32)
                field = .compact
            }
            if type == "uuid" { header += 16 }
            guard size >= header else { throw Refusal.malformed }
            out.append(Box(type: type, range: i..<(i + size), headerSize: header, sizeField: field))
            i += size
        }
        return out
    }

    // MARK: - The item tables

    struct ItemInfo {
        let id: UInt32
        let type: String
        let protectionIndex: UInt64
        let contentType: String?
        let contentEncoding: String?
        let range: Range<Int>

        var isXMP: Bool { type == "mime" && contentType?.lowercased() == "application/rdf+xml" }
    }

    struct Extent {
        let offset: UInt64
        let length: UInt64
        /// Where the offset and length fields are, in the file.
        let offsetField: Int
        let lengthField: Int
    }

    struct Location {
        let itemID: UInt32
        let constructionMethod: UInt64
        /// The 16 bits holding the construction method (versions 1 and 2), in the file.
        let methodField: Int?
        let dataReferenceIndex: UInt64
        let baseOffset: UInt64
        let baseOffsetField: Int
        let extents: [Extent]
    }

    struct ItemLocations {
        let box: Box
        let version: UInt64
        let offsetSize: Int, lengthSize: Int, baseOffsetSize: Int, indexSize: Int
        let countField: Int
        let locations: [Location]
    }

    struct Reference {
        let type: String
        let from: UInt32
        let to: [UInt32]
        let range: Range<Int>
    }

    struct XMPItem {
        let info: ItemInfo
        let location: Location
    }

    // MARK: - The parsed file

    /// A HEIF's top-level boxes and its `meta` box's tables, with every check the rewrite relies on.
    struct File {
        let bytes: Bytes
        let topLevel: [Box]
        let meta: Box
        let metaChildren: [Box]
        let primaryID: UInt32
        let iinf: Box
        let iinfVersion: UInt64
        let iinfCountField: Int
        let items: [ItemInfo]
        let iloc: ItemLocations
        let iref: Box?
        let irefVersion: UInt64
        let references: [Reference]
        let idat: Box?
        /// Every ID in use: items, references, property associations, entity groups (which share the ID space).
        let usedIDs: Set<UInt32>

        init(_ data: Data) throws {
            guard HEIFMetadata.isHEIF(data) else { throw Refusal.notHEIF }
            let b = Bytes(data)
            bytes = b
            topLevel = try boxes(in: 0..<b.count, of: b, topLevel: true)
            for box in topLevel where !["ftyp", "meta", "mdat", "free", "skip"].contains(box.type) {
                throw Refusal.unsupportedTopLevelBox(box.type)
            }
            let metas = topLevel.filter { $0.type == "meta" }
            guard topLevel.filter({ $0.type == "ftyp" }).count == 1, metas.count == 1, let meta = metas.first
            else { throw Refusal.malformed }
            // Only a last mdat may run to the end of the file (anything appended then joins it).
            guard !topLevel.contains(where: { $0.sizeField == .toEnd && $0.type != "mdat" }) else { throw Refusal.malformed }
            self.meta = meta
            guard b.uint(meta.payload.lowerBound, 1) == 0 else { throw Refusal.unsupportedVersion("meta") }
            metaChildren = try boxes(in: (meta.payload.lowerBound + 4)..<meta.range.upperBound, of: b)

            let known: Set<String> = ["hdlr", "dinf", "pitm", "iinf", "iref", "iprp", "idat", "iloc", "grpl", "free", "skip"]
            for child in metaChildren where !known.contains(child.type) { throw Refusal.unsupportedMetaBox(child.type) }
            let children = metaChildren
            func one(_ type: String) throws -> Box? {
                let found = children.filter { $0.type == type }
                guard found.count <= 1 else { throw Refusal.malformed }
                return found.first
            }
            guard let hdlr = try one("hdlr"), let pitm = try one("pitm"), let iinf = try one("iinf"),
                  let ilocBox = try one("iloc") else { throw Refusal.malformed }
            guard hdlr.payload.count >= 12, b.fourCC(hdlr.payload.lowerBound + 8) == "pict" else {
                throw Refusal.unsupportedMetaBox("hdlr")
            }
            _ = try one("dinf")
            let iprp = try one("iprp"), grpl = try one("grpl")
            iref = try one("iref")
            idat = try one("idat")
            self.iinf = iinf

            guard let pitmVersion = b.uint(pitm.payload.lowerBound, 1) else { throw Refusal.malformed }
            guard pitmVersion <= 1 else { throw Refusal.unsupportedVersion("pitm") }
            let idSize = pitmVersion == 0 ? 2 : 4
            guard pitm.payload.count == 4 + idSize, let primary = b.uint(pitm.payload.lowerBound + 4, idSize)
            else { throw Refusal.malformed }
            primaryID = UInt32(primary)

            (iinfVersion, iinfCountField, items) = try Self.itemInfos(iinf, b)
            iloc = try Self.itemLocations(ilocBox, b)
            (irefVersion, references) = try iref.map { try Self.itemReferences($0, b) } ?? (0, [])

            var ids = Set(items.map(\.id)).union(iloc.locations.map(\.itemID)).union([primaryID])
            for reference in references { ids.insert(reference.from); ids.formUnion(reference.to) }
            if let iprp { ids.formUnion(try Self.associatedIDs(iprp, b)) }
            if let grpl { ids.formUnion(try Self.groupIDs(grpl, b)) }
            usedIDs = ids

            guard Set(items.map(\.id)).count == items.count,
                  Set(iloc.locations.map(\.itemID)).count == iloc.locations.count,
                  items.contains(where: { $0.id == primaryID }) else { throw Refusal.malformed }
            try validateLocations()
        }

        private static func itemInfos(_ box: Box, _ b: Bytes) throws -> (UInt64, Int, [ItemInfo]) {
            let p = box.payload.lowerBound
            guard let version = b.uint(p, 1) else { throw Refusal.malformed }
            guard version <= 1 else { throw Refusal.unsupportedVersion("iinf") }
            let countSize = version == 0 ? 2 : 4
            guard let count = b.uint(p + 4, countSize) else { throw Refusal.malformed }
            let entries = try boxes(in: (p + 4 + countSize)..<box.range.upperBound, of: b)
            guard entries.count == count, entries.allSatisfy({ $0.type == "infe" }) else { throw Refusal.malformed }
            let items = try entries.map { entry -> ItemInfo in
                let q = entry.payload.lowerBound, end = entry.range.upperBound
                guard let v = b.uint(q, 1) else { throw Refusal.malformed }
                guard v == 2 || v == 3 else { throw Refusal.unsupportedVersion("infe") }
                let idSize = v == 2 ? 2 : 4
                guard q + 4 + idSize + 6 <= end, let id = b.uint(q + 4, idSize), let protection = b.uint(q + 4 + idSize, 2)
                else { throw Refusal.malformed }
                let type = b.fourCC(q + 4 + idSize + 2)
                var contentType: String?, contentEncoding: String?
                if type == "mime" {
                    guard let (_, afterName) = b.cString(q + 4 + idSize + 6, end: end),
                          let (content, afterType) = b.cString(afterName, end: end) else { throw Refusal.malformed }
                    contentType = content
                    if afterType < end {
                        guard let (encoding, _) = b.cString(afterType, end: end) else { throw Refusal.malformed }
                        contentEncoding = encoding
                    }
                }
                return ItemInfo(id: UInt32(id), type: type, protectionIndex: protection, contentType: contentType,
                                contentEncoding: contentEncoding, range: entry.range)
            }
            return (version, p + 4, items)
        }

        private static func itemLocations(_ box: Box, _ b: Bytes) throws -> ItemLocations {
            var p = box.payload.lowerBound
            let end = box.range.upperBound
            guard let version = b.uint(p, 1) else { throw Refusal.malformed }
            guard version <= 2 else { throw Refusal.unsupportedVersion("iloc") }
            guard let sizes = b.uint(p + 4, 2) else { throw Refusal.malformed }
            let offsetSize = Int(sizes >> 12), lengthSize = Int(sizes >> 8 & 0xF), baseOffsetSize = Int(sizes >> 4 & 0xF)
            let indexSize = version == 0 ? 0 : Int(sizes & 0xF)
            guard [offsetSize, lengthSize, baseOffsetSize, indexSize].allSatisfy({ [0, 4, 8].contains($0) })
            else { throw Refusal.malformed }
            p += 6
            let countField = p
            let idSize = version == 2 ? 4 : 2
            guard let count = b.uint(p, idSize) else { throw Refusal.malformed }
            p += idSize
            var locations: [Location] = []
            for _ in 0..<count {
                guard let id = b.uint(p, idSize) else { throw Refusal.malformed }
                p += idSize
                var method: UInt64 = 0
                var methodField: Int?
                if version >= 1 {
                    guard let field = b.uint(p, 2) else { throw Refusal.malformed }
                    method = field & 0xF
                    methodField = p
                    p += 2
                }
                guard let dataReference = b.uint(p, 2), let base = b.uint(p + 2, baseOffsetSize),
                      let extentCount = b.uint(p + 2 + baseOffsetSize, 2), extentCount >= 1 else { throw Refusal.malformed }
                let baseField = p + 2
                p += 4 + baseOffsetSize
                var extents: [Extent] = []
                for _ in 0..<extentCount {
                    p += indexSize
                    guard let offset = b.uint(p, offsetSize), let length = b.uint(p + offsetSize, lengthSize)
                    else { throw Refusal.malformed }
                    extents.append(Extent(offset: offset, length: length, offsetField: p, lengthField: p + offsetSize))
                    p += offsetSize + lengthSize
                }
                guard p <= end else { throw Refusal.malformed }
                locations.append(Location(itemID: UInt32(id), constructionMethod: method, methodField: methodField,
                                          dataReferenceIndex: dataReference, baseOffset: base, baseOffsetField: baseField,
                                          extents: extents))
            }
            guard p == end else { throw Refusal.malformed }
            return ItemLocations(box: box, version: version, offsetSize: offsetSize, lengthSize: lengthSize,
                                 baseOffsetSize: baseOffsetSize, indexSize: indexSize, countField: countField,
                                 locations: locations)
        }

        private static func itemReferences(_ box: Box, _ b: Bytes) throws -> (UInt64, [Reference]) {
            let p = box.payload.lowerBound
            guard let version = b.uint(p, 1) else { throw Refusal.malformed }
            guard version <= 1 else { throw Refusal.unsupportedVersion("iref") }
            let idSize = version == 0 ? 2 : 4
            let references = try boxes(in: (p + 4)..<box.range.upperBound, of: b).map { reference -> Reference in
                let q = reference.payload.lowerBound
                guard let from = b.uint(q, idSize), let count = b.uint(q + idSize, 2),
                      reference.payload.count == idSize + 2 + Int(count) * idSize else { throw Refusal.malformed }
                let to = try (0..<Int(count)).map { k -> UInt32 in
                    guard let id = b.uint(q + idSize + 2 + k * idSize, idSize) else { throw Refusal.malformed }
                    return UInt32(id)
                }
                return Reference(type: reference.type, from: UInt32(from), to: to, range: reference.range)
            }
            return (version, references)
        }

        /// The item (and entity group) IDs in `ipma`.
        private static func associatedIDs(_ iprp: Box, _ b: Bytes) throws -> [UInt32] {
            var ids: [UInt32] = []
            for box in try boxes(in: iprp.payload, of: b) where box.type == "ipma" {
                var p = box.payload.lowerBound
                guard let version = b.uint(p, 1), let flags = b.uint(p + 1, 3), let count = b.uint(p + 4, 4)
                else { throw Refusal.malformed }
                guard version <= 1 else { throw Refusal.unsupportedVersion("ipma") }
                p += 8
                let idSize = version == 0 ? 2 : 4, associationSize = flags & 1 == 1 ? 2 : 1
                for _ in 0..<count {
                    guard let id = b.uint(p, idSize), let associations = b.uint(p + idSize, 1) else { throw Refusal.malformed }
                    ids.append(UInt32(id))
                    p += idSize + 1 + Int(associations) * associationSize
                }
                guard p == box.range.upperBound else { throw Refusal.malformed }
            }
            return ids
        }

        /// The group and entity IDs of `grpl`'s entity groups.
        private static func groupIDs(_ grpl: Box, _ b: Bytes) throws -> [UInt32] {
            var ids: [UInt32] = []
            for group in try boxes(in: grpl.payload, of: b) {
                let p = group.payload.lowerBound
                guard let id = b.uint(p + 4, 4), let count = b.uint(p + 8, 4), count < UInt64(Int32.max),
                      group.payload.count >= 12 + Int(count) * 4 else { throw Refusal.malformed }
                ids.append(UInt32(id))
                for k in 0..<Int(count) {
                    guard let entity = b.uint(p + 12 + k * 4, 4) else { throw Refusal.malformed }
                    ids.append(UInt32(entity))
                }
            }
            return ids
        }

        /// Every item's data is in this file, at file offsets (method 0) or in `idat` (method 1), in bounded extents
        /// inside the file.
        private func validateLocations() throws {
            for location in iloc.locations {
                guard location.dataReferenceIndex == 0 else { throw Refusal.externalData }
                guard location.constructionMethod <= 1 else { throw Refusal.unsupportedConstruction }
                for extent in location.extents {
                    guard extent.length > 0 else { throw Refusal.unboundedExtent }
                    _ = try range(of: extent, in: location)
                }
            }
        }

        /// Where an extent's bytes are, as file offsets.
        func range(of extent: Extent, in location: Location) throws -> Range<Int> {
            let (start, overflow) = location.baseOffset.addingReportingOverflow(extent.offset)
            let (end, overflow2) = start.addingReportingOverflow(extent.length)
            guard !overflow, !overflow2 else { throw Refusal.malformed }
            let container: Range<Int>
            switch location.constructionMethod {
            case 0: container = 0..<bytes.count
            case 1:
                guard let idat else { throw Refusal.malformed }
                container = idat.payload
            default: throw Refusal.unsupportedConstruction
            }
            guard end <= UInt64(container.count) else { throw Refusal.malformed }
            return (container.lowerBound + Int(start))..<(container.lowerBound + Int(end))
        }

        /// Item `id`'s bytes, its extents joined; nil when it has no location.
        func data(of id: UInt32) throws -> Data? {
            guard let location = iloc.locations.first(where: { $0.itemID == id }) else { return nil }
            var out = Data()
            for extent in location.extents { out.append(bytes.slice(try range(of: extent, in: location))) }
            return out
        }

        /// The one XMP item describing the primary image, or nil when there is none.
        func primaryXMP() throws -> XMPItem? {
            let xmpItems = items.filter(\.isXMP)
            let describing = xmpItems.filter { item in
                references.contains { $0.type == "cdsc" && $0.from == item.id && $0.to.contains(primaryID) }
            }
            let describesNothing = xmpItems.contains { item in !references.contains { $0.type == "cdsc" && $0.from == item.id } }
            guard describing.count <= 1, !describesNothing else { throw Refusal.ambiguousXMP }
            guard let info = describing.first else { return nil }
            guard info.contentEncoding?.isEmpty ?? true, info.protectionIndex == 0 else { throw Refusal.encodedXMP }
            guard let location = iloc.locations.first(where: { $0.itemID == info.id }) else { throw Refusal.malformed }
            guard location.extents.count == 1 else { throw Refusal.xmpInSeveralExtents }
            return XMPItem(info: info, location: location)
        }

        /// The file ranges of every other item's data with this construction method.
        private func ranges(except item: UInt32, method: UInt64) throws -> [Range<Int>] {
            try iloc.locations.filter { $0.itemID != item && $0.constructionMethod == method }
                .flatMap { location in try location.extents.map { try range(of: $0, in: location) } }
        }

        // MARK: Rewrites

        /// Ways 1 to 3: the XMP item's packet replaced.
        func replacing(_ xmp: XMPItem, with packet: Data) throws -> Written {
            let location = xmp.location, extent = location.extents[0]
            let old = try range(of: extent, in: location)
            let method = location.constructionMethod
            let shared = try ranges(except: xmp.info.id, method: method).contains { $0.overlaps(old) }
            let inMediaData = method == 1
                || topLevel.contains { $0.type == "mdat" && $0.payload.lowerBound <= old.lowerBound && old.upperBound <= $0.range.upperBound }

            // 1. In place.
            if packet.count <= old.count, !shared, inMediaData {
                let bytes = HEIFMetadata.padded(packet, to: old.count)
                var out = self.bytes.data
                out.replaceSubrange((out.startIndex + old.lowerBound)..<(out.startIndex + old.upperBound), with: bytes)
                return Written(data: out, change: .inPlace, xmpData: bytes)
            }

            // 2. The file's tail, in its last mdat.
            if method == 0, old.upperBound == bytes.count, let last = topLevel.last, last.type == "mdat",
               last.payload.lowerBound <= old.lowerBound,
               try !ranges(except: xmp.info.id, method: 0).contains(where: { $0.upperBound > old.lowerBound }) {
                var out = Data(bytes.slice(0..<old.lowerBound))
                out.append(packet)
                try Self.put(UInt64(packet.count), size: iloc.lengthSize, at: extent.lengthField, in: &out)
                try Self.resize(last, to: last.range.count - old.count + packet.count, in: &out)
                return Written(data: out, change: .tail, xmpData: packet)
            }

            // 3. Appended.
            var out = bytes.data
            let position = try appendPacket(packet, to: &out)
            try relocate(location, extent: extent, to: position, length: packet.count, in: &out)
            return Written(data: out, change: .appended, xmpData: packet)
        }

        /// Appends `packet` to `out` (this file's bytes, `meta` possibly grown) in a new `mdat`, or in the last `mdat`
        /// when that one runs to the end of the file, and returns the packet's offset.
        private func appendPacket(_ packet: Data, to out: inout Data) throws -> Int {
            if let last = topLevel.last, last.type == "mdat", last.sizeField == .toEnd {
                out.append(packet)
                return out.count - packet.count
            }
            guard fits(UInt64(packet.count + 8), 4) else { throw Refusal.fieldTooSmall }
            out.append(Self.box("mdat", packet))
            return out.count - packet.count
        }

        /// Points `location`'s one extent at `position` (a file offset) for `length` bytes, with construction method 0,
        /// keeping the base offset when it can.
        private func relocate(_ location: Location, extent: Extent, to position: Int, length: Int, in out: inout Data) throws {
            let target = UInt64(position)
            var base = location.baseOffset, offset: UInt64
            if target >= base, fits(target - base, iloc.offsetSize) {
                offset = target - base
            } else if iloc.baseOffsetSize > 0, fits(target, iloc.offsetSize) {
                (base, offset) = (0, target)
            } else if iloc.baseOffsetSize > 0, fits(target, iloc.baseOffsetSize) {
                (base, offset) = (target, 0)
            } else {
                throw Refusal.fieldTooSmall
            }
            if let methodField = location.methodField, location.constructionMethod != 0 {
                guard let field = Bytes(out).uint(methodField, 2) else { throw Refusal.malformed }
                try Self.put(field & ~0xF, size: 2, at: methodField, in: &out)
            }
            try Self.put(base, size: iloc.baseOffsetSize, at: location.baseOffsetField, in: &out)
            try Self.put(offset, size: iloc.offsetSize, at: extent.offsetField, in: &out)
            try Self.put(UInt64(length), size: iloc.lengthSize, at: extent.lengthField, in: &out)
        }

        /// Way 4: a new XMP item for the primary image.
        func adding(_ packet: Data) throws -> Written {
            guard let maxID = usedIDs.max(), maxID < UInt32.max else { throw Refusal.fieldTooSmall }
            let id = maxID + 1
            let smallID = id <= 0xFFFF

            // The new infe (version 2, or 3 for a 32-bit ID), hidden like ImageIO's, unnamed, XMP's content type.
            var infe = Data([smallID ? 2 : 3, 0, 0, 1])
            infe.append(Self.be(UInt64(id), smallID ? 2 : 4))
            infe.append(contentsOf: [0, 0])  // item_protection_index: none
            infe.append(Data("mime".utf8) + Data([0]) + Data("application/rdf+xml".utf8) + Data([0]))
            infe = Self.box("infe", infe)
            guard iinfVersion == 1 || items.count < 0xFFFF else { throw Refusal.fieldTooSmall }

            // The cdsc reference, in the existing iref or a new one.
            let refVersion = iref == nil ? (smallID && primaryID <= 0xFFFF ? 0 : 1) : irefVersion
            guard refVersion == 1 || (smallID && primaryID <= 0xFFFF) else { throw Refusal.fieldTooSmall }
            let refIDSize = refVersion == 0 ? 2 : 4
            let reference = Self.box("cdsc", Self.be(UInt64(id), refIDSize) + Self.be(1, 2) + Self.be(UInt64(primaryID), refIDSize))
            let irefGrowth = reference.count + (iref == nil ? 12 : 0)

            // The iloc entry's size; its location depends on how much meta grows.
            guard iloc.version == 2 || smallID, iloc.version == 2 || iloc.locations.count < 0xFFFF,
                  iloc.lengthSize > 0, fits(UInt64(packet.count), iloc.lengthSize) else { throw Refusal.fieldTooSmall }
            let idSize = iloc.version == 2 ? 4 : 2
            let entrySize = idSize + (iloc.version >= 1 ? 2 : 0) + 2 + iloc.baseOffsetSize + 2
                + iloc.indexSize + iloc.offsetSize + iloc.lengthSize
            let growth = infe.count + irefGrowth + entrySize

            // Every item whose data is after meta moves with it; none may be inside it.
            var ilocBytes = Data(bytes.slice(iloc.box.range))
            let ilocStart = iloc.box.range.lowerBound
            for location in iloc.locations where location.constructionMethod == 0 {
                let ranges = try location.extents.map { try range(of: $0, in: location) }
                guard !ranges.contains(where: { $0.overlaps(meta.range) }) else { throw Refusal.itemDataInsideMeta }
                let moves = ranges.map { $0.lowerBound >= meta.range.upperBound }
                guard moves.contains(true) else { continue }
                if iloc.baseOffsetSize > 0, location.baseOffset >= UInt64(meta.range.upperBound) {
                    try Self.add(growth, size: iloc.baseOffsetSize, at: location.baseOffsetField - ilocStart, in: &ilocBytes)
                } else {
                    for (extent, moved) in zip(location.extents, moves) where moved {
                        try Self.add(growth, size: iloc.offsetSize, at: extent.offsetField - ilocStart, in: &ilocBytes)
                    }
                }
            }

            // The new entry: construction method 0, this file, one extent at the packet.
            let movedEnd = bytes.count + growth
            let packetAt = topLevel.last.map { $0.type == "mdat" && $0.sizeField == .toEnd } == true ? movedEnd : movedEnd + 8
            var base: UInt64 = 0, offset = UInt64(packetAt)
            if !fits(offset, iloc.offsetSize) {
                guard fits(offset, iloc.baseOffsetSize) else { throw Refusal.fieldTooSmall }
                (base, offset) = (offset, 0)
            }
            var entry = Self.be(UInt64(id), idSize)
            if iloc.version >= 1 { entry.append(contentsOf: [0, 0]) }
            entry.append(contentsOf: [0, 0])
            entry.append(Self.be(base, iloc.baseOffsetSize))
            entry.append(Self.be(1, 2))
            entry.append(Self.be(0, iloc.indexSize))
            entry.append(Self.be(offset, iloc.offsetSize))
            entry.append(Self.be(UInt64(packet.count), iloc.lengthSize))
            guard entry.count == entrySize else { throw Refusal.selfCheckFailed }
            ilocBytes.append(entry)
            try Self.add(1, size: idSize, at: iloc.countField - ilocStart, in: &ilocBytes)
            try Self.resizeCopy(iloc.box, to: ilocBytes.count, in: &ilocBytes)

            var iinfBytes = Data(bytes.slice(iinf.range))
            iinfBytes.append(infe)
            try Self.add(1, size: iinfVersion == 0 ? 2 : 4, at: iinfCountField - iinf.range.lowerBound, in: &iinfBytes)
            try Self.resizeCopy(iinf, to: iinfBytes.count, in: &iinfBytes)

            let irefBytes: Data
            if let iref {
                var copy = Data(bytes.slice(iref.range))
                copy.append(reference)
                try Self.resizeCopy(iref, to: copy.count, in: &copy)
                irefBytes = copy
            } else {
                irefBytes = Self.box("iref", Data([UInt8(refVersion), 0, 0, 0]) + reference)
            }

            var metaBytes = Data(bytes.slice(meta.range.lowerBound..<(meta.payload.lowerBound + 4)))
            for child in metaChildren {
                switch child.type {
                case "iinf":
                    metaBytes.append(iinfBytes)
                    if iref == nil { metaBytes.append(irefBytes) }
                case "iref": metaBytes.append(irefBytes)
                case "iloc": metaBytes.append(ilocBytes)
                default: metaBytes.append(bytes.slice(child.range))
                }
            }
            guard metaBytes.count == meta.range.count + growth else { throw Refusal.selfCheckFailed }
            try Self.resizeCopy(meta, to: metaBytes.count, in: &metaBytes)

            var out = Data(capacity: movedEnd + packet.count + 8)
            out.append(bytes.slice(0..<meta.range.lowerBound))
            out.append(metaBytes)
            out.append(bytes.slice(meta.range.upperBound..<bytes.count))
            guard try appendPacket(packet, to: &out) == packetAt else { throw Refusal.selfCheckFailed }
            return Written(data: out, change: .newItem, xmpData: packet)
        }

        // MARK: Field writes

        func fits(_ value: UInt64, _ size: Int) -> Bool { Self.fits(value, size) }

        static func fits(_ value: UInt64, _ size: Int) -> Bool {
            size >= 8 || value < (UInt64(1) << (8 * size))
        }

        static func be(_ value: UInt64, _ size: Int) -> Data {
            Data((0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
        }

        /// Writes `value` big-endian into the `size` bytes at offset `at` of `out`, refusing a value that doesn't fit.
        static func put(_ value: UInt64, size: Int, at: Int, in out: inout Data) throws {
            guard fits(value, size), at >= 0, at + size <= out.count else { throw Refusal.fieldTooSmall }
            out.replaceSubrange((out.startIndex + at)..<(out.startIndex + at + size), with: be(value, size))
        }

        /// Adds `delta` to the `size`-byte field at offset `at` of `out`, refusing an overflow.
        static func add(_ delta: Int, size: Int, at: Int, in out: inout Data) throws {
            guard size > 0, delta >= 0, let value = Bytes(out).uint(at, size) else { throw Refusal.fieldTooSmall }
            let (sum, overflow) = value.addingReportingOverflow(UInt64(delta))
            guard !overflow else { throw Refusal.fieldTooSmall }
            try put(sum, size: size, at: at, in: &out)
        }

        /// Sets `box`'s size field, in the file `out`, to `size`.
        static func resize(_ box: Box, to size: Int, in out: inout Data) throws {
            switch box.sizeField {
            case .compact: try put(UInt64(size), size: 4, at: box.range.lowerBound, in: &out)
            case .large: try put(UInt64(size), size: 8, at: box.range.lowerBound + 8, in: &out)
            case .toEnd: break
            }
        }

        /// Sets the size field of `copy`, a copy of `box` starting at 0, to `size`.
        static func resizeCopy(_ box: Box, to size: Int, in copy: inout Data) throws {
            switch box.sizeField {
            case .compact: try put(UInt64(size), size: 4, at: 0, in: &copy)
            case .large: try put(UInt64(size), size: 8, at: 8, in: &copy)
            case .toEnd: throw Refusal.malformed
            }
        }

        static func box(_ type: String, _ payload: Data) -> Data {
            be(UInt64(payload.count + 8), 4) + Data(type.utf8) + payload
        }
    }

    // MARK: - The check before anything is written

    /// Parses `written` again and checks it against `original`, whose primary XMP item was `xmp` (nil: none):
    /// - the same primary item; every original `infe` and `iref` reference byte for byte and in order, plus, for a
    ///   new item, just its `infe` and its `cdsc` reference to the primary image;
    /// - every `meta` child other than `iinf`, `iref` and `iloc` byte for byte (`idat` apart from the old packet's
    ///   bytes, when those were overwritten in place);
    /// - every original item's data but the XMP item's identical, reached through the new `iloc`; the XMP item's
    ///   data exactly `written.xmpData`;
    /// - every top-level box but `meta` byte for byte, apart from the old packet's bytes (overwritten in place, or cut
    ///   with the last box's size), and a last `mdat` the packet joined; at most one new `mdat`, at the end;
    /// - ImageIO reading it completely, as many images as before (`imageIO`, the original), the same primary.
    static func verify(_ written: Written, against original: File, xmp: XMPItem?, imageIO: CGImageSource) throws {
        func check(_ condition: @autoclosure () throws -> Bool) throws {
            guard (try? condition()) == true else { throw Refusal.selfCheckFailed }
        }
        guard let new = try? File(written.data), let newXMP = try? new.primaryXMP() else { throw Refusal.selfCheckFailed }
        let xmpID = newXMP.info.id
        let added = xmp == nil ? 1 : 0
        try check(new.primaryID == original.primaryID)
        if let xmp { try check(xmpID == xmp.info.id) }

        // Items and references.
        try check(new.items.count == original.items.count + added && new.references.count == original.references.count + added)
        for (a, b) in zip(original.items, new.items) { try check(original.bytes.slice(a.range) == new.bytes.slice(b.range)) }
        for (a, b) in zip(original.references, new.references) {
            try check(original.bytes.slice(a.range) == new.bytes.slice(b.range))
        }
        if xmp == nil {
            try check(new.items.last?.id == xmpID && !original.usedIDs.contains(xmpID))
            try check(new.references.last.map { $0.type == "cdsc" && $0.from == xmpID && $0.to == [original.primaryID] } ?? false)
        }

        // The old packet's bytes, where they were overwritten or cut.
        let oldRange = try xmp.map { try original.range(of: $0.location.extents[0], in: $0.location) }
        let masked = written.change == .inPlace || written.change == .tail ? oldRange : nil
        /// `a` (in the original) and `b` (in the new file) hold the same bytes, apart from `masked`.
        func same(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            guard let masked, a.overlaps(masked) else { return original.bytes.slice(a) == new.bytes.slice(b) }
            let before = masked.lowerBound - a.lowerBound, after = a.upperBound - masked.upperBound
            return before >= 0 && after >= 0 && b.count >= before + after
                && original.bytes.slice(a.lowerBound..<masked.lowerBound) == new.bytes.slice(b.lowerBound..<(b.lowerBound + before))
                && original.bytes.slice(masked.upperBound..<a.upperBound) == new.bytes.slice((b.upperBound - after)..<b.upperBound)
        }

        // Every other meta child.
        let rebuilt: Set<String> = ["iinf", "iref", "iloc"]
        let keptA = original.metaChildren.filter { !rebuilt.contains($0.type) }, keptB = new.metaChildren.filter { !rebuilt.contains($0.type) }
        try check(keptA.map(\.type) == keptB.map(\.type) && keptA.map(\.range.count) == keptB.map(\.range.count))
        for (a, b) in zip(keptA, keptB) { try check(same(a.range, b.range)) }

        // Every item's data.
        try check(new.iloc.locations.count == original.iloc.locations.count + added)
        for location in original.iloc.locations where location.itemID != xmpID {
            try check(try original.data(of: location.itemID) == new.data(of: location.itemID))
        }
        try check(try new.data(of: xmpID) == written.xmpData)

        // Top-level boxes.
        let types = original.topLevel.map(\.type)
        try check(new.topLevel.map(\.type) == types || new.topLevel.map(\.type) == types + ["mdat"])
        for (index, (a, b)) in zip(original.topLevel, new.topLevel).enumerated() where a.type != "meta" {
            let last = index == original.topLevel.count - 1
            if last, written.change == .tail {
                // Cut at the old packet: the header but its size, and the payload up to the packet.
                try check(a.headerSize == b.headerSize && oldRange.map { $0.upperBound == a.range.upperBound } == true)
                try check(original.bytes.slice(a.payload.lowerBound..<(oldRange?.lowerBound ?? 0))
                    == new.bytes.slice(b.payload.lowerBound..<(b.payload.lowerBound + (oldRange?.lowerBound ?? 0) - a.payload.lowerBound)))
            } else if last, a.sizeField == .toEnd, b.range.count > a.range.count {
                // The packet joined it.
                try check(same(a.range, b.range.lowerBound..<(b.range.lowerBound + a.range.count)))
            } else {
                try check(a.range.count == b.range.count && same(a.range, b.range))
            }
        }

        // ImageIO reads it as it read the original.
        guard let after = CGImageSourceCreateWithData(written.data as CFData, nil) else { throw Refusal.selfCheckFailed }
        try check(CGImageSourceGetStatus(after) == .statusComplete)
        try check(CGImageSourceGetCount(after) == CGImageSourceGetCount(imageIO))
        try check(CGImageSourceGetPrimaryImageIndex(after) == CGImageSourceGetPrimaryImageIndex(imageIO))
    }
}
