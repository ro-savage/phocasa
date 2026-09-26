import Foundation
import os

/// What one rating, keyword or edit-parameter write did to its file (`MetadataService.writeMetadata`,
/// `writeEditParameters`, `clearEditParameters`). `MetadataWriter` keeps the ones the owner should hear about
/// (`MetadataWriteProblem`) for the status bar.
enum MetadataWriteOutcome: Sendable, Equatable {
    /// Into the image file itself (a JPEG, PNG, TIFF or HEIC), or the file already held these values.
    case writtenIntoFile
    /// Into the `.xmp` sidecar, where they belong: a RAW file's rating and keywords, a RAW's edit parameters. Or the
    /// sidecar already held them.
    case writtenToSidecar
    /// The last resort: the file can't take them without losing some of its metadata, so they went into its sidecar,
    /// which then wins over the file (`phocasa:OverridesEmbedded`). Not a failure.
    case keptInSidecar
    /// Nothing was written: the file or its sidecar is read-only (so may be its folder or its drive:
    /// `MetadataWriteProblem.Issue` finds which).
    case skippedReadOnly
    /// Nothing was written: the sidecar exists but can't be parsed safely, so it was left byte-identical.
    case skippedUnparseableSidecar
    /// Nothing was written: the file isn't there, or isn't an image ImageIO can read (empty, damaged).
    case skippedUnreadable
    /// Nothing was written: the write failed, and the file is as it was. Why, in a sentence.
    case failed(String)

    /// Whether the values reached the file or its sidecar (the last resort included).
    var isWritten: Bool {
        switch self {
        case .writtenIntoFile, .writtenToSidecar, .keptInSidecar: true
        default: false
        }
    }

    /// A write that threw `error`, in words the owner can act on. Cocoa's own message would name the hidden temp file
    /// the write goes through, so the common causes are said plainly.
    static func failed(writing error: any Error) -> MetadataWriteOutcome {
        .failed(Self.describe(error))
    }

    static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = [nsError, underlying].compactMap { $0 }.first { $0.domain == NSPOSIXErrorDomain }?.code
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError: return "The disk is full."
            case NSFileWriteVolumeReadOnlyError: return "The disk is read-only."
            case NSFileWriteNoPermissionError: return "Phocasa doesn’t have permission to change it."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "The file isn’t there any more."
            default: break
            }
        }
        switch posix.map(Int32.init) {
        case ENOSPC?, EDQUOT?: return "The disk is full."
        case EROFS?: return "The disk is read-only."
        case EACCES?, EPERM?: return "Phocasa doesn’t have permission to change it."
        case ENOENT?: return "The file isn’t there any more."
        default: return nsError.localizedFailureReason ?? nsError.localizedDescription
        }
    }
}

extension MetadataService.SidecarWriteResult {
    /// The outcome of a write that went to the sidecar: `written` when it was made (or needn't be).
    func outcome(written: MetadataWriteOutcome) -> MetadataWriteOutcome {
        switch self {
        case .written, .unchanged: written
        case .skippedReadOnly: .skippedReadOnly
        case .skippedUnparseable: .skippedUnparseableSidecar
        case .failed(let reason): .failed(reason)
        }
    }
}

extension MetadataWriteOperation {
    /// Which of a file's two kinds of writes this is: each keeps its own problem (`MetadataWriteProblem.Key`).
    var kind: MetadataWriteProblem.Kind {
        touchesEditParameters ? .editParameters : .ratingAndKeywords
    }
}

// MARK: - Problems

