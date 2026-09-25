import Foundation

/// Rewrites, in place, the values in an Exif TIFF structure (an APP1 payload after `Exif\0\0`) that describe the
/// pixels, for an export with new, upright pixels. Every other byte stays as it is, so the camera's MakerNote, whose
/// internal offsets count from the TIFF header, keeps working and stays byte-identical.
///
/// Changed: Orientation (1); ImageWidth/ImageLength and PixelXDimension/PixelYDimension (the new size), when present;
/// ColorSpace (1 when the new pixels are sRGB, else uncalibrated) and an Adobe RGB InteropIndex (`R03` becomes `R98`
/// for sRGB pixels), when present. IFD1, the thumbnail of the old pixels, is unlinked, and its image bytes are zeroed
/// unless they overlap the MakerNote.
enum ExifPatch {
    private enum Tag {
        static let imageWidth = 0x0100, imageLength = 0x0101, orientation = 0x0112
        static let stripOffsets = 0x0111, stripByteCounts = 0x0117
        static let exifIFD = 0x8769, interopIFD = 0xA005
        static let colorSpace = 0xA001, pixelXDimension = 0xA002, pixelYDimension = 0xA003
        static let makerNote = 0x927C
        static let thumbnailOffset = 0x0201, thumbnailLength = 0x0202
        static let interopIndex = 0x0001
    }

