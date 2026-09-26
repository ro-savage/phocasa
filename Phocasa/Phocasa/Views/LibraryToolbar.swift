import SwiftUI

/// The window's toolbar: open and rescan, sort and zoom, and the selection's restore and delete buttons. Its own
/// `ToolbarContent`, so selection and bin changes re-evaluate it rather than the whole `ContentView`.
struct LibraryToolbar: ToolbarContent {
    let viewModel: PhotoLibraryViewModel

    var body: some ToolbarContent {
        // A way back from the detail view you can see (Esc and Space close it too).
        if viewModel.showingDetail {
            ToolbarItem(placement: .navigation) {
                Button(action: { viewModel.closeDetail() }) {
                    Label("Library", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .help("Back to the library (Esc)")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { viewModel.openFolder() }) {
                Label("Open Folder", systemImage: "folder.badge.plus")
            }
            .help("Open a folder of photos (⌘O)")

            if viewModel.library.currentLibrary != nil {
                Button(action: { viewModel.library.rescanCurrentLibrary() }) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Look for new, changed and removed photos in the folder (⌘R)")
            }
        }

        ToolbarItemGroup(placement: .automatic) {
            Button(action: { viewModel.toggleSortOrder() }) {
                Label(
                    viewModel.library.sortNewestFirst ? "Newest First" : "Oldest First",
                    systemImage: viewModel.library.sortNewestFirst ? "arrow.down" : "arrow.up"
                )
            }
            .help(viewModel.library.sortNewestFirst ? "Sorted newest first" : "Sorted oldest first")

            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { Double(22 - viewModel.gridColumns) },
                    set: { viewModel.gridColumns = 22 - Int($0) }
                ), in: 2...20, step: 1) {
                    Text("Thumbnail Size")
                }
                .labelsHidden()
                .frame(width: 120)
                .help("Thumbnail size (⌘+ and ⌘−)")
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
                    .accessibilityHidden(true)
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
