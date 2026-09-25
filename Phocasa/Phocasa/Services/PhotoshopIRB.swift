import Foundation
import CryptoKit

/// A JPEG's APP13 segment: Photoshop image resources ("8BIM" blocks), one of which (0x0404) holds the IPTC-IIM
/// datasets. Phocasa changes only what it must and keeps every other byte:
/// - a keyword write replaces the IIM keyword datasets (2:25) and nothing else, and updates the IPTC digest
///   (0x0425) to match; every other resource and dataset stays byte for byte;
/// - an export drops the thumbnail resources (0x0409, 0x040C), which show the old pixels.
/// ImageIO's own rewrite rebuilds the segment from what it models and drops custom resources and datasets.
enum PhotoshopIRB {
    private static let header = JPEGStructure.iptcID
    private static let signatures: [Data] = ["8BIM", "MeSa", "PHUT", "AgHg", "DCSR"].map { Data($0.utf8) }

    static let iptcResource: UInt16 = 0x0404
    static let digestResource: UInt16 = 0x0425
    static let thumbnailResources: Set<UInt16> = [0x0409, 0x040C]

    /// One resource block, with its bytes as they are in the file.
    struct Resource {
        let id: UInt16
        /// The whole block: signature, id, padded name, size, data, padding.
        let block: Data
        /// Where the data is inside `block`.
        let data: Range<Int>

        var dataBytes: Data { block[data] }

        /// This block with new data (signature, id and name kept).
        func replacingData(_ new: Data) -> Resource {
            let nameEnd = data.lowerBound - 4
            var b = Data(block[block.startIndex..<nameEnd])
            b += [UInt8(new.count >> 24 & 0xFF), UInt8(new.count >> 16 & 0xFF), UInt8(new.count >> 8 & 0xFF), UInt8(new.count & 0xFF)]
            let start = b.count
            b += new
            if new.count % 2 == 1 { b.append(0) }
            return Resource(id: id, block: b, data: start..<(start + new.count))
        }
    }

    /// The resources in an APP13 payload, and the zero padding after them (some writers pad), or nil if it isn't a
    /// well-formed run of resource blocks.
    static func resources(in payload: Data) -> (resources: [Resource], padding: Data)? {
        let p = Data(payload)
        guard p.starts(with: header) else { return nil }
        var i = header.count
        var out: [Resource] = []
        while i < p.count {
            if p[i...].allSatisfy({ $0 == 0 }) { return (out, Data(p[i...])) }
            guard i + 12 <= p.count, signatures.contains(p[i..<(i + 4)]) else { return nil }
            let id = UInt16(p[i + 4]) << 8 | UInt16(p[i + 5])
            let nameLength = Int(p[i + 6])
            var j = i + 6 + 1 + nameLength
            if (1 + nameLength) % 2 == 1 { j += 1 }
            guard j + 4 <= p.count else { return nil }
            let size = Int(p[j]) << 24 | Int(p[j + 1]) << 16 | Int(p[j + 2]) << 8 | Int(p[j + 3])
            let dataStart = j + 4
            guard size >= 0, dataStart + size <= p.count else { return nil }
            let end = min(p.count, dataStart + size + size % 2)
            out.append(Resource(id: id, block: Data(p[i..<end]), data: (dataStart - i)..<(dataStart - i + size)))
            i = end
        }
        return (out, Data())
    }

    static func payload(_ resources: [Resource], padding: Data) -> Data {
        resources.reduce(into: header) { $0 += $1.block } + padding
    }

    /// `payload` with its IPTC keywords replaced by `keywords` (every other resource and dataset kept byte for byte,
    /// the digest updated). The payload itself when it has no IPTC resource: then the keywords live in XMP only. Nil
    /// when it can't be done safely: malformed resources or datasets, or non-ASCII keywords in IPTC text of unknown
    /// encoding.
    static func replacingKeywords(in payload: Data, with keywords: [String]) -> Data? {
        guard var (resources, padding) = resources(in: payload) else { return nil }
        guard let index = resources.firstIndex(where: { $0.id == iptcResource }) else { return payload }
        guard let iim = IPTCIIM.replacingKeywords(in: resources[index].dataBytes, with: keywords) else { return nil }
        resources[index] = resources[index].replacingData(iim)
        for (i, resource) in resources.enumerated() where resource.id == digestResource {
            resources[i] = resource.replacingData(Data(Insecure.MD5.hash(data: iim)))
        }
        return self.payload(resources, padding: padding)
    }