/// A write that didn't reach its file, or went to its sidecar as the last resort: the latest one for a file and kind
/// (a file's rating and keyword write and its RAW edit-parameter write each have their own).
struct MetadataWriteProblem: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Hashable {
        case ratingAndKeywords
        case editParameters
    }

    /// Where the read-only part is: `MetadataWriter` looks once a write was skipped or failed.
    enum ReadOnlyPlace: Sendable, Hashable {
        /// The file.
        case file
        /// The file is locked (Finder's Get Info › Locked).
        case locked
        /// Its `.xmp` sidecar.
        case sidecar
        /// The folder it's in, which can't take the new file a write puts in place of the old one.
        case folder(String)
        /// The drive it's on: a read-only volume (a drive formatted as NTFS, a locked card, a read-only share), by
        /// name and by the folder it's mounted at.
        case volume(name: String, path: String)
    }

    enum Issue: Sendable, Equatable {
        /// The values went to the sidecar as the last resort. Not a failure.
        case keptInSidecar
        case readOnly(ReadOnlyPlace)
        case unparseableSidecar
        case unreadable
        case missing
        case failed(String)

        /// The problem an outcome is, for the write to `path`; nil for a write that went where it belongs.
        /// A write that was skipped or failed is checked for where it's read-only, so a read-only folder or drive
        /// reads as that and not as each file's error.
        init?(_ outcome: MetadataWriteOutcome, writing kind: Kind, at path: String,
              fileManager: FileManager = .default) {
            switch outcome {
            case .writtenIntoFile, .writtenToSidecar:
                return nil
            case .keptInSidecar:
                self = .keptInSidecar
            case .skippedUnparseableSidecar:
                self = .unparseableSidecar
            case .skippedUnreadable:
                self = fileManager.fileExists(atPath: path) ? .unreadable : .missing
            case .skippedReadOnly:
                self = .readOnly(Self.readOnlyPlace(of: path, writing: kind, fileManager: fileManager) ?? .file)
            case .failed(let reason):
                self = Self.readOnlyPlace(of: path, writing: kind, fileManager: fileManager).map(Issue.readOnly)
                    ?? .failed(reason)
            }
        }

        /// What of `path` a write can't change, if anything: its drive, its folder, the file (locked, or read-only),
        /// or its sidecar. The image file matters only for a rating and keyword write into a non-RAW file.
        static func readOnlyPlace(of path: String, writing kind: Kind,
                                  fileManager: FileManager = .default) -> ReadOnlyPlace? {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let folder = url.deletingLastPathComponent()
            if let values = try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeNameKey, .volumeURLKey]),
               values.volumeIsReadOnly == true {
                return .volume(name: values.volumeName ?? folder.lastPathComponent,
                               path: values.volume?.path ?? folder.path)
            }
            if !fileManager.isWritableFile(atPath: folder.path) { return .folder(folder.path) }
            let writesIntoFile = kind == .ratingAndKeywords
                && !FolderScanner.rawExtensions.contains(url.pathExtension.lowercased())
            if writesIntoFile, fileManager.fileExists(atPath: url.path) {
                if (try? url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable == true { return .locked }
                if !fileManager.isWritableFile(atPath: url.path) { return .file }
            }
            let sidecar = url.xmpSidecarURL.resolvingSymlinksInPath()
            if fileManager.fileExists(atPath: sidecar.path) {
                if (try? sidecar.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable == true
                    || !fileManager.isWritableFile(atPath: sidecar.path) { return .sidecar }
            }
            return nil
        }
    }

    struct Key: Sendable, Hashable {
        let path: String
        let kind: Kind
    }

    /// The file the write was for: the image file, or the RAW whose sidecar it goes to.
    let path: String
    /// What was to be written, so a RAW edit can be written again (`MetadataWriter.retry`).
    let operation: MetadataWriteOperation
    let issue: Issue
    let date: Date

    var kind: Kind { operation.kind }
    var key: Key { Key(path: path, kind: kind) }
    var id: Key { key }
    var fileName: String { (path as NSString).lastPathComponent }
    var sidecarName: String { URL(fileURLWithPath: path).xmpSidecarURL.lastPathComponent }

    /// The read-only folder or drive this problem shares with others, which the status bar lists once.
    var sharedReadOnlyPlace: ReadOnlyPlace? {
        guard case .readOnly(let place) = issue else { return nil }
        switch place {
        case .folder, .volume: return place
        case .file, .locked, .sidecar: return nil
        }
    }

    /// Why, in a sentence (for a problem listed on its own).
    var reason: String {
        let what = kind == .editParameters ? "Its RAW edit" : "Its rating and keywords"
        switch issue {
        case .keptInSidecar:
            return "\(what) are in \(sidecarName): the file can’t take them without losing some of its metadata."
        case .readOnly(.file): return "The file is read-only."
        case .readOnly(.locked): return "The file is locked (Get Info › Locked in the Finder)."
        case .readOnly(.sidecar): return "Its sidecar, \(sidecarName), is read-only."
        case .readOnly(.folder): return "Its folder is read-only."
        case .readOnly(.volume(let name, _)): return "“\(name)” is read-only."
        case .unparseableSidecar:
            return "Its sidecar, \(sidecarName), can’t be read safely, so Phocasa left it as it is."
        case .unreadable: return "It can’t be read as an image (it may be damaged)."
        case .missing: return "The file isn’t there any more."
        case .failed(let reason): return reason
        }
    }
}

