import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// Image files with an EXIF capture date, written through ImageIO into temp folders.
enum CaptureDateFixtures {
    /// Writes a small JPEG (or TIFF, …) whose EXIF has `exif` (for example `DateTimeOriginal`). No EXIF when nil.
    static func writeImage(at url: URL, type: UTType = .jpeg, exif: [CFString: Any]?) throws {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = ctx.makeImage()!
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [:]
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A JPEG taken at `exifDate` (`yyyy:MM:dd HH:mm:ss`), with optional subseconds and offset.
    static func writeJPEG(at url: URL, exifDate: String?, subseconds: String? = nil, offset: String? = nil) throws {
        var exif: [CFString: Any] = [:]
        if let exifDate { exif[kCGImagePropertyExifDateTimeOriginal] = exifDate }
        if let subseconds { exif[kCGImagePropertyExifSubsecTimeOriginal] = subseconds }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        try writeImage(at: url, exif: exif.isEmpty ? nil : exif)
    }

    /// The date `components` name in `timeZone`, through `Calendar` (the oracle for local-time parsing).
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
                     in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }

    /// Seconds since 1970 of a UTC time.
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        date(year, month, day, hour, minute, second, in: TimeZone(identifier: "UTC")!)
    }
}

/// Parsing EXIF and XMP capture dates (`CaptureDate.parse`).
final class CaptureDateParsingTests: XCTestCase {
    private let auckland = TimeZone(identifier: "Pacific/Auckland")!
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func assertDate(_ actual: Date?, _ expected: Date, accuracy: TimeInterval = 1e-6,
                            _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("nil, expected \(expected) \(message)", file: file, line: line) }
        XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: accuracy,
                       message, file: file, line: line)
    }

    // MARK: EXIF form (`yyyy:MM:dd HH:mm:ss`)

    func testExifDateWithoutOffsetIsLocalTime() {
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", timeZone: auckland),
                   CaptureDateFixtures.date(2021, 7, 4, 13, 45, 10, in: auckland))
        assertDate(CaptureDate.parse("2021:01:15 08:00:00", timeZone: berlin),
                   CaptureDateFixtures.date(2021, 1, 15, 8, 0, 0, in: berlin), "winter time")
        assertDate(CaptureDate.parse("2021:07:15 08:00:00", timeZone: berlin),
                   CaptureDateFixtures.date(2021, 7, 15, 8, 0, 0, in: berlin), "summer time")
    }

    func testExifDateDefaultsToTheCurrentTimeZone() {
        assertDate(CaptureDate.parse("2013:01:02 16:14:49"), CaptureDateFixtures.date(2013, 1, 2, 16, 14, 49))
    }

    func testExifDateWithOffset() {
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", offset: "+02:00", timeZone: auckland),
                   CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 10))
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", offset: "-05:30", timeZone: auckland),
                   CaptureDateFixtures.utc(2021, 7, 4, 19, 15, 10))
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", offset: "+00:00", timeZone: auckland),
                   CaptureDateFixtures.utc(2021, 7, 4, 13, 45, 10))
    }

    func testExifDateWithSubseconds() {
        let base = CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 10)
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", subseconds: "25", offset: "+02:00"),
                   base.addingTimeInterval(0.25))
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", subseconds: "007", offset: "+02:00"),
                   base.addingTimeInterval(0.007))
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", subseconds: " 5 ", offset: "+02:00"),
                   base.addingTimeInterval(0.5), "padded")
    }

    func testMalformedOffsetOrSubsecondsAreIgnored() {
        let local = CaptureDateFixtures.date(2021, 7, 4, 13, 45, 10, in: auckland)
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", offset: "   :  ", timeZone: auckland), local)
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", offset: "+2:00", timeZone: auckland), local)
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", offset: "+24:00", timeZone: auckland), local)
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", subseconds: "ab", timeZone: auckland), local)
        assertDate(CaptureDate.parse("2021:07:04 13:45:10", subseconds: "", timeZone: auckland), local)
    }

    // MARK: XMP form (ImageIO's `photoshop:DateCreated`, ISO 8601)

    func testXMPDateWithFractionAndSeparateOffset() {
        assertDate(CaptureDate.parse("2021-07-04T13:45:10.25", offset: "+02:00", timeZone: auckland),
                   CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 10).addingTimeInterval(0.25))
    }

    func testXMPFractionWinsOverSubseconds() {
        assertDate(CaptureDate.parse("2021-07-04T13:45:10.25", subseconds: "99", offset: "+02:00"),
                   CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 10).addingTimeInterval(0.25))
    }

    func testXMPTimeZoneDesignatorWinsOverOffset() {
        assertDate(CaptureDate.parse("2021-07-04T13:45:10+02:00", offset: "-05:00", timeZone: auckland),
                   CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 10))
        assertDate(CaptureDate.parse("2021-07-04T13:45:10Z", offset: "-05:00", timeZone: auckland),
                   CaptureDateFixtures.utc(2021, 7, 4, 13, 45, 10))
        assertDate(CaptureDate.parse("2021-07-04T13:45:10.5-0330", timeZone: auckland),
                   CaptureDateFixtures.utc(2021, 7, 4, 17, 15, 10).addingTimeInterval(0.5))
    }

    func testXMPDateWithoutSecondsOrTime() {
        assertDate(CaptureDate.parse("2021-07-04T13:45", timeZone: auckland),
                   CaptureDateFixtures.date(2021, 7, 4, 13, 45, 0, in: auckland))
        assertDate(CaptureDate.parse("2021-07-04T13:45+02:00", timeZone: auckland),
                   CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 0))
        assertDate(CaptureDate.parse("2021-07-04", timeZone: auckland),
                   CaptureDateFixtures.date(2021, 7, 4, in: auckland))
        assertDate(CaptureDate.parse("2021-07", timeZone: auckland), CaptureDateFixtures.date(2021, 7, 1, in: auckland))
        assertDate(CaptureDate.parse("1987", timeZone: auckland), CaptureDateFixtures.date(1987, 1, 1, in: auckland))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        assertDate(CaptureDate.parse("  2021:07:04 13:45:10 \n", offset: "+02:00"), CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 10))
    }

    // MARK: Calendar edges

    func testLeapDaysAndOldDates() {
        assertDate(CaptureDate.parse("2020:02:29 12:00:00", offset: "+00:00"), CaptureDateFixtures.utc(2020, 2, 29, 12, 0, 0))
        assertDate(CaptureDate.parse("2000:02:29 00:00:00", offset: "+00:00"), CaptureDateFixtures.utc(2000, 2, 29, 0, 0, 0))
        assertDate(CaptureDate.parse("1900:01:01 00:00:00", offset: "+00:00"), Date(timeIntervalSince1970: -2_208_988_800))
        assertDate(CaptureDate.parse("1969:12:31 23:59:59", offset: "+00:00"), Date(timeIntervalSince1970: -1))
        assertDate(CaptureDate.parse("2038:01:19 03:14:08", offset: "+00:00"), Date(timeIntervalSince1970: 2_147_483_648))
    }

    func testDaylightSavingGapMatchesCalendar() {
        // 02:30 doesn't exist in Berlin on 28 March 2021; both land an hour later, at 03:30 CEST.
        assertDate(CaptureDate.parse("2021:03:28 02:30:00", timeZone: berlin),
                   CaptureDateFixtures.date(2021, 3, 28, 2, 30, 0, in: berlin))
    }

    func testAmbiguousDaylightSavingTimeIsOneOfItsTwoInstants() throws {
        // 02:30 happens twice in Berlin on 31 October 2021: 00:30 and 01:30 UTC.
        let parsed = try XCTUnwrap(CaptureDate.parse("2021:10:31 02:30:00", timeZone: berlin))
        XCTAssertTrue([CaptureDateFixtures.utc(2021, 10, 31, 0, 30, 0), CaptureDateFixtures.utc(2021, 10, 31, 1, 30, 0)]
            .contains(parsed), "\(parsed)")
    }

    // MARK: Malformed

    func testMalformedDatesAreNil() {
        let malformed = [
            "", "   ", "garbage", "0000:00:00 00:00:00", "    :  :     :  :  ",
            "2021:13:04 13:45:10", "2021:00:04 13:45:10", "2021:02:30 10:00:00", "2021:02:29 10:00:00",
            "2021:04:31 10:00:00", "2021:07:00 13:45:10", "2021:07:04 24:00:00", "2021:07:04 13:60:10",
            "2021:07:04 13:45:61", "2021:07:04 13:45:1", "2021:07:04 13:45", "2021:07:04", "2021:07:04 13:45:10 x",
            "2021:07:04T13:45:10x", "21:07:04 13:45:10", "2021-7-4", "2021-07-04T", "2021-07-04T13",
            "2021-07-04T13:45:10.", "2021-07-04T13:45:10+25:00", "2021-07-04T13:45:10+02", "0000", "-2021-07-04",
            "2021/07/04 13:45:10", "２０２１:07:04 13:45:10",
        ]
        for string in malformed {
            XCTAssertNil(CaptureDate.parse(string), "\"\(string)\"")
        }
    }
}

