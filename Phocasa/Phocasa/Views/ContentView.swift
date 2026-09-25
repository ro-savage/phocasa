import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The window: the library and detail view (`MainContentView`), with the toolbar (`LibraryToolbar`), the status bar
/// (`StatusBarView`), search, the permanent-delete alert, the folder picker and the keyboard handling. The toolbar and
/// the status bar are their own types, so selection changes don't re-evaluate this body.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: PhotoLibraryViewModel
    @FocusState private var isContentFocused: Bool

    /// Body evaluations, for tests.
    @MainActor static var bodyEvaluations = 0

    init(viewModel: PhotoLibraryViewModel = PhotoLibraryViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        let _ = Self.bodyEvaluations += 1
        MainContentView(viewModel: viewModel)
            .focusable()
            .focused($isContentFocused)
            .focusEffectDisabled()
            .toolbar { LibraryToolbar(viewModel: viewModel) }
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
            .overlay(alignment: .bottom) { StatusBarView(library: viewModel.library, selection: viewModel.selection) }
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
}
