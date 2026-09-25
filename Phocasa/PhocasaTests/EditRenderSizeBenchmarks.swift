// Gated benchmarks for task 35 (edit renders at viewport size). Skipped unless PHOCASA_BENCH=1; the real-file cases
// also need PHOCASA_TEST_RAW naming a *copy* of a camera RAW (optionally PHOCASA_TEST_RAW_2, a second one, e.g. a
// rotated portrait; the JPG with the same stem next to each is used when present). Every file is copied again into a
// temp folder before anything writes next to it. Results are `BENCH|editsize|…` lines.
//
//   TEST_RUNNER_PHOCASA_BENCH=1 TEST_RUNNER_PHOCASA_TEST_RAW=<copy.ARW> xcodebuild … test \
//     -only-testing:PhocasaTests/EditRenderSizeBenchmarks
//
// The viewports are a 1728×1117 pt window at 2× (a 16" MacBook Pro's full screen) minus a 52 pt toolbar: the detail
// view with the 281 pt edit sidebar (slider pauses) and without it (saved edits while navigating).
//
// Lines marked `NEW-API` use task 35's API. To run the same benchmarks on code before task 35, delete those lines and
// uncomment the `BASE-API` ones (`sed -e '/NEW-API/d' -e 's#// BASE-API ##'`).

import XCTest
import AppKit
import SwiftData
@testable import Phocasa

@MainActor
final class EditRenderSizeBenchmarks: XCTestCase {
    /// The detail view beside the edit sidebar, in device pixels: (1728 − 281) × (1117 − 52) pt at 2×.
    static let editingViewport = CGSize(width: 2894, height: 2130)
    /// The detail view without the edit sidebar: 1728 × (1117 − 52) pt at 2×.
    static let browsingViewport = CGSize(width: 3456, height: 2130)

    private let clock = ContinuousClock()
    private var tempDir: URL!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOCASA_BENCH"] == "1", "Set PHOCASA_BENCH=1 to run benchmarks")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-35-editsize-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        container = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDown() async throws {
        await MetadataWriter.shared.flush()
        ImageEditingService.shared.clearCache()
        context = nil
        container = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    private func f(_ x: Double) -> String { String(format: "%.1f", x) }
    private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
    private func mb(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }

    private func report(_ label: String, _ samples: [Double], extra: String = "") {
        let s = samples.sorted()
        print("BENCH|editsize|\(label)|median_ms=\(f(median(s)))|min_ms=\(f(s.first!))|max_ms=\(f(s.last!))|runs=\(s.count)\(extra)")
    }

