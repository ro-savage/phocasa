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
            .searchable(text: $viewModel.searchText, prompt: "Search by tag or filename")
            .searchSuggestions {
                if !viewModel.searchText.isEmpty {
                    ForEach(viewModel.searchSuggestions, id: \.self) { suggestion in
                        Label(suggestion, systemImage: viewModel.tagCategories.contains(suggestion) ? "folder" : "tag")
                            .searchCompletion(suggestion)
                    }
                }
            }
            .onChange(of: viewModel.searchText) {
                viewModel.applyCurrentFilter()
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
                    viewModel.handleFolderSelected(url: url)
                }
            }
            .overlay(alignment: .bottom) { statusBar }
            .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
                viewModel.openFolder()
            }
            .onAppear {
                viewModel.setModelContext(modelContext)
                isContentFocused = true
            }
            .onKeyPress(phases: .down, action: handleKeyPress)
            .onKeyPress(.init("\\"), phases: .down) { _ in
                if viewModel.isEditing {
                    viewModel.showOriginal = true
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.init("\\"), phases: .up) { _ in
                viewModel.showOriginal = false
                return .handled
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.showingDetail, let photo = viewModel.selectedDetailPhoto {
            HStack(spacing: 0) {
                PhotoDetailView(viewModel: viewModel, photo: photo)
                    .frame(minWidth: 600, minHeight: 600)

                if viewModel.isEditing {
                    Divider()
                    EditSidebarView(viewModel: viewModel)
                }
            }
        } else {
            NavigationSplitView {
                SidebarView(viewModel: viewModel)
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
            if viewModel.isCropping {
                viewModel.cancelCrop()
            } else if viewModel.isEditing {
                viewModel.stopEditing(save: true)
            } else if viewModel.showingDetail {
                viewModel.closeDetail()
            } else {
                viewModel.clearSelection()
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
                viewModel.navigateGrid(direction: .left, extendSelection: shift)
            }
            return .handled

        case .rightArrow:
            if viewModel.showingDetail {
                viewModel.navigateDetail(direction: 1)
            } else {
                viewModel.navigateGrid(direction: .right, extendSelection: shift)
            }
            return .handled

        case .upArrow:
            if viewModel.showingDetail {
                viewModel.navigateDetail(direction: -1)
            } else {
                viewModel.navigateGrid(direction: .up, extendSelection: shift)
            }
            return .handled

        case .downArrow:
            if viewModel.showingDetail {
                viewModel.navigateDetail(direction: 1)
            } else {
                viewModel.navigateGrid(direction: .down, extendSelection: shift)
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
            viewModel.selectAll()
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
        viewModel.selectedPhotos.first.flatMap { id in
            viewModel.photos.first { $0.id == id }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { viewModel.openFolder() }) {
                Label("Open Folder", systemImage: "folder.badge.plus")
            }

            if viewModel.currentLibrary != nil {
                Button(action: { viewModel.rescanCurrentLibrary() }) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
        }

        ToolbarItemGroup(placement: .automatic) {
            Button(action: { viewModel.toggleSortOrder() }) {
                Label(
                    viewModel.sortNewestFirst ? "Newest First" : "Oldest First",
                    systemImage: viewModel.sortNewestFirst ? "arrow.down" : "arrow.up"
                )
            }
            .help(viewModel.sortNewestFirst ? "Sorted newest first" : "Sorted oldest first")

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
            if viewModel.viewingBin && !viewModel.selectedPhotos.isEmpty {
                Button(action: { viewModel.restoreSelected() }) {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }

            if !viewModel.selectedPhotos.isEmpty {
                Button(role: .destructive, action: { viewModel.deleteSelected() }) {
                    Label(viewModel.viewingBin ? "Delete Forever" : "Delete", systemImage: "trash")
                }
            }

            if viewModel.viewingBin && viewModel.binCount > 0 {
                Button(role: .destructive, action: { viewModel.emptyBin() }) {
                    Label("Empty Bin", systemImage: "trash.slash")
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if viewModel.isScanning {
                ProgressView()
                    .scaleEffect(0.6)
                Text(viewModel.scanProgress)
                    .font(.caption)
            } else if viewModel.viewingBin {
                Text("\(viewModel.binCount) in bin")
                    .font(.caption)
                if !viewModel.selectedPhotos.isEmpty {
                    Text("• \(viewModel.selectedPhotos.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(viewModel.allPhotos.count) photos")
                    .font(.caption)
                if viewModel.photos.count != viewModel.allPhotos.count {
                    Text("(\(viewModel.photos.count) shown)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !viewModel.selectedPhotos.isEmpty {
                    Text("• \(viewModel.selectedPhotos.count) selected")
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
