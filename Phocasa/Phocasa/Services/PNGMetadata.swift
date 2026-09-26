import Foundation
import zlib

/// A PNG's chunks, and the one change Phocasa makes to them: its XMP packet, which holds Phocasa's rating and keywords
/// (post-wave-3 task D; CLAUDE.md, "Metadata"). Every other chunk, and anything after `IEND`, stays byte for byte and
/// in order.
///
/// A PNG is an 8-byte signature, then chunks up to `IEND`: a 4-byte big-endian data length (at most 2³¹ − 1), a 4-byte
/// type of ASCII letters (lower-case first letter: ancillary; upper-case: critical), the data, and the CRC-32 of the
/// type and data (W3C PNG, third edition, §5). XMP lives in an `iTXt` chunk with the keyword `XML:com.adobe.xmp`,
/// uncompressed, with an empty language tag and translated keyword, one per file (XMP specification part 3, §1.1.5).
/// `iTXt` may go anywhere between `IHDR` and `IEND`, but ImageIO reads XMP (and `eXIf`) only before the first `IDAT`,
/// and takes the first XMP it finds; exiftool 11.63 and later moves text chunks before `IDAT` for that reason.
///
/// Pure and thread-safe. The caller (`MetadataService`) checks that the result reads back through ImageIO, and
/// replaces the file through a temp file.
enum PNGMetadata {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// The largest chunk data length the format allows.
    static let maxChunkLength = 0x7FFF_FFFF
    /// The largest XMP packet inflated or written: far beyond any real packet, and a bound on the memory a damaged or
    /// hostile compressed chunk can take.
    static let maxPacketSize = 64 << 20

    private static let xmpKeyword = Array("XML:com.adobe.xmp".utf8)
    /// ImageMagick's hex-encoded XMP (`Raw profile type xmp`), compared in lower case.
    private static let rawXMPProfileKeyword = Array("raw profile type xmp".utf8)
    private static let knownCriticalChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND"]
    private static let textChunks: Set<String> = ["tEXt", "zTXt", "iTXt"]

    /// How a file that isn't a well-formed PNG is broken.
    enum Damage: Equatable, Sendable {
        /// A chunk runs past the end of the file, or the file ends before `IEND`.
        case truncated
        /// A chunk length over 2³¹ − 1.
        case badLength
        /// A chunk type with a byte that isn't an ASCII letter.
        case badType
        /// A chunk whose CRC doesn't match its type and data.
        case badCRC
        /// `IHDR` isn't the first chunk, or appears again.
        case misplacedHeader
        /// No `IDAT` chunk.
        case noImageData
        /// `IDAT` chunks with other chunks between them (the format requires them consecutive).
        case splitImageData
    }

    /// Why a PNG can't take a new XMP packet without losing or changing anything else. The caller then keeps the
    /// file byte-identical and writes a sidecar (the last resort).
    enum Refusal: Error, Equatable, Sendable {
        /// No PNG signature.
        case notPNG
        /// Not a well-formed PNG: an editor can't be sure what it would keep.
        case damaged(Damage)
        /// Apple's crushed PNG (Xcode's `pngcrush` for iOS app bundles): a `CgBI` chunk before `IHDR`, and image data
        /// in a non-standard form. Not a standard PNG; other apps can't read it.
        case appleCrushed
        /// A critical chunk the format doesn't define. The PNG specification tells editors to give up on those.
        case unknownCriticalChunk(String)
        /// More than one XMP `iTXt` chunk. ImageIO merges them, the first one winning each property; updating one would
        /// leave the others disagreeing with it.
        case severalXMPChunks
        /// The XMP `iTXt` chunk can't be read: its header is cut short, its compression flag or method is unknown, or
        /// its compressed text is damaged, has bytes after its end, or inflates to more than `maxPacketSize`.
        case unreadableXMPChunk
        /// XMP in a `tEXt` or `zTXt` chunk with the keyword `XML:com.adobe.xmp`. ImageIO ignores those, other readers
        /// (exiftool) don't: a new `iTXt` would make two packets that disagree.
        case xmpInTextChunk
        /// XMP in ImageMagick's `Raw profile type xmp` text chunk, which ImageIO reads as XMP too (the first one
        /// found wins): a new `iTXt` would make two packets that disagree.
        case xmpInRawProfile
        /// `update` returned nil (it can't update the packet without losing a value).
        case updateRefused
        /// The new packet isn't UTF-8, which `iTXt` text must be.
        case packetNotUTF8
        /// The new packet is over `maxPacketSize` (or, with a pathological chunk header, the chunk over 2³¹ − 1).
        case packetTooLarge
        /// zlib couldn't compress the new packet (for a chunk that was compressed). Only out of memory.
        case compressionFailed
    }