    private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { XCTFail("timed out"); throw XCTSkip("timed out") }
            try await Task.sleep(for: .microseconds(250))
        }
    }

    /// User + system CPU time of this process so far, in ms (every thread: the render lane, Core Image's workers).
    private func cpuMs() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func t(_ v: timeval) -> Double { Double(v.tv_sec) * 1000 + Double(v.tv_usec) / 1000 }
        return t(usage.ru_utime) + t(usage.ru_stime)
    }

    private func bytes(_ image: NSImage?) -> Int {
        guard let cg = image.flatMap(EditTestImages.cgImage) else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    private func pixels(_ image: NSImage?) -> String {
        guard let cg = image.flatMap(EditTestImages.cgImage) else { return "none" }
        return "\(cg.width)x\(cg.height)"
    }

    /// A generated 6000×4000 JPEG.
    private func synthetic24MP(_ name: String = "24mp.jpg") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try EditTestImages.writeJPEG(to: url, width: 6000, height: 4000, orientation: 1)
        return url
    }

    /// The real RAW files named by the environment, copied into this test's folder.
    private func realRAWs() throws -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let paths = [env["PHOCASA_TEST_RAW"], env["PHOCASA_TEST_RAW_2"]].compactMap { $0 }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { throw XCTSkip("Set PHOCASA_TEST_RAW to a copy of a camera RAW file") }
        return try paths.map(copyIn)
    }

    /// The JPGs paired with the real RAW files (same stem), copied in.
    private func realJPGs() throws -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let jpgs = [env["PHOCASA_TEST_RAW"], env["PHOCASA_TEST_RAW_2"]].compactMap { $0 }.filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().appendingPathExtension("JPG") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !jpgs.isEmpty else { throw XCTSkip("No JPG next to PHOCASA_TEST_RAW") }
        return try jpgs.map { try copyIn($0.path) }
    }

    private func copyIn(_ path: String) throws -> URL {
        let source = URL(fileURLWithPath: path)
        let target = tempDir.appendingPathComponent(source.lastPathComponent)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: source, to: target)
        }
        return target
    }

    private func insertPhoto(_ url: URL, isRAW: Bool) throws -> PhotoAsset {
        let photo = PhotoAsset(fileName: url.lastPathComponent, jpgPath: isRAW ? nil : url.path,
                               rawPath: isRAW ? url.path : nil, folderPath: tempDir.path, creationDate: Date())
        context.insert(photo)
        try context.save()
        return photo
    }

    private func edit(_ i: Int) -> EditParameters {
        var p = EditParameters()
        p.exposure = 0.3 + Double(i) * 0.01
        p.highlights = 30; p.shadows = 20; p.contrast = 15; p.vibrance = 20; p.sharpness = 40; p.clarity = 30
        return p
    }

    private func makeSession(_ photo: PhotoAsset, isRAW: Bool, viewport: CGSize) -> EditSession {
        let session = EditSession(photo: photo, isRAW: isRAW, modelContext: context)
        session.viewportPixelSize = viewport   // NEW-API
        return session
    }

    private func renderSavedEdit(_ photo: PhotoAsset, viewport: CGSize, reusing handoff: SavedEditHandoff? = nil) async -> SavedEditRender? {
        await SavedEdit.render(for: photo, fitting: viewport, reusing: handoff)   // NEW-API
        // BASE-API await SavedEdit.render(for: photo, reusing: handoff)
    }

    // MARK: - The pass after each slider pause, at fit

    /// Each round: a slider value, its preview, then the pass the session renders 300 ms after the preview landed.
    /// "pass" is the time from the moment the render lane starts it (the service's render count goes up; nothing
    /// else renders then) until `fullImage` is set: the cost of each pause, without the timer's slack. Also the
    /// process CPU time over the same span, "pause to sharp" (preview landed → `fullImage` set, which includes the
    /// 300 ms pause), the main-thread first draw of `fullImage` into 1600×1067 (as the coordinator's harness), and
    /// the bytes `fullImage` holds.
    private func sliderPause(_ label: String, url: URL, isRAW: Bool, rounds: Int = 10) async throws {
        let photo = try insertPhoto(url, isRAW: isRAW)
        let viewport = Self.editingViewport
        let session = makeSession(photo, isRAW: isRAW, viewport: viewport)
        defer { session.end(save: false) }
        session.parameters = edit(0)
        await session.begin()
        try await waitUntil { session.fullImage != nil }

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var pass: [Double] = [], cpu: [Double] = [], draw: [Double] = [], sharp: [Double] = []
        for i in 0...rounds {   // round 0 warms up
            let before = session.previewImage
            session.parameters = edit(10 + i)
            try await waitUntil { session.previewImage != nil && session.previewImage !== before }
            let previewLanded = clock.now
            let rendersAtPreview = ImageEditingService.shared.renderCount
            try await Task.sleep(until: previewLanded + EditSession.fullPassDelay - .milliseconds(5), clock: .continuous)
            try await waitUntil { ImageEditingService.shared.renderCount > rendersAtPreview || session.fullImage != nil }
            let passStart = clock.now
            let cpuStart = cpuMs()
            try await waitUntil { session.fullImage != nil }
            let passMs = ms(clock.now - passStart)
            let cpuUsed = cpuMs() - cpuStart
            let sharpMs = ms(clock.now - previewLanded)
            let cg = try XCTUnwrap(session.fullImage.flatMap(EditTestImages.cgImage))
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1067, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let drawStart = clock.now
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1600, height: 1067))
            let drawMs = ms(clock.now - drawStart)
            if i > 0 {
                pass.append(passMs)
                cpu.append(cpuUsed)
                draw.append(drawMs)
                sharp.append(sharpMs)
            }
        }
        let size = "|viewport=\(Int(viewport.width))x\(Int(viewport.height))|full_px=\(pixels(session.fullImage))|full_MB=\(mb(bytes(session.fullImage)))"
        report("\(label) slider pause: pass", pass, extra: size)
        report("\(label) slider pause: process CPU during the pass", cpu)
        report("\(label) slider pause: preview to sharp (incl. the 300 ms pause)", sharp)
        report("\(label) slider pause: main-thread first draw of fullImage", draw)
    }

    func testBenchSliderPause24MPJPEG() async throws {
        try await sliderPause("synth-24MP-jpg", url: try synthetic24MP(), isRAW: false)
    }

    func testBenchSliderPauseRealJPG() async throws {
        try await sliderPause("real-jpg", url: try realJPGs()[0], isRAW: false)
    }

    func testBenchSliderPauseRealRAW() async throws {
        let raws = try realRAWs()
        try await sliderPause("real-raw", url: raws[0], isRAW: true)
        if raws.count > 1 { try await sliderPause("real-raw-2", url: raws[1], isRAW: true) }
    }

    // MARK: - Navigating to photos with saved edits

    /// What `PhotoDetailView` does for a photo with a saved edit after its fit image: `SavedEdit.render`, alternating
    /// between two photos as arrow-key navigation does (so the RAW filter is never the cached one). Reports the time
    /// until the edit can be shown and the bytes each render holds.
    private func savedEditNavigation(_ label: String, urls: [URL], isRAW: Bool, rounds: Int = 12) async throws {
        var photos: [PhotoAsset] = []
        for (i, url) in urls.enumerated() {
            let photo = try insertPhoto(url, isRAW: isRAW)
            if isRAW {
                RAWEditStore.shared.save(edit(i), forRAWAt: url.path)
                photo.hasRawEdits = true
            } else {
                photo.jpgEditParameters = edit(i)
            }
            photos.append(photo)
        }
        try context.save()
        await MetadataWriter.shared.flush()
        // Two photos are enough to miss the cached filter every time; one file becomes two names.
        if photos.count == 1 {
            let second = tempDir.appendingPathComponent("second-" + urls[0].lastPathComponent)
            try FileManager.default.copyItem(at: urls[0], to: second)
            let photo = try insertPhoto(second, isRAW: isRAW)
            if isRAW {
                RAWEditStore.shared.save(edit(7), forRAWAt: second.path)
                photo.hasRawEdits = true
            } else {
                photo.jpgEditParameters = edit(7)
            }
            try context.save()
            await MetadataWriter.shared.flush()
            photos.append(photo)
        }

        let viewport = Self.browsingViewport
        var shown: [Double] = [], held: [Int] = []
        var sizes: Set<String> = []
        for i in 0..<(rounds + 2) {   // the first two warm up
            let photo = photos[i % photos.count]
            let start = clock.now
            let render = await renderSavedEdit(photo, viewport: viewport)
            let elapsed = ms(clock.now - start)
            XCTAssertNotNil(render)
            if i >= 2 {
                shown.append(elapsed)
                held.append(bytes(render?.image))
                sizes.insert(pixels(render?.image))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let maxHeld = held.max() ?? 0
        report("\(label) saved edit on navigation: until shown", shown,
               extra: "|viewport=\(Int(viewport.width))x\(Int(viewport.height))|px=\(sizes.sorted().joined(separator: ","))|max_MB_per_render=\(mb(maxHeld))")
    }

    func testBenchSavedRAWEditNavigation() async throws {
        try await savedEditNavigation("real-raw", urls: try realRAWs(), isRAW: true)
    }

    func testBenchSavedJPGEditNavigation() async throws {
        try await savedEditNavigation("real-jpg", urls: try realJPGs(), isRAW: false)
    }

    func testBenchSavedJPGEditNavigation24MP() async throws {
        try await savedEditNavigation("synth-24MP-jpg", urls: [try synthetic24MP("a.jpg"), try synthetic24MP("b.jpg")], isRAW: false)
    }

    // MARK: - Memory after a save

    /// Edit at fit beside the edit sidebar, pause, save. The sidebar then closes, so the detail view resolves the
    /// saved edit for the wider viewport, as in the app. Reports what the hand-off holds (the view model keeps it
    /// until the next navigation), what the detail view holds once it has resolved the saved edit (the same object
    /// when the session's render is reused), and the renders that took.
    private func memoryAfterSave(_ label: String, url: URL, isRAW: Bool) async throws {
        let photo = try insertPhoto(url, isRAW: isRAW)
        let session = makeSession(photo, isRAW: isRAW, viewport: Self.editingViewport)
        await session.begin()
        session.parameters = edit(3)
        try await waitUntil { session.fullImage != nil }
        let handoff = try XCTUnwrap(session.end(save: true))
        await MetadataWriter.shared.flush()
        let rendersBefore = ImageEditingService.shared.renderCount
        let resolved = await renderSavedEdit(photo, viewport: Self.browsingViewport, reusing: handoff)
        let renders = ImageEditingService.shared.renderCount - rendersBefore
        let reused = resolved?.image === handoff.image
        let heldBytes = bytes(handoff.image) + (reused ? 0 : bytes(resolved?.image))
        print("BENCH|editsize|\(label) memory after a save|handoff_px=\(pixels(handoff.image))|handoff_MB=\(mb(bytes(handoff.image)))"
              + "|saved_edit_px=\(pixels(resolved?.image))|reused=\(reused)|renders_after_save=\(renders)|held_MB=\(mb(heldBytes))")
    }

    func testBenchMemoryAfterSave24MPJPEG() async throws {
        try await memoryAfterSave("synth-24MP-jpg", url: try synthetic24MP(), isRAW: false)
    }

    func testBenchMemoryAfterSaveRealRAW() async throws {
        try await memoryAfterSave("real-raw", url: try realRAWs()[0], isRAW: true)
    }
}
