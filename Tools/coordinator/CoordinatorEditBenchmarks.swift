// Coordinator A/B edit benchmarks. Copy exactly ONE of the two variants into a checkout's PhocasaTests folder while
// measuring, and delete it afterwards:
//   CoordinatorEditBenchmarks.swift         -> view-model editing API (main before task 22)
//   CoordinatorEditBenchmarks-Session.swift -> EditSession API (task 22 and later)
// Both define the same class and labels, and differ only in how a tick is driven. Env as in CoordinatorBenchmarks.swift.

import XCTest
import SwiftData
import AppKit
@testable import Phocasa

@MainActor
final class CoordinatorEditBenchmarks: XCTestCase {
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
