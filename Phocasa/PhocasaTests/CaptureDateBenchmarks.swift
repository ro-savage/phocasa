// Capture-date backfill and fetch benchmarks (task 33). Opt-in: skipped unless PHOCASA_BENCH=1, e.g.
//   TEST_RUNNER_PHOCASA_BENCH=1 xcodebuild ... test -only-testing:PhocasaTests/CaptureDateBenchmarks
// With TEST_RUNNER_PHOCASA_BENCH_REAL_DIR=<folder of camera JPG+RAW pairs> the rows point at those files (read only;
// 10k rows cycle through them). Otherwise they point at generated JPEGs and TIFF-based ".dng" files.
// Results are printed as lines starting with "BENCH|".

import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

@MainActor
final class CaptureDateBenchmarks: XCTestCase {
    private let clock = ContinuousClock()
    private var tempDirs: [URL] = []
    private var containers: [ModelContainer] = []

    override func tearDown() async throws {
        containers.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

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

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-33-bench-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeContainer(_ storeURL: URL) throws -> ModelContainer {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
        containers.append(container)
        return container
    }

    /// Files to point rows at: the real folder's JPGs or RAWs, or `count` generated ones.
    private func sourceFiles(raw: Bool, count: Int) throws -> (paths: [String], label: String) {
        if let real = ProcessInfo.processInfo.environment["PHOCASA_BENCH_REAL_DIR"] {
            let names = try FileManager.default.contentsOfDirectory(atPath: real).sorted()
            let paths = names.filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return raw ? FolderScanner.rawExtensions.contains(ext) : ext == "jpg" || ext == "jpeg"
            }.map { (real as NSString).appendingPathComponent($0) }
            XCTAssertFalse(paths.isEmpty)
            return (paths, "real \(raw ? "RAW" : "JPG") x\(paths.count)")
        }
        let dir = try makeTempDir(raw ? "dng" : "jpg")
        var paths: [String] = []
        for i in 0..<count {
            let url = dir.appendingPathComponent(String(format: "GEN_%04d.%@", i, raw ? "dng" : "jpg"))
            let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: String(format: "2020:01:%02d 10:%02d:%02d", 1 + i % 28, (i / 60) % 60, i % 60)]
            try CaptureDateFixtures.writeImage(at: url, type: raw ? .tiff : .jpeg, exif: exif)
            paths.append(url.path)
        }
        return (paths, "generated \(raw ? "TIFF .dng" : "JPEG") x\(count)")
    }

    /// `n` rows as an older version stored them: no capture date, creation dates descending.
    private func seed(n: Int, paths: [String], raw: Bool, into context: ModelContext, dated: (Int) -> Bool = { _ in false }) throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<n {
            let path = paths[i % paths.count]
            let photo = PhotoAsset(fileName: String(format: "ROW_%05d", i), jpgPath: raw ? nil : path, rawPath: raw ? path : nil,
                                   folderPath: (path as NSString).deletingLastPathComponent,
                                   creationDate: base.addingTimeInterval(Double(-i) * 60), fileSize: 1000)
            if dated(i) { photo.captureDate = base.addingTimeInterval(Double((i * 7919) % n) * -30) }
            context.insert(photo)
        }
        try context.save()
    }

    private func runBackfill(tag: String, raw: Bool) async throws {
        let n = 10_000
        let (paths, label) = try sourceFiles(raw: raw, count: 1000)
        print("BENCH|\(tag)|info|rows=\(n) files=\(label)")
        let dir = try makeTempDir("store")
        let storeURL = dir.appendingPathComponent("bench.store")
        try seed(n: n, paths: paths, raw: raw, into: try makeContainer(storeURL).mainContext)

        // Launch-like: a fresh container, then the backfill (without the after-launch delay).
        let library = LibraryStore()
        let context = try makeContainer(storeURL).mainContext
        library.open(context)
        var loads: [Double] = []
        for _ in 0..<3 { loads.append(ms(clock.measure { library.loadExistingData() })) }
        report(tag, "loadExistingData() warm, no capture dates yet", loads)

        let result = await library.backfillCaptureDates()
        let chunks = result.chunkMainActorTimes.map(ms)
        let chunkTotal = chunks.reduce(0, +)
        print("BENCH|\(tag)|backfill wall (find + read + plan + write + re-order)|ms=\(f(ms(result.wallTime)))")
        print("BENCH|\(tag)|backfill find candidates (background)|ms=\(f(ms(result.findTime)))")
        print("BENCH|\(tag)|backfill read files (background, utility)|ms=\(f(ms(result.readTime)))")
        print("BENCH|\(tag)|backfill plan order (background)|ms=\(f(ms(result.planTime)))")
        report(tag, "backfill write chunk main-actor time", chunks)
        print("BENCH|\(tag)|backfill write chunks|count=\(chunks.count)|total_ms=\(f(chunkTotal))|p90_ms=\(f(chunks.sorted()[chunks.count * 9 / 10]))|p99_ms=\(f(chunks.sorted()[chunks.count * 99 / 100]))|over16ms=\(chunks.filter { $0 > 16 }.count)|first_ms=\(f(chunks[0]))|rows_per_chunk=\(n / chunks.count)")
        print("BENCH|\(tag)|backfill re-order main-actor time|ms=\(f(ms(result.reorderMainActorTime)))")
        print("BENCH|\(tag)|backfill main-actor total|ms=\(f(chunkTotal + ms(result.reorderMainActorTime)))")
        print("BENCH|\(tag)|info|candidates=\(result.candidates) written=\(result.datesWritten) undated=\(result.undated) unreadable=\(result.unreadable) reordered=\(result.reordered)")
        XCTAssertEqual(result.datesWritten, n)

        loads = []
        for _ in 0..<5 { loads.append(ms(clock.measure { library.loadExistingData() })) }
        report(tag, "loadExistingData() warm, every photo dated", loads)
    }

    func testBackfill10kJPG() async throws {
        try skipUnlessBenchmarking()
        try await runBackfill(tag: "capture10k-jpg", raw: false)
    }

    func testBackfill10kRAWOnly() async throws {
        try skipUnlessBenchmarking()
        try await runBackfill(tag: "capture10k-raw", raw: true)
    }

    /// Every launch re-reads the files that have no capture date (nothing is written for them): 10k such rows, pointing
    /// at 1,000 generated JPEGs without EXIF dates.
    func testBackfill10kUndatedRereadsOnly() async throws {
        try skipUnlessBenchmarking()
        let tag = "capture10k-undated"
        let dir = try makeTempDir("undated")
        var paths: [String] = []
        for i in 0..<1000 {
            let url = dir.appendingPathComponent(String(format: "NODATE_%04d.jpg", i))
            try CaptureDateFixtures.writeImage(at: url, exif: nil)
            paths.append(url.path)
        }
        let storeURL = try makeTempDir("store").appendingPathComponent("bench.store")
        try seed(n: 10_000, paths: paths, raw: false, into: try makeContainer(storeURL).mainContext)
        let library = LibraryStore()
        library.open(try makeContainer(storeURL).mainContext)
        var walls: [Double] = [], finds: [Double] = [], reads: [Double] = [], chunks: [Double] = []
        for _ in 0..<3 {
            let result = await library.backfillCaptureDates()
            XCTAssertEqual(result.undated, 10_000)
            walls.append(ms(result.wallTime))
            finds.append(ms(result.findTime))
            reads.append(ms(result.readTime))
            chunks.append(Double(result.chunkMainActorTimes.count))
        }
        report(tag, "backfill wall, nothing to write (every launch)", walls)
        report(tag, "backfill find candidates (background)", finds)
        report(tag, "backfill read files (background, utility)", reads)
        print("BENCH|\(tag)|info|write chunks=\(chunks.map { Int($0) })")
    }

    /// The fetch's in-memory merge of dated and undated photos, at 10k, against a library with none dated (one run).
    func testLoadExistingDataMixedLibraries() async throws {
        try skipUnlessBenchmarking()
        let tag = "capture10k-fetch"
        for (label, dated) in [("none dated", { (_: Int) in false }), ("all dated", { (_: Int) in true }),
                               ("1% undated", { (i: Int) in i % 100 != 0 }), ("half dated", { (i: Int) in i % 2 == 0 })] {
            let dir = try makeTempDir("mixed")
            let storeURL = dir.appendingPathComponent("bench.store")
            try seed(n: 10_000, paths: ["/fake/x.jpg"], raw: false, into: try makeContainer(storeURL).mainContext, dated: dated)
            let library = LibraryStore()
            library.open(try makeContainer(storeURL).mainContext)
            var loads: [Double] = []
            library.loadExistingData()
            for _ in 0..<5 { loads.append(ms(clock.measure { library.loadExistingData() })) }
            report(tag, "loadExistingData() warm, \(label)", loads)
            let sort = library.sort
            let context = try XCTUnwrap(library.modelContext)
            var fetches: [Double] = []
            for _ in 0..<5 {
                fetches.append(ms(clock.measure { _ = try! sort.fetch(where: #Predicate<PhotoAsset> { _ in true }, in: context) }))
            }
            report(tag, "LibrarySort.fetch warm, \(label)", fetches)
        }
    }
}
