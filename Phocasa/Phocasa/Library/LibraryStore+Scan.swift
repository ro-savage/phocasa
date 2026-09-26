import SwiftData
import Foundation

extension LibraryStore {
    /// State only the scan code uses, stored in `scanning`.
    struct ScanState {
        /// The scan queue while it runs (`startScanQueue`): scans run one at a time (spec §B3), and a library folder's
        /// removal runs on it too.
        var task: Task<Void, Never>?
        /// The library folders (by id) whose scans wait, in the order asked. Every folder asked for is scanned; a
        /// request for a folder already waiting joins it.
        var queued: [UUID] = []
        /// Where Open Folder found a waiting folder that moved (`handleFolderSelected(url:)`), for its scan.
        var requestedURLs: [UUID: URL] = [:]
        /// Total of the metadata reads in progress, while `scanProgress` shows their count.
        var metadataProgressTotal: Int?
        /// What the launch rescan reads ahead (`readAheadForLaunchRescan()`). Any other scan request drops it.
        var readAhead: ReadAhead?
    }

    /// What the launch rescan of a big library uses instead of reading again once the background load is done.
    struct ReadAhead {
        /// The library folder the launch rescan scans first, and where it is.
        let folderID: UUID
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
        /// The library's folder is on a drive (or share) that isn't connected: `volume` is its name.
        case folderNotConnected(path: String, volume: String)
        /// The library's folder isn't there, on a volume that is: moved, renamed or deleted.
        case folderNotFound(path: String)

        var statusText: String {
            switch self {
            case .storeUnreadable(let reason):
                "Scan stopped: Phocasa couldn’t read its library (\(reason)). Nothing was added or changed."
            case .storeUnsaved(let reason):
                "The scan’s changes couldn’t be saved (\(reason)). Rescan to try again."
            case .folderNotConnected(_, let volume):
                "“\(volume)” isn’t connected. Connect the drive and choose Rescan."
            case .folderNotFound(let path):
                "“\((path as NSString).lastPathComponent)” can’t be found. It may have been moved, renamed or deleted."
            }
        }

        /// The library's folder, when the issue is that it isn't there.
        var unavailableFolder: String? {
            switch self {
            case .folderNotConnected(let path, _), .folderNotFound(let path): path
            case .storeUnreadable, .storeUnsaved: nil
            }
        }
    }

    // MARK: - Folder Opening

    /// "Open Folder…": the folder becomes a library folder and is scanned. Every folder opened stays one, and a rescan
    /// scans each of them.
    /// - A folder that is a library folder, or is inside one, isn't another: that library folder is scanned.
    /// - A folder where a library folder that isn't there now has gone (its bookmark finds it there, or it's the same
    ///   folder on its drive mounted under another name) is that library folder, moved: it's scanned there, and its
    ///   photos keep their rows (`ScanPlan`'s match by path).
    /// - Otherwise it's a new library folder, and the library folders inside it become part of it.
    func handleFolderSelected(url: URL) {
        _ = url.startAccessingSecurityScopedResource() // Phocasa isn't sandboxed: its access doesn't depend on this
        guard let context = modelContext else { return }
        let path = Self.canonicalPath(of: url)
        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        let bookmark = Self.bookmark(of: folderURL)

        if let existing = libraryFolders.first(where: { Self.isPath(path, inOrAt: $0.rootFolderPath) }) {
            if existing.rootFolderPath == path, let bookmark { existing.bookmarkData = bookmark }
            try? context.save()
            return queueScan(of: existing)
        }
        if let moved = libraryFolders.first(where: { isMovedLibraryFolder($0, nowAt: path) }) {
            if let bookmark { moved.bookmarkData = bookmark }
            try? context.save()
            return queueScan(of: moved, at: folderURL)
        }
        let absorbed = libraryFolders.filter { Self.isPath($0.rootFolderPath, inOrAt: path) }
        for folder in absorbed {
            forgetLibraryFolder(folder)
            context.delete(folder)
        }
        let library = PhotoLibrary(rootFolderPath: path, bookmarkData: bookmark)
        context.insert(library)
        try? context.save()
        setLibraryFolders(libraryFolders + [library])
        queueScan(of: library)
    }

    /// Rescans every library folder, one after the other (the toolbar's Rescan, and launch). A folder that isn't there
    /// is skipped (it says why: `folderIssues`), and the others are still scanned.
    func rescanCurrentLibrary() {
        // A folder inside (or at) one listed before it is scanned with that one. Opening folders never leaves such
        // pairs, but a store could hold two rows for one folder.
        var scanned: [String] = []
        for folder in libraryFolders {
            let path = folder.rootFolderPath
            guard !scanned.contains(where: { Self.isPath(path, inOrAt: $0) }) else { continue }
            scanned.append(path)
            queueScan(of: folder)
        }
    }

