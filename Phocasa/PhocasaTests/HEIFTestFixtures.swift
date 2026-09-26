import XCTest
import ImageIO
import CoreGraphics
import CoreVideo
import CryptoKit
@testable import Phocasa

// Fixtures and checks for rating writes into HEIF files (task D): an ISO BMFF reader written independently of the
// app's (`HEIFMetadata`), a builder that lays out the same items in any legal way (iloc versions and field sizes,
// base offsets, idat, mdat before meta, free boxes, several XMP items…), and ImageIO-written HEICs like an iPhone's.

// MARK: - Independent ISO BMFF reader (tests only)

/// A HEIF's boxes and item tables, read with `[UInt8]` and nothing from the app.
struct TestHEIF {
    struct Node {
        let type: String
        let start: Int
        let end: Int
        let header: Int
        var children: [Node] = []
        var bodyStart: Int { start + header }
    }

    struct Item: Equatable {
        let id: Int
        let version: Int
        let flags: Int
        let type: String
        let contentType: String?
        let contentEncoding: String?
        let entry: [UInt8]
    }

    struct Extent: Equatable {
        let index: Int
        let offset: Int
        let length: Int
    }

    struct Location: Equatable {
        let id: Int
        let method: Int
        let dataReference: Int
        let base: Int
        let extents: [Extent]
    }

    struct Reference: Equatable {
        let type: String
        let from: Int
        let to: [Int]
        let bytes: [UInt8]
    }

    let bytes: [UInt8]
    /// The same bytes, for slices and comparisons (`Data` compares with memcmp, `[UInt8]` byte by byte in Debug).
    let file: Data
    let top: [Node]
    let meta: Node
    let primary: Int
    let items: [Item]
    let ilocVersion: Int
    let ilocSizes: (offset: Int, length: Int, base: Int, index: Int)
    let locations: [Location]
    let references: [Reference]
    /// ipma: item (or group) ID → associations as written (essential bit included).
    let associations: [(id: Int, properties: [Int])]
    /// ipco's property boxes, whole.
    let properties: [[UInt8]]
    let groups: [(type: String, id: Int, entities: [Int])]

    private static let containers: Set<String> = ["meta", "iinf", "iref", "iprp", "ipco", "grpl", "dinf"]

