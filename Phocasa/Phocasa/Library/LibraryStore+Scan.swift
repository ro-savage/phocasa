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
        /// What the launch rescan reads ahead (`readAheadForLaunchRescan()`). Any other scan request drops it.
        var readAhead: ReadAhead?
    }

    /// What the launch rescan of a big library uses instead of reading again once the background load is done.
    struct ReadAhead {
        /// The folder the launch rescan scans.
        let url: URL
        /// Its walk, started at launch alongside the background load.
        let walk: Task<[DiscoveredPhoto], Never>
        /// The stored rows the background load read, and `loading.generation` once it was applied. The rescan uses
        /// them only if nothing has loaded or changed the store since.
        var rows: (rows: [StoredPhoto], generation: Int)?
    }

    /// Why a scan stopped, or didn't run (`LibraryStore.scanIssue`).
    enum ScanIssue: Equatable {
        /// The store couldn't be read (or the changes waiting in the context couldn't be saved first), so the scan
        /// stopped before changing anything: a diff against rows it couldn't read would insert the library again.
        case storeUnreadable(String)
        /// The scan's changes couldn't be saved. They wait in the context, and a later save writes them.
        case storeUnsaved(String)

        var statusText: String {
            switch self {
            case .storeUnreadable(let reason):
                "Scan stopped: Phocasa couldn’t read its library (\(reason)). Nothing was added or changed."
            case .storeUnsaved(let reason):
                "The scan’s changes couldn’t be saved (\(reason)). Rescan to try again."
            }
        }
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

    /// Returns once no scan is running or queued, the launch rescan included, and once a launch's background load
    /// (`loadInBackground()`) has been applied.
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
        /// Existing rows (in the library or the bin) whose paths or size the scan changed.
        var updated = 0
        var missing = 0
        /// Whether the scan ended in a full `loadExistingData()`.
        var reloaded = false
        /// Why the scan stopped early or didn't run, if it did.
        var issue: ScanIssue?
        /// Whether the scan used the folder walk, and the stored rows, that the launch read ahead (`ReadAhead`).
        var usedWalkReadAhead = false
        var usedRowsReadAhead = false
        /// Time the scan spent in its synchronous main-actor sections (spec §B1, §B2).
        var mainActorTime: Duration = .zero
    }

    /// New photos inserted per main-actor turn. Between chunks the scan saves and yields, so a big import
    /// never holds the main actor for more than a few tens of milliseconds at a time.
    private static let scanInsertChunkSize = 256

    /// Starts a scan of `url`, or queues one if a scan (or the launch's background load) is running. `isScanning` is
    /// true when this returns (`DataPathBenchmarks.waitForScan` relies on that), and stays true until every queued
    /// scan is done.
    private func scanFolder(url: URL) {
        guard modelContext != nil else { return }
        isScanning = true
        scanning.queuedURL = url
        scanning.readAhead = nil // read before this request: the scan it asks for reads again
        if scanning.task == nil {
            startScanQueue()
        }
    }

    /// With a big library the launch rescan waits for the background load, so it starts walking its folder now,
    /// alongside the load, and takes the stored rows from the load's snapshot (`LibrarySnapshot.storedRows`): both
    /// would otherwise be read again after the load.
    func readAheadForLaunchRescan() {
        guard let url = scanning.queuedURL else { return }
        let scanner = self.scanner
        scanning.readAhead = ReadAhead(url: url, walk: Task.detached(priority: .userInitiated) {
            await scanner.scan(folderURL: url)
        })
    }

    /// Runs the scan queue: first the launch's background load, when `open(_:)` passes the load generation it asked
    /// at (`loadInBackground(unlessLoadedAfter:)`), then each queued scan until none is left.
    func startScanQueue(loadingFirstUnlessLoadedAfter loadGeneration: Int? = nil) {
        isScanning = true
        scanProgress = loadGeneration == nil ? "Scanning folder..." : "Loading library..."
        scanning.task = Task { @MainActor in
            if let loadGeneration {
                await self.loadInBackground(unlessLoadedAfter: loadGeneration)
            }
            while let folder = self.scanning.queuedURL {
                self.scanning.queuedURL = nil
                await self.performScan(of: folder)
            }
            self.scanning.task = nil
            self.isScanning = false
        }
    }

    /// One scan. The file system walk, the read of the stored rows, the diff, the stat of photos the scan
    /// didn't find and the metadata reads all run off the main actor. The main actor only writes: it changes
    /// the rows that differ, inserts the new photos and saves. Then it patches the in-memory library with what
    /// changed (`updateLibrary(adding:facts:removing:)`) instead of reloading it, so an unchanged rescan costs
    /// nothing and one that adds k photos costs O(k log n) (spec §B1, §B2).
    private func performScan(of url: URL) async {
        guard let context = modelContext else { return }
        let clock = ContinuousClock()
        var report = ScanReport()
        var sectionStart = clock.now

        scanProgress = "Scanning folder..."
        let readAhead = scanning.readAhead?.url == url ? scanning.readAhead : nil
        scanning.readAhead = nil
        // The stored rows are read through another context, which can't see unsaved changes: if they can't be saved
        // (photos a scan inserted, say), the diff would find those photos new again.
        let hadChanges = context.hasChanges
        if hadChanges {
            do {
                try context.save()
            } catch {
                return scanDidStop(.storeUnreadable(error.localizedDescription), report: &report)
            }
        }
        let container = context.container
        let scanner = self.scanner
        // What the library shows now, which the end of the scan patches.
        let generation = loading.generation
        let previouslyMissing = missingPhotoIDs
        // Rows read ahead by the launch's background load are the store as it is only if nothing has loaded or changed
        // it since.
        let rowsReadAhead = readAhead?.rows.flatMap { !hadChanges && $0.generation == generation ? $0.rows : nil }
        report.usedWalkReadAhead = readAhead != nil
        report.usedRowsReadAhead = rowsReadAhead != nil
        report.mainActorTime += clock.now - sectionStart

        // Off the main actor: the store and the file system are read at the same time (or were read ahead).
        async let storedRows = Self.storedRows(readAhead: rowsReadAhead, in: container)
        async let foundPhotos = Self.walk(url, readAhead: readAhead?.walk, with: scanner)
        let stored: [StoredPhoto]
        do {
            stored = try await storedRows
        } catch {
            _ = await foundPhotos
            return scanDidStop(.storeUnreadable(error.localizedDescription), report: &report)
        }
        let discovered = await foundPhotos
        var plan = await ScanPlan.make(stored: stored, discovered: discovered, previouslyMissing: previouslyMissing,
                                       root: url.path)
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
        var insertedInBackground: [UUID] = []
        if !viaBackground.isEmpty {
            sectionStart = clock.now
            scanProgress = "Adding \(plan.newPhotos.count) new photos..."
            report.mainActorTime += clock.now - sectionStart
            insertedInBackground = await ScanPlan.insertInBackground(viaBackground, into: container)
            report.inserted += insertedInBackground.count
        }

        sectionStart = clock.now
        let changed = applyScanUpdates(plan.updates, in: context)
        report.updated = changed.count

        var insertedHere: [PhotoAsset] = []
        var createdTags = false
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
                let inserted: (photos: [PhotoAsset], createdTags: Bool)
                do {
                    inserted = try insertScannedPhotos(withKeywords[start..<end], into: context)
                } catch {
                    // Without the tags, each keyword would get a new tag. The rest wait for the next scan.
                    report.issue = .storeUnreadable(error.localizedDescription)
                    break
                }
                insertedHere += inserted.photos
                createdTags = createdTags || inserted.createdTags
                start = end
            }
            report.inserted += insertedHere.count
        }

        // What the scan found is available; see `ScanPlan.missingIDs` for what it didn't find.
        missingPhotoIDs = plan.missingIDs
        report.missing = plan.missingIDs.count

        scanWillSave?(context)
        currentLibrary?.lastScanDate = Date()
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                // What it changed waits in the context (and shows in memory); the next scan saves it before it reads.
                report.issue = report.issue ?? .storeUnsaved(error.localizedDescription)
            }
        }

        // Patch the in-memory library with what changed. An unchanged rescan changes nothing.
        let fetchIDs = insertedInBackground + plan.foundAgainIDs
        var added = insertedHere
        var start = 0
        while start < fetchIDs.count, loading.generation == generation {
            if start > 0 {
                report.mainActorTime += clock.now - sectionStart
                await Task.yield()
                sectionStart = clock.now
            }
            let chunk = Array(fetchIDs[start..<min(start + Self.scanFetchChunkSize, fetchIDs.count)])
            added += (try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { chunk.contains($0.id) })))
                ?? []
            start += chunk.count
        }
        if loading.generation != generation || libraryReadFailure != nil {
            // A full load ran during the scan and may already hold some of the new photos, or the last one failed and
            // memory doesn't hold the library: load again, don't patch.
            loadExistingData()
            report.reloaded = true
        } else {
            if createdTags {
                setTagLists((try? context.fetch(FetchDescriptor<Tag>(sortBy: Self.tagSortOrder))) ?? allTags)
            }
            let leaving = plan.missingIDs.subtracting(previouslyMissing)
            if added.isEmpty && leaving.isEmpty {
                if !changed.isEmpty { photosDidChange(changed) }
            } else {
                applyFactChanges(changed)
                updateLibrary(adding: added, facts: makeFacts(for: added), removing: leaving)
            }
        }

        scanProgress = "Found \(plan.discoveredCount) photos (\(report.inserted) new)"
        scanIssue = report.issue
        report.mainActorTime += clock.now - sectionStart
        lastScanReport = report
    }

    /// A scan that stops before it changes anything: the status bar says why until a scan goes through.
    private func scanDidStop(_ issue: ScanIssue, report: inout ScanReport) {
        report.issue = issue
        scanIssue = issue
        scanProgress = issue.statusText
        lastScanReport = report
    }

    /// Rows fetched per main-actor turn when a scan brings its new photos into the in-memory library: about 14 ms
    /// each (measured, 10k library), so a big import never holds the main actor for long.
    private static let scanFetchChunkSize = 500

    private nonisolated static func storedRows(readAhead: [StoredPhoto]?, in container: ModelContainer) async throws
        -> [StoredPhoto]
    {
        if let readAhead { return readAhead }
        return try await StoredPhoto.fetchAll(in: container)
    }

    private nonisolated static func walk(_ url: URL, readAhead: Task<[DiscoveredPhoto], Never>?,
                                         with scanner: FolderScanner) async -> [DiscoveredPhoto] {
        if let readAhead { return await readAhead.value }
        return await scanner.scan(folderURL: url)
    }

    private func showMetadataProgress(done: Int, total: Int) {
        guard scanning.metadataProgressTotal == total else { return } // that phase is over
        scanProgress = "Reading metadata for \(total) new photos... \(done)/\(total)"
    }

    /// Writes the scan's new values into the rows that differ, assigning only fields whose value changes, so
    /// SwiftData doesn't mark unchanged rows dirty. Rows deleted since the scan read the store are skipped. A row in
    /// the bin stays there (user decision, wave 2 #1); the store keeps its bin flag through this write, since the row
    /// is fetched just before it (`ScanTests.testBinnedPhotoWhoseFilesChangedStaysInTheBinWithNewPaths`).
    private func applyScanUpdates(_ updates: [ScanPlan.Update], in context: ModelContext) -> [PhotoAsset] {
        guard !updates.isEmpty else { return [] }
        let ids = updates.map(\.id)
        let rows = (try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [PhotoAsset] = []
        for update in updates {
            guard let photo = rowsByID[update.id] else { continue }
            if photo.jpgPath != update.jpgPath { photo.jpgPath = update.jpgPath }
            if photo.rawPath != update.rawPath { photo.rawPath = update.rawPath }
            if photo.fileSize != update.fileSize { photo.fileSize = update.fileSize }
            changed.append(photo)
        }
        return changed
    }

    private struct TagKey: Hashable {
        let category: String
        let name: String
    }

    /// Inserts new photos with the rating and keywords read from their files. Tags are looked up in one
    /// dictionary built from a single fetch (no fetch per keyword; spec §B2), and created when missing. Returns the
    /// photos inserted, and whether any tag was created. Throws, inserting nothing, if the tags can't be read.
    private func insertScannedPhotos(_ newPhotos: ArraySlice<DiscoveredPhoto>, into context: ModelContext) throws
        -> (photos: [PhotoAsset], createdTags: Bool)
    {
        var inserted: [PhotoAsset] = []
        var createdTags = false
        // Fetched per chunk: a tag may have been added between chunks (from the tag editor, say).
        var tagsByKey: [TagKey: Tag] = [:]
        if newPhotos.contains(where: { !($0.metadata?.keywords.isEmpty ?? true) }) {
            let tags = try context.fetch(FetchDescriptor<Tag>())
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
            asset.captureDate = found.metadata?.captureDate
            context.insert(asset)
            inserted.append(asset)

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
                    createdTags = true
                }
            }
            // One assignment after the insert: much cheaper than appending before it.
            asset.tags = tags
        }
        return (inserted, createdTags)
    }
}