    /// One chunk of a PNG.
    struct Chunk: Equatable, Sendable {
        /// The four type bytes as text, e.g. `IDAT`.
        let type: String
        /// The whole chunk in the file: length, type, data, CRC.
        let range: Range<Int>
        /// The data, between the type and the CRC.
        var data: Range<Int> { (range.lowerBound + 8)..<(range.upperBound - 4) }
        /// Bit 5 of the first type byte clear: a chunk a decoder must understand.
        var isCritical: Bool { type.utf8.first.map { $0 & 0x20 == 0 } ?? false }
    }

    /// Whether `data` starts with the PNG signature.
    static func isPNG(_ data: Data) -> Bool {
        data.count >= signature.count && data.prefix(signature.count).elementsEqual(signature)
    }

    /// `png` with its XMP packet replaced by `update(existing)`. `existing` is the packet in the file's `iTXt` chunk
    /// with keyword `XML:com.adobe.xmp` (nil if it has none); `update` returns the new packet (nil to refuse). Nil
    /// (the caller keeps the file and writes a sidecar) when that can't be done without losing or changing anything
    /// else. Every other chunk stays byte for byte. See `rewritingXMP(in:update:)`.
    static func replacingXMP(in png: Data, update: (Data?) -> Data?) -> Data? {
        try? rewritingXMP(in: png, update: update).get()
    }

    /// `png` with its XMP packet replaced by `update(existing)`, or why that can't be done without losing or changing
    /// anything else.
    ///
    /// What changes, byte by byte:
    /// - **An XMP `iTXt` before the first `IDAT`** (where ImageIO reads it): only that chunk's length, text and CRC.
    ///   Its header (keyword, compression flag and method, language tag, translated keyword) is kept, and so is its
    ///   form: compressed text is inflated for `update` and the new packet compressed again.
    /// - **No XMP chunk:** a new `iTXt` (`XML:com.adobe.xmp`, uncompressed, no language tag or translated keyword) is
    ///   inserted right before the first `IDAT`, or before an animated PNG's first `fcTL` if that comes first. That's
    ///   where ImageIO writes it. The file grows by the chunk; nothing else moves relative to anything else.
    /// - **An XMP `iTXt` after the image data**, which ImageIO doesn't read: it moves to that same place, header and
    ///   form kept, with the new packet. The chunks around it keep their bytes and order.
    ///
    /// Every other chunk (`eXIf`, `iCCP`, text, private and unknown ancillary chunks, `IDAT`, animation chunks) and
    /// every byte after `IEND` stays as it is. Every chunk of the original must be whole with a valid CRC.
    static func rewritingXMP(in png: Data, update: (Data?) -> Data?) -> Result<Data, Refusal> {
        let chunks: [Chunk]
        switch walk(png) {
        case .success(let walked): chunks = walked
        case .failure(let refusal): return .failure(refusal)
        }
        if let refusal = layoutRefusal(chunks) { return .failure(refusal) }
        // The layout check guarantees an IDAT.
        guard let firstIDAT = chunks.firstIndex(where: { $0.type == "IDAT" }),
              let insertion = chunks.firstIndex(where: { $0.type == "IDAT" || $0.type == "fcTL" }) else {
            return .failure(.damaged(.noImageData))
        }

        var xmpIndex: Int?
        for (index, chunk) in chunks.enumerated() where textChunks.contains(chunk.type) {
            switch textKind(chunk, in: png) {
            case .xmp:
                guard xmpIndex == nil else { return .failure(.severalXMPChunks) }
                xmpIndex = index
            case .xmpInText: return .failure(.xmpInTextChunk)
            case .xmpInRawProfile: return .failure(.xmpInRawProfile)
            case .other: break
            }
        }

        var old: XMPText?
        var existing: Data?
        if let xmpIndex {
            guard let text = xmpText(chunks[xmpIndex], in: png) else { return .failure(.unreadableXMPChunk) }
            let bytes = png[text.text]
            if text.compressed {
                guard let inflated = inflate(Data(bytes), limit: maxPacketSize) else { return .failure(.unreadableXMPChunk) }
                existing = inflated
            } else {
                existing = Data(bytes)
            }
            old = text
        }

        guard let packet = update(existing) else { return .failure(.updateRefused) }
        guard packet.count <= maxPacketSize else { return .failure(.packetTooLarge) }
        guard String(data: packet, encoding: .utf8) != nil else { return .failure(.packetNotUTF8) }

        let header = old.map { Data(png[$0.header]) } ?? Data(xmpKeyword + [0, 0, 0, 0, 0])
        let text: Data
        if old?.compressed == true {
            guard let compressed = deflate(packet) else { return .failure(.compressionFailed) }
            text = compressed
        } else {
            text = packet
        }
        // Only a pathological header (a huge language tag) could take the chunk past the format's limit.
        guard header.count + text.count <= maxChunkLength else { return .failure(.packetTooLarge) }
        let newChunk = chunk(type: "iTXt", data: header + text)

        // The ranges of the original to keep, around the new chunk.
        let start = png.startIndex, end = png.endIndex
        var out = Data(capacity: png.count + newChunk.count)
        if let xmpIndex {
            let replaced = chunks[xmpIndex].range
            if xmpIndex < firstIDAT {
                out.append(png[start..<replaced.lowerBound])
                out.append(newChunk)
            } else {
                let at = chunks[insertion].range.lowerBound
                out.append(png[start..<at])
                out.append(newChunk)
                out.append(png[at..<replaced.lowerBound])
            }
            out.append(png[replaced.upperBound..<end])
        } else {
            let at = chunks[insertion].range.lowerBound
            out.append(png[start..<at])
            out.append(newChunk)
            out.append(png[at..<end])
        }
        return .success(out)
    }

