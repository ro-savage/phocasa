import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = PhotoLibraryViewModel()
    @FocusState private var isContentFocused: Bool

    var body: some View {
        mainContent
            .focusable()
            .focused($isContentFocused)
            .focusEffectDisabled()
            .toolbar { toolbarContent }
            .searchable(text: Bindable(viewModel.library).searchText, prompt: "Search by tag or filename")
            .searchSuggestions {
                if !viewModel.library.searchText.isEmpty {
                    ForEach(viewModel.library.searchSuggestions, id: \.self) { suggestion in
                        Label(suggestion, systemImage: viewModel.library.tagCategories.contains(suggestion) ? "folder" : "tag")
                            .searchCompletion(suggestion)
                    }
                }
            }
            .task(id: viewModel.library.searchText) {
                // Debounce: a new keystroke cancels this task before it filters.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                viewModel.library.applyCurrentFilter()
            }
            .onChange(of: viewModel.showingDetail) {
                isContentFocused = true
            }
            .alert("Permanently Delete", isPresented: $viewModel.showPermanentDeleteConfirmation) {
                Button("Delete Forever", role: .destructive) {
                    viewModel.confirmPermanentDelete()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.photosToDelete = []
                }
            } message: {
                let count = viewModel.photosToDelete.count
                Text("Permanently delete \(count) photo\(count == 1 ? "" : "s")? The file\(count == 1 ? "" : "s") will be moved to the system Trash.")
            }
            .fileImporter(
                isPresented: $viewModel.showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    viewModel.library.handleFolderSelected(url: url)
                }
            }
            .overlay(alignment: .bottom) { statusBar }
            .focusedSceneValue(\.openFolderAction) { viewModel.openFolder() }
            .onAppear {
                viewModel.setModelContext(modelContext)
                isContentFocused = true
            }
            .onKeyPress(phases: .down, action: handleKeyPress)
            .onKeyPress(.init("\\"), phases: .down) { _ in
                if let session = viewModel.editSession {
                    session.showOriginal = true
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.init("\\"), phases: .up) { _ in
                viewModel.editSession?.showOriginal = false
                return .handled
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.showingDetail, let photo = viewModel.selectedDetailPhoto {
            HStack(spacing: 0) {
                PhotoDetailView(viewModel: viewModel, photo: photo)
                    .frame(minWidth: 600, minHeight: 600)

                if let session = viewModel.editSession {
                    Divider()
                    EditSidebarView(session: session, viewModel: viewModel)
                }
            }
        } else {
            NavigationSplitView {
                SidebarView(library: viewModel.library)
                    .frame(minWidth: 200)
            } detail: {
                PhotoGridView(viewModel: viewModel)
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if viewModel.showGridTagEditor { return .ignored }

        let shift = keyPress.modifiers.contains(.shift)
        let command = keyPress.modifiers.contains(.command)

        switch keyPress.key {
        case .escape:
            if let session = viewModel.editSession, session.isCropping {
                session.cancelCrop()
            } else if viewModel.isEditing {
                viewModel.stopEditing(save: true)
            } else if viewModel.showingDetail {
                viewModel.closeDetail()
            } else {
                viewModel.selection.clearSelection()
            }
            return .handled

        case .space:
            if let photo = firstSelectedPhoto {
                if viewModel.showingDetail { viewModel.closeDetail() }
                else { viewModel.openDetail(for: photo) }
                return .handled
            }
            return .ignored

        case .return:
            if let photo = firstSelectedPhoto {
                viewModel.openDetail(for: photo)
                return .handled
            }
            return .ignored

        case .leftArrow:
            if viewModel.showingDetail {
                viewModel.navigateDetail(direction: -1)
            } else {
                viewModel.selection.navigateGrid(direction: .left, extendSelection: shift, columns: viewModel.gridColumns)
            }
            return .handled

        case .rightArrow:
            if viewModel.showingDetail {
                viewModel.navigateDetail(direction: 1)
            } else {
                viewModel.selection.navigateGrid(direction: .right, extendSelection: shift, columns: viewModel.gridColumns)
            }
            return .handled

        case .upArrow:
            if viewModel.showingDetail {
                viewModel.navigateDetail(direction: -1)
            } else {
                viewModel.selection.navigateGrid(direction: .up, extendSelection: shift, columns: viewModel.gridColumns)
            }
            return .handled

        case .downArrow:
            if viewModel.showingDetail {
                viewModel.navigateDetail(direction: 1)
            } else {
                viewModel.selection.navigateGrid(direction: .down, extendSelection: shift, columns: viewModel.gridColumns)
            }
            return .handled

        case .delete, .deleteForward:
            viewModel.deleteSelected()
            return .handled

        default:
            break
        }

        // Cmd+A: select all
        if command && keyPress.characters == "a" {
            viewModel.selection.selectAll()
            return .handled
        }

        // Ratings: 0-5
        if let char = keyPress.characters.first, keyPress.modifiers.isEmpty {
            if let digit = char.wholeNumberValue, digit >= 0 && digit <= 5 {
                viewModel.setRatingForSelectionOrCurrent(digit)
                return .handled
            }
        }

        return .ignored
    }

    private var firstSelectedPhoto: PhotoAsset? {
        viewModel.selection.primarySelectedPhoto
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { viewModel.openFolder() }) {
                Label("Open Folder", systemImage: "folder.badge.plus")
            }

            if viewModel.library.currentLibrary != nil {
                Button(action: { viewModel.library.rescanCurrentLibrary() }) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
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
            if viewModel.library.viewingBin && !viewModel.selection.selectedPhotos.isEmpty {
                Button(action: { viewModel.restoreSelected() }) {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }

            if !viewModel.selection.selectedPhotos.isEmpty {
                Button(role: .destructive, action: { viewModel.deleteSelected() }) {
                    Label(viewModel.library.viewingBin ? "Delete Forever" : "Delete", systemImage: "trash")
                }
            }

            if viewModel.library.viewingBin && viewModel.library.binCount > 0 {
                Button(role: .destructive, action: { viewModel.emptyBin() }) {
                    Label("Empty Bin", systemImage: "trash.slash")
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if viewModel.library.isScanning {
                ProgressView()
                    .scaleEffect(0.6)
                Text(viewModel.library.scanProgress)
                    .font(.caption)
            } else if viewModel.library.viewingBin {
                Text("\(viewModel.library.binCount) in bin")
                    .font(.caption)
                if !viewModel.selection.selectedPhotos.isEmpty {
                    Text("• \(viewModel.selection.selectedPhotos.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(viewModel.library.allPhotos.count) photos")
                    .font(.caption)
                if viewModel.library.photos.count != viewModel.library.allPhotos.count {
                    Text("(\(viewModel.library.photos.count) shown)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !viewModel.selection.selectedPhotos.isEmpty {
                    Text("• \(viewModel.selection.selectedPhotos.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
