import SwiftUI

/// The sidebar's library folders: every folder the owner opened, with a mark on one that wasn't there at its last scan
/// (its drive isn't connected, or it was moved, renamed or deleted). Each has Rescan, Show in Finder and "Remove from
/// Library…" in its context menu; the removal is confirmed (`SidebarView`), and never offered while a scan runs.
/// Its own view, so scans and folder changes re-evaluate it rather than the whole sidebar.
struct LibraryFoldersSection: View {
    let viewModel: PhotoLibraryViewModel
    @Environment(\.openURL) private var openURL

    /// Body evaluations, for tests.
    @MainActor static var bodyEvaluations = 0

    var body: some View {
        let _ = Self.bodyEvaluations += 1
        let library = viewModel.library
        if !library.libraryFolders.isEmpty {
            let names = library.libraryFolders.map { Self.name(of: $0.rootFolderPath) }
            Section("Folders") {
                ForEach(Array(library.libraryFolders.enumerated()), id: \.element.id) { index, folder in
                    let path = folder.rootFolderPath
                    // Two folders of the same name (on two drives, say) show where each is.
                    let showsWhere = names.filter { $0 == names[index] }.count > 1
                    row(path: path, issue: library.folderIssues[folder.id], showsWhere: showsWhere)
                        .contextMenu {
                            Button("Rescan") { library.rescan(folder) }
                            Button("Show in Finder") { openURL(URL(fileURLWithPath: path, isDirectory: true)) }
                                .disabled(library.folderIssues[folder.id] != nil)
                            Divider()
                            Button("Remove from Library…", role: .destructive) {
                                viewModel.requestFolderRemoval(folder)
                            }
                            .disabled(!library.canRemoveLibraryFolders)
                        }
                }
            }
        }
    }

    private func row(path: String, issue: LibraryStore.ScanIssue?, showsWhere: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.name(of: path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let issue {
                    Text(Self.mark(for: issue))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if showsWhere {
                    Text((path as NSString).deletingLastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } icon: {
            Image(systemName: Self.symbol(for: issue))
                .foregroundStyle(issue == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(issue.map { "\($0.statusText)\n\(path)" } ?? path)
        .accessibilityElement(children: .combine)
    }

    static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// What the row says about a folder that wasn't there.
    static func mark(for issue: LibraryStore.ScanIssue) -> String {
        if case .folderNotConnected = issue { return "Not connected" }
        return "Can’t be found"
    }

    private static func symbol(for issue: LibraryStore.ScanIssue?) -> String {
        switch issue {
        case nil: "folder"
        case .folderNotConnected: "externaldrive.badge.xmark"
        default: "questionmark.folder"
        }
    }
}
