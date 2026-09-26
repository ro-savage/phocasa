import SwiftUI

/// The window's toolbar: open and rescan, sort and zoom, and the selection's restore and delete buttons. Its own
/// `ToolbarContent`, so selection and bin changes re-evaluate it rather than the whole `ContentView`.
struct LibraryToolbar: ToolbarContent {
    let viewModel: PhotoLibraryViewModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { viewModel.openFolder() }) {
                Label("Open Folder", systemImage: "folder.badge.plus")
            }

            if !viewModel.library.libraryFolders.isEmpty {
                Button(action: { viewModel.library.rescanCurrentLibrary() }) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan every library folder")
            }
        }

        ToolbarItemGroup(placement: .automatic) {
            Button(action: { viewModel.library.toggleSortOrder() }) {
                Label(
                    viewModel.library.sortNewestFirst ? "Newest First" : "Oldest First",
                    systemImage: viewModel.library.sortNewestFirst ? "arrow.down" : "arrow.up"
                )
            }
            .help(viewModel.library.sortNewestFirst ? "Sorted newest first" : "Sorted oldest first")

            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
                Slider(value: Binding(
                    get: { Double(22 - viewModel.gridColumns) },
                    set: { viewModel.gridColumns = 22 - Int($0) }
                ), in: 2...20, step: 1)
                .frame(width: 120)
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
            }
        }

        ToolbarItemGroup(placement: .automatic) {
            // In the detail view these act on the photo on screen, not the grid's (hidden) selection.
            let hasTarget = viewModel.showingDetail ? viewModel.selectedDetailPhoto != nil
                                                    : !viewModel.selection.selectedPhotos.isEmpty
            if viewModel.library.viewingBin && hasTarget {
                Button(action: { viewModel.restoreSelectionOrCurrent() }) {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }

            if hasTarget {
                Button(role: .destructive, action: { viewModel.deleteSelectionOrCurrent() }) {
                    Label(viewModel.deleteActionTitle(count: viewModel.showingDetail ? 1 : viewModel.selection.selectedPhotos.count),
                          systemImage: "trash")
                }
            }

            if viewModel.library.viewingBin && viewModel.library.binCount > 0 {
                Button(role: .destructive, action: { viewModel.emptyBin() }) {
                    Label("Empty Bin", systemImage: "trash.slash")
                }
            }
        }
    }
}