    /// Rescans one library folder (the sidebar's Rescan).
    func rescan(_ folder: PhotoLibrary) {
        queueScan(of: folder)
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
        /// Stored rows the scan found at new paths (moved, renamed, or on a drive mounted under another name).
        var relinked = 0
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

    /// Starts a scan of the library folder, or queues it if a scan (or the launch's background load, or a folder's
    /// removal) is running; `url` is where Open Folder found it, when it moved. `isScanning` is true when this returns
    /// (`DataPathBenchmarks.waitForScan` relies on that), and stays true until every queued scan is done.
    private func queueScan(of folder: PhotoLibrary, at url: URL? = nil) {
        guard modelContext != nil else { return }
        isScanning = true
        if let url { scanning.requestedURLs[folder.id] = url }
        if !scanning.queued.contains(folder.id) { scanning.queued.append(folder.id) }
        scanning.readAhead = nil // read before this request: the scan it asks for reads again
        if scanning.task == nil {
            startScanQueue()
        }
    }

    /// With a big library the launch rescan waits for the background load, so it starts walking its first folder now,
    /// alongside the load, and takes the stored rows from the load's snapshot (`LibrarySnapshot.storedRows`): both
    /// would otherwise be read again after the load.
    func readAheadForLaunchRescan() {
        guard let id = scanning.queued.first, let folder = libraryFolder(withID: id) else { return }
        let url = location(of: folder).url
        let scanner = self.scanner
        scanning.readAhead = ReadAhead(folderID: id, url: url, walk: Task.detached(priority: .userInitiated) {
            await scanner.scan(folderURL: url)
        })
    }

    /// Runs the scan queue: first the launch's background load, when `open(_:)` passes the load generation it asked
    /// at (`loadInBackground(unlessLoadedAfter:)`), then each queued scan until none is left.
    func startScanQueue(loadingFirstUnlessLoadedAfter loadGeneration: Int? = nil) {
        startScanQueue(progress: loadGeneration == nil ? "Scanning..." : "Loading library...") {
            if let loadGeneration {
                await self.loadInBackground(unlessLoadedAfter: loadGeneration)
            }
        }
    }

    /// Runs the scan queue: `first`, then each queued scan until none is left.
    func startScanQueue(progress: String, first: @escaping @MainActor () async -> Void) {
        isScanning = true
        scanProgress = progress
        scanning.task = Task { @MainActor in
            await first()
            while !self.scanning.queued.isEmpty {
                let id = self.scanning.queued.removeFirst()
                // A folder removed, or taken into one opened above it, since it was queued isn't scanned.
                if let folder = self.libraryFolder(withID: id) {
                    await self.performScan(of: folder)
                }
            }
            self.scanning.task = nil
            self.isScanning = false
        }
    }

    /// One scan of a library folder. The file system walk, the read of the stored rows, the diff, the stat of photos
    /// the scan didn't find, the metadata reads and the match of moved photos all run off the main actor. The main
    /// actor only writes: it changes the rows that differ, relinks the moved ones, inserts the new photos and saves.
    /// Then it patches the in-memory library with what changed (`updateLibrary(adding:facts:removing:)`) instead of
    /// reloading it, so an unchanged rescan costs nothing and one that adds k photos costs O(k log n) (spec §B1, §B2).
    private func performScan(of folder: PhotoLibrary) async {
        guard let context = modelContext else { return }
        let clock = ContinuousClock()
        var report = ScanReport()
        var sectionStart = clock.now

        let folderID = folder.id
        let location = location(of: folder)
        let url = location.url
        scanning.requestedURLs[folderID] = nil
        scanProgress = "Scanning “\(url.lastPathComponent)”..."
        let readAhead = scanning.readAhead.flatMap { $0.folderID == folderID && $0.url == url ? $0 : nil }
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

        // A folder that isn't there (a drive unplugged, a folder moved): no walk and no diff, so nothing is added,
        // changed or found missing. Its photos, whose files can't be reached, are hidden until a scan finds it again.
        if let issue = unavailableFolderIssue(url) {
            folderIssues[folderID] = issue
            do {
                hidePhotos(under: url.path, rows: try await Self.storedRows(readAhead: rowsReadAhead, in: container))
            } catch {
                return scanDidStop(.storeUnreadable(error.localizedDescription), report: &report)
            }
            return scanDidStop(issue, report: &report)
        }
        folderIssues[folderID] = nil

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
        // The other library folders' rows are their own scans' to check.
        let otherRoots = libraryFolders.filter { $0.id != folderID }.map(\.rootFolderPath)
        var plan = await ScanPlan.make(stored: stored, discovered: discovered, previouslyMissing: previouslyMissing,
                                       root: url.path, movedFrom: location.movedFrom, otherRoots: otherRoots)
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
            // With their capture dates read, new photos that are stored photos moved keep those rows.
            plan = await plan.relinkingMovedPhotos()
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
        var changed = applyScanUpdates(plan.updates, in: context)
        report.updated = changed.count

        // Moved photos: a whole drive's worth can move at once, so a chunk at a time, like the inserts below.
        if !plan.relinks.isEmpty {
            scanProgress = "Updating \(plan.relinks.count) moved photos..."
            var relinked: [PhotoAsset] = []
            var start = 0
            while start < plan.relinks.count {
                if start > 0 {
                    try? context.save()
                    report.mainActorTime += clock.now - sectionStart
                    await Task.yield()
                    sectionStart = clock.now
                }
                let end = min(start + Self.scanInsertChunkSize, plan.relinks.count)
                relinked += applyScanRelinks(plan.relinks[start..<end], in: context)
                start = end
            }
            report.relinked = relinked.count
            changed += relinked
        }

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
        missingPhotoIDs = plan.missingSet(after: missingPhotoIDs)
        report.missing = plan.missingIDs.count

        scanWillSave?(context)
        // Unless it was removed, or taken into a folder opened above it, meanwhile (or now, moved into another).
        if location.movedFrom != nil, libraryFolders.contains(where: { $0 === folder }) {
            libraryFolderDidMove(folder, to: url)
        }
        if libraryFolders.contains(where: { $0 === folder }) {
            folder.lastScanDate = Date()
        }
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

        let moved = report.relinked > 0 ? ", \(report.relinked) moved" : ""
        scanProgress = "Found \(plan.discoveredCount) photos (\(report.inserted) new\(moved))"
        scanIssue = report.issue ?? firstFolderIssue()
        // The folder is there: writes that waited for its drive can be made now.
        MetadataWriter.shared.retryWaitingWrites()
        report.mainActorTime += clock.now - sectionStart
        lastScanReport = report
    }

    /// Why the folder at `url` can't be scanned, or nil when it's there.
    private func unavailableFolderIssue(_ url: URL) -> ScanIssue? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nil
        }
        if let volume = volumes.volumeName(of: url.path), !volumes.isVolumeAvailable(for: url.path) {
            return .folderNotConnected(path: url.path, volume: volume)
        }
        return .folderNotFound(path: url.path)
    }

    /// Hides the library photos whose files are under `folder` (from the stored `rows`), as missing: without a look at
    /// the disk, which can't reach them. A scan that finds them shows them again (`ScanPlan.foundAgainIDs`).
    private func hidePhotos(under folder: String, rows: [StoredPhoto]) {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let hiding = Set(rows.lazy.filter { !$0.isInBin && ($0.jpgPath ?? $0.rawPath ?? "").hasPrefix(prefix) }.map(\.id))
            .subtracting(missingPhotoIDs)
        guard !hiding.isEmpty else { return }
        missingPhotoIDs.formUnion(hiding)
        updateLibrary(adding: [], facts: [], removing: hiding)
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

    /// Points the rows of moved photos at the files the scan found: their paths, folder, name and size. Nothing else
    /// changes (rating, tags, edits, dates, and the bin flag, which the fetch just before keeps; see
    /// `applyScanUpdates`). Rows deleted since the scan read the store are skipped.
    private func applyScanRelinks(_ relinks: ArraySlice<ScanPlan.Relink>, in context: ModelContext) -> [PhotoAsset] {
        let ids = relinks.map(\.id)
        let rows = (try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [PhotoAsset] = []
        for relink in relinks {
            guard let photo = rowsByID[relink.id] else { continue }
            if photo.jpgPath != relink.jpgPath { photo.jpgPath = relink.jpgPath }
            if photo.rawPath != relink.rawPath { photo.rawPath = relink.rawPath }
            if photo.folderPath != relink.folderPath { photo.folderPath = relink.folderPath }
            if photo.fileName != relink.fileName { photo.fileName = relink.fileName }
            if photo.fileSize != relink.fileSize { photo.fileSize = relink.fileSize }
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
            let asset = ScanPlan.newRow(for: found)
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