    /// `payload` without thumbnail resources, or nil if its resources are malformed.
    static func removingThumbnails(from payload: Data) -> Data? {
        guard let (resources, padding) = resources(in: payload) else { return nil }
        return self.payload(resources.filter { !thumbnailResources.contains($0.id) }, padding: padding)
    }
}

/// IPTC-IIM datasets: 0x1C, record, dataset number, a 2-byte big-endian length, the value.
enum IPTCIIM {
    struct DataSet {
        let record: UInt8
        let number: UInt8
        /// The whole dataset, as it is in the file.
        let bytes: Data
        let value: Data
    }

    /// 1:90 CodedCharacterSet saying the text is UTF-8 (ESC % G).
    static let utf8Declaration = Data([0x1B, 0x25, 0x47])

    /// The datasets, or nil if the data isn't a well-formed run of standard datasets (extended lengths included).
    static func dataSets(in data: Data) -> [DataSet]? {
        let d = Data(data)
        var i = 0, out: [DataSet] = []
        while i < d.count {
            // Some writers pad the resource with zeros.
            if d[i...].allSatisfy({ $0 == 0 }) { break }
            guard i + 5 <= d.count, d[i] == 0x1C else { return nil }
            let length = Int(d[i + 3]) << 8 | Int(d[i + 4])
            guard length & 0x8000 == 0, i + 5 + length <= d.count else { return nil }
            out.append(DataSet(record: d[i + 1], number: d[i + 2], bytes: Data(d[i..<(i + 5 + length)]),
                               value: Data(d[(i + 5)..<(i + 5 + length)])))
            i += 5 + length
        }
        return out
    }

    static func dataSet(_ record: UInt8, _ number: UInt8, _ value: Data) -> Data? {
        guard value.count < 0x8000 else { return nil }
        return Data([0x1C, record, number, UInt8(value.count >> 8), UInt8(value.count & 0xFF)]) + value
    }

    /// `data` with its keyword datasets (2:25) replaced by `keywords`, in UTF-8, where the first one was (or in
    /// dataset order); every other dataset byte for byte, trailing padding included. Non-ASCII keywords need the
    /// text to be UTF-8: a missing 1:90 is added when all the existing text is ASCII; otherwise nil.
    static func replacingKeywords(in data: Data, with keywords: [String]) -> Data? {
        guard let sets = dataSets(in: data) else { return nil }
        let consumed = sets.reduce(0) { $0 + $1.bytes.count }
        let padding = Data(data).suffix(from: consumed)

        let isKeyword = { (s: DataSet) in s.record == 2 && s.number == 25 }
        let newKeywords = keywords.map { Data($0.utf8) }
        let needsUTF8 = newKeywords.contains { $0.contains { $0 >= 0x80 } }
        let declaresUTF8 = sets.contains { $0.record == 1 && $0.number == 90 && $0.value == utf8Declaration }
        var addDeclaration = false
        if needsUTF8 && !declaresUTF8 {
            let othersASCII = sets.filter { !isKeyword($0) }.allSatisfy { !$0.value.contains { $0 >= 0x80 } }
            guard othersASCII, !sets.contains(where: { $0.record == 1 && $0.number == 90 }) else { return nil }
            addDeclaration = true
        }

        var keywordBytes = Data()
        for keyword in newKeywords {
            guard let set = dataSet(2, 25, keyword) else { return nil }
            keywordBytes += set
        }
        let insertAt = sets.firstIndex(where: isKeyword)
            ?? sets.firstIndex { ($0.record == 2 && $0.number > 25) || $0.record > 2 }
            ?? sets.count
        var out = Data()
        if addDeclaration, let declaration = dataSet(1, 90, utf8Declaration) {
            // Record 1 comes first; 1:90 goes after any record-1 datasets numbered below it.
            let at = sets.firstIndex { $0.record > 1 || ($0.record == 1 && $0.number > 90) } ?? sets.count
            for (i, set) in sets.enumerated() {
                if i == at { out += declaration }
                if i == insertAt { out += keywordBytes }
                if !isKeyword(set) { out += set.bytes }
            }
            if at == sets.count { out += declaration }
        } else {
            for (i, set) in sets.enumerated() {
                if i == insertAt { out += keywordBytes }
                if !isKeyword(set) { out += set.bytes }
            }
        }
        if insertAt == sets.count { out += keywordBytes }
        return out + padding
    }
}
