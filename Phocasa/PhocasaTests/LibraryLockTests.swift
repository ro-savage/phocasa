import XCTest
@testable import Phocasa

/// The library folder's single-instance lock (`LibraryLock`): one process at a time opens a library. Each test locks
/// a temp folder of its own; the cross-process checks use `/usr/bin/lockf`, which takes the same BSD `flock`.
final class LibraryLockTests: XCTestCase {

    private var folder: URL!
    private var lockFile: URL { folder.appendingPathComponent(LibraryLock.fileName) }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaTests-LibraryLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    private struct NotAcquired: Error { let outcome: String }

    private func acquire(holder: LibraryLock.Holder = .current) throws -> LibraryLock {
        let outcome = LibraryLock.acquire(in: folder, holder: holder)
        guard case .acquired(let lock) = outcome else { throw NotAcquired(outcome: "\(outcome)") }
        return lock
    }

    /// Runs `/usr/bin/lockf` on the lock file; its exit status.
    @discardableResult
    private func lockf(_ arguments: [String], wait: Bool = true) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-s", "-k"] + arguments
        try process.run()
        if wait { process.waitUntilExit() }
        return process
    }

    func testTheFirstLaunchTakesTheLockAndSaysWhoHoldsIt() throws {
        let lock = try acquire(holder: .init(processID: 4242, appPath: "/Applications/Phocasa.app"))
        defer { lock.release() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: lockFile.path))
        XCTAssertEqual(LibraryLock.holder(ofLockIn: folder),
                       LibraryLock.Holder(processID: 4242, appPath: "/Applications/Phocasa.app"))
    }

    func testASecondLaunchFindsTheLockHeldAndWhoHoldsIt() throws {
        let lock = try acquire(holder: .init(processID: 4242, appPath: "/Applications/Phocasa.app"))
        defer { lock.release() }

        guard case .held(let holder) = LibraryLock.acquire(in: folder, holder: .current) else {
            return XCTFail("a second lock on the same folder must fail")
        }
        XCTAssertEqual(holder, LibraryLock.Holder(processID: 4242, appPath: "/Applications/Phocasa.app"))
        XCTAssertEqual(LibraryLock.holder(ofLockIn: folder)?.processID, 4242, "the loser didn't overwrite the holder")
    }

    func testTheLockIsFreeOnceReleased() throws {
        let first = try acquire()
        first.release()

        let second = try acquire()
        second.release()
    }

    /// The lock is only as long-lived as the object: the app keeps it for the life of the process, and the kernel
    /// drops it when the process exits, however it exits, so a crash never leaves a stale lock.
    func testTheLockIsFreeOnceItsHolderIsGone() throws {
        do { _ = try acquire() }
        let again = try acquire()
        again.release()
    }

    func testAnotherProcessCantTakeTheLockWhileItsHeld() throws {
        let lock = try acquire()

        XCTAssertNotEqual(try lockf(["-t", "0", lockFile.path, "/usr/bin/true"]).terminationStatus, 0,
                          "another process sees the lock held")
        lock.release()
        XCTAssertEqual(try lockf(["-t", "0", lockFile.path, "/usr/bin/true"]).terminationStatus, 0,
                       "and free once released")
    }

    func testALockHeldByAnotherProcessKeepsThisOneOut() throws {
        let holder = try lockf([lockFile.path, "/bin/sleep", "10"], wait: false)
        defer { holder.terminate(); holder.waitUntilExit() }
        let deadline = Date().addingTimeInterval(5)
        var outcome = LibraryLock.acquire(in: folder, holder: .current)
        while case .acquired(let lock) = outcome, Date() < deadline {   // until lockf has taken it
            lock.release()
            Thread.sleep(forTimeInterval: 0.02)
            outcome = LibraryLock.acquire(in: folder, holder: .current)
        }

        guard case .held = outcome else { return XCTFail("expected the lock to be held, got \(outcome)") }
    }

    func testAFolderThatCantHoldALockFileFails() throws {
        let missing = folder.appendingPathComponent("no such folder", isDirectory: true)
        guard case .failed = LibraryLock.acquire(in: missing, holder: .current) else {
            return XCTFail("no lock file can be made in a folder that doesn't exist")
        }
    }

    func testTheCurrentHolderIsThisProcess() {
        XCTAssertEqual(LibraryLock.Holder.current.processID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(LibraryLock.Holder.current.appPath, Bundle.main.bundlePath)
    }
}
