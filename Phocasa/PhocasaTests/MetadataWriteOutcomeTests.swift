import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Each rating, keyword and edit write says what it did (REL-4 #1): into the file, into the sidecar, kept in a sidecar
/// as the last resort, or skipped or failed and why. Real files in a temp folder; read-only and locked states are
/// undone in tearDown so the folder can be removed.
final class MetadataWriteOutcomeTests: XCTestCase {
    private var dir: URL!
    private let service = MetadataService.shared

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-outcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        guard let dir else { return }
        let fm = FileManager.default
        // Unlock and make writable everything a test locked, then remove the folder.
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        for url in (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: url.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? fm.removeItem(at: dir)
        self.dir = nil
    }

    // MARK: - Helpers

    private func makeImage(_ name: String, type: UTType = .jpeg, in folder: URL? = nil) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = (folder ?? dir).appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeRAW(_ name: String, sidecar: String? = nil, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        try Data("fake raw bytes".utf8).write(to: url)
        if let sidecar { try Data(sidecar.utf8).write(to: url.xmpSidecarURL) }
        return url
    }

    private func readOnly(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    }

    private func issue(_ outcome: MetadataWriteOutcome, _ url: URL,
                       _ kind: MetadataWriteProblem.Kind = .ratingAndKeywords) -> MetadataWriteProblem.Issue? {
        MetadataWriteProblem.Issue(outcome, writing: kind, at: url.path)
    }

    // MARK: - Where the values went

    func testAJPEGIsWrittenIntoTheFile() throws {
        let jpg = try makeImage("a.jpg")
        let outcome = service.writeMetadata(rating: 3, keywords: ["k"], toImageAt: jpg.path)
        XCTAssertEqual(outcome, .writtenIntoFile)
        XCTAssertNil(issue(outcome, jpg), "not a problem")
        XCTAssertEqual(service.readMetadata(from: jpg.path).rating, 3)
    }

    func testARAWIsWrittenToItsSidecar() throws {
        let raw = try makeRAW("b.ARW")
        let outcome = service.writeMetadata(rating: 2, keywords: [], toImageAt: raw.path)
        XCTAssertEqual(outcome, .writtenToSidecar)
        XCTAssertNil(issue(outcome, raw))
        XCTAssertEqual(service.writeEditParameters(EditParameters(exposure: 1), forRAWAt: raw.path), .writtenToSidecar)
        XCTAssertEqual(service.clearEditParameters(forRAWAt: raw.path), .writtenToSidecar)
    }

    func testTheSameValuesAgainCountAsWritten() throws {
        let jpg = try makeImage("same.jpg")
        service.writeMetadata(rating: 4, keywords: ["k"], toImageAt: jpg.path)
        XCTAssertEqual(service.writeMetadata(rating: 4, keywords: ["k"], toImageAt: jpg.path), .writtenIntoFile)
    }

    /// A format with no in-file writer (a GIF): its values go to its sidecar, which overrides it. Not a failure.
    func testAFileThatCantTakeThemIsKeptInASidecar() throws {
        let gif = try makeImage("c.gif", type: .gif)
        let before = try Data(contentsOf: gif)
        let outcome = service.writeMetadata(rating: 5, keywords: ["k"], toImageAt: gif.path)
        XCTAssertEqual(outcome, .keptInSidecar)
        XCTAssertEqual(issue(outcome, gif), .keptInSidecar)
        XCTAssertEqual(try Data(contentsOf: gif), before, "the file keeps its bytes")
        XCTAssertTrue(service.sidecarOverridesEmbedded(gif))
    }

    // MARK: - Skipped

    func testAReadOnlyFileIsSkippedAndSaysSo() throws {
        let jpg = try makeImage("ro.jpg")
        try readOnly(jpg)
        let before = try Data(contentsOf: jpg)
        let outcome = service.writeMetadata(rating: 3, keywords: [], toImageAt: jpg.path)
        XCTAssertEqual(outcome, .skippedReadOnly)
        XCTAssertEqual(issue(outcome, jpg), .readOnly(.file))
        XCTAssertEqual(try Data(contentsOf: jpg), before)
    }

    func testALockedFileIsReportedAsLocked() throws {
        let jpg = try makeImage("locked.jpg")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: jpg.path)
        let outcome = service.writeMetadata(rating: 3, keywords: [], toImageAt: jpg.path)
        XCTAssertFalse(outcome.isWritten, "\(outcome)")
        XCTAssertEqual(issue(outcome, jpg), .readOnly(.locked))
    }

    /// The file is writable, but its folder can't take the new file that replaces it.
    func testAReadOnlyFolderIsReportedAsTheFolder() throws {
        let folder = dir.appendingPathComponent("Locked Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let jpg = try makeImage("in-folder.jpg", in: folder)
        let raw = try makeRAW("in-folder.ARW", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        let jpgOutcome = service.writeMetadata(rating: 3, keywords: [], toImageAt: jpg.path)
        guard case .failed = jpgOutcome else { return XCTFail("\(jpgOutcome)") }
        XCTAssertEqual(issue(jpgOutcome, jpg), .readOnly(.folder(folder.path)))

        let rawOutcome = service.writeMetadata(rating: 3, keywords: [], toImageAt: raw.path)
        XCTAssertFalse(rawOutcome.isWritten, "the sidecar can't be created: \(rawOutcome)")
        XCTAssertEqual(issue(rawOutcome, raw), .readOnly(.folder(folder.path)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.xmpSidecarURL.path))
    }

    func testAReadOnlySidecarIsReportedAsTheSidecar() throws {
        let raw = try makeRAW("rs.ARW", sidecar: SidecarFixtures.lightroom)
        try readOnly(raw.xmpSidecarURL)
        let outcome = service.writeMetadata(rating: 1, keywords: [], toImageAt: raw.path)
        XCTAssertEqual(outcome, .skippedReadOnly)
        XCTAssertEqual(issue(outcome, raw), .readOnly(.sidecar))
        let edit = service.writeEditParameters(EditParameters(exposure: 1), forRAWAt: raw.path)
        XCTAssertEqual(issue(edit, raw, .editParameters), .readOnly(.sidecar))
    }

    func testAnUnparseableSidecarIsSkippedAndLeftAsItIs() throws {
        let garbage = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF> not closed"
        let raw = try makeRAW("bad.ARW", sidecar: garbage)
        let outcome = service.writeMetadata(rating: 4, keywords: ["k"], toImageAt: raw.path)
        XCTAssertEqual(outcome, .skippedUnparseableSidecar)
        XCTAssertEqual(issue(outcome, raw), .unparseableSidecar)
        XCTAssertEqual(try String(contentsOf: raw.xmpSidecarURL, encoding: .utf8), garbage)
    }

    func testAMissingFileAndAFileThatIsntAnImage() throws {
        let gone = dir.appendingPathComponent("gone.jpg")
        let goneOutcome = service.writeMetadata(rating: 1, keywords: [], toImageAt: gone.path)
        XCTAssertEqual(goneOutcome, .skippedUnreadable)
        XCTAssertEqual(issue(goneOutcome, gone), .missing)

        let junk = dir.appendingPathComponent("junk.jpg")
        try Data("not an image".utf8).write(to: junk)
        let junkOutcome = service.writeMetadata(rating: 1, keywords: [], toImageAt: junk.path)
        XCTAssertEqual(junkOutcome, .skippedUnreadable)
        XCTAssertEqual(issue(junkOutcome, junk), .unreadable)
    }

    // MARK: - Failures, in words

    func testCommonErrorsAreSaidPlainly() {
        XCTAssertEqual(MetadataWriteOutcome.describe(POSIXError(.ENOSPC)), "The disk is full.")
        XCTAssertEqual(MetadataWriteOutcome.describe(CocoaError(.fileWriteOutOfSpace)), "The disk is full.")
        XCTAssertEqual(MetadataWriteOutcome.describe(CocoaError(.fileWriteVolumeReadOnly)), "The disk is read-only.")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))])
        XCTAssertEqual(MetadataWriteOutcome.describe(wrapped), "The disk is read-only.")
        XCTAssertEqual(MetadataWriteOutcome.describe(POSIXError(.EACCES)),
                       "Phocasa doesn’t have permission to change it.")
        // Anything else: the system's own reason.
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                            userInfo: [NSLocalizedFailureReasonErrorKey: "The server went away."])
        XCTAssertEqual(MetadataWriteOutcome.describe(other), "The server went away.")
    }

    func testAFailureWithNothingReadOnlyKeepsItsReason() throws {
        let jpg = try makeImage("ok.jpg")
        XCTAssertEqual(issue(.failed("The disk is full."), jpg), .failed("The disk is full."))
    }
}
