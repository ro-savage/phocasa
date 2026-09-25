import XCTest
import ImageIO
@testable import Phocasa

/// `readMetadata` cost for RAW files with and without a sidecar (task 23 reads sidecars through ImageIO).
/// Skipped unless `PHOCASA_BENCH=1` (pass `TEST_RUNNER_PHOCASA_BENCH=1`). Uses only APIs that also exist before
/// task 23, so the same file measures both sides.
final class MetadataSidecarBenchmarks: XCTestCase {

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func report(_ label: String, _ samples: [Double]) {
        let s = samples.sorted()
        print(String(format: "BENCH|sidecar|%@|median_ms=%.3f|min_ms=%.3f|max_ms=%.3f|runs=%d",
                     label, s[s.count / 2], s.first!, s.last!, s.count))
    }

    func testReadMetadataWithAndWithoutSidecars() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOCASA_BENCH"] == "1", "set PHOCASA_BENCH=1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phocasa-sidecar-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edits = EditParameters(exposure: 0.5, contrast: 10)
        let sets: [(String, String?)] = [
            ("no sidecar", nil),
            ("old Phocasa sidecar", SidecarFixtures.oldPhocasa(rating: 3, keywords: ["people:ann", "beach"], edits: edits)),
            ("Lightroom-style sidecar", SidecarFixtures.lightroom),
        ]
        let clock = ContinuousClock()
        for (label, sidecar) in sets {
            let folder = dir.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let paths = try (0..<200).map { i -> String in
                let raw = folder.appendingPathComponent(String(format: "IMG_%04d.ARW", i))
                try Data("fake raw bytes".utf8).write(to: raw)
                if let sidecar { try Data(sidecar.utf8).write(to: raw.xmpSidecarURL) }
                return raw.path
            }
            var samples: [Double] = []
            var rated = 0
            for _ in 0..<7 {
                let start = clock.now
                for path in paths where MetadataService.shared.readMetadata(from: path).rating > 0 { rated += 1 }
                samples.append(ms(clock.now - start))
            }
            report("readMetadata x200 fake RAW, \(label)", samples)
            print("BENCH|sidecar|info|\(label)|rated=\(rated / 7)")
        }
    }
}
