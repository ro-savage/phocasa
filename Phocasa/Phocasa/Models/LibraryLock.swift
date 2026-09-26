import Foundation

/// The library's single-instance lock: a BSD `flock` on `Phocasa.lock` in the library's folder, taken at launch
/// before the store opens (and before `StoreLocation`'s legacy move and the backup) and held for the life of the
/// process. A second Phocasa on the same library (a Debug build run from Xcode beside the installed app) finds it held
/// and opens nothing, so two processes never scan and insert the same photos.
///
/// The kernel drops a `flock` when the process exits, however it exits, so a crash never leaves the library locked;
/// the file itself stays, and only says who holds it (`Holder`), for the message the loser shows.
final class LibraryLock {
    static let fileName = "Phocasa.lock"

    /// The process that holds the lock, as it wrote itself into the lock file.
    struct Holder: Equatable, Sendable {
        let processID: Int32
        /// The holder's app bundle, which tells a Debug build from the installed app.
        let appPath: String

        static var current: Holder {
            Holder(processID: ProcessInfo.processInfo.processIdentifier, appPath: Bundle.main.bundlePath)
        }
    }

    enum Outcome {
        case acquired(LibraryLock)
        /// Another process holds it; `holder` is nil when the file doesn't say who (it's still being written, or the
        /// holder isn't Phocasa).
        case held(by: Holder?)
        /// The lock file couldn't be opened or locked; the reason.
        case failed(String)
    }

    let url: URL
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit { release() }

    /// Takes the lock in `folder` (which must exist) without waiting, and writes `holder` into the file.
    static func acquire(in folder: URL, holder: Holder = .current) -> Outcome {
        let url = folder.appendingPathComponent(fileName)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .failed(String(cString: strerror(errno))) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            return error == EWOULDBLOCK ? .held(by: self.holder(ofLockIn: folder)) : .failed(String(cString: strerror(error)))
        }
        let record = Array("\(holder.processID)\n\(holder.appPath)\n".utf8)
        if ftruncate(descriptor, 0) == 0 {
            _ = record.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        }
        return .acquired(LibraryLock(url: url, descriptor: descriptor))
    }

    /// Who holds the lock in `folder`, as the file says; nil when it says nothing readable.
    static func holder(ofLockIn folder: URL) -> Holder? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8) else {
            return nil
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, let processID = Int32(lines[0]), !lines[1].isEmpty else { return nil }
        return Holder(processID: processID, appPath: String(lines[1]))
    }

    /// Lets go of the lock. The app never calls this (its lock lasts until it exits); tests do.
    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)   // closing the only descriptor drops the flock
        descriptor = -1
    }
}
