import XCTest
@testable import Phocasa

/// The status bar's list of write problems (REL-4 #1): a read-only folder or drive is one row, not one per file;
/// each row shows the right thing in the Finder.
final class WriteProblemsViewTests: XCTestCase {

    private func problem(_ path: String, _ issue: MetadataWriteProblem.Issue, at seconds: TimeInterval,
                         kind: MetadataWriteProblem.Kind = .ratingAndKeywords) -> MetadataWriteProblem {
        MetadataWriteProblem(path: path, operation: kind == .editParameters ? .setEditParameters(EditParameters())
                                                                            : .metadata(rating: 1, keywords: []),
                             issue: issue, date: Date(timeIntervalSince1970: seconds))
    }

    func testAReadOnlyFolderOrDriveIsOneRowNewestFirst() {
        let folder = MetadataWriteProblem.ReadOnlyPlace.folder("/Photos/2019")
        let drive = MetadataWriteProblem.ReadOnlyPlace.volume(name: "Archive", path: "/Volumes/Archive")
        // Oldest first, as the writer keeps them.
        let problems = [
            problem("/Photos/2019/a.jpg", .readOnly(folder), at: 1),
            problem("/Volumes/Archive/x.jpg", .readOnly(drive), at: 2),
            problem("/Photos/2019/b.jpg", .readOnly(folder), at: 3),
            problem("/Photos/c.ARW", .unparseableSidecar, at: 4),
            problem("/Photos/2019/b.jpg", .readOnly(folder), at: 5, kind: .editParameters),
        ]

        let rows = WriteProblemRow.rows(problems)

        XCTAssertEqual(rows.map(\.id), [
            .shared(folder),
            .single(MetadataWriteProblem.Key(path: "/Photos/c.ARW", kind: .ratingAndKeywords)),
            .shared(drive),
        ])
        XCTAssertEqual(rows[0].fileCount, 2, "b.jpg's rating and edit are one file")
        XCTAssertEqual(rows[0].title, "“2019” is read-only")
        XCTAssertEqual(rows[0].detail, "2 files in this folder weren’t updated.")
        XCTAssertEqual(rows[0].pathsToShow, ["/Photos/2019"])
        XCTAssertEqual(rows[2].title, "“Archive” is read-only")
        XCTAssertTrue(rows[2].detail.hasPrefix("1 file on this drive wasn’t updated."), rows[2].detail)
        XCTAssertEqual(rows[2].pathsToShow, ["/Volumes/Archive"])
    }

    func testARowOfItsOwnShowsItsFileOrItsSidecar() {
        let unparseable = WriteProblemRow.rows([problem("/P/c.ARW", .unparseableSidecar, at: 1)])[0]
        XCTAssertEqual(unparseable.title, "c.ARW")
        XCTAssertEqual(unparseable.detail, "Its sidecar, c.xmp, can’t be read safely, so Phocasa left it as it is.")
        XCTAssertEqual(unparseable.pathsToShow, ["/P/c.xmp"])

        let kept = WriteProblemRow.rows([problem("/P/d.gif", .keptInSidecar, at: 1)])[0]
        XCTAssertEqual(kept.pathsToShow, ["/P/d.xmp"])

        let locked = WriteProblemRow.rows([problem("/P/e.jpg", .readOnly(.locked), at: 1)])[0]
        XCTAssertEqual(locked.pathsToShow, ["/P/e.jpg"])
        XCTAssertEqual(locked.location, "/P")
    }

    func testShowInFinderSelectsTheFileOrTheNearestFolderThatIsThere() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phocasa-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: file)

        let urls = ShowInFinder.urls(toShow: [file.path, dir.appendingPathComponent("gone/b.jpg").path, file.path])
        XCTAssertEqual(urls.map(\.path), [file.path, dir.path], "each once; a missing file shows its folder")
    }
}