    private static let typeSizes: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]

    /// `tiff` with the pixel-describing values patched, or nil when its structure can't be walked safely (then the
    /// caller must not write anything that would lose it).
    static func patched(_ tiff: Data, pixelWidth: Int, pixelHeight: Int, sRGB: Bool) -> Data? {
        var t = TIFF(bytes: [UInt8](tiff))
        guard t.isValid, let ifd0 = t.ifd(at: t.u32(4)) else { return nil }

        for entry in ifd0 {
            switch entry.tag {
            case Tag.orientation: guard t.setNumber(entry, 1) else { return nil }
            case Tag.imageWidth: guard t.setNumber(entry, pixelWidth) else { return nil }
            case Tag.imageLength: guard t.setNumber(entry, pixelHeight) else { return nil }
            default: break
            }
        }

        /// The MakerNote's bytes; `.none` if there is none, nil inside if its value can't be located.
        var makerNote: Range<Int>??
        if let pointer = ifd0.first(where: { $0.tag == Tag.exifIFD }) {
            guard let offset = t.number(pointer), let exif = t.ifd(at: offset) else { return nil }
            for entry in exif {
                switch entry.tag {
                case Tag.pixelXDimension: guard t.setNumber(entry, pixelWidth) else { return nil }
                case Tag.pixelYDimension: guard t.setNumber(entry, pixelHeight) else { return nil }
                case Tag.colorSpace: guard t.setNumber(entry, sRGB ? 1 : 0xFFFF) else { return nil }
                case Tag.makerNote: makerNote = .some(t.valueRange(entry))
                case Tag.interopIFD:
                    guard let interopOffset = t.number(entry), let interop = t.ifd(at: interopOffset) else { return nil }
                    if sRGB, let index = interop.first(where: { $0.tag == Tag.interopIndex }),
                       let range = t.valueRange(index), t.bytes[range].starts(with: Array("R03".utf8)) {
                        t.bytes.replaceSubrange(range.lowerBound..<(range.lowerBound + 3), with: Array("R98".utf8))
                    }
                default: break
                }
            }
        }

        // IFD1: the thumbnail. Unlink it, and zero its image data where that can't touch the MakerNote.
        let nextPointer = ifd0.nextPointer
        let ifd1Offset = t.u32(nextPointer)
        if ifd1Offset != 0 {
            if let ifd1 = t.ifd(at: ifd1Offset) {
                var images: [Range<Int>] = []
                if let offset = ifd1.first(where: { $0.tag == Tag.thumbnailOffset }).flatMap(t.number),
                   let length = ifd1.first(where: { $0.tag == Tag.thumbnailLength }).flatMap(t.number) {
                    images.append(offset..<(offset + length))
                }
                if let offsets = ifd1.first(where: { $0.tag == Tag.stripOffsets }).flatMap(t.numbers),
                   let counts = ifd1.first(where: { $0.tag == Tag.stripByteCounts }).flatMap(t.numbers),
                   offsets.count == counts.count {
                    images += zip(offsets, counts).map { $0..<($0 + $1) }
                }
                // A MakerNote whose bytes can't be located might be anywhere: then nothing is zeroed.
                let untouchable: Range<Int>? = switch makerNote {
                case .none: nil
                case .some(.none): 0..<t.bytes.count
                case .some(.some(let range)): range
                }
                for image in images where image.lowerBound >= 8 && image.upperBound <= t.bytes.count
                    && !(untouchable.map { $0.overlaps(image) } ?? false) {
                    t.bytes.replaceSubrange(image, with: repeatElement(0, count: image.count))
                }
            }
            t.set32(at: nextPointer, 0)
        }
        return Data(t.bytes)
    }

    // MARK: - TIFF walking

    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        /// The entry's 4-byte value field.
        let field: Int
    }

    private struct IFD: Sequence {
        let entries: [Entry]
        let nextPointer: Int
        func makeIterator() -> IndexingIterator<[Entry]> { entries.makeIterator() }
    }

    private struct TIFF {
        var bytes: [UInt8]
        var littleEndian: Bool { bytes[0] == 0x49 }

        var isValid: Bool {
            bytes.count >= 8 && ((bytes[0] == 0x49 && bytes[1] == 0x49 && u16(2) == 42)
                                 || (bytes[0] == 0x4D && bytes[1] == 0x4D && u16(2) == 42))
        }

        func u16(_ o: Int) -> Int {
            littleEndian ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : Int(bytes[o]) << 8 | Int(bytes[o + 1])
        }
        func u32(_ o: Int) -> Int { littleEndian ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }

        mutating func set16(at o: Int, _ v: Int) {
            let b = [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            bytes.replaceSubrange(o..<(o + 2), with: littleEndian ? b.reversed() : b)
        }
        mutating func set32(at o: Int, _ v: Int) {
            let b = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            bytes.replaceSubrange(o..<(o + 4), with: littleEndian ? b.reversed() : b)
        }

        /// The IFD at `offset`, if its entries and next-IFD pointer lie inside the structure. (Entries' values aren't
        /// checked: cameras write odd ones, and only the values this patch reads or writes need to be sound.)
        func ifd(at offset: Int) -> IFD? {
            guard offset >= 8, offset + 2 <= bytes.count else { return nil }
            let count = u16(offset)
            let end = offset + 2 + count * 12
            guard count <= 1000, end + 4 <= bytes.count else { return nil }
            var entries: [Entry] = []
            for k in 0..<count {
                let e = offset + 2 + k * 12
                entries.append(Entry(tag: u16(e), type: u16(e + 2), count: u32(e + 4), field: e + 8))
            }
            return IFD(entries: entries, nextPointer: end)
        }

        /// Where the entry's value is: inline in its field, or at the offset the field holds.
        func valueRange(_ e: Entry) -> Range<Int>? {
            guard let size = ExifPatch.typeSizes[e.type], e.count >= 0, e.count <= bytes.count else { return nil }
            let length = size * e.count
            if length <= 4 { return e.field..<(e.field + length) }
            let start = u32(e.field)
            guard start >= 8, start + length <= bytes.count else { return nil }
            return start..<(start + length)
        }

        /// A single SHORT or LONG value.
        func number(_ e: Entry) -> Int? {
            guard e.count == 1 else { return nil }
            switch e.type {
            case 3: return u16(e.field)
            case 4: return u32(e.field)
            default: return nil
            }
        }

        /// SHORT or LONG values.
        func numbers(_ e: Entry) -> [Int]? {
            guard e.type == 3 || e.type == 4, let range = valueRange(e) else { return nil }
            let size = e.type == 3 ? 2 : 4
            return stride(from: range.lowerBound, to: range.upperBound, by: size).map { size == 2 ? u16($0) : u32($0) }
        }

        /// Sets a single SHORT or LONG value; false for any other shape, or a value too big for a SHORT.
        mutating func setNumber(_ e: Entry, _ value: Int) -> Bool {
            guard e.count == 1 else { return false }
            switch e.type {
            case 3:
                guard value <= 0xFFFF else { return false }
                set16(at: e.field, value)
            case 4:
                set32(at: e.field, value)
            default:
                return false
            }
            return true
        }
    }
}
