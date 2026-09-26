import Foundation
import CryptoKit
import ImageIO

/// A classic TIFF's rating and keywords, written into the file itself without moving or losing anything (task D;
/// CLAUDE.md, "Metadata").
///
/// The XMP is IFD0's tag 700 (XMLPacket, BYTE or UNDEFINED, count in bytes: Adobe's XMP specification, part 3,
/// 1.1.6). The IPTC keywords are in IFD0's IPTC-NAA (33723) and in the IPTC resource (1028) of its Photoshop image
/// resources (34377), when it has them: Photoshop writes both copies (part 3, 3.3.4). No existing byte moves, because
/// MakerNotes and other private tags hold absolute offsets:
/// - a new value that fits its old one's space is written over it, padded: the XMP with whitespace before its packet
///   trailer (part 1's in-place padding), the IPTC with zeros after its datasets. The entry's type, count and offset
///   stay, so IFD0 and the header don't change;
/// - otherwise the new value is appended at the end of the file, 4-byte aligned, with room to grow (`xmpSlack`,
///   `iptcSlack`), followed by a copy of IFD0 whose entries are the old ones byte for byte (so every value, strip,
///   SubIFD, Exif, GPS and Interop pointer points where it did), apart from the changed ones and a new tag 700 inserted
///   in tag order; its next-IFD pointer is the old one. The header then points at the copy. The old IFD0 and the old
///   values stay in the file, unreferenced.
///
/// A file this can't write that way is refused (`Refusal`, each case named): the caller keeps it byte-identical and
/// writes the rating to its `.xmp` sidecar.
///
/// What ImageIO reads (macOS 26, checked by hand-built files): only IFD0's tag 700, as BYTE, UNDEFINED or ASCII (not
/// SHORT or LONG), wherever it is in the file, padded or not, wrapped or not, with trailing NULs or not; not XMP in the
/// Photoshop resources (1060), the Exif IFD or another page. IFD0's Microsoft Rating tag (0x4746) isn't read as
/// `xmp:Rating`. The IPTC keywords are merged into `dc:subject`: 33723's if present, else 34377's; the XMP wins when it
/// has `dc:subject` (an empty one included), the IPTC's show when it has none. Zero padding after the IPTC datasets,
/// in either tag, is read fine. A BigTIFF's pixels decode, but none of its metadata is read.
enum TIFFMetadata {
    /// Why a TIFF can't take the values in the file. Each is a last resort: the file stays byte-identical and the
    /// values go to its sidecar.
    enum Refusal: Error, Equatable, Sendable {
        /// Not a TIFF: it doesn't start with `II*\0` or `MM\0*`.
        case notTIFF
        /// A BigTIFF (version 43). ImageIO decodes its pixels but reads none of its metadata, so a rating written there
        /// couldn't be read back. Rare: files over 4 GB, mostly scientific and GIS imagery.
        case bigTIFF
        /// Something points outside the file, or into its header: a truncated file, IFD, value or strip.
        case outOfBounds
        /// An IFD that can't be read as one: an IFD0 without entries, a sub-IFD pointer or a strip table of the wrong
        /// type, strip offsets without matching byte counts (or an old-style JPEG offset without its length), more than
        /// `maxIFDs` IFDs, or an IFD0 with no room for one more entry.
        case malformedIFD
        /// An IFD reached twice: a page chain or a sub-IFD pointer that loops (or two pointers sharing one IFD).
        case ifdLoop
        /// A field type TIFF 6.0 (and its technical note 1, type 13 IFD) doesn't define, so its value's size and so the
        /// bytes it uses are unknown.
        case unknownFieldType
        /// IFD0 has tag 700, 33723 or 34377 more than once: which one readers use is unknown (ImageIO then doesn't
        /// decode the file at all).
        case duplicateMetadataTag
        /// A new tag 700 would have to be inserted into an IFD0 whose entries aren't in ascending tag order (TIFF 6.0
        /// requires it), so where it belongs is unknown.
        case unsortedIFD0
        /// Tag 700 isn't BYTE or UNDEFINED (ImageIO doesn't read SHORT or LONG, and ASCII needs a terminating NUL a
        /// padded rewrite would have to keep), 33723 isn't BYTE, UNDEFINED or LONG, or 34377 isn't BYTE or UNDEFINED.
        case unexpectedFieldType(UInt16)
        /// The Photoshop resources hold an XMP packet (1060), which a TIFF shouldn't have (XMP specification part 3,
        /// 3.3.4). ImageIO ignores it but other readers don't: two packets that would disagree.
        case xmpInPhotoshopResources
        /// The IPTC can't be patched safely: malformed datasets or resources, or non-ASCII keywords over IPTC text of
        /// unknown encoding (`IPTCIIM.replacingKeywords`). Leaving it stale would contradict the XMP.
        case iptcNotPatchable
        /// `update` refused the packet (another app's XMP ImageIO can't parse, or can't re-serialise without changing a
        /// value), or the padded packet doesn't read back with the same values.
        case xmpNotUpdatable
        /// Appended data would lie beyond classic TIFF's 32-bit offsets.
        case offsetsBeyond4GB
        /// The result didn't read back as written: a safeguard against a bug here, never expected.
        case verificationFailed
    }

