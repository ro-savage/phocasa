// Gated benchmark (PHOCASA_BENCH=1, and PHOCASA_TEST_RAW naming a *copy* of a camera RAW with its JPG beside it):
// what a rating write costs in a camera JPG and in a RAW's sidecar, and what each export costs, on copies in a temp
// folder. Prints `BENCH|write|…` lines (post-wave-3 task A). The export calls carry `NEW-API` / `BASE-API` markers so
// the same file runs on code before task A: `sed -e '/NEW-API/d' -e 's#// BASE-API ##'`.

import XCTest
@testable import Phocasa

final class MetadataWriteBenchmarks: XCTestCase {
    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private func report(_ label: String, _ ms: [Double]) {
        print(String(format: "BENCH|write|%@|median_ms=%.3f|min_ms=%.3f|max_ms=%.3f|runs=%d",
                     label, median(ms), ms.min() ?? 0, ms.max() ?? 0, ms.count))
    }

    private func time(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    func testRatingWritesAndExports() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PHOCASA_BENCH"] == "1" else { throw XCTSkip("set PHOCASA_BENCH=1") }
        guard let rawPath = env["PHOCASA_TEST_RAW"], !rawPath.isEmpty else { throw XCTSkip("set PHOCASA_TEST_RAW") }
        let source = URL(fileURLWithPath: rawPath)
        let sourceJPG = try XCTUnwrap(["JPG", "jpg"].lazy.map { source.deletingPathExtension().appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phocasa-writebench-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent(source.lastPathComponent)
        let jpg = dir.appendingPathComponent(sourceJPG.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: raw)
        try FileManager.default.copyItem(at: sourceJPG, to: jpg)
        let service = MetadataService.shared

        // Rating and keyword writes, as MetadataWriter runs them (synchronously, one at a time).
        service.writeMetadata(rating: 1, keywords: ["warm"], toImageAt: jpg.path)
        report("jpg rating write (16 MP camera JPG)", (0..<20).map { i in
            time { service.writeMetadata(rating: i % 5 + 1, keywords: ["k\(i)", "people:ann"], toImageAt: jpg.path) }
        })
        service.writeMetadata(rating: 1, keywords: ["warm"], toImageAt: raw.path)
        report("raw sidecar rating write", (0..<20).map { i in
            time { service.writeMetadata(rating: i % 5 + 1, keywords: ["k\(i)", "people:ann"], toImageAt: raw.path) }
        })

        // Exports, native, on the full lane.
        let editing = ImageEditingService()
        var params = EditParameters()
        params.exposure = 0.5
        var rawExports: [Double] = [], bakes: [Double] = []
        for i in 0..<4 {
            let out = dir.appendingPathComponent("raw-edit-\(i).jpg")
            var start = ContinuousClock.now
            let rawOK = await editing.exportRAWToJPEG(rawURL: raw, parameters: params, outputURL: out, metadataSources: [jpg, raw]) == .written // NEW-API
            // BASE-API let rawOK = await editing.exportRAWToJPEG(rawURL: raw, parameters: params, outputURL: out)
            var d = ContinuousClock.now - start
            XCTAssertTrue(rawOK)
            if i > 0 { rawExports.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }

            let bake = dir.appendingPathComponent("bake-\(i).jpg")
            try FileManager.default.copyItem(at: sourceJPG, to: bake)
            start = ContinuousClock.now
            let bakeOK = await editing.exportStandardToJPEG(sourceURL: bake, parameters: params, outputURL: bake) == .written // NEW-API
            // BASE-API let bakeOK = await editing.exportStandardToJPEG(sourceURL: bake, parameters: params, outputURL: bake)
            d = ContinuousClock.now - start
            XCTAssertTrue(bakeOK)
            if i > 0 { bakes.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        }
        report("export raw to new jpg (native)", rawExports)
        report("apply edits permanently to jpg (native)", bakes)
    }
}