    // MARK: - Chunks

    /// The chunks from the signature to `IEND`, each checked: whole, a length within the format's limit, a type of
    /// four ASCII letters, a CRC that matches. Bytes after `IEND` aren't chunks (nothing reads them) and are kept.
    static func walk(_ png: Data) -> Result<[Chunk], Refusal> {
        guard isPNG(png) else { return .failure(.notPNG) }
        var chunks: [Chunk] = []
        var i = png.startIndex + signature.count
        while true {
            guard png.endIndex - i >= 12 else { return .failure(.damaged(.truncated)) }
            let length = Int(bigEndian32(png, at: i))
            guard length <= maxChunkLength else { return .failure(.damaged(.badLength)) }
            guard png.endIndex - i - 12 >= length else { return .failure(.damaged(.truncated)) }
            let typeBytes = png[(i + 4)..<(i + 8)]
            guard typeBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else {
                return .failure(.damaged(.badType))
            }
            let end = i + 12 + length
            guard crc(png[(i + 4)..<(end - 4)]) == bigEndian32(png, at: end - 4) else { return .failure(.damaged(.badCRC)) }
            let chunk = Chunk(type: String(decoding: typeBytes, as: UTF8.self), range: i..<end)
            chunks.append(chunk)
            i = end
            if chunk.type == "IEND" { return .success(chunks) }
        }
    }

    /// Why a sequence of whole chunks can't be edited, or nil: `IHDR` first and only there, no critical chunk the
    /// format doesn't define, and at least one `IDAT`, all of them consecutive.
    private static func layoutRefusal(_ chunks: [Chunk]) -> Refusal? {
        if chunks.first?.type == "CgBI" { return .appleCrushed }
        guard chunks.first?.type == "IHDR", !chunks.dropFirst().contains(where: { $0.type == "IHDR" }) else {
            return .damaged(.misplacedHeader)
        }
        if let unknown = chunks.first(where: { $0.isCritical && !knownCriticalChunks.contains($0.type) }) {
            return .unknownCriticalChunk(unknown.type)
        }
        let imageData = chunks.indices.filter { chunks[$0].type == "IDAT" }
        guard let first = imageData.first, let last = imageData.last else { return .damaged(.noImageData) }
        guard last - first + 1 == imageData.count else { return .damaged(.splitImageData) }
        return nil
    }

