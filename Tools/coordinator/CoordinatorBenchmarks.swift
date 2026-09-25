// Coordinator A/B benchmarks. Lives outside the test target: copy it into a checkout's PhocasaTests folder only while measuring.
// Uses only APIs that exist both on main (after task 00) and on the wave-1 branches.
//   COORD_BENCH_DATA = an imagebench data dir (master.jpg + copy_000…199.jpg)
//   COORD_REAL_DIR   = the user's read-only folder of real JPG+ARW pairs (read only; nothing here writes)
//   PHOCASA_THUMBNAIL_CACHE_DIR = (task 21 and later) a temp folder for the test host's thumbnail disk cache.
//     Code without a disk cache ignores it. Cold runs empty it first; "relaunch" runs keep it and empty memory only.
// Pass them as TEST_RUNNER_COORD_BENCH_DATA / TEST_RUNNER_COORD_REAL_DIR / TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR.

import XCTest
import SwiftData
import AppKit
@testable import Phocasa

@MainActor
final class CoordinatorBenchmarks: XCTestCase {
    private let clock = ContinuousClock()
    private let env = ProcessInfo.processInfo.environment

    private func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    private func f(_ x: Double) -> String { String(format: "%.1f", x) }
    private func report(_ label: String, _ samples: [Double]) {
        let s = samples.sorted()
        print("COORD|\(label)|median_ms=\(f(s[s.count / 2]))|min_ms=\(f(s.first!))|max_ms=\(f(s.last!))|runs=\(s.count)")
    }
    private func waitUntil(timeout: Duration = .seconds(30), _ cond: () -> Bool) async throws {
        let deadline = clock.now + timeout
        while !cond() {
            if clock.now > deadline { XCTFail("timeout"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func synthDir() throws -> String {
        guard let d = env["COORD_BENCH_DATA"] else { throw XCTSkip("COORD_BENCH_DATA not set") }
        return d
    }
    private func realFiles(_ ext: String) throws -> [String] {
        guard let d = env["COORD_REAL_DIR"] else { throw XCTSkip("COORD_REAL_DIR not set") }
        let names = try FileManager.default.contentsOfDirectory(atPath: d)
            .filter { ($0 as NSString).pathExtension.lowercased() == ext }.sorted()
        return names.map { d + "/" + $0 }
    }

    // MARK: Thumbnails

    /// Fast scroll: cells request a 380 px thumbnail 2.5 ms apart; a cell more than 40 behind the newest is
    /// cancelled (scrolled away), as SwiftUI cancels `.task` for cells that leave the lazy grid.
    /// last20 = time from the final request until the last 20 requested cells have their image.
    // MARK: Thumbnail disk cache (task 21)

    private var thumbDiskDir: String? { env["PHOCASA_THUMBNAIL_CACHE_DIR"] }

    private nonisolated static func fileCount(_ dir: String) -> Int {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return 0 }
        var n = 0
        while e.nextObject() != nil { n += 1 }
        return n
    }

    /// Waits until the disk cache folder stops changing (its writes run on a background queue): no change in the
    /// file count for 300 ms, at most 15 s. Returns at once when there is no disk cache folder.
    private func settleThumbDisk() async throws {
        guard let dir = thumbDiskDir else { return }
        var last = -1
        var stableSince = clock.now
        let deadline = clock.now + .seconds(15)
        while clock.now < deadline {
            let n = Self.fileCount(dir)
            if n != last { last = n; stableSince = clock.now } else if clock.now - stableSince > .milliseconds(300) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Empties memory and, if there is one, the disk cache (after its pending writes land): a first launch.
    private func clearThumbnailsCold() async throws {
        try await settleThumbDisk()
        ImageLoader.shared.clearCache()
        if let dir = thumbDiskDir {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { try? fm.removeItem(atPath: dir + "/" + name) }
        }
    }

    /// Loads every path once so the disk cache (if any) holds them, then waits for its writes.
    private func warmThumbDisk(_ paths: [String]) async throws {
        try await clearThumbnailsCold()
        for p in paths { _ = await ImageLoader.shared.loadThumbnail(for: p, maxSize: 380) }
        try await settleThumbDisk()
        print("COORD|info|thumb disk files=\(thumbDiskDir.map { Self.fileCount($0) } ?? -1)")
    }

    private func fastScroll(_ label: String, paths: [String], runs: Int = 5, relaunch: Bool = false) async throws {
        var last20: [Double] = [], allDone: [Double] = []
        if relaunch { try await warmThumbDisk(paths) }
        for _ in 0..<runs {
            // Relaunch: the memory cache is empty, the disk cache (if any) is warm. Otherwise: a first launch.
            if relaunch { ImageLoader.shared.clearCache() } else { try await clearThumbnailsCold() }
            var tasks: [Task<Void, Never>] = []
            for (i, path) in paths.enumerated() {
                tasks.append(Task { _ = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 380) })
                if i >= 40 { tasks[i - 40].cancel() }
                try await Task.sleep(for: .microseconds(2500))
            }
            let tLast = clock.now
            for t in tasks.suffix(20) { await t.value }
            last20.append(ms(clock.now - tLast))
            for t in tasks { await t.value }
            allDone.append(ms(clock.now - tLast))
        }
        report("\(label) fastScroll last20", last20)
        report("\(label) fastScroll all tasks finished", allDone)
    }

    /// Cold thumbnail of one file at a time (no concurrency): the per-image decode cost.
    private func singleThumb(_ label: String, paths: [String], relaunch: Bool = false) async throws {
        var samples: [Double] = []
        if relaunch { try await warmThumbDisk(Array(paths.prefix(20))) }
        for path in paths.prefix(20) {
            if relaunch { ImageLoader.shared.clearCache() } else { try await clearThumbnailsCold() }
            let t = clock.now
            _ = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 380)
            samples.append(ms(clock.now - t))
        }
        report("\(label) single cold thumbnail 380px", samples)
    }

    func testThumbSynthetic() async throws {
        let d = try synthDir()
        let paths = (0..<200).map { d + "/copy_" + String(format: "%03d", $0) + ".jpg" }
        try await fastScroll("thumb synth-jpg", paths: paths)
    }

    func testThumbRealJPG() async throws {
        let paths = try realFiles("jpg")
        try await singleThumb("thumb real-jpg", paths: paths)
        try await fastScroll("thumb real-jpg", paths: paths)
    }

    func testThumbRealARW() async throws {
        let paths = try realFiles("arw")
        try await singleThumb("thumb real-arw", paths: paths)
        try await fastScroll("thumb real-arw", paths: paths)
    }

    /// After a relaunch: memory cache empty, disk cache (task 21) warm. Without a disk cache this equals a cold run.
    func testThumbRelaunch() async throws {
        let d = try synthDir()
        let synth = (0..<200).map { d + "/copy_" + String(format: "%03d", $0) + ".jpg" }
        try await singleThumb("thumb relaunch synth-jpg", paths: synth, relaunch: true)
        try await fastScroll("thumb relaunch synth-jpg", paths: synth, relaunch: true)
        for ext in ["jpg", "arw"] {
            let paths = try realFiles(ext)
            try await singleThumb("thumb relaunch real-\(ext)", paths: paths, relaunch: true)
            try await fastScroll("thumb relaunch real-\(ext)", paths: paths, relaunch: true)
        }
        try await clearThumbnailsCold()
    }

    // MARK: Metadata (read-only)

    /// readMetadata over every real file, as the first scan does. Reads only (no sidecars exist there).
    func testReadMetadataReal() throws {
        for ext in ["jpg", "arw"] {
            let paths = try realFiles(ext)
            var samples: [Double] = []
            var rated = 0, tagged = 0
            for _ in 0..<3 {
                let t = clock.now
                for p in paths {
                    let m = MetadataService.shared.readMetadata(from: p)
                    if m.rating > 0 { rated += 1 }
                    if !m.keywords.isEmpty { tagged += 1 }
                }
                samples.append(ms(clock.now - t))
            }
            report("readMetadata real-\(ext) x\(paths.count)", samples)
            print("COORD|info|readMetadata real-\(ext)|rated=\(rated / 3)|tagged=\(tagged / 3)")
        }
    }

    // MARK: Editing

    /// Slider ticks through the view model: once when idle, once ~5 ms after the 300 ms full-resolution pass
    /// has started. Latency = updateEditPreview() → new editedPreviewImage (includes the 30 ms debounce).
    /// Also times the main-thread cost of first drawing fullResEditImage (deferred CI output renders there).
    private func editTicks(_ label: String, jpg: String?, raw: String?, isRAW: Bool) async throws {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        let photo = PhotoAsset(fileName: "bench", jpgPath: jpg, rawPath: raw, folderPath: "/bench",
                               creationDate: Date(), fileSize: 0)
        context.insert(photo)
        try context.save()
        vm.loadExistingData()
        vm.openDetail(for: photo)
        vm.startEditing(photo: photo, isRAW: isRAW)
        try await waitUntil { vm.editedPreviewImage != nil }

        var idle: [Double] = [], during: [Double] = [], draw: [Double] = []
        for i in 0..<10 {
            try await waitUntil { vm.fullResEditImage != nil }
            if let full = vm.fullResEditImage, let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let ctx = CGContext(data: nil, width: 1600, height: 1067, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let t = clock.now
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1600, height: 1067))
                draw.append(ms(clock.now - t))
            }

            let before = vm.editedPreviewImage
            vm.editParameters.exposure = 0.1 + Double(i) * 0.01
            vm.updateEditPreview()
            let t0 = clock.now
            try await waitUntil { vm.editedPreviewImage !== before }
            idle.append(ms(clock.now - t0))

            try await Task.sleep(for: .milliseconds(305))
            let before2 = vm.editedPreviewImage
            vm.editParameters.exposure += 0.005
            vm.updateEditPreview()
            let t1 = clock.now
            try await waitUntil { vm.editedPreviewImage !== before2 }
            during.append(ms(clock.now - t1))
        }
        vm.stopEditing(save: false)
        report("\(label) edit tick idle", idle)
        report("\(label) edit tick during full-res pass", during)
        report("\(label) main-thread first draw of full-res result", draw)
    }

    func testEditSyntheticJPG() async throws {
        let d = try synthDir()
        try await editTicks("edit synth-jpg-24MP", jpg: d + "/master.jpg", raw: nil, isRAW: false)
    }

    func testEditRealJPG() async throws {
        let jpg = try realFiles("jpg")[0]
        try await editTicks("edit real-jpg", jpg: jpg, raw: nil, isRAW: false)
    }

    func testEditRealARW() async throws {
        let raw = try realFiles("arw")[0]
        try await editTicks("edit real-arw", jpg: nil, raw: raw, isRAW: true)
    }
}
