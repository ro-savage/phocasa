import Foundation

/// Tells a file that is gone from one on a drive that isn't connected. Drives and network shares are mounted at
/// `/Volumes/<name>`, which goes away when they're unplugged or unmounted; everything else is on the startup disk,
/// which is always there. So a missing file under `/Volumes/<name>` is on an unavailable volume when that folder is
/// missing too, and gone otherwise.
struct VolumeCheck: Sendable {
    /// Where volumes are mounted. Tests pass a temp folder.
    var volumesDirectory = "/Volumes"

    /// The mount folder of the volume `path` is on (`/Volumes/Photos` for `/Volumes/Photos/2024/a.jpg`), or nil for a
    /// path on the startup disk.
    func volumeFolder(of path: String) -> String? {
        let prefix = volumesDirectory.hasSuffix("/") ? volumesDirectory : volumesDirectory + "/"
        guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else {
            return nil
        }
        return prefix + name
    }

    /// The name of the volume `path` is on ("Photos"), or nil for the startup disk.
    func volumeName(of path: String) -> String? {
        volumeFolder(of: path).map { ($0 as NSString).lastPathComponent }
    }

    /// Whether the volume `path` is on is mounted: always for the startup disk.
    func isVolumeAvailable(for path: String) -> Bool {
        guard let folder = volumeFolder(of: path) else { return true }
        return FileManager.default.fileExists(atPath: folder)
    }
}
