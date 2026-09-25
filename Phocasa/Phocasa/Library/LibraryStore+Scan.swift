import SwiftData
import Foundation

extension LibraryStore {
    /// State only the scan code uses, stored in `scanning`.
    struct ScanState {
        /// The scan in progress. Scans run one at a time (spec §B3).
        var task: Task<Void, Never>?
        /// A scan requested while one was running; it runs once that one ends. Repeated requests coalesce, and
        /// the latest folder wins.
        var queuedURL: URL?
        /// Total of the metadata reads in progress, while `scanProgress` shows their count.
        var metadataProgressTotal: Int?
    }

    // MARK: - Folder Opening

    func handleFolderSelected(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }

        let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        guard let context = modelContext else { return }

        if let library = currentLibrary {
            library.rootFolderPath = url.path
            library.bookmarkData = bookmarkData
        } else {
            let library = PhotoLibrary(rootFolderPath: url.path, bookmarkData: bookmarkData)
            context.insert(library)
            currentLibrary = library
        }

        scanFolder(url: url)
    }

    func rescanCurrentLibrary() {
        guard let library = currentLibrary else { return }

        var isStale = false
        if let bookmarkData = library.bookmarkData,
           let url = try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            _ = url.startAccessingSecurityScopedResource()
            scanFolder(url: url)
        } else {
            let url = URL(fileURLWithPath: library.rootFolderPath)
            scanFolder(url: url)
        }
    }

    /// Returns once no scan is running or queued, the launch rescan included.
    func waitForScans() async {
        while let task = scanning.task {
            await task.value
        }
    }

    // MARK: - Scanning

    /// What a scan did. For tests and benchmarks.
    struct ScanReport {
        var discovered = 0
        var inserted = 0
        /// Existing rows whose paths, size or bin state the scan changed.
        var updated = 0
        var missing = 0
        /// Whether the scan ended in a full `loadExistingData()`.
        var reloaded = false
        /// Time the scan spent in its synchronous main-actor sections (spec §B1, §B2).
        var mainActorTime: Duration = .zero
    }

    /// New photos inserted per main-actor turn. Between chunks the scan saves and yields, so a big import
    /// never holds the main actor for more than a few tens of milliseconds at a time.
    private static let scanInsertChunkSize = 256

    /// Starts a scan of `url`, or queues one if a scan is running. `isScanning` is true when this returns
    /// (`DataPathBenchmarks.waitForScan` relies on that), and stays true until every queued scan is done.
    private func scanFolder(url: URL) {
        guard modelContext != nil else { return }
        isScanning = true
        if scanning.task != nil {
            scanning.queuedURL = url
            return
        }
        scanProgress = "Scanning folder..."
        scanning.task = Task { @MainActor in
            var next: URL? = url
            while let folder = next {
                await self.performScan(of: folder)
                next = self.scanning.queuedURL
                self.scanning.queuedURL = nil
            }
            self.scanning.task = nil
            self.isScanning = false
        }
    }

    /// One scan. The file system walk, the read of the stored rows, the diff, the stat of photos the scan
    /// didn't find and the metadata reads all run off the main actor. The main actor only writes: it changes
    /// the rows that differ, inserts the new photos and saves. An unchanged rescan writes no photo row and
    /// doesn't reload the library (spec §B1, §B2).
    private func performScan(of url: URL) async {
        guard let context = modelContext else { return }
        let clock = ContinuousClock()
        var report = ScanReport()
        var sectionStart = clock.now

        scanProgress = "Scanning folder..."
        // The stored rows are read through another context, which can't see unsaved changes.
        if context.hasChanges { try? context.save() }
        let container = context.container
        let scanner = self.scanner
        report.mainActorTime += clock.now - sectionStart

        // Off the main actor: the store and the file system are read at the same time.
        async let storedRows = StoredPhoto.fetchAll(in: container)
        async let foundPhotos = scanner.scan(folderURL: url)
        let stored = await storedRows
        let discovered = await foundPhotos
        var plan = await ScanPlan.make(stored: stored, discovered: discovered)
        report.discovered = plan.discoveredCount

        if !plan.newPhotos.isEmpty {
            sectionStart = clock.now
            let total = plan.newPhotos.count
            scanning.metadataProgressTotal = total
            scanProgress = "Reading metadata for \(total) new photos..."
            report.mainActorTime += clock.now - sectionStart
            plan.newPhotos = await scanner.readMetadata(for: plan.newPhotos) { done, total in
                Task { @MainActor in self.showMetadataProgress(done: done, total: total) }
            }
            scanning.metadataProgressTotal = nil
        }

        // New photos without keywords go in through a background context (see `ScanPlan.canInsertInBackground`).
        let viaBackground = plan.newPhotos.filter(ScanPlan.canInsertInBackground)
        let withKeywords = plan.newPhotos.filter { !ScanPlan.canInsertInBackground($0) }
        if !viaBackground.isEmpty {
            sectionStart = clock.now
            scanProgress = "Adding \(plan.newPhotos.count) new photos..."
            report.mainActorTime += clock.now - sectionStart
            report.inserted += await ScanPlan.insertInBackground(viaBackground, into: container)
        }

        sectionStart = clock.now
        let changed = applyScanUpdates(plan.updates, in: context)
        report.updated = changed.photos.count

        if !withKeywords.isEmpty {
            scanProgress = "Adding \(plan.newPhotos.count) new photos..."
            var start = 0
            while start < withKeywords.count {
                if start > 0 {
                    // Save this chunk and let other main-actor work run before the next one.
                    try? context.save()
                    report.mainActorTime += clock.now - sectionStart
                    await Task.yield()
                    sectionStart = clock.now
                }
                let end = min(start + Self.scanInsertChunkSize, withKeywords.count)
                insertScannedPhotos(withKeywords[start..<end], into: context)
                start = end
            }
            report.inserted += withKeywords.count
        }

        // What the scan found is available; see `ScanPlan.missingIDs` for what it didn't find.
        let missingChanged = plan.missingIDs != missingPhotoIDs
        missingPhotoIDs = plan.missingIDs
        report.missing = plan.missingIDs.count

        scanWillSave?(context)
        currentLibrary?.lastScanDate = Date()
        if context.hasChanges { try? context.save() }

        // The in-memory library is already right after an unchanged rescan, so skip the reload (~300 ms at 10k).
        if report.inserted > 0 || changed.restoredFromBin || missingChanged {
            loadExistingData()
            report.reloaded = true
        } else if !changed.photos.isEmpty {
            photosDidChange(changed.photos)
        }

        scanProgress = "Found \(plan.discoveredCount) photos (\(report.inserted) new)"
        report.mainActorTime += clock.now - sectionStart
        lastScanReport = report
    }

    private func showMetadataProgress(done: Int, total: Int) {
        guard scanning.metadataProgressTotal == total else { return } // that phase is over
        scanProgress = "Reading metadata for \(total) new photos... \(done)/\(total)"
    }

    /// Writes the scan's new values into the rows that differ, assigning only fields whose value changes, so
    /// SwiftData doesn't mark unchanged rows dirty. Rows deleted since the scan read the store are skipped.
    private func applyScanUpdates(_ updates: [ScanPlan.Update], in context: ModelContext)
        -> (photos: [PhotoAsset], restoredFromBin: Bool)
    {
        guard !updates.isEmpty else { return ([], false) }
        let ids = updates.map(\.id)
        let rows = (try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [PhotoAsset] = []
        var restoredFromBin = false
        for update in updates {
            guard let photo = rowsByID[update.id] else { continue }
            if photo.jpgPath != update.jpgPath { photo.jpgPath = update.jpgPath }
            if photo.rawPath != update.rawPath { photo.rawPath = update.rawPath }
            if photo.fileSize != update.fileSize { photo.fileSize = update.fileSize }
            if update.restoresFromBin {
                // Not compared first: reading `isDeleted` can be stale (see `StoredPhoto.fetchAllNow`).
                photo.isDeleted = false
                restoredFromBin = true
            }
            changed.append(photo)
        }
        return (changed, restoredFromBin)
    }

    private struct TagKey: Hashable {
        let category: String
        let name: String
    }

    /// Inserts new photos with the rating and keywords read from their files. Tags are looked up in one
    /// dictionary built from a single fetch (no fetch per keyword; spec §B2), and created when missing.
    private func insertScannedPhotos(_ newPhotos: ArraySlice<DiscoveredPhoto>, into context: ModelContext) {
        // Fetched per chunk: a tag may have been added between chunks (from the tag editor, say).
        var tagsByKey: [TagKey: Tag] = [:]
        if newPhotos.contains(where: { !($0.metadata?.keywords.isEmpty ?? true) }) {
            let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
            tagsByKey = Dictionary(tags.map { (TagKey(category: $0.category, name: $0.name), $0) },
                                   uniquingKeysWith: { first, _ in first })
        }
        for found in newPhotos {
            let asset = PhotoAsset(
                fileName: found.fileName,
                jpgPath: found.jpgPath,
                rawPath: found.rawPath,
                folderPath: found.folderPath,
                creationDate: found.creationDate,
                fileSize: found.fileSize
            )
            asset.rating = found.metadata?.rating ?? 0
            context.insert(asset)

            guard let keywords = found.metadata?.keywords, !keywords.isEmpty else { continue }
            var tags: [Tag] = []
            var seen = Set<TagKey>()
            for keyword in keywords {
                let parsed = Tag.parse(keyword: keyword)
                let key = TagKey(category: parsed.category, name: parsed.name)
                guard seen.insert(key).inserted else { continue }
                if let tag = tagsByKey[key] {
                    tags.append(tag)
                } else {
                    let tag = Tag(name: parsed.name, category: parsed.category)
                    context.insert(tag)
                    tagsByKey[key] = tag
                    tags.append(tag)
                }
            }
            // One assignment after the insert: much cheaper than appending before it.
            asset.tags = tags
        }
    }
}
