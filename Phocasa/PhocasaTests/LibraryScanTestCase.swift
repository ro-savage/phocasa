import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Shared setup for tests that scan real files in temp folders into a temp on-disk store, through the view model
/// (`ScanRelinkTests`, `LibraryFolderTests`).
@MainActor
class LibraryScanTestCase: XCTestCase {
    private var tempDirs: [URL] = []
    private var containers: [ModelContainer] = []

    override func tearDown() async throws {
        containers.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    /// A temp folder, as the canonical path the folder enumerator reports (`/private/var/…`).
    func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-rel5-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let canonical = try XCTUnwrap(realpath(dir.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    /// A folder (and its parents) inside a temp folder.
    @discardableResult
    func makeFolder(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeStoreURL() throws -> URL {
        try makeTempDir("store").appendingPathComponent("library.store")
    }

    /// A container on the store at `storeURL`. A second one on the same file is what the app sees after a relaunch.
    func makeContainer(storeURL: URL? = nil) throws -> ModelContainer {
        let config = ModelConfiguration(url: try storeURL ?? makeStoreURL(), cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: config
        )
        containers.append(container)
        return container
    }

    /// A small JPEG taken at `taken` (EXIF `DateTimeOriginal`, `yyyy:MM:dd HH:mm:ss`; none when nil), optionally with a
    /// rating and keywords written by the app's own write path.
    @discardableResult
    func makeJPEG(_ name: String, in dir: URL, taken: String? = "2021:05:04 10:00:00", rating: Int? = nil,
                  keywords: [String] = []) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try CaptureDateFixtures.writeJPEG(at: url, exifDate: taken)
        if rating != nil || !keywords.isEmpty {
            MetadataService.shared.writeMetadata(rating: rating ?? 0, keywords: keywords, toImageAt: url.path)
        }
        return url
    }

    /// A stand-in RAW file: fake bytes, which only the extension makes a RAW to the scanner.
    @discardableResult
    func makeRAW(_ name: String, in dir: URL, bytes: String = "not a real raw") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    /// A bookmark of `folder`, as "Open Folder…" records one.
    func bookmark(of folder: URL) throws -> Data {
        try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// A library with `folders` as its library folders (with bookmarks when `bookmarks`), in a fresh on-disk store (or
    /// the one at `storeURL`), opened as the app does at launch (`setModelContext`, which rescans). Waits for the scans.
    func openLibrary(folders: [URL], bookmarks: Bool = false, storeURL: URL? = nil,
                     seed: (ModelContext) throws -> Void = { _ in })
        async throws -> (PhotoLibraryViewModel, ModelContainer)
    {
        let container = try makeContainer(storeURL: storeURL)
        let context = container.mainContext
        for folder in folders {
            context.insert(PhotoLibrary(rootFolderPath: folder.path, bookmarkData: bookmarks ? try bookmark(of: folder) : nil))
        }
        try seed(context)
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        try await waitForScan(vm)
        return (vm, container)
    }

    func waitForScan(_ vm: PhotoLibraryViewModel, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while vm.library.isScanning {
            if ContinuousClock.now > deadline {
                XCTFail("scan did not finish within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func rescan(_ vm: PhotoLibraryViewModel) async throws {
        vm.library.rescanCurrentLibrary()
        XCTAssertTrue(vm.library.isScanning, "rescanCurrentLibrary() must set isScanning before it returns")
        try await waitForScan(vm)
    }

    /// Every stored photo row, read through a separate context so nothing cached in the view model's context can hide
    /// a duplicate.
    func storedPhotos(_ container: ModelContainer) throws -> [PhotoAsset] {
        try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>())
    }

    /// The stored rows' file names, sorted, duplicates included.
    func storedNames(_ container: ModelContainer) throws -> [String] {
        try storedPhotos(container).map(\.fileName).sorted()
    }

    /// File names of the photos in the bin, as the store has them (a predicate, not the model property; see
    /// `StoredPhoto.fetchAllNow`).
    func storedBinNames(_ container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.isInBin }))
            .map(\.fileName).sorted()
    }

    /// Every library folder's path in the store, sorted.
    func storedFolderPaths(_ container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<PhotoLibrary>()).map(\.rootFolderPath).sorted()
    }

    func names(_ photos: [PhotoAsset]) -> [String] { photos.map(\.fileName).sorted() }

    /// The library's in-memory state must equal what a full `loadExistingData()` of the same store gives, with the same
    /// filters, search, sort and missing set (as `ScanTests` checks it).
    func assertMatchesFreshLoad(_ vm: PhotoLibraryViewModel, _ step: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let library = vm.library
        let oracle = LibraryStore()
        oracle.modelContext = library.modelContext
        oracle.sort = library.sort
        oracle.activeFilters = library.activeFilters
        oracle.viewingBin = library.viewingBin
        oracle.searchText = library.searchText
        oracle.missingPhotoIDs = library.missingPhotoIDs
        oracle.loadExistingData()
        func ids(_ photos: [PhotoAsset]) -> [UUID] { photos.map(\.id) }
        // A photo's tags have no stable order, so neither do the tag lines of its search key.
        func comparable(_ facts: [PhotoFacts]) -> [PhotoFacts] {
            facts.map { f in
                var lines = f.searchKey.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let name = lines.removeFirst()
                var copy = f
                copy.searchKey = ([name] + lines.sorted()).joined(separator: "\n")
                return copy
            }
        }
        XCTAssertEqual(ids(library.photos), ids(oracle.photos), "photos after \(step)", file: file, line: line)
        XCTAssertEqual(ids(library.allPhotos), ids(oracle.allPhotos), "allPhotos after \(step)", file: file, line: line)
        XCTAssertEqual(ids(library.binPhotos), ids(oracle.binPhotos), "binPhotos after \(step)", file: file, line: line)
        XCTAssertEqual(comparable(library.allFacts), comparable(oracle.allFacts), "allFacts after \(step)",
                       file: file, line: line)
        XCTAssertEqual(comparable(library.binFacts), comparable(oracle.binFacts), "binFacts after \(step)",
                       file: file, line: line)
        XCTAssertEqual(library.binCount, oracle.binCount, "binCount after \(step)", file: file, line: line)
        XCTAssertEqual(library.ratingCounts, oracle.ratingCounts, "ratingCounts after \(step)", file: file, line: line)
        XCTAssertEqual(library.tagCounts, oracle.tagCounts, "tagCounts after \(step)", file: file, line: line)
        XCTAssertEqual(library.jpgCount, oracle.jpgCount, "jpgCount after \(step)", file: file, line: line)
        XCTAssertEqual(library.rawCount, oracle.rawCount, "rawCount after \(step)", file: file, line: line)
        XCTAssertEqual(library.libraryCounts, oracle.libraryCounts, "libraryCounts after \(step)", file: file, line: line)
        XCTAssertEqual(library.photos.indices.map { library.index(of: library.photos[$0].id) },
                       library.photos.indices.map { $0 }, "index(of:) after \(step)", file: file, line: line)
    }
}