    init?(_ data: Data) {
        let b = [UInt8](data)
        bytes = b
        file = Data(data)
        func be(_ at: Int, _ n: Int) -> Int? {
            guard n >= 0, at >= 0, at + n <= b.count else { return nil }
            return b[at..<(at + n)].reduce(0) { $0 << 8 | Int($1) }
        }
        func name(_ at: Int) -> String { String(decoding: b[at..<(at + 4)], as: UTF8.self) }
        func nodes(_ from: Int, _ to: Int, top: Bool) -> [Node]? {
            var out: [Node] = []
            var at = from
            while at < to {
                guard let small = be(at, 4), at + 8 <= to else { return nil }
                var size = small, header = 8
                if small == 1 { guard let large = be(at + 8, 8) else { return nil }; size = large; header = 16 }
                if small == 0 { guard top else { return nil }; size = to - at }
                guard size >= header, at + size <= to else { return nil }
                var node = Node(type: name(at + 4), start: at, end: at + size, header: header)
                if Self.containers.contains(node.type) {
                    // meta, iinf, iref and grpl's children follow a full-box header (iinf's also an entry count).
                    var first = node.bodyStart
                    switch node.type {
                    case "meta": first += 4
                    case "iinf": first += 4 + ((b[node.bodyStart] == 0) ? 2 : 4)
                    case "iref": first += 4
                    default: break
                    }
                    guard let children = nodes(first, node.end, top: false) else { return nil }
                    node.children = children
                }
                out.append(node)
                at += size
            }
            return out
        }
        guard let top = nodes(0, b.count, top: true), let meta = top.first(where: { $0.type == "meta" }) else { return nil }
        self.top = top
        self.meta = meta
        func child(_ type: String, _ of: Node) -> Node? { of.children.first { $0.type == type } }

        guard let pitm = meta.children.first(where: { $0.type == "pitm" }) else { return nil }
        primary = be(pitm.bodyStart + 4, b[pitm.bodyStart] == 0 ? 2 : 4) ?? -1

        // iinf / infe
        var items: [Item] = []
        for infe in child("iinf", meta)?.children ?? [] {
            let v = Int(b[infe.bodyStart]), flags = be(infe.bodyStart + 1, 3) ?? 0
            guard v >= 2 else { return nil }
            let idLength = v == 2 ? 2 : 4
            let id = be(infe.bodyStart + 4, idLength) ?? -1
            let typeAt = infe.bodyStart + 4 + idLength + 2
            let type = name(typeAt)
            let strings = b[(typeAt + 4)..<infe.end].split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            let contentType = type == "mime" && strings.count > 1 ? strings[1] : nil
            let encoding = type == "mime" && strings.count > 2 && !strings[2].isEmpty ? strings[2] : nil
            items.append(Item(id: id, version: v, flags: flags, type: type, contentType: contentType,
                              contentEncoding: encoding, entry: Array(b[infe.start..<infe.end])))
        }
        self.items = items

        // iloc
        guard let iloc = meta.children.first(where: { $0.type == "iloc" }) else { return nil }
        var at = iloc.bodyStart
        let v = Int(b[at])
        at += 4
        let o = Int(b[at] >> 4), l = Int(b[at] & 15), bo = Int(b[at + 1] >> 4), ix = v == 0 ? 0 : Int(b[at + 1] & 15)
        ilocVersion = v
        ilocSizes = (o, l, bo, ix)
        at += 2
        let idLength = v == 2 ? 4 : 2
        guard let count = be(at, idLength) else { return nil }
        at += idLength
        var locations: [Location] = []
        for _ in 0..<count {
            guard let id = be(at, idLength) else { return nil }
            at += idLength
            var method = 0
            if v >= 1 { method = (be(at, 2) ?? 0) & 15; at += 2 }
            guard let dri = be(at, 2), let base = be(at + 2, bo), let n = be(at + 2 + bo, 2) else { return nil }
            at += 4 + bo
            var extents: [Extent] = []
            for _ in 0..<n {
                guard let index = be(at, ix), let off = be(at + ix, o), let len = be(at + ix + o, l) else { return nil }
                extents.append(Extent(index: index, offset: off, length: len))
                at += ix + o + l
            }
            locations.append(Location(id: id, method: method, dataReference: dri, base: base, extents: extents))
        }
        guard at == iloc.end else { return nil }
        self.locations = locations

        // iref
        var references: [Reference] = []
        if let iref = child("iref", meta) {
            let small = b[iref.bodyStart] == 0
            let n = small ? 2 : 4
            for r in iref.children {
                guard let from = be(r.bodyStart, n), let c = be(r.bodyStart + n, 2) else { return nil }
                let to = (0..<c).compactMap { be(r.bodyStart + n + 2 + $0 * n, n) }
                references.append(Reference(type: r.type, from: from, to: to, bytes: Array(b[r.start..<r.end])))
            }
        }
        self.references = references

        // iprp
        var associations: [(Int, [Int])] = []
        var properties: [[UInt8]] = []
        if let iprp = child("iprp", meta) {
            properties = (child("ipco", iprp)?.children ?? []).map { Array(b[$0.start..<$0.end]) }
            for ipma in iprp.children where ipma.type == "ipma" {
                let v = Int(b[ipma.bodyStart]), wide = (b[ipma.bodyStart + 3] & 1) == 1
                var p = ipma.bodyStart + 4
                let n = be(p, 4) ?? 0
                p += 4
                for _ in 0..<n {
                    let id = be(p, v == 0 ? 2 : 4) ?? -1
                    p += v == 0 ? 2 : 4
                    let c = Int(b[p]); p += 1
                    var list: [Int] = []
                    for _ in 0..<c { list.append(be(p, wide ? 2 : 1) ?? -1); p += wide ? 2 : 1 }
                    associations.append((id, list))
                }
            }
        }
        self.associations = associations
        self.properties = properties

        var groups: [(String, Int, [Int])] = []
        for g in child("grpl", meta)?.children ?? [] {
            let id = be(g.bodyStart + 4, 4) ?? -1, n = be(g.bodyStart + 8, 4) ?? 0
            groups.append((g.type, id, (0..<n).compactMap { be(g.bodyStart + 12 + $0 * 4, 4) }))
        }
        self.groups = groups
    }

    func node(_ type: String) -> Node? { meta.children.first { $0.type == type } }

    func slice(_ node: Node) -> Data { file.subdata(in: node.start..<node.end) }

    /// Where item `id`'s bytes are, as file ranges (construction methods 0 and 1 only).
    func ranges(of id: Int) -> [Range<Int>]? {
        guard let location = locations.first(where: { $0.id == id }) else { return nil }
        let origin: Int
        switch location.method {
        case 0: origin = 0
        case 1: guard let idat = node("idat") else { return nil }; origin = idat.bodyStart
        default: return nil
        }
        return location.extents.map { (origin + location.base + $0.offset)..<(origin + location.base + $0.offset + $0.length) }
    }

    func data(of id: Int) -> Data? {
        guard let ranges = ranges(of: id), ranges.allSatisfy({ $0.upperBound <= bytes.count }) else { return nil }
        return ranges.reduce(into: Data()) { $0.append(file.subdata(in: $1)) }
    }

    var xmpItems: [Item] { items.filter { $0.type == "mime" && $0.contentType == "application/rdf+xml" } }

    /// The XMP item(s) with a `cdsc` reference to the primary image.
    var primaryXMP: [Item] {
        xmpItems.filter { item in references.contains { $0.type == "cdsc" && $0.from == item.id && $0.to.contains(primary) } }
    }
}

// MARK: - A HEIF builder (tests only)

