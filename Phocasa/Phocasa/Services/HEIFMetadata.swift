import Foundation

/// Phocasa's rating and keywords inside a HEIF file (stub: refuses everything).
enum HEIFMetadata {
    enum Refusal: Error, Equatable, Sendable {
        case notHEIF, malformed, unsupportedTopLevelBox(String), unsupportedMetaBox(String), unsupportedVersion(String)
        case externalData, unsupportedConstruction, unboundedExtent, itemDataInsideMeta, ambiguousXMP, encodedXMP
        case xmpInSeveralExtents, appendedData, fieldTooSmall, updateRefused, unreadable, selfCheckFailed
    }

    enum Change: Equatable, Sendable { case inPlace, tail, appended, newItem }

    struct Written {
        let data: Data
        let change: Change
    }

    static func isHEIF(_ data: Data) -> Bool { false }

    static func replacingXMP(in heif: Data, update: (Data?) -> Data?) -> Data? { nil }

    static func writingXMP(in heif: Data, update: (Data?) -> Data?) -> Result<Written, Refusal> { .failure(.notHEIF) }
}