    /// Whether `data` starts like a classic TIFF (`II*\0` or `MM\0*`).
    static func isTIFF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        let head = [data[s], data[s + 1], data[s + 2], data[s + 3]]
        return head == [0x49, 0x49, 0x2A, 0x00] || head == [0x4D, 0x4D, 0x00, 0x2A]
    }

    /// `tiff` with IFD0's XMP packet (tag 700, XMLPacket) replaced by `update(existing)` (`existing` nil if IFD0 has
    /// none; `update` returns the new packet, nil to refuse), and IFD0's IPTC keywords set to `keywords` when it has
    /// IPTC (33723, and the IPTC resource in 34377). Nil (the caller keeps the file and writes a sidecar) when that
    /// can't be done without moving or losing anything (`rewrite` says why). No existing byte is moved.
    static func replacingXMP(in tiff: Data, update: (Data?) -> Data?, keywords: [String]) -> Data? {
        try? rewrite(tiff, update: update, keywords: keywords).get()
    }

    /// `replacingXMP`, with the reason for a refusal. `offsetLimit` is the largest file size classic TIFF's offsets
    /// can address (smaller in tests).
    static func rewrite(_ tiff: Data, update: (Data?) -> Data?, keywords: [String],
                        offsetLimit: Int = Int(UInt32.max)) -> Result<Data, Refusal> {
        do {
            return .success(try rewriting(tiff.startIndex == 0 ? tiff : Data(tiff), update: update, keywords: keywords,
                                          offsetLimit: offsetLimit))
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(.verificationFailed)
        }
    }

    // MARK: - Constants

    static let xmpTag = 700
    static let iptcTag = 33723
    static let photoshopTag = 34377
    private static let metadataTags = [xmpTag, iptcTag, photoshopTag]

    /// Bytes per value of each TIFF 6.0 field type, and type 13 (IFD, technical note 1).
    private static let typeSizes: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
    /// SubIFDs, Exif, GPS, Interop: tags whose values are offsets of further IFDs.
    private static let ifdPointerTags: Set<Int> = [330, 34665, 34853, 40965]
    /// Offsets and byte counts of image data: strips, tiles, free space, JPEG interchange format.
    private static let dataTags: [(offsets: Int, lengths: Int)] = [(273, 279), (324, 325), (288, 289), (513, 514)]
    /// More IFDs than any real file has; a bound on the work a damaged file can cause.
    static let maxIFDs = 65_536

    /// Room left after an appended XMP packet, so later, larger packets fit in place: at least 2 KB (the XMP
    /// specification's recommendation) or half the packet. Appends then grow geometrically (×1.5).
    static func xmpSlack(_ packetLength: Int) -> Int { max(2048, packetLength / 2) }
    /// The same for appended IPTC datasets (zero padding).
    static func iptcSlack(_ datasetsLength: Int) -> Int { max(256, datasetsLength / 2) }

    private static let xpacketHeader = Data("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n".utf8)
    private static let xpacketTrailer = Data("<?xpacket end=\"w\"?>".utf8)
    private static let photoshopHeader = Data("Photoshop 3.0\u{0}".utf8)
    private static let iptcResource = 0x0404
    private static let digestResource = 0x0425
    private static let xmpResource = 0x0424

    // MARK: - Structure

    private struct ByteOrder {
        let little: Bool
        func u16(_ d: Data, _ o: Int) -> Int { little ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1]) }
        func u32(_ d: Data, _ o: Int) -> Int { little ? u16(d, o) | u16(d, o + 2) << 16 : u16(d, o) << 16 | u16(d, o + 2) }
        func bytes16(_ v: Int) -> [UInt8] {
            little ? [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] : [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
        func bytes32(_ v: Int) -> [UInt8] {
            little ? bytes16(v & 0xFFFF) + bytes16(v >> 16 & 0xFFFF) : bytes16(v >> 16 & 0xFFFF) + bytes16(v & 0xFFFF)
        }
    }

    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        /// Where the 12-byte entry is.
        let position: Int
        /// Where the value is: the entry's own 4-byte field when it fits there, else the bytes that field points at.
        let value: Range<Int>
        var isInline: Bool { value.count <= 4 }
        var record: Range<Int> { position..<(position + 12) }
    }

    private struct IFD {
        let offset: Int
        let entries: [Entry]
        var table: Range<Int> { offset..<(offset + 2 + 12 * entries.count + 4) }
        var nextPointer: Range<Int> { (table.upperBound - 4)..<table.upperBound }
        func entry(_ tag: Int) -> Entry? { entries.first { $0.tag == tag } }
    }

    private struct Structure {
        let order: ByteOrder
        let ifd0: IFD
        /// Every byte range the file is known to use: the header, each IFD's table, each out-of-line value (with its
        /// entry's position) and the image data.
        let regions: [(range: Range<Int>, entry: Int?)]

        /// Whether `entry`'s value bytes are its own: no other value, IFD, header or image data shares them (an IFD0
        /// that shares its storage oddly), so they can be overwritten in place.
        func isExclusive(_ entry: Entry) -> Bool {
            !entry.isInline && !regions.contains { $0.entry != entry.position && $0.range.overlaps(entry.value) }
        }
    }

    /// The file's header and every IFD reachable from it: the page chain, SubIFDs, Exif, GPS and Interop IFDs, with
    /// every value and strip checked to lie inside the file.
    private static func parse(_ d: Data) throws -> Structure {
        guard d.count >= 4 else { throw Refusal.notTIFF }
        let order: ByteOrder
        switch (d[0], d[1]) {
        case (0x49, 0x49): order = ByteOrder(little: true)
        case (0x4D, 0x4D): order = ByteOrder(little: false)
        default: throw Refusal.notTIFF
        }
        switch order.u16(d, 2) {
        case 42: break
        case 43: throw Refusal.bigTIFF
        default: throw Refusal.notTIFF
        }
        guard d.count >= 8 else { throw Refusal.outOfBounds }

        var regions: [(range: Range<Int>, entry: Int?)] = [(0..<8, nil)]
        var visited: Set<Int> = []
        var pending = [order.u32(d, 4)]
        var ifd0: IFD?
        while let offset = pending.popLast() {
            guard visited.insert(offset).inserted else { throw Refusal.ifdLoop }
            guard visited.count <= maxIFDs else { throw Refusal.malformedIFD }
            let ifd = try readIFD(d, at: offset, order)
            if ifd0 == nil { ifd0 = ifd }
            regions.append((ifd.table, nil))
            for entry in ifd.entries where !entry.isInline { regions.append((entry.value, entry.position)) }
            let next = order.u32(d, ifd.nextPointer.lowerBound)
            if next != 0 { pending.append(next) }
            for entry in ifd.entries where ifdPointerTags.contains(entry.tag) {
                guard entry.type == 4 || entry.type == 13 else { throw Refusal.malformedIFD }
                pending += numbers(d, entry, order).filter { $0 != 0 }
            }
            for pair in dataTags {
                let offsets = ifd.entry(pair.offsets), lengths = ifd.entry(pair.lengths)
                guard offsets != nil || lengths != nil else { continue }
                guard let offsets, let lengths, [3, 4].contains(offsets.type), [3, 4].contains(lengths.type),
                      offsets.count == lengths.count else { throw Refusal.malformedIFD }
                for (start, length) in zip(numbers(d, offsets, order), numbers(d, lengths, order)) where length > 0 {
                    guard start >= 8, start + length <= d.count else { throw Refusal.outOfBounds }
                    regions.append((start..<(start + length), nil))
                }
            }
        }
        guard let ifd0 else { throw Refusal.outOfBounds }
        guard !ifd0.entries.isEmpty else { throw Refusal.malformedIFD }
        return Structure(order: order, ifd0: ifd0, regions: regions)
    }

    private static func readIFD(_ d: Data, at offset: Int, _ order: ByteOrder) throws -> IFD {
        guard offset >= 8, offset + 2 <= d.count else { throw Refusal.outOfBounds }
        let count = order.u16(d, offset)
        guard offset + 2 + 12 * count + 4 <= d.count else { throw Refusal.outOfBounds }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for k in 0..<count {
            let p = offset + 2 + 12 * k
            let tag = order.u16(d, p), type = order.u16(d, p + 2), n = order.u32(d, p + 4)
            guard let size = typeSizes[type] else { throw Refusal.unknownFieldType }
            let length = size * n
            var start = p + 8
            if length > 4 {
                start = order.u32(d, p + 8)
                guard start >= 8, start + length <= d.count else { throw Refusal.outOfBounds }
            }
            entries.append(Entry(tag: tag, type: type, count: n, position: p, value: start..<(start + length)))
        }
        return IFD(offset: offset, entries: entries)
    }

    /// A SHORT, LONG or IFD entry's values.
    private static func numbers(_ d: Data, _ entry: Entry, _ order: ByteOrder) -> [Int] {
        let size = typeSizes[entry.type] ?? 4
        return stride(from: entry.value.lowerBound, to: entry.value.upperBound, by: size).map {
            size == 2 ? order.u16(d, $0) : order.u32(d, $0)
        }
    }

    // MARK: - The rewrite

    /// A new value for one of IFD0's metadata tags.
    private enum Change {
        /// Written over the old value, which is exactly as long.
        case inPlace(Range<Int>)
        /// Appended, with IFD0's entry for it pointing there.
        case appended(type: Int)
    }

    private static func rewriting(_ data: Data, update: (Data?) -> Data?, keywords: [String], offsetLimit: Int) throws -> Data {
        let structure = try parse(data)
        let ifd0 = structure.ifd0
        for tag in metadataTags where ifd0.entries.filter({ $0.tag == tag }).count > 1 { throw Refusal.duplicateMetadataTag }
        var changes: [(tag: Int, change: Change, bytes: Data)] = []

        // XMP.
        let xmpEntry = ifd0.entry(xmpTag)
        if let xmpEntry, ![1, 7].contains(xmpEntry.type) { throw Refusal.unexpectedFieldType(UInt16(xmpTag)) }
        let existing = xmpEntry.flatMap { packet(in: Data(data[$0.value])) }
        guard let packet = update(existing), let values = xmpValues(packet) else { throw Refusal.xmpNotUpdatable }
        if existing.flatMap(xmpValues) != values {
            guard let unpadded = padded(packet, by: 0) else { throw Refusal.xmpNotUpdatable }
            let bytes: Data?, change: Change
            if let xmpEntry, structure.isExclusive(xmpEntry), unpadded.count <= xmpEntry.value.count {
                bytes = padded(packet, by: xmpEntry.value.count - unpadded.count)
                change = .inPlace(xmpEntry.value)
            } else {
                if xmpEntry == nil {
                    let tags = ifd0.entries.map(\.tag)
                    guard zip(tags, tags.dropFirst()).allSatisfy({ $0 < $1 }) else { throw Refusal.unsortedIFD0 }
                }
                let slack = xmpSlack(unpadded.count)
                bytes = padded(packet, by: slack + (unpadded.count + slack) % 2)
                change = .appended(type: xmpEntry?.type ?? 1)
            }
            guard let bytes, isWellFormedXML(bytes), xmpValues(bytes) == values else { throw Refusal.xmpNotUpdatable }
            changes.append((xmpTag, change, bytes))
        }

        // IPTC-NAA (33723): the datasets with the new keywords, where they were or appended.
        let iptcEntry = ifd0.entry(iptcTag)
        var stored33723: Data?
        if let iptcEntry {
            guard [1, 4, 7].contains(iptcEntry.type) else { throw Refusal.unexpectedFieldType(UInt16(iptcTag)) }
            let old = Data(data[iptcEntry.value])
            guard let replaced = IPTCIIM.replacingKeywords(in: old, with: keywords),
                  let core = datasets(in: replaced) else { throw Refusal.iptcNotPatchable }
            stored33723 = old
            if replaced != old {
                let unit = typeSizes[iptcEntry.type] ?? 1
                let bytes: Data, change: Change
                if structure.isExclusive(iptcEntry), core.count <= iptcEntry.value.count {
                    bytes = core + Data(count: iptcEntry.value.count - core.count)
                    change = .inPlace(iptcEntry.value)
                } else {
                    let length = roundUp(core.count + iptcSlack(core.count), to: max(unit, 2))
                    bytes = core + Data(count: length - core.count)
                    change = .appended(type: iptcEntry.type)
                }
                stored33723 = bytes
                changes.append((iptcTag, change, bytes))
            }
        }

        // Photoshop image resources (34377): the IPTC resource with the new keywords, and its digest.
        if let entry = ifd0.entry(photoshopTag) {
            guard [1, 7].contains(entry.type) else { throw Refusal.unexpectedFieldType(UInt16(photoshopTag)) }
            if let (change, bytes) = try photoshopChange(Data(data[entry.value]), entry: entry, structure: structure,
                                                         keywords: keywords, old33723: iptcEntry.map { Data(data[$0.value]) },
                                                         new33723: stored33723) {
                changes.append((photoshopTag, change, bytes))
            }
        }

        guard !changes.isEmpty else { return data }
        let out = try assemble(data, structure: structure, changes: changes, offsetLimit: offsetLimit)
        try verify(out, original: data, ifd0: ifd0, changes: changes)
        return out
    }

    /// The new bytes of 34377 and where they go, or nil when nothing in it changes (it has no IPTC resource, or that
    /// already holds these keywords).
    ///
    /// The keywords are replaced by `PhotoshopIRB` (every other resource and dataset kept byte for byte). The IPTC
    /// resource's data is then padded with zeros after its datasets, so that the whole fits the old space, or has room
    /// to grow when appended: zeros at the end of the resources would make exiftool warn ("Bad Photoshop IRB
    /// resource"), zeros after IPTC datasets are read by ImageIO and exiftool alike. When the two IPTC copies were
    /// byte-identical they stay so (the resource gets 33723's new bytes).
    ///
    /// The digest (1061) keeps describing what it described: 33723's bytes when it was their MD5 and not the
    /// resource's (exiftool compares it with 33723 in a TIFF; Photoshop pads 33723 to whole LONGs), else the resource's
    /// new data, as `PhotoshopIRB` makes it for a JPEG.
    private static func photoshopChange(_ old: Data, entry: Entry, structure: Structure, keywords: [String],
                                        old33723: Data?, new33723: Data?) throws -> (Change, Data)? {
        guard let oldBlocks = resourceBlocks(old) else { throw Refusal.iptcNotPatchable }
        guard !oldBlocks.contains(where: { $0.id == xmpResource }) else { throw Refusal.xmpInPhotoshopResources }
        guard let patched = PhotoshopIRB.replacingKeywords(in: photoshopHeader + old, with: keywords),
              patched.starts(with: photoshopHeader) else { throw Refusal.iptcNotPatchable }
        let updated = Data(patched.dropFirst(photoshopHeader.count))
        guard let blocks = resourceBlocks(updated) else { throw Refusal.iptcNotPatchable }
        let iptc = blocks.first { $0.id == iptcResource }
        let oldIPTC = oldBlocks.first { $0.id == iptcResource }.map { Data(old[$0.data]) }
        let oldDigest = oldBlocks.first { $0.id == digestResource }.map { Data(old[$0.data]) }
        let digestOf33723 = oldDigest != nil && oldDigest == old33723.map(md5) && oldDigest != oldIPTC.map(md5)
        // Only Phocasa's fields make a change: a digest that was stale stays as it was while they don't change.
        let iptcChanged = iptc.map { Data(updated[$0.data]) != oldIPTC } ?? false
        guard iptcChanged || (digestOf33723 && new33723 != old33723) else { return nil }

        func rebuilt(_ iptcData: Data?) -> Data {
            let digest = digestOf33723 ? md5(new33723 ?? Data()) : md5(iptcData ?? Data())
            return rebuiltResources(updated, blocks: blocks, iptc: iptc, iptcData: iptcData, digest: digest)
        }
        func placed(_ bytes: Data) -> (Change, Data) {
            let fits = structure.isExclusive(entry) && bytes.count == entry.value.count
            return (fits ? .inPlace(entry.value) : .appended(type: entry.type), bytes)
        }
        // No IPTC resource: only the digest of 33723 changes.
        guard let iptc else { return placed(rebuilt(nil)) }
        guard let core = datasets(in: Data(updated[iptc.data])) else { throw Refusal.iptcNotPatchable }
        if let old33723, oldIPTC == old33723, let new33723 { return placed(rebuilt(new33723)) }

        // In place: the IPTC resource sized so the whole keeps its length (possible unless that length is odd).
        let header = iptc.data.lowerBound - iptc.block.lowerBound
        let size = entry.value.count - (updated.count - iptc.block.count) - header
        if structure.isExclusive(entry), size >= core.count {
            let bytes = rebuilt(core + Data(count: size - core.count))
            if bytes.count == entry.value.count { return (.inPlace(entry.value), bytes) }
        }
        let length = roundUp(core.count + iptcSlack(core.count), to: 2)
        return placed(rebuilt(core + Data(count: length - core.count)))
    }

    /// `data` with the changes written: in place over the old values, or appended with a copy of IFD0 pointing at
    /// them, which the header then points at.
    private static func assemble(_ data: Data, structure: Structure, changes: [(tag: Int, change: Change, bytes: Data)],
                                 offsetLimit: Int) throws -> Data {
        let order = structure.order, ifd0 = structure.ifd0
        var out = data
        var records = ifd0.entries.map { (tag: $0.tag, bytes: Data(data[$0.record])) }
        var appended = false
        for (tag, change, bytes) in changes {
            switch change {
            case .inPlace(let range):
                guard bytes.count == range.count else { throw Refusal.verificationFailed }
                out.replaceSubrange(range, with: bytes)
            case .appended(let type):
                appended = true
                let unit = typeSizes[type] ?? 1
                guard bytes.count % unit == 0 else { throw Refusal.verificationFailed }
                var field = Data(bytes.prefix(4))
                if bytes.count > 4 {
                    align(&out)
                    field = Data(order.bytes32(out.count))
                    out += bytes
                    guard out.count <= offsetLimit else { throw Refusal.offsetsBeyond4GB }
                }
                field += Data(count: 4 - field.count)
                let record = Data(order.bytes16(tag) + order.bytes16(type) + order.bytes32(bytes.count / unit)) + field
                if let index = records.firstIndex(where: { $0.tag == tag }) {
                    records[index].bytes = record
                } else {
                    guard records.count < 0xFFFF else { throw Refusal.malformedIFD }
                    records.insert((tag, record), at: records.firstIndex { $0.tag > tag } ?? records.count)
                }
            }
        }
        guard appended else { return out }
        align(&out)
        let offset = out.count
        out += Data(order.bytes16(records.count))
        for record in records { out += record.bytes }
        out += data[ifd0.nextPointer]
        guard out.count <= offsetLimit else { throw Refusal.offsetsBeyond4GB }
        out.replaceSubrange(4..<8, with: order.bytes32(offset))
        return out
    }

    /// Checks the result before anyone's photo is replaced by it: it parses, IFD0 holds exactly the old entries
    /// (byte for byte) apart from the changed ones, whose values are the new bytes, and nothing before the old end
    /// changed except the header's offset and the values rewritten in place.
    private static func verify(_ out: Data, original: Data, ifd0 old: IFD,
                               changes: [(tag: Int, change: Change, bytes: Data)]) throws {
        let structure = try parse(out)
        let ifd0 = structure.ifd0
        let changed = Set(changes.map(\.tag))
        for entry in old.entries where !changed.contains(entry.tag) {
            guard let now = ifd0.entry(entry.tag), out[now.record] == original[entry.record] else { throw Refusal.verificationFailed }
        }
        for (tag, _, bytes) in changes {
            guard let now = ifd0.entry(tag), out[now.value] == bytes else { throw Refusal.verificationFailed }
        }
        guard ifd0.entries.count == old.entries.count + (old.entry(xmpTag) == nil && changed.contains(xmpTag) ? 1 : 0)
        else { throw Refusal.verificationFailed }
        var mayChange: [Range<Int>] = []
        for (_, change, _) in changes {
            if case .inPlace(let range) = change { mayChange.append(range) }
        }
        if ifd0.offset != old.offset { mayChange.append(4..<8) }
        var start = 0
        for range in mayChange.sorted(by: { $0.lowerBound < $1.lowerBound }) + [original.count..<original.count] {
            guard out[start..<range.lowerBound] == original[start..<range.lowerBound] else { throw Refusal.verificationFailed }
            start = max(start, range.upperBound)
        }
    }

    private static func align(_ data: inout Data) {
        if data.count % 4 != 0 { data.append(Data(count: 4 - data.count % 4)) }
    }

    private static func roundUp(_ n: Int, to unit: Int) -> Int { (n + unit - 1) / unit * unit }

    private static func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }

    // MARK: - XMP

    /// The packet in tag 700's bytes: without trailing NULs (some writers end it with one), nil when nothing's left
    /// but whitespace.
    private static func packet(in bytes: Data) -> Data? {
        var end = bytes.endIndex
        while end > bytes.startIndex, bytes[end - 1] == 0 { end -= 1 }
        let packet = bytes[bytes.startIndex..<end]
        guard packet.contains(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return nil }
        return Data(packet)
    }

    /// Every value in `packet`, or nil if ImageIO can't parse it.
    private static func xmpValues(_ packet: Data) -> [String: String]? {
        CGImageMetadataCreateFromXMPData(packet as CFData).map(XMPProperties.values)
    }

    /// Whether `packet` is well-formed XML. ImageIO's parser also accepts junk after the root element; other readers
    /// don't, so the padded packet is checked on its own.
    private static func isWellFormedXML(_ packet: Data) -> Bool {
        let parser = XMLParser(data: packet)
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    /// `packet` in an XMP packet wrapper with `padding` bytes of whitespace before its trailer: the XMP
    /// specification's padding for in-place updates (part 1: whitespace after the serialised XMP, before
    /// `<?xpacket end="w"?>`), spaces with a newline every 100 bytes as Adobe writes it. A packet that already has a
    /// trailer gets the padding before it. Nil for one that can't be wrapped: an XML declaration (which must come
    /// first), or a wrapper without a trailer.
    static func padded(_ packet: Data, by padding: Int) -> Data? {
        let packet = Data(packet)
        let whitespace = Data((0..<padding).map { $0 % 100 == 99 ? 0x0A : 0x20 })
        if let trailer = packet.range(of: Data("<?xpacket end=".utf8), options: .backwards) {
            return packet[..<trailer.lowerBound] + whitespace + packet[trailer.lowerBound...]
        }
        guard packet.range(of: Data("<?xpacket".utf8)) == nil, packet.range(of: Data("<?xml".utf8)) == nil else { return nil }
        return xpacketHeader + packet + whitespace + xpacketTrailer
    }

    // MARK: - IPTC

    /// `iim` up to the end of its last dataset (without the zero padding after it), or nil if it isn't a run of
    /// standard datasets.
    private static func datasets(in iim: Data) -> Data? {
        let d = Data(iim)
        var i = 0
        while i < d.count {
            if d[i] != 0x1C {
                guard d[i...].allSatisfy({ $0 == 0 }) else { return nil }
                break
            }
            guard i + 5 <= d.count else { return nil }
            let length = Int(d[i + 3]) << 8 | Int(d[i + 4])
            guard length & 0x8000 == 0, i + 5 + length <= d.count else { return nil }
            i += 5 + length
        }
        return d.prefix(i)
    }

    /// One Photoshop image resource: signature, id, padded name, size, data, padding.
    private struct ResourceBlock {
        let id: Int
        let block: Range<Int>
        let data: Range<Int>
    }

    private static let resourceSignatures: [Data] = ["8BIM", "MeSa", "PHUT", "AgHg", "DCSR"].map { Data($0.utf8) }

    /// The resource blocks in 34377's bytes (no "Photoshop 3.0" header there), with the zero padding some writers
    /// leave after them; nil if they aren't a well-formed run of blocks.
    private static func resourceBlocks(_ d: Data) -> [ResourceBlock]? {
        var i = 0
        var out: [ResourceBlock] = []
        while i < d.count {
            if d[i] == 0, d[i...].allSatisfy({ $0 == 0 }) { break }
            guard i + 12 <= d.count, resourceSignatures.contains(d[i..<(i + 4)]) else { return nil }
            let id = Int(d[i + 4]) << 8 | Int(d[i + 5])
            let nameLength = Int(d[i + 6])
            var j = i + 7 + nameLength
            if (1 + nameLength) % 2 == 1 { j += 1 }
            guard j + 4 <= d.count else { return nil }
            let size = Int(d[j]) << 24 | Int(d[j + 1]) << 16 | Int(d[j + 2]) << 8 | Int(d[j + 3])
            let start = j + 4
            guard start + size <= d.count else { return nil }
            let end = min(d.count, start + size + size % 2)
            out.append(ResourceBlock(id: id, block: i..<end, data: start..<(start + size)))
            i = end
        }
        return out
    }

    /// `resources` with `iptc`'s data replaced by `iptcData` and every digest resource's by `digest`; every other
    /// byte (other resources, names, padding after the last) kept.
    private static func rebuiltResources(_ resources: Data, blocks: [ResourceBlock], iptc: ResourceBlock?, iptcData: Data?,
                                         digest: Data) -> Data {
        func withData(_ block: ResourceBlock, _ data: Data) -> Data {
            let n = data.count
            var out = Data(resources[block.block.lowerBound..<(block.data.lowerBound - 4)])
            out += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            out += data
            if n % 2 == 1 { out.append(0) }
            return out
        }
        var out = Data()
        var i = 0
        for block in blocks {
            out += resources[i..<block.block.lowerBound]
            if let iptc, let iptcData, block.block == iptc.block {
                out += withData(block, iptcData)
            } else if block.id == digestResource {
                out += withData(block, digest)
            } else {
                out += resources[block.block]
            }
            i = block.block.upperBound
        }
        out += resources[i...]
        return out
    }
}
