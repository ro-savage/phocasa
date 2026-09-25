// Data-path benchmarks for PhotoLibraryViewModel (SwiftData fetch, filtering, scanning).
// Opt-in: skipped unless PHOCASA_BENCH=1 is set for the test runner, e.g.
//   TEST_RUNNER_PHOCASA_BENCH=1 xcodebuild ... test -only-testing:PhocasaTests/DataPathBenchmarks
// Results are printed as lines starting with "BENCH|" — grep the xcodebuild log for them.

import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

@MainActor
final class DataPathBenchmarks: XCTestCase {
    private let clock = ContinuousClock()
    private var tempDirs: [URL] = []
    private var retained: [AnyObject] = []

    override func tearDown() async throws {
        retained.removeAll()
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs.removeAll()
    }

    // MARK: Helpers

    private func skipUnlessBenchmarking() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOCASA_BENCH"] == "1", "Set PHOCASA_BENCH=1 to run benchmarks")
    }

    private func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private func f(_ x: Double) -> String { String(format: "%.3f", x) }

    private func report(_ tag: String, _ label: String, _ samples: [Double]) {
        let s = samples.sorted()
        print("BENCH|\(tag)|\(label)|median_ms=\(f(s[s.count / 2]))|min_ms=\(f(s.first!))|max_ms=\(f(s.last!))|runs=\(s.count)")
    }

    private func bench(_ tag: String, _ label: String, warmup: Int = 1, runs: Int = 5, _ body: () -> Void) {
        for _ in 0..<warmup { body() }
        var samples: [Double] = []
        for _ in 0..<runs { samples.append(ms(clock.measure { body() })) }
        report(tag, label, samples)
    }

    /// Like `bench`, but runs `setup` untimed before each timed `body`, so every run measures a change.
    private func benchChange(_ tag: String, _ label: String, warmup: Int = 1, runs: Int = 5,
                             setup: () -> Void, _ body: () -> Void) {
        for _ in 0..<warmup { setup(); body() }
        var samples: [Double] = []
        for _ in 0..<runs {
            setup()
            samples.append(ms(clock.measure { body() }))
        }
        report(tag, label, samples)
    }

    private func benchAsync(_ tag: String, _ label: String, warmup: Int = 1, runs: Int = 5,
                            _ body: () async throws -> Void) async throws {
        for _ in 0..<warmup { try await body() }
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = clock.now
            try await body()
            samples.append(ms(clock.now - start))
        }
        report(tag, label, samples)
    }

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-bench-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir.resolvingSymlinksInPath()
    }

    private func makeContainer(storeURL: URL) throws -> ModelContainer {
        let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        let c = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: config
        )
        retained.append(c)
        return c
    }

    private func waitForScan(_ vm: PhotoLibraryViewModel) async throws {
        while vm.library.isScanning { try await Task.sleep(for: .milliseconds(1)) }
    }

    /// Main-actor time of the view model's last scan, from task 20's `lastScanReport` hook. To run this harness
    /// against code without that hook, make this return nil: the main-actor lines are then left out.
    private func lastScanMainActorMs(_ vm: PhotoLibraryViewModel) -> Double? {
        vm.library.lastScanReport.map { ms($0.mainActorTime) }
    }

    /// Main-actor time of a launch's background load (task 32), over all its turns and its longest turn. To run this
    /// harness against code without it, make this return nil: those lines are then left out.
    private func backgroundLoadMs(_ vm: PhotoLibraryViewModel) -> (total: Double, longest: Double)? {
        vm.library.loading.lastBackgroundLoad.map { (ms($0.mainActorTime), ms($0.longestTurn)) }
    }

    private func reportIfAny(_ tag: String, _ label: String, _ samples: [Double]) {
        if !samples.isEmpty { report(tag, label, samples) }
    }

    /// The path the folder enumerator reports for `url` (`/private/var/…`, where `resolvingSymlinksInPath()`
    /// gives `/var/…`), so seeded rows match what a scan finds.
    private func canonical(_ url: URL) throws -> URL {
        let path = try XCTUnwrap(realpath(url.path, nil))
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    // MARK: Seeding

    /// Seeds `n` photos (real empty .jpg files), 40 tags in 5 categories, 2 tags each.
    private func seed(n: Int, into context: ModelContext, filesDir: URL) throws -> [Tag] {
        var rng = SplitMix64(state: 42)
        let categories = ["people", "places", "events", "gear", "misc"]
        var tags: [Tag] = []
        for cat in categories {
            for j in 0..<8 {
                let t = Tag(name: "\(cat)-\(j)", category: cat)
                context.insert(t)
                tags.append(t)
            }
        }
        let fm = FileManager.default
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<n {
            let name = String(format: "IMG_%05d", i)
            let path = filesDir.appendingPathComponent("\(name).jpg").path
            fm.createFile(atPath: path, contents: nil)
            let p = PhotoAsset(
                fileName: name, jpgPath: path, folderPath: filesDir.path,
                creationDate: base.addingTimeInterval(Double(-i) * 60), fileSize: 0
            )
            p.rating = Int.random(in: 0...5, using: &rng)
            context.insert(p)
            let a = Int.random(in: 0..<tags.count, using: &rng)
            var b = Int.random(in: 0..<tags.count, using: &rng)
            if b == a { b = (a + 1) % tags.count }
            p.tags = [tags[a], tags[b]]
        }
        try context.save()
        return tags
    }

    // MARK: Suite

    private func runSuite(n: Int) async throws {
        let tag = "N=\(n)"
        let dir = try makeTempDir("seed\(n)")
        // Canonical paths (task 32), so 7x rescans the n seeded rows. It used to seed `/var/…` paths, which the scan
        // doesn't match, so its warm-up run inserted a second row per file (results/20.md, deviation 1).
        let filesDir = try canonical(dir.appendingPathComponent("files", isDirectory: true).creatingDir())
        let storeURL = dir.appendingPathComponent("bench.store")
        let container = try makeContainer(storeURL: storeURL)
        let context = container.mainContext

        let seedStart = clock.now
        let tags = try seed(n: n, into: context, filesDir: filesDir)
        print("BENCH|\(tag)|seed (insert+save; harness, not app code)|ms=\(f(ms(clock.now - seedStart)))")

        // --- Cold paths: fresh containers on the same on-disk store (app-launch-like) ---
        do {
            let c2 = try makeContainer(storeURL: storeURL)
            let vm2 = PhotoLibraryViewModel()
            let start = clock.now
            let t = clock.measure { vm2.setModelContext(c2.mainContext) }
            print("BENCH|\(tag)|COLD setModelContext (fetch+stat+counts+tags)|ms=\(f(ms(t)))|allPhotos=\(vm2.library.allPhotos.count)")
            // (added by task 32) The library can load after setModelContext() returns: until it is in memory.
            await vm2.library.waitForScans()
            print("BENCH|\(tag)|COLD setModelContext until the library is loaded (waitForScans)|ms=\(f(ms(clock.now - start)))|allPhotos=\(vm2.library.allPhotos.count)")
            if let load = backgroundLoadMs(vm2) {
                print("BENCH|\(tag)|COLD background load: main-actor time / longest turn|ms=\(f(load.total))|longest_ms=\(f(load.longest))")
            }
        }
        do {
            let c3 = try makeContainer(storeURL: storeURL)
            let ctx = c3.mainContext
            var fetched: [PhotoAsset] = []
            let tFetch = clock.measure {
                fetched = (try? ctx.fetch(FetchDescriptor<PhotoAsset>(
                    predicate: #Predicate { !$0.isDeleted },
                    sortBy: [SortDescriptor(\.creationDate, order: .reverse)]))) ?? []
            }
            var refs = 0
            let tFault = clock.measure { for p in fetched { refs += p.tags.count } }
            let tWarm = clock.measure { for p in fetched { refs += p.tags.count } }
            print("BENCH|\(tag)|COLD fetch photos (no prefetch)|ms=\(f(ms(tFetch)))")
            print("BENCH|\(tag)|COLD first touch of photo.tags on all (relationship faults)|ms=\(f(ms(tFault)))")
            print("BENCH|\(tag)|second touch of photo.tags on all|ms=\(f(ms(tWarm)))|refs=\(refs)")
        }
        do {
            let c4 = try makeContainer(storeURL: storeURL)
            let ctx = c4.mainContext
            var fetched: [PhotoAsset] = []
            let tFetch = clock.measure {
                var d = FetchDescriptor<PhotoAsset>(
                    predicate: #Predicate { !$0.isDeleted },
                    sortBy: [SortDescriptor(\.creationDate, order: .reverse)])
                d.relationshipKeyPathsForPrefetching = [\.tags]
                fetched = (try? ctx.fetch(d)) ?? []
            }
            var refs = 0
            let tFault = clock.measure { for p in fetched { refs += p.tags.count } }
            print("BENCH|\(tag)|COLD fetch photos WITH prefetch [tags]|ms=\(f(ms(tFetch)))")
            print("BENCH|\(tag)|COLD touch photo.tags after prefetch|ms=\(f(ms(tFault)))|refs=\(refs)")
        }

        // --- Warm paths on the seeding context ---
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        await vm.library.waitForScans() // (added by task 32) a big library loads after setModelContext() returns
        vm.library.refreshAvailability()
        XCTAssertEqual(vm.library.allPhotos.count, n)

        // 1
        bench(tag, "1 loadExistingData() warm") { vm.loadExistingData() }
        bench(tag, "1a raw fetch(!isDeleted, sorted) warm") {
            _ = try? context.fetch(FetchDescriptor<PhotoAsset>(
                predicate: #Predicate { !$0.isDeleted },
                sortBy: [SortDescriptor(\.creationDate, order: .reverse)]))
        }
        bench(tag, "1b raw fetch(isDeleted) bin warm") {
            _ = try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.isDeleted }))
        }
        // 2
        bench(tag, "2 refreshAvailability() (stat all + load)") { vm.library.refreshAvailability() }
        let fm = FileManager.default
        let paths = vm.library.allPhotos.compactMap(\.jpgPath)
        bench(tag, "2a fileExists loop only (\(paths.count) stats)") {
            var c = 0
            for p in paths where fm.fileExists(atPath: p) { c += 1 }
            XCTAssertEqual(c, n)
        }
        // 3
        bench(tag, "3a applyFilter(.rated(3))") { vm.library.applyFilter(.rated(3)) }
        let rated3Count = vm.library.photos.count
        let tagId = tags[0].id
        bench(tag, "3b applyFilter(.tag(people-0))") { vm.library.applyFilter(.tag(tagId)) }
        let tagCount = vm.library.photos.count
        bench(tag, "3c applyFilter(.all)") { vm.library.applyFilter(.all) }
        bench(tag, "3d toggleSortOrder()") { vm.library.toggleSortOrder() }
        if !vm.library.sortNewestFirst { vm.library.toggleSortOrder() }
        // 3e–3h (added by task 10): 3a–3c repeat the same click, which an in-memory data path can
        // answer without work. These change the filter on every run.
        benchChange(tag, "3e applyFilter(.rated(3)) from no filter", setup: { vm.library.applyFilter(.all) }) {
            vm.library.applyFilter(.rated(3))
        }
        benchChange(tag, "3f applyFilter(.tag(people-0)) from no filter", setup: { vm.library.applyFilter(.all) }) {
            vm.library.applyFilter(.tag(tagId))
        }
        benchChange(tag, "3g applyFilter(.all) from .rated(3)", setup: { vm.library.applyFilter(.rated(3)) }) {
            vm.library.applyFilter(.all)
        }
        benchChange(tag, "3h applyFilter(.rated(4)) replacing .rated(3)", setup: { vm.library.applyFilter(.rated(3)) }) {
            vm.library.applyFilter(.rated(4))
        }
        vm.library.applyFilter(.all)
        print("BENCH|\(tag)|info|rated3=\(rated3Count)|tagPeople0=\(tagCount)")

        // 4
        vm.library.applyFilter(.all)
        bench(tag, "4 search keystroke 't' (set searchText + applyCurrentFilter)") {
            vm.library.searchText = "t"
            vm.library.applyCurrentFilter()
        }
        print("BENCH|\(tag)|info|searchMatches=\(vm.library.photos.count)")
        // 4b (added by task 10): 4 repeats the same text; this changes it on every run.
        benchChange(tag, "4b search keystroke '' -> 't' (text changes every run)", setup: {
            vm.library.searchText = ""
            vm.library.applyCurrentFilter()
        }) {
            vm.library.searchText = "t"
            vm.library.applyCurrentFilter()
        }
        vm.library.searchText = ""
        vm.library.applyFilter(.all)

        // 5
        vm.library.applyFilter(.rated(3))
        let target = vm.library.photos[0]
        var flip = false
        bench(tag, "5a setRating with .rated(3) filter active") {
            flip.toggle()
            vm.library.setRating(flip ? 4 : 3, for: target)
        }
        vm.library.applyFilter(.all)
        let target2 = vm.library.photos[vm.library.photos.count / 2]
        bench(tag, "5b setRating no filter") {
            flip.toggle()
            vm.library.setRating(flip ? 4 : 3, for: target2)
        }

        // 8 bin moves and batch rating (added by task 10; each run moves a different photo)
        vm.library.applyFilter(.all)
        let binTargets = Array(vm.library.photos.prefix(6)) // 1 warmup + 5 runs
        var nextTarget = 0
        bench(tag, "8a moveToBin single photo") {
            vm.deletePhoto(binTargets[nextTarget])
            nextTarget += 1
        }
        nextTarget = 0
        bench(tag, "8b restoreFromBin single photo") {
            vm.restoreFromBin([binTargets[nextTarget]])
            nextTarget += 1
        }
        XCTAssertEqual(vm.library.allPhotos.count, n)
        vm.selection.selectedPhotos = Set(vm.library.photos.prefix(50).map(\.id))
        bench(tag, "8c setRatingForSelection 50 photos") {
            flip.toggle()
            vm.setRatingForSelection(flip ? 4 : 3)
        }
        vm.selection.selectedPhotos = []
        await MetadataWriter.shared.flush() // let the queued metadata writes drain

        // 6 in-memory baselines
        vm.library.applyFilter(.all)
        let all = vm.library.allPhotos
        bench(tag, "6a allPhotos.filter { rating == 3 }") { _ = all.filter { $0.rating == 3 } }
        bench(tag, "6b one-pass rating/tag/category/type counts") {
            var counts: [Int: Int] = [:], cat: [String: Int] = [:], tc: [UUID: Int] = [:]
            var jpg = 0, raw = 0
            for p in all {
                counts[p.rating, default: 0] += 1
                if p.jpgPath != nil { jpg += 1 }
                if p.rawPath != nil { raw += 1 }
                var seen = Set<String>()
                for t in p.tags {
                    tc[t.id, default: 0] += 1
                    if !t.category.isEmpty && seen.insert(t.category).inserted { cat[t.category, default: 0] += 1 }
                }
            }
            _ = (counts, cat, tc, jpg, raw)
        }
        bench(tag, "6c photos.map(\\.id)") { _ = all.map(\.id) }
        let lastId = all.last!.id
        let midId = all[all.count / 2].id
        bench(tag, "6d photos.firstIndex(where: id == last)") { _ = all.firstIndex { $0.id == lastId } }
        bench(tag, "6e photos.firstIndex(where: id == middle)") { _ = all.firstIndex { $0.id == midId } }
        var index: [UUID: Int] = [:]
        bench(tag, "6f build [UUID: Int] index") {
            index = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        }
        bench(tag, "6g [UUID: Int] index lookup x1000") {
            for _ in 0..<1000 { _ = index[lastId] }
        }
        let ids = all.map(\.id)
        bench(tag, "6h Set(ids) over cached [UUID] (no model access)") { _ = Set(ids) }
        bench(tag, "6i Array(allPhotos.reversed()) (sort-toggle alternative)") { _ = Array(all.reversed()) }
        bench(tag, "6j search 't' in-memory over allPhotos (no refetch)") {
            _ = all.filter { p in
                p.fileName.lowercased().contains("t") ||
                p.tags.contains { $0.name.lowercased().contains("t") || $0.category.lowercased().contains("t") }
            }
        }
        vm.selection.selectedPhotos = Set(all.prefix(50).map(\.id))
        bench(tag, "6k selectedPhotosList (50 selected)") { _ = vm.selection.selectedPhotosList }
        vm.selection.selectedPhotos = []

        // 7x Rescan where every row already exists (empty files → no metadata reads)
        context.insert(PhotoLibrary(rootFolderPath: filesDir.path))
        try context.save()
        vm.loadExistingData()
        XCTAssertNotNil(vm.library.currentLibrary)
        var rescanMainActor: [Double] = [] // (added by task 20)
        try await benchAsync(tag, "7x rescanCurrentLibrary() all-existing (until !isScanning)", runs: 3) {
            vm.library.rescanCurrentLibrary()
            try await waitForScan(vm)
            if let t = lastScanMainActorMs(vm) { rescanMainActor.append(t) }
        }
        print("BENCH|\(tag)|info|scanProgress=\(vm.library.scanProgress)")
        // (added by task 20) Until task 32 the seed's `/var/…` paths weren't the `/private/var/…` ones the folder
        // enumerator reports, so 7x's warm-up run inserted a second row per file and its timed runs rescanned twice the
        // rows. The seed is canonical now (re-baselined): stored rows = n.
        let storedRows = (try? context.fetchCount(FetchDescriptor<PhotoAsset>())) ?? -1
        print("BENCH|\(tag)|info|7x stored rows=\(storedRows) allPhotos=\(vm.library.allPhotos.count)")
        reportIfAny(tag, "7x main-actor time of each rescan (scan task)", Array(rescanMainActor.dropFirst()))
        try await benchAsync(tag, "7y FolderScanner.scan alone", runs: 3) {
            _ = await FolderScanner().scan(folderURL: filesDir)
        }
    }

    func testBench2k() async throws { try skipUnlessBenchmarking(); try await runSuite(n: 2_000) }
    func testBench10k() async throws { try skipUnlessBenchmarking(); try await runSuite(n: 10_000) }

    // MARK: Launch and rescan of an unchanged 10k library (added by task 20)

    /// Unlike 7x, the rows are seeded under the paths the folder enumerator reports, so a rescan finds exactly
    /// the stored photos: the launch case of spec §B1.
    func testRescanUnchanged10k() async throws {
        try skipUnlessBenchmarking()
        let tag = "N=10000"
        let dir = try makeTempDir("rescan10k")
        let filesDir = try canonical(dir.appendingPathComponent("files", isDirectory: true).creatingDir())
        let storeURL = dir.appendingPathComponent("bench.store")
        let context = try makeContainer(storeURL: storeURL).mainContext
        _ = try seed(n: 10_000, into: context, filesDir: filesDir)
        context.insert(PhotoLibrary(rootFolderPath: filesDir.path))
        try context.save()

        // 7v: launch on a fresh container, like opening the app: the synchronous part, then its rescan.
        var launchSync: [Double] = [], launchScan: [Double] = [], launchMainActor: [Double] = []
        var loadMainActor: [Double] = [], loadLongest: [Double] = [], launchTotal: [Double] = [] // (added by task 32)
        for _ in 0..<3 {
            let launchContext = try makeContainer(storeURL: storeURL).mainContext
            let launchVM = PhotoLibraryViewModel()
            let start = clock.now
            launchVM.setModelContext(launchContext)
            let sync = ms(clock.now - start)
            launchSync.append(sync)
            try await waitForScan(launchVM)
            launchScan.append(ms(clock.now - start))
            let scan = lastScanMainActorMs(launchVM)
            if let scan { launchMainActor.append(scan) }
            let load = backgroundLoadMs(launchVM)
            if let load {
                loadMainActor.append(load.total)
                loadLongest.append(load.longest)
            }
            launchTotal.append(sync + (load?.total ?? 0) + (scan ?? 0))
            XCTAssertEqual(launchVM.library.allPhotos.count, 10_000)
            retained.append(launchVM)
        }
        report(tag, "7v launch: setModelContext() with a library, fresh container (synchronous part)", launchSync)
        report(tag, "7v launch: setModelContext() until its rescan ends (!isScanning)", launchScan)
        reportIfAny(tag, "7v launch rescan: main-actor time (scan task)", launchMainActor)
        // (added by task 32) With a big library the load runs after setModelContext() returns, in main-actor turns.
        reportIfAny(tag, "7v launch background load: main-actor time (all turns)", loadMainActor)
        reportIfAny(tag, "7v launch background load: longest main-actor turn", loadLongest)
        report(tag, "7v launch: all main-actor time (synchronous part + background load + rescan)", launchTotal)

        // 7w: rescan of the unchanged library, warm.
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        try await waitForScan(vm)
        var mainActor: [Double] = []
        try await benchAsync(tag, "7w rescanCurrentLibrary() unchanged 10k library (until !isScanning)") {
            vm.library.rescanCurrentLibrary()
            try await waitForScan(vm)
            if let t = lastScanMainActorMs(vm) { mainActor.append(t) }
        }
        reportIfAny(tag, "7w main-actor time of each rescan (scan task)", Array(mainActor.dropFirst()))
        let storedRows = (try? context.fetchCount(FetchDescriptor<PhotoAsset>())) ?? -1
        print("BENCH|\(tag)|info|7w scanProgress=\(vm.library.scanProgress) stored rows=\(storedRows) allPhotos=\(vm.library.allPhotos.count)")

        // 7u (added by task 32): a rescan that finds 10 new files (empty, like the seed's) in the 10k library. Each run
        // adds 10 more, untimed, before its rescan; the first run is a warm-up.
        var addWall: [Double] = [], addMainActor: [Double] = []
        for run in 0..<6 {
            for i in 0..<10 {
                FileManager.default.createFile(
                    atPath: filesDir.appendingPathComponent(String(format: "NEW_%02d_%02d.jpg", run, i)).path, contents: nil)
            }
            let start = clock.now
            vm.library.rescanCurrentLibrary()
            try await waitForScan(vm)
            guard run > 0 else { continue }
            addWall.append(ms(clock.now - start))
            if let t = lastScanMainActorMs(vm) { addMainActor.append(t) }
        }
        report(tag, "7u rescanCurrentLibrary() finding 10 new files in a 10k library (until !isScanning)", addWall)
        reportIfAny(tag, "7u main-actor time of each rescan (scan task)", addMainActor)
        print("BENCH|\(tag)|info|7u scanProgress=\(vm.library.scanProgress) reloaded=\(vm.library.lastScanReport?.reloaded ?? false) allPhotos=\(vm.library.allPhotos.count)")
        XCTAssertEqual(vm.library.allPhotos.count, 10_060)
    }

    // MARK: Scan of real JPEGs

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }

    func testScan1k() async throws {
        try skipUnlessBenchmarking()
        let tag = "scan1k"
        let dir = try makeTempDir("scan")
        let photosDir = try dir.appendingPathComponent("photos", isDirectory: true).creatingDir()
        let img = makeImage()
        let genStart = clock.now
        for i in 0..<1000 {
            let url = photosDir.appendingPathComponent(String(format: "SCAN_%04d.jpg", i))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            if i % 2 == 0 {
                // The app's own write path (dc:subject + xmp:Rating via CGImageDestinationCopyImageSource)
                MetadataService.shared.writeMetadata(rating: 3, keywords: ["cat:a", "cat:b"], toImageAt: url.path)
            }
        }
        print("BENCH|\(tag)|generate 1000 jpegs (harness, not app code)|ms=\(f(ms(clock.now - genStart)))")
        let sample = MetadataService.shared.readMetadata(from: photosDir.appendingPathComponent("SCAN_0000.jpg").path)
        print("BENCH|\(tag)|info|round-trip via app write→read: keywords=\(sample.keywords) rating=\(sample.rating)")

        try await benchAsync(tag, "FolderScanner.scan alone (1000 files)") {
            _ = await FolderScanner().scan(folderURL: photosDir)
        }
        let discovered = await FolderScanner().scan(folderURL: photosDir)
        bench(tag, "readMetadata x1000 (runs on main actor inside first scan)") {
            for d in discovered { _ = MetadataService.shared.readMetadata(from: d.jpgPath!) }
        }

        // First scan into fresh stores (3 separate runs)
        var firstSamples: [Double] = []
        var firstMainActor: [Double] = [] // (added by task 20)
        var lastVM: PhotoLibraryViewModel?
        var lastCtx: ModelContext?
        for run in 0..<3 {
            let storeDir = try makeTempDir("scanstore\(run)")
            let container = try makeContainer(storeURL: storeDir.appendingPathComponent("s.store"))
            let ctx = container.mainContext
            let vm = PhotoLibraryViewModel()
            vm.setModelContext(ctx) // empty store → no scan kicked off
            ctx.insert(PhotoLibrary(rootFolderPath: photosDir.path))
            try ctx.save()
            vm.loadExistingData()
            XCTAssertNotNil(vm.library.currentLibrary)
            let start = clock.now
            vm.library.rescanCurrentLibrary()
            try await waitForScan(vm)
            firstSamples.append(ms(clock.now - start))
            if let t = lastScanMainActorMs(vm) { firstMainActor.append(t) }
            print("BENCH|\(tag)|info|run\(run) scanProgress=\(vm.library.scanProgress) allPhotos=\(vm.library.allPhotos.count) tags=\(vm.library.allTags.count) tagged=\(vm.library.allPhotos.filter { !$0.tags.isEmpty }.count) rated=\(vm.library.allPhotos.filter { $0.rating > 0 }.count)")
            lastVM = vm
            lastCtx = ctx
        }
        report(tag, "FIRST rescanCurrentLibrary() fresh store (until !isScanning)", firstSamples)
        reportIfAny(tag, "7z first scan of 1k new photos: main-actor time", firstMainActor) // (added by task 20)

        let vm = lastVM!
        let ctx = lastCtx!
        var secondMainActor: [Double] = [] // (added by task 20)
        try await benchAsync(tag, "SECOND rescanCurrentLibrary() all-existing (until !isScanning)") {
            vm.library.rescanCurrentLibrary()
            try await waitForScan(vm)
            if let t = lastScanMainActorMs(vm) { secondMainActor.append(t) }
        }
        reportIfAny(tag, "SECOND main-actor time (scan task)", Array(secondMainActor.dropFirst()))

        // 1000 calls = 500 tagged photos x 2 keywords; tags already exist → one fetch per call
        bench(tag, "findOrCreateTag x1000 (existing tags)") {
            for i in 0..<1000 { _ = vm.library.findOrCreateTag(name: i % 2 == 0 ? "a" : "b", category: "cat", in: ctx) }
        }
        let tagDict = Dictionary(uniqueKeysWithValues: vm.library.allTags.map { ($0.fullName, $0) })
        bench(tag, "dictionary tag lookup x1000 (alternative)") {
            for i in 0..<1000 { _ = tagDict[i % 2 == 0 ? "cat:a" : "cat:b"] }
        }
        bench(tag, "context.save() nothing dirty") { try? ctx.save() }
        let all = vm.library.allPhotos
        bench(tag, "same-value reassign 4 fields on 1000 rows + save") {
            for p in all { p.jpgPath = p.jpgPath; p.rawPath = p.rawPath; p.fileSize = p.fileSize; p.isDeleted = false }
            try? ctx.save()
        }
        for p in all { p.fileSize = p.fileSize }
        print("BENCH|\(tag)|info|ctx.hasChanges after same-value assignment=\(ctx.hasChanges)")
        try? ctx.save()
    }
}

private extension URL {
    func creatingDir() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}

/// Deterministic seeded generator (standard SplitMix64), so every run seeds the same library.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
