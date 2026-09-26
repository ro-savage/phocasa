import Foundation

/// A JPEG's MPF segment (CIPA DC-007 Multi-Picture Format: APP2 "MPF\0", then a TIFF-style structure): the MP Index
/// IFD's MP Entry locates every image in the file, the first one (the primary, SOI to EOI) by its size and the others
/// (camera previews, MPO views, gain maps) by an offset counted from the MP header's endian field.
///
/// A rating write that changes the header's size moves what follows: the primary grows, and so do the offsets of the
/// images after it when the change is after the MPF segment. DC-007 A.2.3.1 requires a writer that inserts APPn
/// segments to update those fields, so `patched` rewrites exactly them (each 4 bytes, in the segment's byte order) and
/// keeps every other byte of the segment. Everything is validated first; anything it can't account for is refused.
enum MPFIndex {
    private static let mpEntryTag: UInt16 = 0xB002
    private static let undefinedType: UInt16 = 7

    /// The MPF segment at `range` in `file` (a JPEG whose header ends at `sos`), with its MP entries updated for a new
    /// header that is `growth` bytes longer (the first image's size) and puts the images after the primary `shift`
    /// bytes further from this segment (their offsets). Nil, to leave the file alone, when the segment can't be read as
    /// an MP Index IFD, when an entry doesn't describe this file (the first image isn't at offset 0 or isn't longer
    /// than its header, another image has no offset, starts inside the header or runs past the end), or when a new
    /// value wouldn't fit 32 bits. A segment without an MP Entry locates nothing and comes back unchanged.
    static func patched(_ file: Data, segment range: Range<Int>, sos: Int, growth: Int, shift: Int) -> Data? {
        var segment = [UInt8](file[range])
        let h = 8   // "FF E2", the length, "MPF\0"; the MP header's endian field starts here
        guard segment.count >= h + 8, Data(segment[4..<8]) == JPEGStructure.mpfID else { return nil }
        let little: Bool
        switch (segment[h], segment[h + 1], segment[h + 2], segment[h + 3]) {
        case (0x49, 0x49, 0x2A, 0x00): little = true
        case (0x4D, 0x4D, 0x00, 0x2A): little = false
        default: return nil
        }
        let end = segment.count
        func read(_ at: Int, _ n: Int) -> Int? {
            guard at >= h, at + n <= end else { return nil }
            let bytes = segment[at..<(at + n)].map(Int.init)
            return (little ? bytes.reversed() : bytes).reduce(0) { $0 << 8 | $1 }
        }
        func write32(_ at: Int, _ value: Int) {
            let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            segment.replaceSubrange(at..<(at + 4), with: little ? bytes.reversed() : bytes)
        }

        guard let ifdOffset = read(h + 4, 4), let count = read(h + ifdOffset, 2),
              h + ifdOffset + 2 + count * 12 + 4 <= end else { return nil }
        let entryTags = (0..<count).map { h + ifdOffset + 2 + $0 * 12 }.filter { read($0, 2) == Int(mpEntryTag) }
        guard let tag = entryTags.first else { return Data(segment) }
        guard entryTags.count == 1, read(tag + 2, 2) == Int(undefinedType),
              let bytes = read(tag + 4, 4), bytes >= 16, bytes % 16 == 0,
              let valueOffset = read(tag + 8, 4), h + valueOffset + bytes <= end else { return nil }

        let fileStart = file.startIndex
        let headerLength = sos - fileStart
        for k in 0..<(bytes / 16) {
            let entry = h + valueOffset + k * 16
            guard let size = read(entry + 4, 4), let offset = read(entry + 8, 4) else { return nil }
            if k == 0 {
                // The first image, whose SOI is the file's: offset 0, SOI to EOI.
                guard offset == 0, size > headerLength, size <= file.count else { return nil }
                if growth != 0 {
                    let new = size + growth
                    guard new > 0, new <= Int(UInt32.max) else { return nil }
                    write32(entry + 4, new)
                }
            } else {
                // A secondary image: after the header (so it moves with the image data), inside the file.
                let start = range.lowerBound + h + offset
                guard offset > 0, start >= sos, start + size <= file.endIndex else { return nil }
                if shift != 0 {
                    let new = offset + shift
                    guard new > 0, new <= Int(UInt32.max) else { return nil }
                    write32(entry + 8, new)
                }
            }
        }
        return Data(segment)
    }
}