/// Everything a HEIF says, as values: laid out again by `bytes(_:)` in whatever legal way a test asks for.
struct HEIFModel {
    struct Item {
        var id: Int
        var type: String
        var flags: Int
        var contentType: String? = nil
        var contentEncoding: String? = nil
        var data: [UInt8]
        /// Stored in `idat` (construction method 1) rather than `mdat`.
        var inIdat = false
        /// Split into this many extents.
        var extents = 1
        /// Its `iloc` entry's data reference index (0: this file).
        var dataReference = 0
        /// Its `iloc` construction method, when it isn't 0 or 1 (from `inIdat`).
        var method: Int? = nil
        /// Its extent's length written as 0.
        var zeroLength = false
        /// Located at this file offset (construction method 0) rather than in the mdat.
        var absoluteOffset: Int? = nil
    }

    var ftyp: [UInt8]
    var hdlr: [UInt8]
    var dinf: [UInt8]?
    var primary: Int
    var items: [Item]
    var references: [(type: String, from: Int, to: [Int])]
    var iprp: [UInt8]?
    var grpl: [UInt8]?

    struct Layout {
        var ilocVersion = 1
        var offsetSize = 4, lengthSize = 4, baseOffsetSize = 0, indexSize = 0
        /// With a base offset field: each item's first byte goes in it, its extents relative to it.
        var useBaseOffsets = false
        var iinfVersion = 0
        var irefVersion = 0
        var mdatBeforeMeta = false
        /// A `free` box of this size right after `meta`.
        var freeAfterMeta: Int? = nil
        /// The mdat's size field: 0 ("to the end of the file").
        var mdatToEnd = false
        /// The mdat's size in a 64-bit `largesize`.
        var mdatLargeSize = false
        /// Items (by ID) whose data goes last in the mdat, in this order.
        var last: [Int] = []
        /// Bytes after meta's other children and before iloc: an extra `free` box inside meta.
        var freeInMeta: Int? = nil
        /// A top-level box appended after everything (its type and payload).
        var trailingBox: (type: String, payload: [UInt8])? = nil
        /// An extra box at the end of meta.
        var extraMetaChild: [UInt8]? = nil
        /// `iloc` right after `pitm`, before `iinf` (as libheif writes it), rather than last.
        var ilocFirst = false
    }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be(payload.count + 8, 4) + Array(type.utf8) + payload }
    static func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// The model of an existing HEIF (read with `TestHEIF`).
    init?(_ heif: TestHEIF) {
        guard let ftypNode = heif.top.first(where: { $0.type == "ftyp" }), let hdlr = heif.node("hdlr") else { return nil }
        ftyp = [UInt8](heif.slice(ftypNode))
        self.hdlr = [UInt8](heif.slice(hdlr))
        dinf = heif.node("dinf").map { [UInt8](heif.slice($0)) }
        primary = heif.primary
        iprp = heif.node("iprp").map { [UInt8](heif.slice($0)) }
        grpl = heif.node("grpl").map { [UInt8](heif.slice($0)) }
        var items: [Item] = []
        for item in heif.items {
            guard let data = heif.data(of: item.id) else { return nil }
            let location = heif.locations.first { $0.id == item.id }
            items.append(Item(id: item.id, type: item.type, flags: item.flags, contentType: item.contentType,
                              contentEncoding: item.contentEncoding, data: [UInt8](data), inIdat: location?.method == 1))
        }
        self.items = items
        references = heif.references.map { ($0.type, $0.from, $0.to) }
    }

    /// The file, laid out as `layout` says: ftyp, meta (hdlr, dinf, pitm, iinf, iref, iprp, grpl, idat, iloc), mdat.
    func bytes(_ layout: Layout = Layout()) -> Data {
        // Item data: mdat order (layout.last at the end), idat order.
        let inMdat = items.filter { !$0.inIdat && !$0.data.isEmpty && $0.absoluteOffset == nil }
        let ordered = inMdat.filter { !layout.last.contains($0.id) } + layout.last.compactMap { id in inMdat.first { $0.id == id } }
        var idat: [UInt8] = []
        var idatOffsets: [Int: Int] = [:]
        for item in items where item.inIdat { idatOffsets[item.id] = idat.count; idat += item.data }

        func pieces(_ item: Item) -> [(Int, Int)] {
            // (offset within the item's data, length) for each extent.
            let n = max(1, min(item.extents, item.data.count))
            let step = item.data.count / n
            return (0..<n).map { k in (k * step, k == n - 1 ? item.data.count - k * step : step) }
        }

        func meta(mdatPayloadStart: Int) -> [UInt8] {
            var mdatOffsets: [Int: Int] = [:]
            var at = mdatPayloadStart
            for item in ordered { mdatOffsets[item.id] = at; at += item.data.count }

            var pitm: [UInt8] = [0, 0, 0, 0] + Self.be(primary, 2)
            if primary > 0xFFFF { pitm = [1, 0, 0, 0] + Self.be(primary, 4) }
            var iinf: [UInt8] = [UInt8(layout.iinfVersion), 0, 0, 0] + Self.be(items.count, layout.iinfVersion == 0 ? 2 : 4)
            for item in items {
                let v = item.id > 0xFFFF ? 3 : 2
                var e: [UInt8] = [UInt8(v)] + Self.be(item.flags, 3) + Self.be(item.id, v == 2 ? 2 : 4) + [0, 0] + Array(item.type.utf8) + [0]
                if let contentType = item.contentType {
                    e += Array(contentType.utf8) + [0]
                    if let encoding = item.contentEncoding { e += Array(encoding.utf8) + [0] }
                }
                iinf += Self.box("infe", e)
            }
            let idLength = layout.irefVersion == 0 ? 2 : 4
            var iref: [UInt8] = [UInt8(layout.irefVersion), 0, 0, 0]
            for r in references {
                iref += Self.box(r.type, Self.be(r.from, idLength) + Self.be(r.to.count, 2) + r.to.flatMap { Self.be($0, idLength) })
            }
            let v = layout.ilocVersion
            var iloc: [UInt8] = [UInt8(v), 0, 0, 0,
                                 UInt8(layout.offsetSize << 4 | layout.lengthSize),
                                 UInt8(layout.baseOffsetSize << 4 | (v == 0 ? 0 : layout.indexSize))]
            let located = items.filter { !$0.data.isEmpty }
            iloc += Self.be(located.count, v == 2 ? 4 : 2)
            for item in located {
                iloc += Self.be(item.id, v == 2 ? 4 : 2)
                if v >= 1 { iloc += Self.be(item.method ?? (item.inIdat ? 1 : 0), 2) }
                iloc += Self.be(item.dataReference, 2)
                let start = item.absoluteOffset ?? (item.inIdat ? idatOffsets[item.id]! : mdatOffsets[item.id]!)
                let base = layout.useBaseOffsets ? start : 0
                iloc += Self.be(base, layout.baseOffsetSize)
                let parts = pieces(item)
                iloc += Self.be(parts.count, 2)
                for (offset, length) in parts {
                    iloc += Self.be(0, v == 0 ? 0 : layout.indexSize)
                    iloc += Self.be(start + offset - base, layout.offsetSize) + Self.be(item.zeroLength ? 0 : length, layout.lengthSize)
                }
            }
            var children = hdlr + (dinf ?? []) + Self.box("pitm", pitm)
            if layout.ilocFirst { children += Self.box("iloc", iloc) }
            children += Self.box("iinf", iinf)
            if !references.isEmpty { children += Self.box("iref", iref) }
            children += (iprp ?? []) + (grpl ?? [])
            if !idat.isEmpty { children += Self.box("idat", idat) }
            if let free = layout.freeInMeta { children += Self.box("free", [UInt8](repeating: 0, count: free - 8)) }
            if !layout.ilocFirst { children += Self.box("iloc", iloc) }
            children += layout.extraMetaChild ?? []
            return Self.box("meta", [0, 0, 0, 0] + children)
        }

        var payload: [UInt8] = []
        for item in ordered { payload.append(contentsOf: item.data) }
        let mdatHeader = layout.mdatLargeSize ? 16 : 8
        func mdat() -> [UInt8] {
            if layout.mdatLargeSize { return Self.be(1, 4) + Array("mdat".utf8) + Self.be(payload.count + 16, 8) + payload }
            if layout.mdatToEnd { return Self.be(0, 4) + Array("mdat".utf8) + payload }
            return Self.box("mdat", payload)
        }
        let free = layout.freeAfterMeta.map { Self.box("free", [UInt8](repeating: 0, count: $0 - 8)) } ?? []
        var out: [UInt8]
        if layout.mdatBeforeMeta {
            let m = mdat()
            out = ftyp + m + meta(mdatPayloadStart: ftyp.count + mdatHeader) + free
        } else {
            let size = meta(mdatPayloadStart: 0).count
            out = ftyp + meta(mdatPayloadStart: ftyp.count + size + free.count + mdatHeader) + free + mdat()
        }
        if let trailing = layout.trailingBox { out += Self.box(trailing.type, trailing.payload) }
        return Data(out)
    }

    var maxID: Int { items.map(\.id).max() ?? 0 }

    /// Adds an XMP item describing the primary image.
    mutating func addXMP(_ packet: String, id: Int? = nil, describing: [Int]? = nil) {
        let id = id ?? maxID + 1
        items.append(Item(id: id, type: "mime", flags: 1, contentType: "application/rdf+xml", data: Array(packet.utf8)))
        references.append(("cdsc", id, describing ?? [primary]))
    }

    mutating func removeXMP() {
        let ids = Set(items.filter { $0.contentType == "application/rdf+xml" }.map(\.id))
        items.removeAll { ids.contains($0.id) }
        references.removeAll { ids.contains($0.from) }
    }
}

