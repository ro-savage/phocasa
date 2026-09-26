// Scale checks: does Phocasa still *work* (no freeze, crash, runaway memory, lost photos) on a library of tens of
// thousands of real JPG+RAW pairs? Not a benchmark for speed-ups: it looks for breakage at size.
//
// Opt-in: skipped unless PHOCASA_SCALE=1 is set for the test runner, e.g.
//   TEST_RUNNER_PHOCASA_SCALE=1 Tools/coordinator/runtests.sh "$PWD" scale -only-testing:PhocasaTests/ScaleChecks
// - TEST_RUNNER_PHOCASA_SCALE_SIZES: photo counts, comma-separated (default 10000,25000,50000).
// - TEST_RUNNER_PHOCASA_SCALE_SOURCE: a folder of JPG+RAW pairs to clone (default ~/PhocasaBenchRAW). It is only ever
//   read: the library is APFS clones of it (`copyfile` with COPYFILE_CLONE_FORCE, which clones or fails, never copies)
//   in a nested temp folder tree, plus keyword sidecars for a third of the folders. The clones keep the source's
//   read-only mode, so rating and keyword writes skip the JPEGs (each would otherwise un-share a 4 MB clone) and land in
//   the RAWs' sidecars; `testMetadataWriteThroughput` measures real JPEG rewrites on a small writable set instead.
// - Stores are temp files; the tree, the stores and the thumbnail cache folder are deleted at the end.
// - Tests: testScaleLibrary (every size: first scan, rescans, relaunch, bulk operations, the grid in a window),
//   testFirstScanPhases (the largest size's first scan, its main-thread blocks against its phases; override the size
//   with PHOCASA_SCALE_PHASES_SIZE), testMetadataWriteThroughput (real JPEG rewrites on 190 writable clones),
//   testThumbnailDiskCachePastItsCap (1.5 GB into a temp cache), testTagRelationshipCost (tagging patterns, temp store),
//   testTagCostAtLibraryScale (saves and tag changes with 150,000 photos loaded; PHOCASA_SCALE_TAG_N).
// - Big changes (rating everything, tagging 5,000) show in memory at once and reach the store in chunks sized by time
//   (`LibraryStore+RowWrites`): their `sync_ms` is the in-memory part, and the chunks' blocks show in the next steps'
//   and in the drains' `longest_main_block_ms` (`row_writes_s` is how long the chunks took).
//   The largest sizes take long: 100k + 150k ran about 18 minutes on a 10-core M-series machine.
//
// Each result is a line starting with "SCALE|": grep the xcodebuild log for them. "longest_main_block_ms" is the
// longest the main thread went without answering a probe (a background thread pings the main queue every ~5 ms), so
// it covers every main-actor turn in the phase, the app's own tasks included, not just the call being timed.

import XCTest
import SwiftData
import SwiftUI
import AppKit
import SQLite3
@testable import Phocasa

