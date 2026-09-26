import AppKit

/// Shows files in the Finder, selected. SwiftUI has no API for it (`openURL` opens a folder but can't select a file
/// in it), so this is `NSWorkspace.activateFileViewerSelecting`, a known AppKit exception (CLAUDE.md).
enum ShowInFinder {
    /// What to select for `paths`: each file, or, for one that isn't there any more, the nearest folder that is.
    /// Each once, in order.
    static func urls(toShow paths: [String], fileManager: FileManager = .default) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for path in paths {
            var url = URL(fileURLWithPath: path)
            while !fileManager.fileExists(atPath: url.path), url.pathComponents.count > 1 {
                url.deleteLastPathComponent()
            }
            if seen.insert(url.path).inserted { urls.append(url) }
        }
        return urls
    }

    @MainActor static func reveal(_ paths: [String]) {
        let urls = urls(toShow: paths)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