// MARK: - ImageIO-written HEICs

enum HEIFFixtures {
    /// A packet from another app that rates the photo 2 and tags it "old".
    static let otherAppXMP = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
        xmlns:acme="http://example.com/acme/1.0/"
       xmp:CreatorTool="OtherApp 2.0"
       xmp:Rating="2"
       xmp:Label="Blue"
       photoshop:City="Paris"
       acme:Flag="keep-me">
       <dc:creator><rdf:Seq><rdf:li>Ann Example</rdf:li></rdf:Seq></dc:creator>
       <dc:description><rdf:Alt><rdf:li xml:lang="x-default">A caption</rdf:li></rdf:Alt></dc:description>
       <dc:subject><rdf:Bag><rdf:li>old</rdf:li></rdf:Bag></dc:subject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    static func pattern(_ w: Int, _ h: Int, seed: Int = 0) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in stride(from: 0, to: h, by: 16) {
            for x in stride(from: 0, to: w, by: 16) {
                ctx.setFillColor(red: CGFloat((x + seed) % 256) / 255, green: CGFloat(y % 256) / 255,
                                 blue: CGFloat((x * 3 + y) % 256) / 255, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        return ctx.makeImage()!
    }

    static var exifProperties: [CFString: Any] { [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                                         kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
                                         kCGImagePropertyExifUserComment: "keep me",
                                         kCGImagePropertyExifLensModel: "50mm F1.8",
                                         kCGImagePropertyExifFNumber: 1.8,
                                         kCGImagePropertyExifISOSpeedRatings: [200]],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Model X"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E",
                                        kCGImagePropertyGPSAltitude: 35.0],
        kCGImagePropertyOrientation: 6,
    ] }

