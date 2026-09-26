import SwiftUI

/// What the window shows instead of the library when the launch couldn't open it (`LibraryLaunch`): another Phocasa
/// has it open, or its store didn't open. It says where the library is, that nothing was changed, and where the
/// backups are. Quit closes the window, which quits the app (its only scene is a `Window`, and an app whose primary
/// scene is a `Window` quits when that window closes).
struct LibraryUnavailableView: View {
    let problem: LibraryProblem
    @Environment(\.openURL) private var openURL
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: problem.symbolName)
                    .font(.system(size: 40))
                    .foregroundStyle(problem.isAlreadyOpen ? Color.secondary : Color.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(problem.title)
                        .font(.title2.weight(.semibold))
                    ForEach(problem.details, id: \.self) { paragraph in
                        Text(paragraph)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Show in Finder") { openURL(problem.folder) }
                Button("Quit") { dismissWindow(id: PhocasaApp.windowID) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension LibraryProblem {
    var isAlreadyOpen: Bool {
        if case .alreadyOpen = reason { return true }
        return false
    }

    var symbolName: String { isAlreadyOpen ? "lock" : "exclamationmark.triangle" }

    var title: String {
        isAlreadyOpen ? "Phocasa is already open with this library" : "Phocasa can't open its library"
    }

    /// The paragraphs under the title.
    var details: [String] {
        let library = Self.display(folder.path)
        switch reason {
        case .alreadyOpen(let holder):
            let other = holder.map { "Another copy of Phocasa (\(Self.display($0.appPath)), process \($0.processID))" }
                ?? "Another copy of Phocasa"
            return [
                "\(other) has the library in \(library) open. Only one copy of Phocasa can open a library at a "
                    + "time, so this one hasn't opened it, and nothing was changed.",
                "Quit the other copy first, or carry on in it.",
            ]
        case .lockFailed(let reason):
            return [
                "Phocasa couldn't lock the library in \(library) (\(reason)), so it can't be sure no other copy has "
                    + "it open. It hasn't opened it, and nothing was changed.",
            ]
        case .cannotOpen(let reason):
            var details = [
                "The library at \(Self.display((store ?? folder).path)) couldn't be opened. \(reason)",
                "Nothing was changed: the library's files are where they were, as they were.",
            ]
            if let newest = backups.first {
                details.append(
                    "Backups of the library are in \(Self.display(newest.deletingLastPathComponent().path)) "
                        + "(\(backups.count), the newest from \(newest.lastPathComponent)). To restore one, quit "
                        + "Phocasa, move the library's Phocasa.store, Phocasa.store-wal, Phocasa.store-shm and "
                        + ".Phocasa_SUPPORT out of \(library), and copy the backup's files in their place."
                )
            } else {
                details.append("There are no backups of the library yet.")
            }
            return details
        }
    }

    /// A path with the home folder shown as `~`.
    private static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
