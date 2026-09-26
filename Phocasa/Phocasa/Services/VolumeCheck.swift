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

    /// Whether `path` is the folder `recorded` names, on its volume mounted under another name. macOS mounts a volume
    /// whose name is taken (by another volume, or a folder left behind in `/Volumes`) as "Name 1", "Name 2"…, so a drive
    /// can come back at `/Volumes/Photos 1/2024` for `/Volumes/Photos/2024`, and later go back. Only the names are
    /// compared: the same path on the volume, and the same volume name less that number.
    func isSameFolderOnRenamedVolume(_ path: String, as recorded: String) -> Bool {
        guard let volume = volumeFolder(of: path), let recordedVolume = volumeFolder(of: recorded),
              volume != recordedVolume,
              path.dropFirst(volume.count) == recorded.dropFirst(recordedVolume.count) else { return false }
        return Self.nameWithoutMountNumber(volume) == Self.nameWithoutMountNumber(recordedVolume)
    }

    /// A volume's name without the " 1" macOS adds when the name is taken.
    private static func nameWithoutMountNumber(_ volumeFolder: String) -> Substring {
        let name = Substring((volumeFolder as NSString).lastPathComponent)
        guard let space = name.lastIndex(of: " ") else { return name }
        let number = name[name.index(after: space)...]
        return !number.isEmpty && number.allSatisfy({ $0.isASCII && $0.isNumber }) ? name[..<space] : name
    }
}