@MainActor
final class ScaleChecks: XCTestCase {
    private let clock = ContinuousClock()
    private var activity: NSObjectProtocol?
    private var tempRoots: [URL] = []

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOCASA_SCALE"] == "1",
                          "Set PHOCASA_SCALE=1 to run the scale checks")
        // The test host is usually in the background: keep App Nap from throttling timers and utility work.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Phocasa scale checks")
    }

    override func tearDown() async throws {
        await MetadataWriter.shared.flush()
        for url in tempRoots.reversed() { Self.removeTree(url) }
        tempRoots.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - The library at each size

    func testScaleLibrary() async throws {
        // No thumbnails may land outside a temp folder.
        XCTAssertNil(ImageLoader.shared.diskCache, "run without PHOCASA_THUMBNAIL_CACHE_DIR")
        let sizes = Self.sizes
        let pairs = try Self.sourcePairs()
        XCTAssertGreaterThan(pairs.count, 0)
        let base = try makeTempRoot("scale")
        printEnvironment(base: base, pairs: pairs.count)

        var start = clock.now
        let tree = try CloneTree(source: Self.sourceFolder, pairs: pairs, base: base, sizes: sizes)
        let populated = try tree.populate()
        line("tree", "clone tree built (harness)", [
            "photos": tree.photoCount(sizes.count - 1), "files": populated.files, "folders": tree.leafCount,
            "max_depth": tree.maxDepth, "keyword_sidecars": populated.sidecars, "s": sec(clock.now - start),
        ])
        // A sidecar written the way the tree writes them reads back as a camera's JPG would with Lightroom's sidecar.
        if let leaf = tree.allLeaves.first(where: \.keyworded) {
            let read = MetadataService.shared.readMetadata(from: leaf.url.appendingPathComponent(pairs[1].jpgName).path)
            XCTAssertEqual(read.keywords, tree.keywords(leaf: leaf.index, pair: 1))
            XCTAssertEqual(read.rating, tree.rating(leaf: leaf.index, pair: 1))
            XCTAssertNotNil(read.captureDate)
        }

        for level in sizes.indices {
            start = clock.now
            try await runScale(tree, level: level)
            line("N=\(tree.photoCount(level))", "size done (harness)", ["s": sec(clock.now - start)])
        }
        start = clock.now
        Self.removeTree(base)
        tempRoots.removeAll { $0 == base }
        line("tree", "clone tree removed", ["exists": FileManager.default.fileExists(atPath: base.path),
                                            "s": sec(clock.now - start)])
    }

    private func runScale(_ tree: CloneTree, level: Int) async throws {
        let n = tree.photoCount(level)
        let tag = "N=\(n)"
        let root = tree.roots[level]
        let storeDir = tree.base.appendingPathComponent("store-\(n)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("scale.store")
        let expectedKeyworded = tree.keywordedCount(level)
        let expectedTags = tree.tagNames(level).count
        let expectedRated = tree.ratedCount(level)

        // 1. The first scan: open the folder with an empty store.
        var container: ModelContainer! = try makeContainer(storeURL)
        var vm: PhotoLibraryViewModel! = PhotoLibraryViewModel()
        vm.setModelContext(container.mainContext)
        container.mainContext.insert(PhotoLibrary(rootFolderPath: root.path))
        try container.mainContext.save()
        vm.loadExistingData()
        XCTAssertNotNil(vm.library.currentLibrary)
        var footprintBefore = Memory.footprint()
        var probe = MainThreadProbe.start()
        var start = clock.now
        vm.library.rescanCurrentLibrary()
        await vm.library.waitForScans()
        var wall = clock.now - start
        var stats = await probe.stop()
        var report = vm.library.lastScanReport
        let keyworded = vm.library.allFacts.filter { !$0.tagIDs.isEmpty }.count
        let rated = vm.library.allFacts.filter { $0.rating > 0 }.count
        let pairsFound = vm.library.allFacts.filter { $0.hasJPG && $0.hasRAW }.count
        line(tag, "first scan (open folder, empty store)", [
            "wall_s": sec(wall), "main_actor_ms": ms(report?.mainActorTime), "longest_main_block_ms": stats.longest,
            "blocks_over_250ms": stats.over250, "blocks_over_1s": stats.over1s,
            "footprint_before_mb": mb(footprintBefore), "peak_footprint_mb": mb(stats.peakFootprint),
            "footprint_after_mb": mb(Memory.footprint()), "discovered": report?.discovered ?? -1,
            "inserted": report?.inserted ?? -1, "library": vm.library.allPhotos.count, "pairs": pairsFound,
            "keyworded": keyworded, "rated": rated, "tags": vm.library.allTags.count,
        ])
        XCTAssertEqual(vm.library.allPhotos.count, n, "the first scan finds every photo")
        XCTAssertEqual(pairsFound, n, "every photo is a JPG+RAW pair")
        XCTAssertEqual(keyworded, expectedKeyworded, "every keyword sidecar is read")
        XCTAssertEqual(rated, expectedRated, "every sidecar rating is read")
        XCTAssertEqual(vm.library.allTags.count, expectedTags)
        XCTAssertEqual((try? container.mainContext.fetchCount(FetchDescriptor<PhotoAsset>())) ?? -1, n)
        line(tag, "store after the first scan", ["store_mb": mb(Self.storeBytes(storeURL)),
                                                 "history_changes": Self.storeCount(storeURL, table: "ACHANGE"),
                                                 "indexes": Self.storeIndexes(storeURL).joined(separator: ",")])

        // 2. A rescan with nothing changed.
        _ = try await rescan(vm, tag, "rescan, nothing changed")
        XCTAssertEqual(vm.library.lastScanReport?.inserted, 0)
        XCTAssertEqual(vm.library.lastScanReport?.updated, 0)

        // 3. Relaunch: a fresh container on the store (the background load, then the launch rescan).
        await MetadataWriter.shared.flush()
        vm = nil
        container = nil
        try await Task.sleep(for: .milliseconds(500))
        footprintBefore = Memory.footprint()
        container = try makeContainer(storeURL)
        vm = PhotoLibraryViewModel()
        probe = MainThreadProbe.start()
        try await Task.sleep(for: .milliseconds(30))
        start = clock.now
        vm.setModelContext(container.mainContext)
        let syncPart = clock.now - start
        while vm.library.allPhotos.count < n && vm.library.isScanning {
            try await Task.sleep(for: .milliseconds(5))
        }
        let shown = clock.now - start
        await vm.library.waitForScans()
        wall = clock.now - start
        stats = await probe.stop()
        let load = vm.library.loading.lastBackgroundLoad
        report = vm.library.lastScanReport
        line(tag, "relaunch (open the store, background load, launch rescan)", [
            "setModelContext_ms": ms(syncPart), "library_shown_s": sec(shown), "rescan_done_s": sec(wall),
            "load_main_actor_ms": ms(load?.mainActorTime), "load_longest_turn_ms": ms(load?.longestTurn),
            "load_turns": load?.turns ?? -1, "load_applied": load?.applied ?? false,
            "rescan_main_actor_ms": ms(report?.mainActorTime), "rescan_used_readahead": report?.usedRowsReadAhead ?? false,
            "longest_main_block_ms": stats.longest, "blocks_over_250ms": stats.over250,
            "footprint_before_mb": mb(footprintBefore), "peak_footprint_mb": mb(stats.peakFootprint),
            "footprint_after_mb": mb(Memory.footprint()), "library": vm.library.allPhotos.count,
        ])
        XCTAssertEqual(vm.library.allPhotos.count, n, "the relaunch shows every photo")

        // 4. Bulk operations on the main actor.
        let lib = vm.library
        let sel = vm.selection
        let context = container.mainContext
        await op(tag, "select all (Cmd-A)") { sel.selectAll() }
        XCTAssertEqual(sel.selectedPhotos.count, n)
        await op(tag, "rate the whole selection 5 (setRatingForSelection)") { vm.setRatingForSelection(5) }
        XCTAssertEqual(lib.ratingCounts[5], n)
        await drain(tag, "metadata writes for the rating (JPGs read-only: skipped; RAW sidecars written)", writes: 2 * n,
                    library: lib)
        let sample = lib.allPhotos[n / 2]
        XCTAssertEqual(MetadataService.shared.readMetadata(from: sample.rawPath ?? "").rating, 5, "the sidecar got it")
        let one = lib.photos[n / 3]
        sel.select(only: one.id)
        await op(tag, "rate one photo (key 3)") { vm.setRatingForSelectionOrCurrent(3) }
        // Where a one-photo change's time goes: the main-context save, with every photo registered in the context.
        await op(tag, "harness: main-context save, nothing changed") { try? context.save() }
        await op(tag, "harness: main-context save, one row changed") {
            one.rating = 2
            try? context.save()
        }
        one.rating = 3
        try context.save()
        await op(tag, "filter: 3 stars") { lib.applyFilter(.rated(3)) }
        XCTAssertEqual(lib.photos.count, 1)
        await op(tag, "filter: all photos") { lib.applyFilter(.all) }
        await op(tag, "filter: tag category 'people'") { lib.applyFilter(.tagCategory("people")) }
        XCTAssertEqual(lib.photos.count, expectedKeyworded)
        await op(tag, "filter: all photos again") { lib.applyFilter(.all) }
        await op(tag, "search keystroke 'dsc0870'") {
            lib.searchText = "dsc0870"
            lib.applyCurrentFilter()
        }
        await op(tag, "clear search") {
            lib.searchText = ""
            lib.applyCurrentFilter()
        }
        await op(tag, "sort toggle (oldest first)") { lib.toggleSortOrder() }
        await op(tag, "sort toggle (newest first)") { lib.toggleSortOrder() }

        let fiveK = Array(lib.shownIDs.prefix(5_000))
        sel.selectedPhotos = Set(fiveK)
        await op(tag, "tag 5,000 photos with a new tag") { vm.addTagToSelection(name: "bulk", category: "scale") }
        XCTAssertEqual(lib.categoryCounts["scale"], fiveK.count)
        await drain(tag, "metadata writes for the tag", writes: 2 * fiveK.count, library: lib)
        let bulkTag = try XCTUnwrap(lib.allTags.first { $0.name == "bulk" && $0.category == "scale" })
        // Everyday tagging once a tag is on thousands of photos.
        let other = try XCTUnwrap(lib.photos.last { !fiveK.contains($0.id) })
        await op(tag, "tag one more photo with that tag (on 5,000 already)") {
            lib.addTag(name: "bulk", category: "scale", to: other)
        }
        await op(tag, "untag that one photo") { lib.removeTag(bulkTag, from: other) }
        await drain(tag, "metadata writes for those two", writes: 4, library: lib)
        await op(tag, "untag the 5,000") { lib.removeTag(bulkTag, from: sel.selectedPhotosList) }
        XCTAssertNil(lib.categoryCounts["scale"])
        await drain(tag, "metadata writes for the untag", writes: 2 * fiveK.count, library: lib)
        await op(tag, "move 5,000 to the bin (Delete)") { vm.deleteSelected() }
        XCTAssertEqual(lib.binCount, fiveK.count)
        XCTAssertEqual(lib.allPhotos.count, n - fiveK.count)
        await op(tag, "show the bin") { lib.applyFilter(.bin) }
        sel.selectAll()
        await op(tag, "restore 5,000 from the bin") { vm.restoreSelected() }
        await op(tag, "back to all photos") { lib.applyFilter(.all) }
        XCTAssertEqual(lib.allPhotos.count, n)
        XCTAssertEqual(lib.binCount, 0)

        // 5. The window: the grid (LazyVGrid over every photo) hosted in a real window.
        try await hostedGridChecks(vm, tag: tag)

        // 6. A rescan after every photo's file size changed, as after a bulk rating rewrote every JPEG (here the
        // stored sizes change instead, so no clone is un-shared).
        await lib.waitForRowWrites() // the bin moves' last chunks, so the harness's save is its own
        let harness = clock.measure {
            for photo in lib.allPhotos { photo.fileSize = 1 }
            try? context.save()
        }
        line(tag, "harness: change fileSize on every row and save on the main context", ["ms": ms(harness)])
        let sizeRescan = try await rescan(vm, tag, "rescan after every photo's file size changed")
        XCTAssertEqual(sizeRescan?.updated, n, "every row gets its new size")
        let again = try await rescan(vm, tag, "rescan after that (nothing changed)")
        XCTAssertEqual(again?.updated, 0, "the new sizes were saved")

        // 7. A rescan after 1,000 photos were added and 1,000 removed.
        let changes = try tree.change(level: level, removing: 1_000, adding: 1_000)
        let changeRescan = try await rescan(vm, tag, "rescan after adding 1,000 photos and removing 1,000")
        XCTAssertEqual(changeRescan?.inserted, 1_000)
        XCTAssertEqual(changeRescan?.missing, 1_000)
        XCTAssertEqual(lib.allPhotos.count, n)
        try tree.undo(changes)
        let backRescan = try await rescan(vm, tag, "rescan after undoing that (1,000 back, 1,000 gone)")
        XCTAssertEqual(lib.allPhotos.count, n, "\(backRescan?.missing ?? -1) missing")

        // 8. Empty a bin of 1,000 (permanent delete; the files go to a temp folder, then back).
        let trash = TrashLog(folder: tree.base.appendingPathComponent("trash-\(n)", isDirectory: true))
        try FileManager.default.createDirectory(at: trash.folder, withIntermediateDirectories: true)
        lib.fileTrasher = FileTrasher { url in try trash.move(url) }
        lib.applyFilter(.all)
        sel.selectedPhotos = Set(lib.shownIDs.suffix(1_000))
        vm.deleteSelected()
        lib.applyFilter(.bin)
        sel.selectAll()
        vm.deleteSelected() // asks for confirmation
        XCTAssertEqual(vm.photosToDelete.count, 1_000)
        probe = MainThreadProbe.start()
        start = clock.now
        let deleteTask = vm.confirmPermanentDelete()
        let deleteSync = clock.now - start
        await deleteTask?.value
        await lib.waitForRowWrites() // the rows go after the library has changed, in chunks
        wall = clock.now - start
        stats = await probe.stop()
        line(tag, "empty a bin of 1,000 (permanent delete)", [
            "sync_ms": ms(deleteSync), "wall_s": sec(wall), "files_trashed": trash.count,
            "longest_main_block_ms": stats.longest, "bin": lib.binCount,
            "rows": (try? context.fetchCount(FetchDescriptor<PhotoAsset>())) ?? -1,
        ])
        XCTAssertEqual(lib.binCount, 0)
        try trash.putBack()
        lib.applyFilter(.all)

        // Done with this size.
        await MetadataWriter.shared.flush()
        vm = nil
        container = nil
        // SwiftData keeps persistent history (ACHANGE: a row per changed object per save) unless something prunes it.
        line(tag, "store after every step", [
            "store_mb": mb(Self.storeBytes(storeURL)), "history_changes": Self.storeCount(storeURL, table: "ACHANGE"),
            "history_transactions": Self.storeCount(storeURL, table: "ATRANSACTION"),
            "photo_rows": Self.storeCount(storeURL, table: "ZPHOTOASSET"),
        ])
        Self.removeTree(storeDir)
        let reset = clock.measure { try? tree.resetSidecars() }
        line(tag, "harness: sidecars reset for the next size", ["s": sec(reset)])
    }

    // MARK: - Where the first scan's main-actor time goes

    /// The first scan of the largest size only, logging each main-thread block over 100 ms with when it started,
    /// against the scan's phases: its progress text, each main-context save (the keyword-insert chunks save one by
    /// one) and `scanWillSave` (the inserts are done; then come the fetch of the background-inserted rows and the
    /// final patch of the in-memory library).
    func testFirstScanPhases() async throws {
        let n = try XCTUnwrap(ProcessInfo.processInfo.environment["PHOCASA_SCALE_PHASES_SIZE"].flatMap { Int($0) }
                              ?? Self.sizes.last)
        let pairs = try Self.sourcePairs()
        let base = try makeTempRoot("phases")
        let tree = try CloneTree(source: Self.sourceFolder, pairs: pairs, base: base, sizes: [n])
        _ = try tree.populate()
        let container = try makeContainer(base.appendingPathComponent("phases.store"))
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(container.mainContext)
        container.mainContext.insert(PhotoLibrary(rootFolderPath: tree.roots[0].path))
        try container.mainContext.save()
        vm.loadExistingData()

        let log = EventLog()
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: container.mainContext,
                                                              queue: nil) { _ in log.addSave() }
        defer { NotificationCenter.default.removeObserver(observer) }
        vm.library.scanWillSave = { _ in log.add("scanWillSave (inserts done; fetch + final patch next)") }
        let probe = MainThreadProbe.start(logBlocksOver: 100, since: log.origin)
        vm.library.rescanCurrentLibrary()
        var phase = ""
        while vm.library.isScanning {
            let progress = String(vm.library.scanProgress.prefix { !$0.isNumber })
            if progress != phase {
                phase = progress
                log.add("phase: \(vm.library.scanProgress)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        log.add("scan done: \(vm.library.scanProgress)")
        let stats = await probe.stop()
        var events = log.events
        for block in probe.blocks { events.append((block.start, "main block \(Int(block.ms)) ms")) }
        for event in events.sorted(by: { $0.time < $1.time }) {
            line("phases N=\(n)", String(format: "t=%.2f s", event.time), ["event": event.what])
        }
        line("phases N=\(n)", "summary", [
            "main_actor_ms": ms(vm.library.lastScanReport?.mainActorTime), "blocks_over_100ms": probe.blocks.count,
            "blocks_ms_total": probe.blocks.reduce(0) { $0 + $1.ms }, "longest_main_block_ms": stats.longest,
            "main_context_saves": log.saves, "library": vm.library.allPhotos.count,
        ])
        vm.library.scanWillSave = nil
        Self.removeTree(base)
        tempRoots.removeAll { $0 == base }
    }

    // MARK: - The grid in a window

    private func hostedGridChecks(_ vm: PhotoLibraryViewModel, tag: String) async throws {
        let lib = vm.library
        let sel = vm.selection
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        var probe = MainThreadProbe.start()
        try await Task.sleep(for: .milliseconds(30))
        var start = clock.now
        window.contentView = NSHostingView(rootView: MainContentView(viewModel: vm))
        let laidOut = await waitUntil(timeout: 30) { (Self.gridScrollView(in: window)?.documentView?.frame.height ?? 0) > 5_000 }
        var wall = clock.now - start
        var stats = await probe.stop()
        let height = Self.gridScrollView(in: window)?.documentView?.frame.height ?? 0
        line(tag, "grid: host the window (first layout)", [
            "laid_out": laidOut, "s": sec(wall), "document_height": Int(height),
            "longest_main_block_ms": stats.longest, "peak_footprint_mb": mb(stats.peakFootprint),
        ])
        guard laidOut else {
            XCTFail("the hosted grid never laid out (is the display asleep?)")
            return
        }

        func step(_ label: String, settle: Duration = .milliseconds(800), _ action: () -> Void) async throws {
            probe = MainThreadProbe.start()
            try await Task.sleep(for: .milliseconds(30))
            let sync = clock.measure(action)
            try await Task.sleep(for: settle)
            stats = await probe.stop()
            line(tag, "grid: \(label)", ["sync_ms": ms(sync), "longest_main_block_ms": stats.longest,
                                         "blocks_over_250ms": stats.over250, "shown": lib.photos.count])
        }

        try await step("click one photo") { sel.select(only: lib.photos[7].id) }
        try await step("scroll down 3 screens, one photo selected") { Self.scroll(window, by: 2_400) }
        try await step("scroll back up") { Self.scroll(window, by: -2_400) }
        try await step("select all (Cmd-A)") { sel.selectAll() }
        try await step("scroll down 3 screens, everything selected") { Self.scroll(window, by: 2_400) }
        try await step("scroll back up, everything selected") { Self.scroll(window, by: -2_400) }
        // Rows never shown before: their cells are built with everything selected.
        try await step("scroll to rows not shown yet (one screen), everything selected", settle: .milliseconds(1500)) {
            Self.scroll(window, by: 12_000)
        }
        try await step("scroll back to the top, everything selected") { Self.scroll(window, by: -12_000) }
        // What each visible cell's context menu works out when its photo is part of the selection.
        let menuState = clock.measure { _ = vm.contextMenuTagIDs(for: lib.photos[0]) }
        line(tag, "grid: contextMenuTagIDs for one cell, everything selected", ["ms": ms(menuState),
                                                                                "selected": sel.selectedPhotos.count])
        try await step("clear the selection (Esc)") { sel.clearSelection() }
        try await step("filter: tag category 'people'") { lib.applyFilter(.tagCategory("people")) }
        try await step("filter: all photos") { lib.applyFilter(.all) }
        try await step("search keystroke 'dsc0870'") {
            lib.searchText = "dsc0870"
            lib.applyCurrentFilter()
        }
        try await step("clear search") {
            lib.searchText = ""
            lib.applyCurrentFilter()
        }
        let last = try XCTUnwrap(lib.photos.last)
        try await step("select the last photo (scrolls to the end)", settle: .milliseconds(1500)) {
            sel.select(only: last.id)
        }
        let offset = Self.gridScrollView(in: window)?.contentView.bounds.origin.y ?? 0
        line(tag, "grid: scroll offset after selecting the last photo", ["offset": Int(offset),
                                                                          "document_height": Int(height)])
        try await step("rate the selected photo (key 4)") { vm.setRatingForSelectionOrCurrent(4) }
        try await step("zoom out to 10 columns") { vm.gridColumns = 10 }
        try await step("open the detail view") { vm.openDetail(for: last) }
        try await step("close the detail view") { vm.closeDetail() }
        try await step("zoom back to 6 columns") { vm.gridColumns = 6 }

        probe = MainThreadProbe.start()
        start = clock.now
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(300))
        wall = clock.now - start
        stats = await probe.stop()
        line(tag, "grid: tear the window down", ["s": sec(wall), "longest_main_block_ms": stats.longest])
    }

    // MARK: - Metadata write throughput (real JPEG rewrites, on a small writable set)

    func testMetadataWriteThroughput() async throws {
        let pairs = try Self.sourcePairs()
        let base = try makeTempRoot("writes")
        let writable = base.appendingPathComponent("writable", isDirectory: true)
        let readOnly = base.appendingPathComponent("read-only", isDirectory: true)
        for folder in [writable, readOnly] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for pair in pairs {
                try CloneTree.clone(Self.sourceFolder.appendingPathComponent(pair.jpgName),
                                    to: folder.appendingPathComponent(pair.jpgName), inside: base)
                try CloneTree.clone(Self.sourceFolder.appendingPathComponent(pair.rawName),
                                    to: folder.appendingPathComponent(pair.rawName), inside: base)
            }
        }
        // Only the clones' JPGs in `writable` are made writable, as a user's photos are.
        for pair in pairs {
            XCTAssertEqual(chmod(writable.appendingPathComponent(pair.jpgName).path, 0o644), 0)
        }
        let count = pairs.count
        func items(_ folder: URL, rating: Int, raw: Bool) -> [MetadataWriteItem] {
            pairs.map { pair in
                let jpg = folder.appendingPathComponent(pair.jpgName).path
                let rawPath = folder.appendingPathComponent(pair.rawName).path
                return raw ? MetadataWriteItem(path: rawPath, rating: rating, keywords: ["scale:write"])
                    : MetadataWriteItem(path: jpg, rating: rating, keywords: ["scale:write"], pairedRAWPath: rawPath)
            }
        }
        func run(_ label: String, _ batch: [MetadataWriteItem], writes: Int) async -> Double {
            let freeBefore = Self.freeBytes(base)
            let probe = MainThreadProbe.start()
            let start = clock.now
            MetadataWriter.shared.enqueue(batch)
            await MetadataWriter.shared.flush()
            let wall = clock.now - start
            let stats = await probe.stop()
            let perItem = ms(wall) / Double(batch.count)
            line("writes", label, [
                "photos": batch.count, "file_writes": writes, "s": sec(wall), "ms_per_photo": perItem,
                "est_min_50k": perItem * 50_000 / 60_000, "est_min_150k": perItem * 150_000 / 60_000,
                "photos_in_5s_quit_flush": Int(5_000 / perItem),
                "disk_used_mb": Double(freeBefore - Self.freeBytes(base)) / 1_048_576,
                "longest_main_block_ms": stats.longest,
            ])
            return perItem
        }
        let sample = writable.appendingPathComponent(pairs[0].jpgName).path
        let sizeBefore = (try FileManager.default.attributesOfItem(atPath: sample)[.size] as? NSNumber)?.intValue ?? -1
        _ = await run("pair, writable JPG (JPEG splice + new sidecar)", items(writable, rating: 4, raw: false),
                      writes: 2 * count)
        XCTAssertEqual(MetadataService.shared.readMetadata(from: sample).rating, 4)
        // The rewrite changes the JPEG's size, so the next scan updates the photo's stored `fileSize`.
        let sizeAfter = (try FileManager.default.attributesOfItem(atPath: sample)[.size] as? NSNumber)?.intValue ?? -1
        line("writes", "a JPEG's size after its first rating write", ["before": sizeBefore, "after": sizeAfter,
                                                                      "delta": sizeAfter - sizeBefore])
        _ = await run("pair, writable JPG again (JPEG with XMP + sidecar update)", items(writable, rating: 2, raw: false),
                      writes: 2 * count)
        XCTAssertEqual(MetadataService.shared.readMetadata(from: sample).rating, 2)
        _ = await run("pair, read-only JPG (what the scale run's clones do: sidecar only)",
                      items(readOnly, rating: 4, raw: false), writes: count)
        _ = await run("RAW sidecar update only", items(readOnly, rating: 1, raw: true), writes: count)
        Self.removeTree(base)
        tempRoots.removeAll { $0 == base }
    }

    // MARK: - The thumbnail disk cache past its cap

    func testThumbnailDiskCachePastItsCap() async throws {
        let base = try makeTempRoot("thumbnails")
        let directory = ThumbnailDiskCache.directory(in: base)
        XCTAssertTrue(directory.path.hasPrefix(base.path))
        let cache = ThumbnailDiskCache(directory: directory) // the app's settings: 1 GB, a trim check every 100 stores
        let image = Self.makeThumbnailImage(width: 384, height: 256)
        let encoded = Self.jpegSize(image)
        let target = cache.byteLimit + cache.byteLimit / 2
        let stores = target / max(1, encoded)
        line("thumbnails", "fill plan", ["limit_mb": mb(UInt64(cache.byteLimit)), "file_kb": encoded / 1024,
                                         "stores": stores, "target_mb": mb(UInt64(target))])

        let keys = (0..<stores).map { i in
            ThumbnailDiskCache.Key(path: "/scale/shoot-\(i / 190)/DSC\(i).JPG", fileSize: Int64(4_000_000 + i),
                                   modificationDate: Date(timeIntervalSince1970: 1_600_000_000 + Double(i)), bucket: 384)
        }
        // Stores at about the rate the grid would make them, in batches the pending-bytes cap never drops.
        let probe = MainThreadProbe.start()
        let start = clock.now
        let fill = await Task.detached(priority: .userInitiated) { () -> (batches: Int, slowest: Double, trims: Int) in
            var slowest = 0.0
            var batches = 0
            for batchStart in stride(from: 0, to: keys.count, by: 100) {
                let t0 = DispatchTime.now().uptimeNanoseconds
                for key in keys[batchStart..<min(batchStart + 100, keys.count)] { cache.store(image, for: key) }
                cache.waitForPendingWork()
                slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                batches += 1
            }
            return (batches, slowest, cache.fullScanCount)
        }.value
        let wall = clock.now - start
        let stats = await probe.stop()
        var disk = Self.cacheUsage(directory)
        line("thumbnails", "filled to 1.5x the cap", [
            "s": sec(wall), "batches_of_100": fill.batches, "slowest_batch_ms": fill.slowest, "full_scans": fill.trims,
            "files_on_disk": disk.files, "on_disk_mb": mb(UInt64(disk.bytes)),
            "known_total_mb": mbInt(cache.knownByteTotal), "longest_main_block_ms": stats.longest,
        ])
        XCTAssertLessThanOrEqual(disk.bytes, cache.byteLimit + 100 * encoded * 2, "trimmed back under the cap")
        XCTAssertEqual(Double(cache.knownByteTotal ?? -1), Double(disk.bytes), accuracy: Double(disk.bytes) / 50,
                       "the running total is right")

        // LRU: of the oldest survivors, the ones read since survive the next trims; the others go first.
        let survivors = keys.filter { FileManager.default.fileExists(atPath: cache.fileURL(for: $0).path) }
        let oldest = Array(survivors.prefix(400))
        let read = oldest.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        for key in read { XCTAssertNotNil(cache.image(for: key)) }
        cache.waitForPendingWork()
        let more = (0..<(stores / 5)).map { i in
            ThumbnailDiskCache.Key(path: "/scale/more-\(i).JPG", fileSize: Int64(i), modificationDate: Date(), bucket: 384)
        }
        await Task.detached {
            for batchStart in stride(from: 0, to: more.count, by: 100) {
                for key in more[batchStart..<min(batchStart + 100, more.count)] { cache.store(image, for: key) }
                cache.waitForPendingWork()
            }
        }.value
        let readKept = read.filter { FileManager.default.fileExists(atPath: cache.fileURL(for: $0).path) }.count
        let unreadKept = oldest.count - read.count
            - oldest.filter { !read.contains($0) && !FileManager.default.fileExists(atPath: cache.fileURL(for: $0).path) }.count
        disk = Self.cacheUsage(directory)
        line("thumbnails", "LRU after 20% more stores", [
            "read_kept": "\(readKept)/\(read.count)", "unread_kept": "\(unreadKept)/\(oldest.count - read.count)",
            "files_on_disk": disk.files, "on_disk_mb": mb(UInt64(disk.bytes)), "full_scans": cache.fullScanCount,
        ])
        XCTAssertEqual(readKept, read.count, "recently read thumbnails survive the trims")
        XCTAssertEqual(unreadKept, 0, "the oldest unread thumbnails go first")

        // Relaunch with an intact byte total: no scan. With it gone: one full scan, which mustn't block reads.
        let relaunched = ThumbnailDiskCache(directory: directory)
        var t = clock.measure { relaunched.trimIfNeeded(); relaunched.waitForPendingWork() }
        line("thumbnails", "relaunch, byte total intact: first trim check", ["ms": ms(t), "full_scans": relaunched.fullScanCount])
        XCTAssertEqual(relaunched.fullScanCount, 0)
        try FileManager.default.removeItem(at: relaunched.byteTotalURL)
        let rescanning = ThumbnailDiskCache(directory: directory)
        let sampleKeys = Array(read.prefix(100))
        let readerDone = Task.detached { () -> Double in
            var slowest = 0.0
            for key in sampleKeys {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = rescanning.image(for: key)
                slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            return slowest
        }
        t = clock.measure { rescanning.trimIfNeeded(); rescanning.waitForPendingWork() }
        let slowestRead = await readerDone.value
        line("thumbnails", "relaunch, byte total gone: first trim scans the cache", [
            "ms": ms(t), "full_scans": rescanning.fullScanCount, "slowest_read_during_ms": slowestRead,
            "known_total_mb": mbInt(rescanning.knownByteTotal),
        ])
        XCTAssertEqual(rescanning.fullScanCount, 1)
        Self.removeTree(base)
        tempRoots.removeAll { $0 == base }
    }

    // MARK: - Tagging many photos: where the time goes

    /// `LibraryStore.addTag(…to: photos)` / `removeTag(_:from: photos)` change each photo's `tags`, one photo at a time.
    /// This times that against changing the tag's side (`tag.photos`) once, on a temp store with k photos and one tag,
    /// and checks both leave the same relationship behind. Not app code: evidence for a fix.
    func testTagRelationshipCost() async throws {
        let base = try makeTempRoot("tags")
        for k in [1_000, 2_000, 4_000] {
            let container = try makeContainer(base.appendingPathComponent("tags-\(k).store"))
            let context = container.mainContext
            let tag = Tag(name: "bulk", category: "scale")
            context.insert(tag)
            var photos: [PhotoAsset] = []
            for i in 0..<k {
                let photo = PhotoAsset(fileName: "p\(i)", jpgPath: "/scale/p\(i).jpg", folderPath: "/scale",
                                       creationDate: Date(timeIntervalSince1970: Double(i)), fileSize: 1)
                context.insert(photo)
                photos.append(photo)
            }
            try context.save()
            func timed(_ label: String, _ mutate: () -> Void) throws {
                let mutateTime = clock.measure(mutate)
                let saveTime = try clock.measure { try context.save() }
                let fresh = ModelContext(container)
                let stored = try fresh.fetch(FetchDescriptor<Tag>()).first?.photos.count ?? -1
                line("tags", label, ["k": k, "mutate_ms": ms(mutateTime), "save_ms": ms(saveTime),
                                     "tag_photos_stored": stored,
                                     "photos_with_tag": photos.filter { $0.tags.contains { $0.id == tag.id } }.count])
            }
            try timed("add, per photo (photo.tags.append, as addTag does)") {
                for photo in photos where !photo.tags.contains(where: { $0.id == tag.id }) { photo.tags.append(tag) }
            }
            try timed("remove, per photo (photo.tags.removeAll, as removeTag does)") {
                for photo in photos { photo.tags.removeAll { $0.id == tag.id } }
            }
            try timed("add, once on the tag (tag.photos.append(contentsOf:))") {
                tag.photos.append(contentsOf: photos.filter { !$0.tags.contains(where: { $0.id == tag.id }) })
            }
            try timed("remove, once on the tag (tag.photos.removeAll)") {
                let ids = Set(photos.map(\.id))
                tag.photos.removeAll { ids.contains($0.id) }
            }
            // Deleting tagged photos (emptying the bin): each delete takes the photo out of its tags.
            tag.photos.append(contentsOf: photos)
            try context.save()
            let doomed = Array(photos.prefix(k / 2))
            let deleteTime = try clock.measure {
                for photo in doomed { context.delete(photo) }
                try context.save()
            }
            // As many new tagged photos again, so the tag is back to k photos for the second way.
            var untagFirst: [PhotoAsset] = []
            for i in 0..<(k / 2) {
                let photo = PhotoAsset(fileName: "q\(i)", jpgPath: "/scale/q\(i).jpg", folderPath: "/scale",
                                       creationDate: Date(timeIntervalSince1970: Double(i)), fileSize: 1)
                context.insert(photo)
                untagFirst.append(photo)
            }
            tag.photos.append(contentsOf: untagFirst)
            try context.save()
            let untagThenDelete = try clock.measure {
                let ids = Set(untagFirst.map(\.id))
                tag.photos.removeAll { ids.contains($0.id) }
                for photo in untagFirst { context.delete(photo) }
                try context.save()
            }
            line("tags", "delete tagged photos (context.delete each + save)", [
                "k": k, "deleted": doomed.count, "ms": ms(deleteTime),
                "untag_on_the_tag_first_then_delete_ms": ms(untagThenDelete),
                "rows_left": try ModelContext(container).fetchCount(FetchDescriptor<PhotoAsset>()),
            ])
        }
        Self.removeTree(base)
        tempRoots.removeAll { $0 == base }
    }

    /// The same patterns with the library and the tag at the owner's size: n photos (PHOCASA_SCALE_TAG_N, default
    /// 150,000) registered in the main context of a temp store, and one tag grown to 50,000 and then to every photo.
    /// Times each change and its save apart: a save pays for every photo the context holds, and a to-many relationship
    /// is read whole on every access, so a tag-side change costs time in proportion to the tag's size. Not app code:
    /// evidence for sizing the chunks the library writes in.
    func testTagCostAtLibraryScale() async throws {
        let n = ProcessInfo.processInfo.environment["PHOCASA_SCALE_TAG_N"].flatMap { Int($0) } ?? 150_000
        let base = try makeTempRoot("tagscale")
        let container = try makeContainer(base.appendingPathComponent("tagscale.store"))
        var start = clock.now
        try await Task.detached(priority: .userInitiated) {
            let background = ModelContext(container)
            for batch in stride(from: 0, to: n, by: 5_000) {
                for i in batch..<min(batch + 5_000, n) {
                    background.insert(PhotoAsset(fileName: "p\(i)", jpgPath: "/scale/p\(i).jpg", folderPath: "/scale",
                                                 creationDate: Date(timeIntervalSince1970: Double(i)), fileSize: 1))
                }
                try background.save()
            }
        }.value
        line("tagscale", "harness: insert rows (background context)", ["n": n, "s": sec(clock.now - start)])
        let context = container.mainContext
        start = clock.now
        let photos = try context.fetch(FetchDescriptor<PhotoAsset>(sortBy: [SortDescriptor(\.creationDate)]))
        line("tagscale", "harness: fetch every row into the main context", ["n": photos.count, "s": sec(clock.now - start)])
        XCTAssertEqual(photos.count, n)

        func timed(_ label: String, _ mutate: () -> Void) {
            let mutateTime = clock.measure(mutate)
            let saveTime = clock.measure { try? context.save() }
            line("tagscale", label, ["n": n, "mutate_ms": ms(mutateTime), "save_ms": ms(saveTime),
                                     "total_ms": ms(mutateTime) + ms(saveTime)])
        }
        timed("save, nothing changed") {}
        timed("rating of 1 photo") { photos[0].rating = 1 }
        timed("rating of 500 photos") { for photo in photos[1..<501] { photo.rating = 2 } }
        timed("rating of 2,000 photos") { for photo in photos[501..<2_501] { photo.rating = 3 } }
        let tag = Tag(name: "big", category: "scale")
        let small = Tag(name: "small", category: "scale")
        timed("insert two tags") { context.insert(tag); context.insert(small) }

        timed("tag side: add 500 (tag has 0)") { tag.photos.append(contentsOf: photos[0..<500]) }
        timed("tag side: add 49,500 (tag has 500)") { tag.photos.append(contentsOf: photos[500..<50_000]) }
        timed("read the tag's photos (50,000)") { _ = tag.photos.count }
        timed("tag side: add 500 (tag has 50,000)") { tag.photos.append(contentsOf: photos[50_000..<50_500]) }
        timed("photo side: add 1 (tag has 50,500)") { photos[60_000].tags.append(tag) }
        timed("tag side: add 1 (tag has 50,501)") { tag.photos.append(photos[60_001]) }
        let doomed = Set(photos[0..<500].map(ObjectIdentifier.init))
        timed("tag side: remove 500 (tag has 50,502)") { tag.photos.removeAll { doomed.contains(ObjectIdentifier($0)) } }
        timed("photo side: remove 1 (tag has 50,002)") { photos[1_000].tags.removeAll { $0 === tag } }
        let one = ObjectIdentifier(photos[1_001])
        timed("tag side: remove 1 (tag has 50,001)") { tag.photos.removeAll { ObjectIdentifier($0) == one } }
        timed("tag side: add the rest (tag has 50,000)") {
            let has = Set(tag.photos.map(ObjectIdentifier.init))
            tag.photos.append(contentsOf: photos.filter { !has.contains(ObjectIdentifier($0)) })
        }
        timed("read the tag's photos (every photo)") { _ = tag.photos.count }
        timed("tag side: remove 500 (tag has every photo)") {
            tag.photos.removeAll { doomed.contains(ObjectIdentifier($0)) }
        }
        timed("tag side: add 500 back (tag has all but 500)") { tag.photos.append(contentsOf: photos[0..<500]) }
        timed("photo side: remove 1 (tag has every photo)") { photos[2_000].tags.removeAll { $0 === tag } }
        timed("photo side: add 1 (tag has all but 1)") { photos[2_000].tags.append(tag) }
        timed("small tag, tag side: add 500 (every photo has the big tag)") {
            small.photos.append(contentsOf: photos[3_000..<3_500])
        }
        timed("small tag, photo side: add 500 one by one") {
            for photo in photos[4_000..<4_500] { photo.tags.append(small) }
        }

        // New photos with keywords, as a scan inserts them: each with the big tag and the small one.
        var inserted: [PhotoAsset] = []
        timed("insert 256 photos, tags assigned on each photo (as scans do)") {
            for i in 0..<256 {
                let photo = PhotoAsset(fileName: "q\(i)", jpgPath: "/scale/q\(i).jpg", folderPath: "/scale", fileSize: 1)
                context.insert(photo)
                photo.tags = [tag, small]
                inserted.append(photo)
            }
        }
        timed("insert 256 photos, tags added on the tags' side") {
            var batch: [PhotoAsset] = []
            for i in 0..<256 {
                let photo = PhotoAsset(fileName: "r\(i)", jpgPath: "/scale/r\(i).jpg", folderPath: "/scale", fileSize: 1)
                context.insert(photo)
                batch.append(photo)
            }
            tag.photos.append(contentsOf: batch)
            small.photos.append(contentsOf: batch)
            inserted += batch
        }
        timed("delete 500 tagged photos, untagged on the tags' side first") {
            let doomedPhotos = Array(photos[10_000..<10_500])
            let ids = Set(doomedPhotos.map(ObjectIdentifier.init))
            tag.photos.removeAll { ids.contains(ObjectIdentifier($0)) }
            for photo in doomedPhotos { context.delete(photo) }
        }
        let fresh = ModelContext(container)
        let stored = try fresh.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.name == "big" })).first?.photos.count
        line("tagscale", "links stored", ["big": stored ?? -1, "expected": n + 512 - 500])
        XCTAssertEqual(stored, n + 512 - 500)
        withExtendedLifetime(photos) {}
        Self.removeTree(base)
        tempRoots.removeAll { $0 == base }
    }

    // MARK: - Measuring

    private func rescan(_ vm: PhotoLibraryViewModel, _ tag: String, _ label: String) async throws
        -> LibraryStore.ScanReport?
    {
        let probe = MainThreadProbe.start()
        try await Task.sleep(for: .milliseconds(30))
        let start = clock.now
        vm.library.rescanCurrentLibrary()
        await vm.library.waitForScans()
        let wall = clock.now - start
        let stats = await probe.stop()
        let report = vm.library.lastScanReport
        line(tag, label, [
            "wall_s": sec(wall), "main_actor_ms": ms(report?.mainActorTime), "longest_main_block_ms": stats.longest,
            "blocks_over_250ms": stats.over250, "discovered": report?.discovered ?? -1,
            "inserted": report?.inserted ?? -1, "updated": report?.updated ?? -1, "missing": report?.missing ?? -1,
            "reloaded": report?.reloaded ?? false, "library": vm.library.allPhotos.count,
            "peak_footprint_mb": mb(stats.peakFootprint),
        ])
        return report
    }

    /// Times `body` (synchronous, on the main actor), then lets whatever it started run for `settle`.
    private func op(_ tag: String, _ label: String, settle: Duration = .milliseconds(300), _ body: () -> Void) async {
        let probe = MainThreadProbe.start()
        try? await Task.sleep(for: .milliseconds(30))
        let sync = clock.measure(body)
        try? await Task.sleep(for: settle)
        let stats = await probe.stop()
        line(tag, label, ["sync_ms": ms(sync), "longest_main_block_ms": stats.longest,
                          "peak_footprint_mb": mb(stats.peakFootprint)])
    }

    /// Waits for `library`'s rows to be written (a big change goes in chunks, and queues each photo's file writes as
    /// its row is written), then for `MetadataWriter.shared` to write everything queued.
    private func drain(_ tag: String, _ label: String, writes: Int, library: LibraryStore? = nil) async {
        let probe = MainThreadProbe.start()
        let start = clock.now
        await library?.waitForRowWrites()
        let rows = clock.now - start
        await MetadataWriter.shared.flush()
        let wall = clock.now - start
        let stats = await probe.stop()
        line(tag, label, ["row_writes_s": sec(rows), "drain_s": sec(wall), "file_writes": writes,
                          "ms_per_write": ms(wall) / Double(max(writes, 1)), "longest_main_block_ms": stats.longest])
    }

    private func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: - Output

    private func line(_ tag: String, _ label: String, _ fields: KeyValuePairs<String, Any>) {
        let values = fields.map { key, value -> String in
            if let d = value as? Double { return "\(key)=\(String(format: "%.1f", d))" }
            return "\(key)=\(value)"
        }
        print((["SCALE", tag, label] + values).joined(separator: "|"))
    }

    private func ms(_ d: Duration?) -> Double {
        guard let d else { return -1 }
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private func sec(_ d: Duration) -> Double { ms(d) / 1000 }
    private func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
    private func mbInt(_ bytes: Int?) -> Double { bytes.map { Double($0) / 1_048_576 } ?? -1 }

    private func printEnvironment(base: URL, pairs: Int) {
        let info = ProcessInfo.processInfo
        line("env", "machine", [
            "cores": info.activeProcessorCount, "ram_gb": Double(info.physicalMemory) / 1_073_741_824,
            "os": info.operatingSystemVersionString, "sizes": Self.sizes.map(String.init).joined(separator: ","),
            "source_pairs": pairs, "free_disk_gb": Double(Self.freeBytes(base)) / 1_073_741_824,
        ])
    }

    // MARK: - Setup helpers

    static var sizes: [Int] {
        let raw = ProcessInfo.processInfo.environment["PHOCASA_SCALE_SIZES"] ?? "10000,25000,50000"
        return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }.sorted()
    }

    static var sourceFolder: URL {
        if let path = ProcessInfo.processInfo.environment["PHOCASA_SCALE_SOURCE"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PhocasaBenchRAW", isDirectory: true)
    }

    /// The source's JPG+RAW pairs (by stem), from one listing of the folder.
    static func sourcePairs() throws -> [CloneTree.Pair] {
        let names = try FileManager.default.contentsOfDirectory(atPath: sourceFolder.path)
        var byStem: [String: (jpg: String?, raw: String?)] = [:]
        for name in names where !name.hasPrefix(".") {
            let ext = (name as NSString).pathExtension.lowercased()
            let stem = (name as NSString).deletingPathExtension
            if ext == "jpg" || ext == "jpeg" {
                byStem[stem, default: (nil, nil)].jpg = name
            } else if FolderScanner.rawExtensions.contains(ext) {
                byStem[stem, default: (nil, nil)].raw = name
            }
        }
        return byStem.compactMap { stem, files in
            guard let jpg = files.jpg, let raw = files.raw else { return nil }
            return CloneTree.Pair(stem: stem, jpgName: jpg, rawName: raw)
        }.sorted { $0.stem < $1.stem }
    }

    private func makeTempRoot(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-scale-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(realpath(dir.path, nil))
        defer { free(canonical) }
        let url = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        tempRoots.append(url)
        return url
    }

    private func makeContainer(_ storeURL: URL) throws -> ModelContainer {
        precondition(storeURL.path.contains("/phocasa-scale-") && !storeURL.path.contains("Application Support"),
                     "temp stores only")
        return try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                  configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
    }

    /// Removes a temp tree (its files are read-only clones: removal needs only the folders to be writable).
    static func removeTree(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func freeBytes(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).flatMap { $0 }
            .map(Int64.init) ?? 0
    }

    static func storeBytes(_ storeURL: URL) -> UInt64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: storeURL.path + suffix)[.size] as? NSNumber)
            return total + (size?.uint64Value ?? 0)
        }
    }

    /// The store's SQLite indexes (read-only look at a temp store).
    static func storeIndexes(_ storeURL: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT tbl_name, name FROM sqlite_master WHERE type = 'index' ORDER BY tbl_name, name"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var indexes: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            indexes.append("\(String(cString: sqlite3_column_text(statement, 0))).\(String(cString: sqlite3_column_text(statement, 1)))")
        }
        return indexes
    }

    /// Rows in one of the store's tables (read-only look at a temp store), or -1.
    static func storeCount(_ storeURL: URL, table: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }

    /// Scrolls the grid as a scroll wheel would, by `dy` points.
    static func scroll(_ window: NSWindow, by dy: CGFloat) {
        guard let scrollView = gridScrollView(in: window) else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = max(0, origin.y + dy)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    static func gridScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    /// A thumbnail-like image: soft shapes with a little grain, so its JPEG is about the size of a photo's.
    static func makeThumbnailImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            context.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                         blue: .random(in: 0...1, using: &rng), alpha: 0.5))
            let w = CGFloat.random(in: 4...80, using: &rng), h = CGFloat.random(in: 4...80, using: &rng)
            context.fillEllipse(in: CGRect(x: .random(in: 0...CGFloat(width), using: &rng),
                                           y: .random(in: 0...CGFloat(height), using: &rng), width: w, height: h))
        }
        return context.makeImage()!
    }

    static func jpegSize(_ image: CGImage) -> Int {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data.length
    }

    /// Files and allocated bytes of the cache's thumbnails.
    static func cacheUsage(_ directory: URL) -> (files: Int, bytes: Int) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return (0, 0)
        }
        var files = 0, bytes = 0
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jpg", let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += values.totalFileAllocatedSize ?? 0
        }
        return (files, bytes)
    }
}

