import Foundation
import UniformTypeIdentifiers

struct DiscoveredPhoto: Sendable {
    let fileName: String
    let jpgPath: String?
    let rawPath: String?
    let folderPath: String
    let fileSize: Int64
    let creationDate: Date?
}

final class FolderScanner: Sendable {
    static let standardExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif"
    ]

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2",
        "pef", "srw", "3fr", "iiq", "rwl", "raw", "mrw", "dcr"
    ]

    static let allExtensions: Set<String> = standardExtensions.union(rawExtensions)

    func scan(folderURL: URL) async -> [DiscoveredPhoto] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results = self.scanSync(folderURL: folderURL)
                continuation.resume(returning: results)
            }
        }
    }

    private func scanSync(folderURL: URL) -> [DiscoveredPhoto] {
        var filesByFolder: [String: [String: [(url: URL, isRaw: Bool, fileSize: Int64, creationDate: Date?)]]] = [:]

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard Self.allExtensions.contains(ext) else { continue }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey]),
                  resourceValues.isRegularFile == true else { continue }

            let stem = fileURL.deletingPathExtension().lastPathComponent
            let folder = fileURL.deletingLastPathComponent().path
            let isRaw = Self.rawExtensions.contains(ext)
            let fileSize = Int64(resourceValues.fileSize ?? 0)

            filesByFolder[folder, default: [:]][stem, default: []].append(
                (url: fileURL, isRaw: isRaw, fileSize: fileSize, creationDate: resourceValues.creationDate)
            )
        }

        var results: [DiscoveredPhoto] = []

        for (folder, stems) in filesByFolder {
            for (stem, files) in stems {
                var jpgPath: String?
                var rawPath: String?
                var totalSize: Int64 = 0
                var creationDate: Date?

                for file in files {
                    totalSize += file.fileSize

                    if creationDate == nil {
                        creationDate = file.creationDate
                    }

                    if file.isRaw {
                        rawPath = file.url.path
                    } else {
                        if jpgPath == nil {
                            jpgPath = file.url.path
                        }
                    }
                }

                results.append(DiscoveredPhoto(
                    fileName: stem,
                    jpgPath: jpgPath,
                    rawPath: rawPath,
                    folderPath: folder,
                    fileSize: totalSize,
                    creationDate: creationDate
                ))
            }
        }

        results.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        return results
    }
}