    /// A chunk with this type and data, its length and CRC computed. `data` must be at most `maxChunkLength` bytes.
    static func chunk(type: String, data: Data) -> Data {
        let body = Data(type.utf8) + data
        var out = Data(capacity: body.count + 8)
        out.append(contentsOf: bytes(UInt32(data.count)))
        out.append(body)
        out.append(contentsOf: bytes(crc(body)))
        return out
    }

    /// The PNG CRC of `bytes` (ISO 3309 / ITU-T V.42, the same CRC-32 as zlib's), with the system's zlib.
    static func crc(_ bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { raw in
            UInt32(crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)))
        }
    }

    private static func bigEndian32(_ d: Data, at i: Int) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    private static func bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    // MARK: - Text chunks

    private enum TextKind { case xmp, xmpInText, xmpInRawProfile, other }

    /// What a `tEXt`, `zTXt` or `iTXt` chunk holds, as far as XMP goes.
    private static func textKind(_ chunk: Chunk, in png: Data) -> TextKind {
        let data = png[chunk.data]
        // A keyword is 1 to 79 bytes, then a null. Without the null, what follows reads as part of the keyword (a
        // different one); an XMP chunk with nothing after its keyword is then refused as unreadable.
        let keyword = data.prefix(80).prefix { $0 != 0 }
        if keyword.elementsEqual(xmpKeyword) { return chunk.type == "iTXt" ? .xmp : .xmpInText }
        let lowered = keyword.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }
        return lowered.starts(with: rawXMPProfileKeyword) ? .xmpInRawProfile : .other
    }

    /// Where an XMP `iTXt` chunk's parts are.
    private struct XMPText {
        /// Keyword, null, compression flag and method, language tag, null, translated keyword, null.
        let header: Range<Int>
        let text: Range<Int>
        let compressed: Bool
    }

    /// The parts of an XMP `iTXt` chunk, or nil if its header is cut short or names a compression it can't be read
    /// with (flag other than 0 or 1; method other than 0 for compressed text). For uncompressed text the method byte
    /// is ignored, as the format says, and kept.
    private static func xmpText(_ chunk: Chunk, in png: Data) -> XMPText? {
        let data = chunk.data
        let flags = data.lowerBound + xmpKeyword.count + 1
        guard flags + 2 <= data.upperBound else { return nil }
        let compressed: Bool
        switch (png[flags], png[flags + 1]) {
        case (0, _): compressed = false
        case (1, 0): compressed = true
        default: return nil
        }
        guard let languageEnd = png[(flags + 2)..<data.upperBound].firstIndex(of: 0),
              let translatedEnd = png[(languageEnd + 1)..<data.upperBound].firstIndex(of: 0) else { return nil }
        return XMPText(header: data.lowerBound..<(translatedEnd + 1), text: (translatedEnd + 1)..<data.upperBound,
                       compressed: compressed)
    }

    // MARK: - zlib

    /// The content of a zlib stream (RFC 1950, as PNG compresses text), or nil if it's damaged or cut short, has
    /// bytes after its end, or holds more than `limit` bytes.
    static func inflate(_ compressed: Data, limit: Int) -> Data? {
        var capacity = min(limit, max(4096, compressed.count * 4))
        while true {
            var out = Data(count: capacity)
            var outLength = uLong(capacity)
            var inLength = uLong(compressed.count)
            let status = out.withUnsafeMutableBytes { o in
                compressed.withUnsafeBytes { i in
                    uncompress2(o.bindMemory(to: Bytef.self).baseAddress, &outLength,
                                i.bindMemory(to: Bytef.self).baseAddress, &inLength)
                }
            }
            if status == Z_OK {
                guard inLength == uLong(compressed.count) else { return nil }
                out.count = Int(outLength)
                return out
            }
            guard status == Z_BUF_ERROR, capacity < limit else { return nil }
            capacity = min(limit, capacity * 4)
        }
    }

    /// `data` as a zlib stream, or nil if zlib fails (out of memory).
    static func deflate(_ data: Data) -> Data? {
        var length = compressBound(uLong(data.count))
        var out = Data(count: Int(length))
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                compress2(o.bindMemory(to: Bytef.self).baseAddress, &length, i.bindMemory(to: Bytef.self).baseAddress,
                          uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { return nil }
        out.count = Int(length)
        return out
    }
}