// MARK: - The synthetic library

/// APFS clones of the source's pairs in a nested folder tree under `base`: the library root for each size contains the
/// one for the next smaller size, so a scan of `roots[i]` finds `photoCount(i)` photos. Leaves hold up to one copy of
/// each source pair (`year/month/shoot-k/`); every third leaf has a Lightroom-style `.xmp` sidecar per pair, with a
/// rating and three keywords.
final class CloneTree {
    struct Pair {
        let stem: String
        let jpgName: String
        let rawName: String
    }

    struct Leaf {
        let url: URL
        let pairs: Int
        let keyworded: Bool
        let index: Int
    }

    /// What `change(level:removing:adding:)` did, for `undo(_:)`.
    struct Change {
        var moved: [(from: URL, to: URL)] = []
        var addedFolder: URL
    }

    let source: URL
    let pairs: [Pair]
    let base: URL
    private(set) var roots: [URL] = []
    private(set) var leavesByLevel: [[Leaf]] = []

    init(source: URL, pairs: [Pair], base: URL, sizes: [Int]) throws {
        self.source = source
        self.pairs = pairs
        self.base = base
        var descending: [URL] = []
        var current = base.appendingPathComponent("Photos", isDirectory: true)
        for level in sizes.indices.reversed() {
            descending.append(current)
            current = current.appendingPathComponent("Archive \(level)", isDirectory: true)
        }
        roots = descending.reversed()
        var leafIndex = 0
        var previous = 0
        for (level, size) in sizes.enumerated() {
            var remaining = size - previous
            var leaves: [Leaf] = []
            while remaining > 0 {
                let count = min(pairs.count, remaining)
                let url = roots[level]
                    .appendingPathComponent(String(2008 + leafIndex / 12), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", leafIndex % 12 + 1), isDirectory: true)
                    .appendingPathComponent("Shoot \(leafIndex)", isDirectory: true)
                leaves.append(Leaf(url: url, pairs: count, keyworded: leafIndex % 3 == 0, index: leafIndex))
                remaining -= count
                leafIndex += 1
            }
            leavesByLevel.append(leaves)
            previous = size
        }
    }

    var allLeaves: [Leaf] { leavesByLevel.flatMap { $0 } }
    var leafCount: Int { allLeaves.count }
    var maxDepth: Int {
        let baseDepth = base.pathComponents.count
        return (allLeaves.map { $0.url.pathComponents.count }.max() ?? baseDepth) - baseDepth
    }

    func leaves(upTo level: Int) -> [Leaf] { leavesByLevel[0...level].flatMap { $0 } }
    func photoCount(_ level: Int) -> Int { leaves(upTo: level).reduce(0) { $0 + $1.pairs } }
    func keywordedCount(_ level: Int) -> Int { leaves(upTo: level).filter(\.keyworded).reduce(0) { $0 + $1.pairs } }

    func ratedCount(_ level: Int) -> Int {
        leaves(upTo: level).filter(\.keyworded).reduce(0) { total, leaf in
            total + (0..<leaf.pairs).filter { rating(leaf: leaf.index, pair: $0) > 0 }.count
        }
    }

    func tagNames(_ level: Int) -> Set<String> {
        var names = Set<String>()
        for leaf in leaves(upTo: level) where leaf.keyworded {
            for pair in 0..<leaf.pairs { names.formUnion(keywords(leaf: leaf.index, pair: pair)) }
        }
        return names
    }

    func rating(leaf: Int, pair: Int) -> Int { (leaf + pair) % 6 }

    func keywords(leaf: Int, pair: Int) -> [String] {
        ["people:person \(pair % 20)", "places:place \(leaf % 25)", "trip \(leaf)"]
    }

    /// Clones every leaf's pairs and writes the keyword sidecars.
    func populate() throws -> (files: Int, sidecars: Int) {
        var files = 0
        var sidecars = 0
        for leaf in allLeaves {
            try FileManager.default.createDirectory(at: leaf.url, withIntermediateDirectories: true)
            for p in 0..<leaf.pairs {
                let pair = pairs[p]
                try Self.clone(source.appendingPathComponent(pair.jpgName), to: leaf.url.appendingPathComponent(pair.jpgName),
                               inside: base)
                try Self.clone(source.appendingPathComponent(pair.rawName), to: leaf.url.appendingPathComponent(pair.rawName),
                               inside: base)
                files += 2
            }
            if leaf.keyworded { sidecars += try writeSidecars(leaf) }
        }
        return (files, sidecars)
    }

    private func writeSidecars(_ leaf: Leaf) throws -> Int {
        for p in 0..<leaf.pairs {
            let url = leaf.url.appendingPathComponent(pairs[p].stem).appendingPathExtension("xmp")
            try Self.sidecar(rating: rating(leaf: leaf.index, pair: p), keywords: keywords(leaf: leaf.index, pair: p))
                .write(to: url)
        }
        return leaf.pairs
    }

    /// Removes every sidecar (the scale run's writes add one to every pair) and writes the tree's own again.
    func resetSidecars() throws {
        let top = roots.last!
        guard let enumerator = FileManager.default.enumerator(at: top, includingPropertiesForKeys: nil) else { return }
        var doomed: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if url.pathExtension.lowercased() == "xmp" || name.contains(".phocasa-tmp-") { doomed.append(url) }
        }
        for url in doomed { try FileManager.default.removeItem(at: url) }
        for leaf in allLeaves where leaf.keyworded { _ = try writeSidecars(leaf) }
    }

