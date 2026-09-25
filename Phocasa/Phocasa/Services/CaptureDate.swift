import Foundation
import ImageIO

/// When a photo was taken: its EXIF `DateTimeOriginal`, with `SubsecTimeOriginal` and `OffsetTimeOriginal` when the
/// file has them. The grid is ordered by it (`LibrarySort`).
///
/// - A capture date without an offset is the camera's local time. It is read in the time zone that is current when
///   the file is read (by the scan that finds the photo, or by the backfill), which is the best guess: EXIF doesn't say
///   where the camera was.
/// - The date comes from the metadata tree `readMetadata` already copies, where ImageIO shows `DateTimeOriginal` as the
///   XMP property it maps to (`photoshop:DateCreated`, ISO 8601, subseconds merged in) and the offset as
///   `exif:OffsetTimeOriginal`. Copying the properties dictionary instead would cost about 30% more per JPEG.
/// - Parsing is by hand over the fixed formats: no `DateFormatter`, which is slow and not safe to share across threads.
///
/// Everything here is stateless and thread-safe: `readMetadata` calls it from `DispatchQueue.concurrentPerform`.
enum CaptureDate {
    /// What reading a file's capture date found.
    enum Read: Sendable, Equatable {
        /// The file has a capture date.
        case date(Date)
        /// ImageIO read the file as an image, and it has no capture date.
        case noDate
        /// The file is missing, empty, or not an image ImageIO recognises: try again later.
        case unreadable
    }

    // MARK: - Reading

