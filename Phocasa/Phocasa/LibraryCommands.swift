import SwiftUI

private struct LibraryWindowKey: FocusedValueKey {
    typealias Value = PhotoLibraryViewModel
}

private struct PhotoCommandsKey: FocusedValueKey {
    typealias Value = PhotoLibraryViewModel
}

extension FocusedValues {
    /// The library window's view model, whatever has focus in the window (`ContentView`'s `focusedSceneValue`): for the
    /// File, Library and View menus, whose shortcuts mean nothing to a text field.
    var libraryWindow: PhotoLibraryViewModel? {
        get { self[LibraryWindowKey.self] }
        set { self[LibraryWindowKey.self] = newValue }
    }

    /// The view model while the window's content has focus (`ContentView`'s `focusedValue`): not while the search
    /// field, a tag editor or another sheet does. For the Photo menu, whose ⌘⌫ must stay the text fields' own.
    var photoCommands: PhotoLibraryViewModel? {
        get { self[PhotoCommandsKey.self] }
        set { self[PhotoCommandsKey.self] = newValue }
    }
}

/// The app's menus: File › Open Folder…, Library › Rescan, the Photo menu (rate, bin, restore, Show in Finder, edit),
/// and View › zoom, sort and the sidebar. Each is disabled when it doesn't apply.
///
/// No menu shortcut repeats a key the window already handles (digits, arrows, Space, Return, ⌫, Esc), and none is a
/// plain key: a menu's key equivalent comes before a text field's typing. The items' titles and states are views
/// (`PhotoMenuItems`, `ViewMenuItems`), so they follow the view model through Observation.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryWindow) private var window
    @FocusedValue(\.photoCommands) private var content

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder...") {
                window?.openFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(window == nil)
        }
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            ViewMenuItems(viewModel: window)
        }
        CommandMenu("Library") {
            LibraryMenuItems(viewModel: window)
        }
        CommandMenu("Photo") {
            PhotoMenuItems(viewModel: content)
        }
    }
}

private struct LibraryMenuItems: View {
    let viewModel: PhotoLibraryViewModel?

    var body: some View {
        Button("Rescan") { viewModel?.library.rescanCurrentLibrary() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel?.library.currentLibrary == nil)
    }
}

private struct ViewMenuItems: View {
    let viewModel: PhotoLibraryViewModel?

    var body: some View {
        Divider()
        Button("Zoom In") { viewModel?.zoomIn() }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(viewModel?.canZoomIn != true)
        Button("Zoom Out") { viewModel?.zoomOut() }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(viewModel?.canZoomOut != true)
        Divider()
        Picker("Sort", selection: Binding(
            get: { viewModel?.library.sortNewestFirst ?? true },
            set: { newestFirst in
                if let viewModel, viewModel.library.sortNewestFirst != newestFirst { viewModel.toggleSortOrder() }
            }
        )) {
            Text("Newest First").tag(true)
            Text("Oldest First").tag(false)
        }
        .disabled(viewModel == nil)
        Divider()
        Button("Back to Library") { viewModel?.closeDetail() }
            .disabled(viewModel?.showingDetail != true)
    }
}

/// The Photo menu: the photo in the detail view, or else the grid's selection. Off while a text field in the content
/// is typed in (`isTypingInContent`), and while the focus is outside the content (`photoCommands` is nil).
struct PhotoMenuItems: View {
    let viewModel: PhotoLibraryViewModel?

    var body: some View {
        let target = viewModel.flatMap { $0.isTypingInContent ? nil : $0 }
        let hasTarget = target?.hasCommandTarget == true
        Menu("Rate") {
            // The digit keys rate too, in the grid and the detail view.
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "No Rating" : stars.counted("Star")) {
                    target?.setRatingForSelectionOrCurrent(stars)
                }
            }
        }
        .disabled(!hasTarget)
        Divider()
        // "Move to Bin"; with the RAW or JPG filter on "Delete RAW Files…", in the bin "Delete Forever…" (both asked
        // first), as ⌫ and the toolbar do.
        Button(target.map { $0.deleteActionTitle(count: $0.showingDetail ? 1 : $0.selection.selectedPhotos.count) }
               ?? "Move to Bin") {
            target?.deleteSelectionOrCurrent()
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!hasTarget)
        Button("Restore") { target?.restoreSelectionOrCurrent() }
            .disabled(!hasTarget || target?.library.viewingBin != true)
        Divider()
        Button("Show in Finder") { target?.showCommandTargetsInFinder() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasTarget)
        Divider()
        editItems(target)
    }

    /// Edit: the RAW of a photo that has one, else its other file; for a pair, its JPG too. While that edit is open,
    /// Done Editing.
    @ViewBuilder
    private func editItems(_ target: PhotoLibraryViewModel?) -> some View {
        let photo = target?.editTarget
        let hasRAW = photo?.rawPath != nil
        let otherKind = EditSession.kind(ofStandardFileAt: photo?.jpgPath)
        let editingMain = photo.map { target?.isEditing($0, raw: hasRAW) == true } == true
        Button(editingMain ? "Done Editing" : "Edit \(hasRAW ? "RAW" : otherKind)") {
            target?.toggleEditing(raw: hasRAW)
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(photo == nil || (!hasRAW && photo?.jpgPath == nil))
        if let photo, hasRAW, photo.jpgPath != nil {
            let editingOther = target?.isEditing(photo, raw: false) == true
            Button(editingOther ? "Done Editing \(otherKind)" : "Edit \(otherKind)") {
                target?.toggleEditing(raw: false)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}