/// Reading the capture date from image files (`readMetadata` and the backfill's `CaptureDate.read`).
final class CaptureDateReadingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhocasaCaptureDate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func testReadMetadataReadsTheCaptureDateWithSubsecondsAndOffset() throws {
        let file = url("full.jpg")
        try CaptureDateFixtures.writeJPEG(at: file, exifDate: "2021:07:04 13:45:10", subseconds: "25", offset: "+02:00")
        let metadata = MetadataService.shared.readMetadata(from: file.path)
        XCTAssertEqual(try XCTUnwrap(metadata.captureDate).timeIntervalSince1970,
                       CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 10).timeIntervalSince1970 + 0.25, accuracy: 1e-6)
        XCTAssertTrue(metadata.captureDateChecked)
        XCTAssertEqual(CaptureDate.read(from: file.path), metadata.captureDate.map(CaptureDate.Read.date))
    }

    func testReadMetadataReadsALocalCaptureDate() throws {
        let file = url("plain.jpg")
        try CaptureDateFixtures.writeJPEG(at: file, exifDate: "2013:01:02 16:14:49")
        let metadata = MetadataService.shared.readMetadata(from: file.path)
        XCTAssertEqual(metadata.captureDate, CaptureDateFixtures.date(2013, 1, 2, 16, 14, 49))
        XCTAssertTrue(metadata.captureDateChecked)
    }

    func testImageWithoutACaptureDateIsCheckedWithNoDate() throws {
        let file = url("none.jpg")
        try CaptureDateFixtures.writeJPEG(at: file, exifDate: nil)
        let metadata = MetadataService.shared.readMetadata(from: file.path)
        XCTAssertNil(metadata.captureDate)
        XCTAssertTrue(metadata.captureDateChecked, "the file was read: it has no capture date")
        XCTAssertEqual(CaptureDate.read(from: file.path), CaptureDate.Read.noDate)
    }

    func testMalformedExifDateIsNil() throws {
        let file = url("zeros.jpg")
        try CaptureDateFixtures.writeJPEG(at: file, exifDate: "0000:00:00 00:00:00")
        let metadata = MetadataService.shared.readMetadata(from: file.path)
        XCTAssertNil(metadata.captureDate)
        XCTAssertTrue(metadata.captureDateChecked)
        XCTAssertEqual(CaptureDate.read(from: file.path), CaptureDate.Read.noDate)
    }

    func testMissingOrEmptyFilesAreNotChecked() throws {
        let empty = url("empty.jpg")
        FileManager.default.createFile(atPath: empty.path, contents: nil)
        for path in [empty.path, url("missing.jpg").path] {
            let metadata = MetadataService.shared.readMetadata(from: path)
            XCTAssertNil(metadata.captureDate, path)
            XCTAssertFalse(metadata.captureDateChecked, "\(path): couldn't be read, so try again later")
            XCTAssertEqual(CaptureDate.read(from: path), CaptureDate.Read.unreadable, path)
        }
    }

    func testTIFFCaptureDate() throws {
        let file = url("scan.tiff")
        try CaptureDateFixtures.writeImage(at: file, type: .tiff, exif: [kCGImagePropertyExifDateTimeOriginal: "1999:12:31 23:59:58",
                                                                         kCGImagePropertyExifOffsetTimeOriginal: "-08:00"])
        XCTAssertEqual(MetadataService.shared.readMetadata(from: file.path).captureDate,
                       CaptureDateFixtures.utc(2000, 1, 1, 7, 59, 58))
    }

    func testCaptureDateIsReadAlongsideRatingAndKeywordsAndSurvivesTheAppsOwnWrite() throws {
        let file = url("rated.jpg")
        try CaptureDateFixtures.writeJPEG(at: file, exifDate: "2021:07:04 13:45:10", offset: "+02:00")
        MetadataService.shared.writeMetadata(rating: 4, keywords: ["people:ann", "beach"], toImageAt: file.path)
        let metadata = MetadataService.shared.readMetadata(from: file.path)
        XCTAssertEqual(metadata.rating, 4)
        XCTAssertEqual(Set(metadata.keywords), ["people:ann", "beach"])
        XCTAssertEqual(metadata.captureDate, CaptureDateFixtures.utc(2021, 7, 4, 11, 45, 10))
    }

    /// A real camera pair: set `TEST_RUNNER_PHOCASA_TEST_RAW` to a *copy* of a RAW file (its JPG next to it).
    func testRealCameraFilesReadTheirCaptureDate() throws {
        guard let rawPath = ProcessInfo.processInfo.environment["PHOCASA_TEST_RAW"] else {
            throw XCTSkip("Set PHOCASA_TEST_RAW to a copy of a camera RAW file")
        }
        let raw = MetadataService.shared.readMetadata(from: rawPath)
        let rawDate = try XCTUnwrap(raw.captureDate, "the RAW has a DateTimeOriginal")
        XCTAssertTrue(raw.captureDateChecked)
        XCTAssertEqual(CaptureDate.read(from: rawPath), .date(rawDate))
        let jpgPath = URL(fileURLWithPath: rawPath).deletingPathExtension().appendingPathExtension("JPG").path
        if FileManager.default.fileExists(atPath: jpgPath) {
            XCTAssertEqual(MetadataService.shared.readMetadata(from: jpgPath).captureDate, rawDate,
                           "the JPG of the pair has the same capture date")
        }
        // Checked against the EXIF string ImageIO reports, parsed by Calendar in the current time zone.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: rawPath) as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let exifDate = try XCTUnwrap(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if exif[kCGImagePropertyExifOffsetTimeOriginal as String] == nil,
           exif[kCGImagePropertyExifSubsecTimeOriginal as String] == nil {
            XCTAssertEqual(rawDate, formatter.date(from: exifDate))
        }
    }
}