    /// Reads only the capture date (the backfill's read; `readMetadata` reads it with the rating and keywords).
    static func read(from path: String) -> Read {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return .unreadable }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            return date(in: metadata).map(Read.date) ?? .noDate
        }
        guard isImage(source) else { return .unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        return properties.flatMap { date(inProperties: $0) }.map(Read.date) ?? .noDate
    }

    /// Whether ImageIO recognises the file as an image (a type and at least one image), so a missing date is final.
    static func isImage(_ source: CGImageSource) -> Bool {
        CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    /// The capture date in a file's metadata tree (`CGImageSourceCopyMetadataAtIndex`). ImageIO has already merged
    /// `SubsecTimeOriginal` into the value's fraction, so only the offset is looked up (about 1.2 µs per lookup).
    static func date(in metadata: CGImageMetadata, timeZone: TimeZone = .current) -> Date? {
        guard let value = value(in: metadata, matching: kCGImagePropertyExifDateTimeOriginal),
              var fields = Fields(value) else { return nil }
        if fields.offset == nil, let offset = Self.value(in: metadata, matching: kCGImagePropertyExifOffsetTimeOriginal) {
            fields.offset = Fields.offsetSeconds(offset)
        }
        return fields.date(in: timeZone)
    }

    /// The capture date in a properties dictionary (`CGImageSourceCopyPropertiesAtIndex`), for files ImageIO gives no
    /// metadata tree.
    static func date(inProperties properties: [String: Any], timeZone: TimeZone = .current) -> Date? {
        guard let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let value = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        return parse(value,
                     subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
                     offset: exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
                     timeZone: timeZone)
    }

    /// The string value of the metadata tag ImageIO maps the EXIF property to.
    private static func value(in metadata: CGImageMetadata, matching property: CFString) -> String? {
        guard let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, property)
        else { return nil }
        return CGImageMetadataTagCopyValue(tag) as? String
    }

    // MARK: - Parsing

    /// Parses a capture date: EXIF's `yyyy:MM:dd HH:mm:ss`, or XMP's ISO 8601 form (`yyyy[-MM[-dd[THH:mm[:ss[.s…]]]]]`
    /// with an optional `Z`, `±HH:mm` or `±HHmm`). `subseconds` (EXIF `SubsecTimeOriginal`, digits) applies when the
    /// string has no fraction, and `offset` (EXIF `OffsetTimeOriginal`, `±HH:mm`) when it has no time zone. Without
    /// either, the time is local to `timeZone`. Returns nil for anything malformed; a malformed `subseconds` or
    /// `offset` is ignored.
    static func parse(_ string: String, subseconds: String? = nil, offset: String? = nil,
                      timeZone: TimeZone = .current) -> Date? {
        guard var fields = Fields(string) else { return nil }
        if !fields.hasFraction, let subseconds { fields.add(subseconds: subseconds) }
        if fields.offset == nil, let offset { fields.offset = Fields.offsetSeconds(offset) }
        return fields.date(in: timeZone)
    }

    /// A parsed date and time, before the time zone is applied.
    private struct Fields {
        /// The wall-clock time as seconds since 1970 as if it were UTC, fraction included.
        var wallSeconds: Double
        var hasFraction: Bool
        /// Seconds east of UTC, when known.
        var offset: Int?

        init?(_ string: String) {
            var string = string
            guard let fields = string.withUTF8({ Self.parse($0) }) else { return nil }
            self = fields
        }

        private init(wallSeconds: Double, hasFraction: Bool, offset: Int?) {
            self.wallSeconds = wallSeconds
            self.hasFraction = hasFraction
            self.offset = offset
        }

        func date(in timeZone: TimeZone) -> Date {
            if let offset { return Date(timeIntervalSince1970: wallSeconds - Double(offset)) }
            // Local time: the offset at the instant it names. Near a daylight-saving change the first guess can be an
            // hour out, so check it once.
            let guess = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wallSeconds))
            let actual = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wallSeconds - Double(guess)))
            return Date(timeIntervalSince1970: wallSeconds - Double(actual == guess ? guess : actual))
        }

        mutating func add(subseconds string: String) {
            var string = string
            guard let fraction = string.withUTF8({ bytes -> Double? in
                var scanner = Scanner(bytes)
                scanner.trim()
                guard let fraction = scanner.fraction(), scanner.atEnd else { return nil }
                return fraction
            }) else { return }
            wallSeconds += fraction
            hasFraction = true
        }

        static func offsetSeconds(_ string: String) -> Int? {
            var string = string
            return string.withUTF8 { bytes in
                var scanner = Scanner(bytes)
                scanner.trim()
                guard let offset = scanner.timeZone(), scanner.atEnd else { return nil }
                return offset
            }
        }

        /// The form almost every camera file has, `yyyy-MM-ddTHH:mm:ss` (or EXIF's `yyyy:MM:dd HH:mm:ss`), read at fixed
        /// positions: the general scanner costs about 2 µs per date in the Debug builds tests and benchmarks run, this
        /// well under 1 µs. Anything else is nil here and goes to the scanner.
        private static func parseFixedForm(_ bytes: UnsafeBufferPointer<UInt8>) -> Fields? {
            guard bytes.count == 19, let p = bytes.baseAddress else { return nil }
            let separator = p[4]
            guard separator == .hyphen || separator == .colon, p[7] == separator,
                  p[10] == .letterT || p[10] == .space, p[13] == .colon, p[16] == .colon else { return nil }
            func two(_ i: Int) -> Int {
                let high = Int(p[i]) - 48, low = Int(p[i + 1]) - 48
                return high >= 0 && high <= 9 && low >= 0 && low <= 9 ? high * 10 + low : -1
            }
            let century = two(0), yearOfCentury = two(2), month = two(5), day = two(8)
            let hour = two(11), minute = two(14), second = two(17)
            guard century >= 0, yearOfCentury >= 0, month >= 1, day >= 1, hour >= 0, minute >= 0, second >= 0
            else { return nil }
            let year = century * 100 + yearOfCentury
            guard year >= 1, month <= 12, day <= daysIn(month: month, year: year),
                  hour <= 23, minute <= 59, second <= 60 else { return nil }
            let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400 + hour * 3_600 + minute * 60 + second
            return Fields(wallSeconds: Double(seconds), hasFraction: false, offset: nil)
        }

        private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> Fields? {
            if let fields = parseFixedForm(bytes) { return fields }
            var scanner = Scanner(bytes)
            scanner.trim()
            guard let year = scanner.digits(4), year >= 1 else { return nil }
            var month = 1, day = 1, hour = 0, minute = 0, second = 0
            var fraction = 0.0, hasFraction = false, offset: Int?

            parsing: do {
                // A bare year, year-month or date is XMP's (ISO 8601) reduced precision; EXIF always has the time.
                if scanner.atEnd { break parsing }
                guard let separator = scanner.next(), separator == .hyphen || separator == .colon else { return nil }
                let exifForm = separator == .colon
                guard let m = scanner.digits(2) else { return nil }
                month = m
                if scanner.atEnd { guard !exifForm else { return nil }; break parsing }
                guard scanner.skip(separator), let d = scanner.digits(2) else { return nil }
                day = d
                if scanner.atEnd { guard !exifForm else { return nil }; break parsing }
                guard scanner.skip(.letterT) || scanner.skip(.space),
                      let h = scanner.digits(2), scanner.skip(.colon), let mi = scanner.digits(2) else { return nil }
                hour = h
                minute = mi
                if scanner.skip(.colon) {
                    guard let s = scanner.digits(2) else { return nil }
                    second = s
                    if scanner.skip(.period) {
                        guard let f = scanner.fraction() else { return nil }
                        fraction = f
                        hasFraction = true
                    }
                } else if exifForm {
                    return nil
                }
                if !scanner.atEnd {
                    guard let zone = scanner.timeZone() else { return nil }
                    offset = zone
                }
                guard scanner.atEnd else { return nil }
            }

            // Plain comparisons: `ClosedRange.contains` is generic, and slow in the Debug builds tests run.
            guard month >= 1, month <= 12, day >= 1, day <= daysIn(month: month, year: year),
                  hour <= 23, minute <= 59, second <= 60 else { return nil }
            let days = daysFromCivil(year: year, month: month, day: day)
            let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
            return Fields(wallSeconds: Double(seconds) + fraction, hasFraction: hasFraction, offset: offset)
        }

        private static func daysIn(month: Int, year: Int) -> Int {
            switch month {
            case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
            case 4, 6, 9, 11: return 30
            default: return 31
            }
        }

        /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
        private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            return era * 146_097 + dayOfEra - 719_468
        }
    }

    /// Reads ASCII tokens from UTF-8 bytes.
    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var position: Int
        var end: Int

        init(_ bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            position = 0
            end = bytes.count
        }

        var atEnd: Bool { position >= end }

        /// Drops surrounding whitespace (and the NUL padding some cameras leave).
        mutating func trim() {
            func isPadding(_ byte: UInt8) -> Bool { byte == 0 || byte == 32 || (byte >= 9 && byte <= 13) }
            while position < end, isPadding(bytes[position]) { position += 1 }
            while end > position, isPadding(bytes[end - 1]) { end -= 1 }
        }

        mutating func next() -> UInt8? {
            guard position < end else { return nil }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func skip(_ byte: UInt8) -> Bool {
            guard position < end, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        /// Exactly `count` ASCII digits.
        mutating func digits(_ count: Int) -> Int? {
            guard end - position >= count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = bytes[position + offset]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            position += count
            return value
        }

        /// One or more digits read as a fraction of a second ("25" is 0.25).
        mutating func fraction() -> Double? {
            var value = 0.0, scale = 1.0
            let start = position
            while position < end, bytes[position] >= 48, bytes[position] <= 57 {
                scale /= 10
                value += Double(bytes[position] - 48) * scale
                position += 1
            }
            return position > start ? value : nil
        }

        /// `Z`, `±HH:mm` or `±HHmm`, as seconds east of UTC.
        mutating func timeZone() -> Int? {
            if skip(.letterZ) { return 0 }
            guard let sign = next(), sign == .plus || sign == .hyphen,
                  let hours = digits(2) else { return nil }
            _ = skip(.colon)
            guard let minutes = digits(2), hours <= 23, minutes <= 59 else { return nil }
            return (sign == .hyphen ? -1 : 1) * (hours * 3_600 + minutes * 60)
        }
    }
}

private extension UInt8 {
    static let hyphen = UInt8(ascii: "-"), colon = UInt8(ascii: ":"), space = UInt8(ascii: " ")
    static let letterT = UInt8(ascii: "T"), letterZ = UInt8(ascii: "Z")
    static let period = UInt8(ascii: "."), plus = UInt8(ascii: "+")
}