    /// Moves `removing` pairs of this level's own leaves out of the tree (into `base/held`), and clones `adding` new
    /// pairs into a new folder of the level's root.
    func change(level: Int, removing: Int, adding: Int) throws -> Change {
        let held = base.appendingPathComponent("held-\(level)", isDirectory: true)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        var change = Change(addedFolder: roots[level].appendingPathComponent("Import \(level)", isDirectory: true))
        var left = removing
        for leaf in leavesByLevel[level].reversed() where left > 0 {
            for p in 0..<min(leaf.pairs, left) {
                for name in [pairs[p].jpgName, pairs[p].rawName, pairs[p].stem + ".xmp"] {
                    let from = leaf.url.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: from.path) else { continue }
                    let to = held.appendingPathComponent("\(leaf.index)-\(name)")
                    try FileManager.default.moveItem(at: from, to: to)
                    change.moved.append((from, to))
                }
                left -= 1
            }
        }
        precondition(left == 0, "not enough photos to remove")
        var added = 0
        var batch = 0
        while added < adding {
            let folder = change.addedFolder.appendingPathComponent("Batch \(batch)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for pair in pairs.prefix(adding - added) {
                try Self.clone(source.appendingPathComponent(pair.jpgName), to: folder.appendingPathComponent(pair.jpgName),
                               inside: base)
                try Self.clone(source.appendingPathComponent(pair.rawName), to: folder.appendingPathComponent(pair.rawName),
                               inside: base)
                added += 1
            }
            batch += 1
        }
        return change
    }

    func undo(_ change: Change) throws {
        for (from, to) in change.moved { try FileManager.default.moveItem(at: to, to: from) }
        try FileManager.default.removeItem(at: change.addedFolder)
    }

    /// An APFS clone of `source` at `destination`, which must be inside `root`. Fails rather than copy.
    static func clone(_ source: URL, to destination: URL, inside root: URL) throws {
        precondition(destination.path.hasPrefix(root.path + "/"), "clones go inside the temp tree only")
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    /// A Lightroom-style sidecar: rating and keywords.
    static func sidecar(rating: Int, keywords: [String]) -> Data {
        let items = keywords.map { "     <rdf:li>\($0)</rdf:li>" }.joined(separator: "\n")
        return Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmp:Rating="\(rating)">
           <dc:subject>
            <rdf:Bag>
        \(items)
            </rdf:Bag>
           </dc:subject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """.utf8)
    }
}

/// Timestamped events from any thread, in seconds since it was made.
final class EventLog: @unchecked Sendable {
    let origin = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var logged: [(time: Double, what: String)] = []
    private var saveCount = 0
    private var lastSaveLogged = -1.0

    private var now: Double { Double(DispatchTime.now().uptimeNanoseconds - origin) / 1e9 }
    var events: [(time: Double, what: String)] { lock.withLock { logged } }
    var saves: Int { lock.withLock { saveCount } }

    func add(_ what: String) {
        let time = now
        lock.withLock { logged.append((time, what)) }
    }

    /// Counts a save, and logs one at most every second.
    func addSave() {
        let time = now
        lock.withLock {
            saveCount += 1
            if time - lastSaveLogged >= 1 {
                logged.append((time, "main-context save #\(saveCount)"))
                lastSaveLogged = time
            }
        }
    }
}

/// Files a test `FileTrasher` moved into a temp folder, so they can be put back.
final class TrashLog: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var moved: [(from: URL, to: URL)] = []

    init(folder: URL) { self.folder = folder }

    var count: Int { lock.withLock { moved.count } }

    func move(_ url: URL) throws {
        let to = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: to)
        lock.withLock { moved.append((url, to)) }
    }

    func putBack() throws {
        for (from, to) in lock.withLock({ moved }) { try FileManager.default.moveItem(at: to, to: from) }
        lock.withLock { moved.removeAll() }
    }
}

// MARK: - Probing the main thread and memory

/// From a background thread, pings the main queue every ~5 ms and records how long each ping waited (the main thread
/// was busy that long), and samples the process's memory footprint every ~10 ms.
final class MainThreadProbe: @unchecked Sendable {
    struct Stats {
        var longest: Double = 0 // ms
        var over250 = 0
        var over1s = 0
        var pings = 0
        var peakFootprint: UInt64 = 0
    }

    /// A ping that waited more than `threshold`: when it was sent (seconds since `origin`) and how long it waited.
    struct Block {
        let start: Double
        let ms: Double
    }

    private let lock = NSLock()
    private var stats = Stats()
    private var running = true
    private var threshold = Double.infinity
    private var origin: UInt64 = 0
    private var logged: [Block] = []

    var blocks: [Block] { lock.withLock { logged } }

    static func start(logBlocksOver threshold: Double = .infinity, since origin: UInt64 = 0) -> MainThreadProbe {
        let probe = MainThreadProbe()
        probe.threshold = threshold
        probe.origin = origin
        let thread = Thread { probe.run() }
        thread.qualityOfService = .userInteractive
        thread.start()
        return probe
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func run() {
        while isRunning {
            let sent = DispatchTime.now().uptimeNanoseconds
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                let waited = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                self.lock.withLock {
                    self.stats.longest = max(self.stats.longest, waited)
                    if waited > 250 { self.stats.over250 += 1 }
                    if waited > 1000 { self.stats.over1s += 1 }
                    if waited > self.threshold {
                        self.logged.append(Block(start: Double(sent &- self.origin) / 1e9, ms: waited))
                    }
                    self.stats.pings += 1
                }
                answered.signal()
            }
            sample()
            while answered.wait(timeout: .now() + .milliseconds(10)) == .timedOut { sample() }
            usleep(5_000)
        }
    }

    private func sample() {
        let footprint = Memory.footprint()
        lock.withLock { stats.peakFootprint = max(stats.peakFootprint, footprint) }
    }

    /// Stops, after giving the main queue time to answer the ping in flight.
    func stop() async -> Stats {
        try? await Task.sleep(for: .milliseconds(60))
        return lock.withLock {
            running = false
            return stats
        }
    }
}

enum Memory {
    /// The process's physical footprint (what Activity Monitor shows as Memory).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