/// The problems `MetadataWriter` keeps: the latest per file and kind, oldest first, at most `limit` (the oldest go
/// first, counted in `droppedCount`). A write that goes where it belongs clears its key's problem.
struct MetadataWriteProblemList: Sendable, Equatable {
    static let limit = 2_000

    private(set) var problems: [MetadataWriteProblem] = []
    /// Problems dropped to stay within `limit` since the list was last cleared (some may have been fixed since).
    private(set) var droppedCount = 0
    private var byKey: [MetadataWriteProblem.Key: MetadataWriteProblem] = [:]

    var isEmpty: Bool { problems.isEmpty }

    /// Sets `key`'s problem (nil clears it). Returns whether the list changed. O(1) for a key with no problem.
    @discardableResult
    mutating func set(_ problem: MetadataWriteProblem?, for key: MetadataWriteProblem.Key) -> Bool {
        let had = byKey[key] != nil
        guard had || problem != nil else { return false }
        if had { problems.removeAll { $0.key == key } }
        byKey[key] = problem
        guard let problem else { return true }
        problems.append(problem)
        if problems.count > Self.limit {
            byKey[problems.removeFirst().key] = nil
            droppedCount += 1
        }
        return true
    }

    func contains(_ key: MetadataWriteProblem.Key) -> Bool { byKey[key] != nil }

    /// `key`'s problem, if it has one.
    func problem(for key: MetadataWriteProblem.Key) -> MetadataWriteProblem? { byKey[key] }
}

/// What the writer tells the status bar: the writes that didn't reach their files, and those kept in a sidecar as the
/// last resort.
struct MetadataWriteReport: Sendable, Equatable {
    var failures = MetadataWriteProblemList()
    var keptInSidecar = MetadataWriteProblemList()

    /// Files with a write that didn't reach them (a file with two, rating and edit, counts once).
    var failedFileCount: Int { Set(failures.problems.map(\.path)).count }
    var keptInSidecarFileCount: Int { Set(keptInSidecar.problems.map(\.path)).count }

    /// Records the outcome of a write to `path`. Returns whether the report changed.
    mutating func record(_ problem: MetadataWriteProblem?, for key: MetadataWriteProblem.Key) -> Bool {
        let kept = problem?.issue == .keptInSidecar ? problem : nil
        let failed = problem?.issue == .keptInSidecar ? nil : problem
        let changedKept = keptInSidecar.set(kept, for: key)
        return failures.set(failed, for: key) || changedKept
    }
}

/// The writer's report (`MetadataWriteReport`) for the status bar ("⚠︎ 3 files not updated"). Updated from the
/// writer's queue a few times a second at most, and when it's done.
@MainActor @Observable
final class MetadataWriteProblems {
    static let shared = MetadataWriteProblems()

    private(set) var report = MetadataWriteReport()
    @ObservationIgnored private var applied = 0

    /// Orders the updates: each hops to the main actor on a task of its own.
    nonisolated private static let sequence = OSAllocatedUnfairLock(initialState: 0)

    /// The writer's report; from any thread.
    nonisolated static func post(_ report: MetadataWriteReport) {
        let number = sequence.withLock { value -> Int in
            value += 1
            return value
        }
        Task { @MainActor in shared.apply(report, number: number) }
    }

    private func apply(_ report: MetadataWriteReport, number: Int) {
        guard number > applied else { return }
        applied = number
        if self.report != report { self.report = report }
    }
}
