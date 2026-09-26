import Foundation

/// A classic TIFF's rating and keywords, written into the file itself, additively (stub).
enum TIFFMetadata {
    enum Refusal: Error, Equatable, Sendable {
        case notTIFF
        case bigTIFF
        case outOfBounds
        case malformedIFD
        case ifdLoop
        case unknownFieldType
        case duplicateMetadataTag
        case unsortedIFD0
        case unexpectedFieldType(UInt16)
        case xmpInPhotoshopResources
        case iptcNotPatchable
        case xmpNotUpdatable
        case offsetsBeyond4GB
    }

    static func isTIFF(_ data: Data) -> Bool { false }

    static func replacingXMP(in tiff: Data, update: (Data?) -> Data?, keywords: [String]) -> Data? {
        try? rewrite(tiff, update: update, keywords: keywords).get()
    }

    static func rewrite(_ tiff: Data, update: (Data?) -> Data?, keywords: [String],
                        offsetLimit: Int = Int(UInt32.max)) -> Result<Data, Refusal> {
        .failure(.notTIFF)
    }
}