    /// `exifProperties` without a capture date. ImageIO, like the iPhone, writes an XMP item (`photoshop:DateCreated`)
    /// for a capture date; without one there is none.
    static var exifPropertiesWithoutCaptureDate: [CFString: Any] {
        var properties = exifProperties
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = nil
        exif[kCGImagePropertyExifOffsetTimeOriginal] = nil
        properties[kCGImagePropertyExifDictionary] = exif
        return properties
    }

    /// An iPhone-like HEIC from ImageIO (Apple's HEIF writer, as the camera's): a grid of 512×512 tiles above 512
    /// pixels, Exif (camera, GPS, capture date), an XMP item (`xmp`, when given), an embedded thumbnail, and, with
    /// `auxiliary`, a disparity map, an HDR gain map and a portrait matte, each an `auxl` image with its own XMP item.
    static func heic(width: Int = 1024, height: Int = 768, xmp: String? = otherAppXMP, exif: Bool = true,
                     thumbnail: Bool = true, auxiliary: Bool = false, type: String = "public.heic") -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil)!
        var properties: [CFString: Any] = exif ? (xmp == nil ? exifPropertiesWithoutCaptureDate : exifProperties) : [:]
        if thumbnail { properties[kCGImageDestinationEmbedThumbnail] = true }
        if let xmp {
            let meta = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData)!
            CGImageDestinationAddImageAndMetadata(destination, pattern(width, height), meta, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, pattern(width, height), properties as CFDictionary)
        }
        if auxiliary { addAuxiliaryImages(to: destination, width: width / 4, height: height / 4) }
        precondition(CGImageDestinationFinalize(destination))
        return out as Data
    }

    static func addAuxiliaryImages(to destination: CGImageDestination, width w: Int, height h: Int) {
        var disparity = [UInt16](repeating: 0, count: w * h)
        for i in disparity.indices { disparity[i] = UInt16(0x3000 + (i % 1024)) }
        let disparityInfo: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: disparity.withUnsafeBytes { Data($0) },
            kCGImageAuxiliaryDataInfoDataDescription: [kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat16,
                                                       kCGImagePropertyWidth: w, kCGImagePropertyHeight: h,
                                                       kCGImagePropertyBytesPerRow: w * 2] as [CFString: Any],
        ]
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, disparityInfo as CFDictionary)
        let oneChannel: [CFString: Any] = [kCGImagePropertyPixelFormat: kCVPixelFormatType_OneComponent8,
                                           kCGImagePropertyWidth: w, kCGImagePropertyHeight: h, kCGImagePropertyBytesPerRow: w]
        let gainMeta = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(gainMeta, "http://ns.apple.com/HDRGainMap/1.0/" as CFString,
                                                  "HDRGainMap" as CFString, nil)
        CGImageMetadataSetValueWithPath(gainMeta, nil, "HDRGainMap:HDRGainMapVersion" as CFString, "65536" as CFString)
        let gain = Data((0..<(w * h)).map { UInt8($0 % 251) })
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeHDRGainMap, [
            kCGImageAuxiliaryDataInfoData: gain, kCGImageAuxiliaryDataInfoDataDescription: oneChannel,
            kCGImageAuxiliaryDataInfoMetadata: gainMeta,
        ] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypePortraitEffectsMatte, [
            kCGImageAuxiliaryDataInfoData: Data(gain.reversed()), kCGImageAuxiliaryDataInfoDataDescription: oneChannel,
        ] as CFDictionary)
    }

    /// An HDR photo as iOS 18 writes one: an SDR base, an ISO 21496-1 gain map (a `tmap` derived item in `idat`),
    /// and an `altr` entity group in `grpl`.
    @available(macOS 15, *)
    static func isoGainMapHEIC() -> Data {
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
        let ctx = CGContext(data: nil, width: 1024, height: 768, bitsPerComponent: 16, bytesPerRow: 0, space: cs, bitmapInfo: info)!
        for x in stride(from: 0, to: 1024, by: 32) {
            let v = CGFloat(x) / 1024 * 4
            ctx.setFillColor(CGColor(colorSpace: cs, components: [v, v * 0.8, v * 0.5, 1])!)
            ctx.fill(CGRect(x: x, y: 0, width: 32, height: 768))
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.heic" as CFString, 1, nil)!
        var properties = exifPropertiesWithoutCaptureDate
        properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
        CGImageDestinationAddImage(destination, ctx.makeImage()!, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// A spatial (stereo) photo: two images in a `ster` entity group, which has a property of its own in `ipma`.
    static func stereoHEIC() -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.heic" as CFString, 2, nil)!
        for (index, left) in [true, false].enumerated() {
            var group: [CFString: Any] = [kCGImagePropertyGroupIndex: 0, kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair]
            group[left ? kCGImagePropertyGroupImageIsLeftImage : kCGImagePropertyGroupImageIsRightImage] = true
            var properties: [CFString: Any] = [kCGImagePropertyGroups: group]
            if index == 0 { properties.merge(exifPropertiesWithoutCaptureDate) { $1 } }
            CGImageDestinationAddImage(destination, pattern(640, 480, seed: index * 40), properties as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// An image sequence (`.heics`): a `moov` track as well as items.
    static func sequenceHEICS() -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.heics" as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, pattern(320, 240), nil)
        CGImageDestinationAddImage(destination, pattern(320, 240, seed: 80), nil)
        precondition(CGImageDestinationFinalize(destination))
        return out as Data
    }
}

// MARK: - The check: nothing lost

enum HEIFProof {
    /// ImageIO's decode of image `index`, as RGBA8 bytes.
    static func pixels(_ data: Data, index: Int = 0) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        return render(image)
    }

    static func render(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        var out = Data(count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? out : nil
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: false, kCGImageSourceThumbnailMaxPixelSize: 100_000,
              ] as CFDictionary) else { return nil }
        return render(thumb)
    }

    static var auxiliaryTypes: [CFString] {
        var types = [
            kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
        ]
        if #available(macOS 15, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        return types
    }

    static func auxiliary(_ data: Data, index: Int = 0) -> [String: String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        var out: [String: String] = [:]
        for type in auxiliaryTypes {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) as? [String: Any] else { continue }
            let bytes = (info[kCGImageAuxiliaryDataInfoData as String] as? Data)
                .map { "\($0.count) bytes, SHA-256 \(SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined())" } ?? "-"
            let description = (info[kCGImageAuxiliaryDataInfoDataDescription as String]).map { "\($0)" } ?? "-"
            var metadata = "-"
            if let value = info[kCGImageAuxiliaryDataInfoMetadata as String], CFGetTypeID(value as CFTypeRef) == CGImageMetadataGetTypeID() {
                metadata = KeptMetadata.xmpValues(value as! CGImageMetadata).sorted { $0.key < $1.key }.description
            }
            out[type as String] = "\(bytes) \(description) \(metadata)"
        }
        return out
    }

    static func properties(_ data: Data, index: Int = 0) -> [String: Any] {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, index, nil) as? [String: Any] } ?? [:]
    }

    static func metadataValues(_ data: Data, index: Int = 0) -> [String: String] {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyMetadataAtIndex($0, index, nil) }.map(KeptMetadata.xmpValues) ?? [:]
    }

    /// Phocasa's values, which may change: in the XMP, and ImageIO's IPTC view of it.
    static let changeable = ["xmp:Rating", "dc:subject"]

    /// Asserts that `output`, written from `original`, lost and changed nothing but the primary image's XMP packet,
    /// read with `TestHEIF` (not the app's parser) and with ImageIO:
    /// - the primary item, every original item entry (`infe`, byte for byte), reference (byte for byte), property and
    ///   property association, entity group, and every other `meta` child but `iinf`, `iref` and `iloc`, unchanged;
    ///   at most one new item, an XMP item with a `cdsc` reference to the primary;
    /// - every original item's data, but the XMP item's, identical and reachable through the new `iloc`;
    /// - every top-level box but `meta` and the last `mdat` byte for byte (moved at most); at most one new `mdat`;
    /// - ImageIO: every image decodes to the same pixels, the thumbnail and every auxiliary image are identical,
    ///   every property key and value is kept (Phocasa's IPTC view excepted), every XMP value other than
    ///   `xmp:Rating` and `dc:subject` is kept, and the rating and keywords read back.
    static func assertLossless(original: Data, output: Data, rating: Int, keywords: [String],
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let a = TestHEIF(original), let b = TestHEIF(output) else {
            return XCTFail("both files parse", file: file, line: line)
        }
        XCTAssertEqual(b.primary, a.primary, "primary item", file: file, line: line)

        // Items: the originals, entry bytes identical, plus at most one new XMP item.
        let originalIDs = Set(a.items.map(\.id))
        for item in a.items {
            XCTAssertEqual(b.items.first { $0.id == item.id }?.entry, item.entry, "infe of item \(item.id)", file: file, line: line)
        }
        let added = b.items.filter { !originalIDs.contains($0.id) }
        XCTAssertLessThanOrEqual(added.count, 1, "at most one new item", file: file, line: line)
        for item in added {
            XCTAssertEqual(item.type, "mime", file: file, line: line)
            XCTAssertEqual(item.contentType, "application/rdf+xml", file: file, line: line)
            XCTAssertTrue(a.primaryXMP.isEmpty, "a new item only when there was no XMP", file: file, line: line)
        }
        let xmpID = b.primaryXMP.first?.id
        XCTAssertEqual(b.primaryXMP.count, 1, "one XMP item describes the primary", file: file, line: line)
        if let old = a.primaryXMP.first { XCTAssertEqual(xmpID, old.id, "the same XMP item", file: file, line: line) }

        // References: every original one, byte for byte; a new one only for the new item.
        for reference in a.references {
            XCTAssertTrue(b.references.contains { $0.bytes == reference.bytes }, "reference \(reference.type) from \(reference.from)",
                          file: file, line: line)
        }
        let newReferences = b.references.filter { r in !a.references.contains { $0.bytes == r.bytes } }
        XCTAssertEqual(newReferences.map { "\($0.type) \($0.from)->\($0.to)" },
                       added.map { "cdsc \($0.id)->[\(a.primary)]" }, "new references", file: file, line: line)
        XCTAssertEqual(b.references.map(\.bytes).filter { r in a.references.contains { $0.bytes == r } },
                       a.references.map(\.bytes), "the original references in order", file: file, line: line)

        // Properties, associations, groups, and the meta children that don't change.
        XCTAssertEqual(b.properties, a.properties, "ipco properties", file: file, line: line)
        XCTAssertEqual(b.associations.map { "\($0.id):\($0.properties)" }, a.associations.map { "\($0.id):\($0.properties)" },
                       "ipma associations", file: file, line: line)
        XCTAssertEqual(b.groups.map { "\($0.type) \($0.id) \($0.entities)" }, a.groups.map { "\($0.type) \($0.id) \($0.entities)" },
                       "entity groups", file: file, line: line)
        // The old packet's bytes may change only where the new packet was written over them (in place, or at the
        // tail): same construction method, same start.
        let oldXMP = a.primaryXMP.first.flatMap { item in a.locations.first { $0.id == item.id } }
        let newXMP = xmpID.flatMap { id in b.locations.first { $0.id == id } }
        let overwritten = oldXMP != nil && oldXMP?.method == newXMP?.method
            && a.ranges(of: oldXMP!.id)?.first?.lowerBound == b.ranges(of: newXMP!.id)?.first?.lowerBound
        let overwrittenIn = { (method: Int) -> [Range<Int>] in
            overwritten && oldXMP?.method == method ? (a.ranges(of: oldXMP!.id) ?? []) : []
        }
        for type in ["hdlr", "dinf", "pitm", "iprp", "grpl", "idat"] {
            var x = a.node(type).map(a.slice), y = b.node(type).map(b.slice)
            if type == "idat", let node = a.node(type) {
                for r in overwrittenIn(1) { for k in r { x?[k - node.start] = 0; y?[k - node.start] = 0 } }
            }
            XCTAssertEqual(y, x, "meta's \(type), byte for byte", file: file, line: line)
        }
        XCTAssertEqual(b.meta.children.map(\.type).filter { $0 != "iref" }, a.meta.children.map(\.type).filter { $0 != "iref" },
                       "meta's children", file: file, line: line)

        // Every original item's data, through the new iloc.
        for item in a.items where item.id != xmpID {
            XCTAssertEqual(b.data(of: item.id), a.data(of: item.id), "data of item \(item.id) (\(item.type))", file: file, line: line)
        }
        for location in a.locations where location.id != xmpID {
            let now = b.locations.first { $0.id == location.id }
            XCTAssertEqual(now?.method, location.method, "item \(location.id) construction method", file: file, line: line)
            XCTAssertEqual(now?.dataReference, location.dataReference, file: file, line: line)
            XCTAssertEqual(now?.extents.map(\.length), location.extents.map(\.length), "item \(location.id) extents", file: file, line: line)
        }

        // The tables' own headers: versions, flags, field sizes.
        for type in ["iinf", "iref", "iloc"] {
            if let x = a.node(type), let y = b.node(type) {
                XCTAssertEqual(b.bytes[y.bodyStart..<(y.bodyStart + 4)], a.bytes[x.bodyStart..<(x.bodyStart + 4)],
                               "\(type) version and flags", file: file, line: line)
            }
        }
        XCTAssertEqual("\(b.ilocSizes)", "\(a.ilocSizes)", "iloc field sizes", file: file, line: line)

        // Top-level boxes: every one but meta byte for byte (moved at most), apart from the old packet's bytes, and
        // for the last box, its size and what follows a cut at the old packet (a tail rewrite) or its end (a last
        // mdat that runs to the end of the file, which the new packet joins). At most one new mdat, at the end.
        let types = b.top.map(\.type)
        XCTAssertTrue(types == a.top.map(\.type) || types == a.top.map(\.type) + ["mdat"], "top-level boxes \(types)",
                      file: file, line: line)
        let oldPacket = overwrittenIn(0)
        for (i, x) in a.top.enumerated() where x.type != "meta" && i < b.top.count {
            let y = b.top[i]
            var xb = a.slice(x), yb = b.slice(y)
            let inside = oldPacket.filter { $0.lowerBound >= x.start && $0.upperBound <= x.end }
            for r in inside { for k in r { let j = k - x.start; xb[j] = 0; if j < yb.count { yb[j] = 0 } } }
            if i == a.top.count - 1 && yb.count != xb.count {
                let cut = inside.filter { $0.upperBound == x.end }.map { $0.lowerBound - x.start }.min() ?? xb.count
                for j in [0, 1, 2, 3] + (x.header == 16 ? Array(8..<16) : []) { xb[j] = 0; yb[j] = 0 }
                XCTAssertEqual(yb.prefix(cut), xb.prefix(cut), "the last \(x.type) up to the old packet",
                               file: file, line: line)
            } else {
                XCTAssertEqual(yb, xb, "top-level \(x.type) at \(x.start), byte for byte", file: file, line: line)
            }
        }

        // ImageIO.
        let sourceA = CGImageSourceCreateWithData(original as CFData, nil)!, sourceB = CGImageSourceCreateWithData(output as CFData, nil)!
        XCTAssertEqual(CGImageSourceGetStatus(sourceB), .statusComplete, file: file, line: line)
        XCTAssertEqual(CGImageSourceGetCount(sourceB), CGImageSourceGetCount(sourceA), "image count", file: file, line: line)
        XCTAssertEqual(CGImageSourceGetPrimaryImageIndex(sourceB), CGImageSourceGetPrimaryImageIndex(sourceA), file: file, line: line)
        for index in 0..<CGImageSourceGetCount(sourceA) {
            let before = pixels(original, index: index)
            XCTAssertNotNil(before, "fixture: image \(index) decodes", file: file, line: line)
            XCTAssertTrue(before == pixels(output, index: index), "image \(index): identical pixels", file: file, line: line)
            XCTAssertEqual(auxiliary(output, index: index), auxiliary(original, index: index), "image \(index): auxiliary images",
                           file: file, line: line)
            // Every property, every key: Phocasa's IPTC view (ImageIO's reading of the XMP rating and keywords, a new
            // {IPTC} dictionary when there was none) excepted.
            let p = properties(original, index: index), q = properties(output, index: index)
            XCTAssertTrue(Set(p.keys).isSubset(of: q.keys), "image \(index): every property key kept", file: file, line: line)
            XCTAssertTrue(Set(q.keys).subtracting(p.keys).isSubset(of: ["{IPTC}"]), "image \(index): new keys \(Set(q.keys).subtracting(p.keys))",
                          file: file, line: line)
            if p["{IPTC}"] == nil, let iptc = q["{IPTC}"] as? [String: Any] {
                XCTAssertTrue(Set(iptc.keys).isSubset(of: ["Keywords", "StarRating"]), "a new {IPTC} holds only Phocasa's values",
                              file: file, line: line)
            }
            for (key, value) in p {
                if key == "{IPTC}", var iptcA = value as? [String: Any], var iptcB = q[key] as? [String: Any] {
                    for k in ["Keywords", "StarRating"] { iptcA[k] = nil; iptcB[k] = nil }
                    XCTAssertEqual("\(iptcB as NSDictionary)", "\(iptcA as NSDictionary)", "{IPTC}", file: file, line: line)
                } else {
                    XCTAssertEqual(q[key].map { "\($0)" }, "\(value)", "image \(index): property \(key)", file: file, line: line)
                }
            }
        }
        XCTAssertTrue(thumbnail(output) == thumbnail(original), "the thumbnail", file: file, line: line)

        // Every XMP value, from ImageIO's merged view, but Phocasa's.
        let valuesA = metadataValues(original), valuesB = metadataValues(output)
        for (path, value) in valuesA where !changeable.contains(where: { path == $0 || path.hasPrefix($0 + "[") }) {
            XCTAssertEqual(valuesB[path], value, "XMP \(path)", file: file, line: line)
        }
        XCTAssertEqual(valuesB["xmp:Rating"], "\(rating)", "rating read back by ImageIO", file: file, line: line)
        XCTAssertEqual(subject(valuesB), keywords, "keywords read back by ImageIO", file: file, line: line)
    }

    /// `dc:subject`'s items, in order, from `KeptMetadata.xmpValues`.
    static func subject(_ values: [String: String]) -> [String] {
        values.compactMap { key, value -> (Int, String)? in
            guard key.hasPrefix("dc:subject["), let index = Int(key.dropFirst("dc:subject[".count).dropLast()) else { return nil }
            return (index, value)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
