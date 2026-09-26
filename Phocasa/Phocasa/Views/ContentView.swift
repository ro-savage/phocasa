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
                // One photo is named: it's the photo on screen in the detail view, or the one clicked.
                let photos = viewModel.photosToDelete
                if photos.count == 1, let photo = photos.first {
                    Text("Permanently delete \(photo.fileName)? Its files will be moved to the system Trash.")
                } else {
                    Text("Permanently delete \(photos.count.formatted()) photos? Their files will be moved to the system Trash.")
                }
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
            if viewModel.showingDetail {
                viewModel.closeDetail()
                return .handled
            }
            if let photo = firstSelectedPhoto {
                viewModel.openDetail(for: photo)
                return .handled
            }
            return .ignored

        case .return:
            // Only from the grid: in the detail view it would swap the grid's (hidden) selection in for the photo on
            // screen, and in edit mode show one photo while the sliders edit another.
            if !viewModel.showingDetail, let photo = firstSelectedPhoto {
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

        // The ⌫ key sends U+007F, which isn't SwiftUI's `.delete` (U+0008); ⌦ sends `.deleteForward` (U+F728).
        // In the detail view: the photo on screen.
        case .delete, .deleteForward, KeyEquivalent("\u{7F}"):
            viewModel.deleteSelectionOrCurrent()
            return .handled

        default:
            break
        }

        // Cmd+A: select all. Not in the detail view, where the grid is hidden (a selection there is invisible, and
        // ⌫ acts on the photo on screen anyway).
        if command && keyPress.characters == "a" {
            if !viewModel.showingDetail { viewModel.selection.selectAll() }
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
