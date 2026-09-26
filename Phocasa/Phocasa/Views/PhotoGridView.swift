import SwiftUI

struct PhotoGridView: View {
    @Bindable var viewModel: PhotoLibraryViewModel
    /// The grid is hidden under the detail view: its cells start no thumbnail loads.
    var thumbnailsPaused = false
    @Environment(\.displayScale) private var displayScale

    nonisolated private static let spacing: CGFloat = 8
    /// The default `.padding()` around the grid, on both sides.
    nonisolated private static let horizontalPadding: CGFloat = 32
    /// `PhotoGridItemView` pads its content by 6 on each side.
    nonisolated private static let cellInset: CGFloat = 12

    var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: viewModel.gridColumns)
    }

    /// The thumbnail size bucket for a grid layout, from the width of the thumbnail each cell draws.
    /// It only changes when a resize or zoom crosses a bucket edge, so the cells' loads (keyed on it) don't restart
    /// on every pixel of a window resize (spec §C4).
    nonisolated static func thumbnailBucket(gridWidth: CGFloat, columns: Int, displayScale: CGFloat) -> Int {
        let cols = CGFloat(max(columns, 1))
        let cellWidth = (gridWidth - horizontalPadding - spacing * (cols - 1)) / cols
        return ImageLoader.thumbnailBucket(forPixels: (cellWidth - cellInset) * displayScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let bucket = Self.thumbnailBucket(
                gridWidth: geometry.size.width, columns: viewModel.gridColumns, displayScale: displayScale
            )

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Self.spacing) {
                        ForEach(viewModel.library.photos, id: \.id) { photo in
                            PhotoGridItemView(
                                photo: photo,
                                isSelected: viewModel.selection.selectedPhotos.contains(photo.id),
                                thumbnailBucket: bucket,
                                onRate: { rating in
                                    viewModel.library.setRating(rating, for: photo)
                                },
                                onSelect: {
                                    handleSelectionClick(photo)
                                },
                                onOpen: {
                                    viewModel.openDetail(for: photo)
                                },
                                thumbnailsPaused: thumbnailsPaused
                            )
                        .id(photo.id)
                        .contextMenu {
                            contextMenu(for: photo)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.selection.lastSelectedId) { _, newId in
                if let id = newId {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scrollProxy.scrollTo(id, anchor: nil)
                    }
                }
            }
        }
        }
        .sheet(isPresented: $viewModel.showGridTagEditor) {
            TagEditorView(viewModel: viewModel, photo: viewModel.tagEditorTarget)
                .frame(width: 300, height: 400)
        }
        .confirmationDialog(revertTitle, isPresented: Binding(
            get: { !viewModel.photosToRevert.isEmpty },
            set: { if !$0 { viewModel.photosToRevert = [] } }
        ), titleVisibility: .visible) {
            Button("Revert", role: .destructive) { viewModel.confirmRevertEdits() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their saved JPG and RAW edits are cleared. The files themselves don't change.")
        }
        .overlay {
            if viewModel.library.photos.isEmpty && !viewModel.library.isScanning {
                if viewModel.library.viewingBin {
                    ContentUnavailableView {
                        Label("Bin is Empty", systemImage: "trash")
                    } description: {
                        Text("Deleted photos will appear here")
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Photos", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        if viewModel.library.allPhotos.isEmpty {
                            Text("Open a folder to get started")
                        } else {
                            Text("No photos match the current filter")
                        }
                    }
                }
            }
        }
    }

    private var revertTitle: String {
        let photos = viewModel.photosToRevert
        if photos.count == 1, let photo = photos.first { return "Revert all edits of \(photo.fileName)?" }
        return "Revert all edits of \(photos.count.formatted()) photos?"
    }

    private func handleSelectionClick(_ photo: PhotoAsset) {
        let addToSelection = NSEvent.modifierFlags.contains(.command)
        let rangeSelect = NSEvent.modifierFlags.contains(.shift)

        if rangeSelect {
            viewModel.selection.rangeSelect(to: photo)
        } else {
            viewModel.selection.toggleSelection(for: photo, addToSelection: addToSelection)
        }
    }

    @ViewBuilder
    private func contextMenu(for photo: PhotoAsset) -> some View {
        let isMulti = viewModel.selection.isPartOfMultiSelection(photo)

        if !viewModel.library.viewingBin {
            Button("View") {
                viewModel.openDetail(for: photo)
            }

            Divider()

            Menu("Rate") {
                ForEach(1...5, id: \.self) { stars in
                    Button(String(repeating: "\u{2605}", count: stars)) {
                        if isMulti {
                            viewModel.setRatingForSelection(stars)
                        } else {
                            viewModel.library.setRating(stars, for: photo)
                        }
                    }
                }
                Divider()
                Button("Clear Rating") {
                    if isMulti {
                        viewModel.setRatingForSelection(0)
                    } else {
                        viewModel.library.setRating(0, for: photo)
                    }
                }
            }

            Menu("Tags") {
                tagMenuContent(for: photo)
            }

            if !viewModel.editPresets.isEmpty {
                Menu("Apply Preset") {
                    ForEach(viewModel.editPresets, id: \.id) { preset in
                        Button(preset.name) {
                            if isMulti {
                                viewModel.applyPresetToSelection(preset)
                            } else {
                                let wasSelected = viewModel.selection.selectedPhotos
                                viewModel.selection.selectedPhotos = [photo.id]
                                viewModel.applyPresetToSelection(preset)
                                viewModel.selection.selectedPhotos = wasSelected
                            }
                        }
                    }
                }
            }

            Divider()

            if photo.hasAnyEdits || isMulti {
                Button(isMulti ? "Revert All Edits of Selection…" : "Revert All Edits…") {
                    viewModel.requestRevertEdits(from: photo)
                }

                Divider()
            }

            // "Move to Bin", or with the RAW or JPG filter on "Delete RAW Files…" (asked first: files go to the Trash).
            Button(viewModel.deleteActionTitle(count: isMulti ? viewModel.selection.selectedPhotos.count : 1),
                   role: .destructive) {
                if isMulti { viewModel.deleteSelected() }
                else { viewModel.deletePhoto(photo) }
            }
        } else {
            Button("Restore") {
                if isMulti { viewModel.restoreSelected() }
                else { viewModel.restoreFromBin([photo]) }
            }

            Button("Delete Forever", role: .destructive) {
                if isMulti { viewModel.deleteSelected() }
                else { viewModel.deletePhoto(photo) }
            }
        }
    }

    @ViewBuilder
    private func tagMenuContent(for photo: PhotoAsset) -> some View {
        // Which tags are checked, worked out once for the whole menu.
        let checked = viewModel.contextMenuTagIDs(for: photo)

        ForEach(viewModel.library.tagCategories, id: \.self) { category in
            Menu(category.capitalized) {
                ForEach(viewModel.library.tagsByCategory[category] ?? [], id: \.id) { tag in
                    tagToggleButton(tag, for: photo, isChecked: checked.contains(tag.id))
                }
            }
        }

        ForEach(viewModel.library.uncategorizedTags, id: \.id) { tag in
            tagToggleButton(tag, for: photo, isChecked: checked.contains(tag.id))
        }

        if !viewModel.library.allTags.isEmpty {
            Divider()
        }

        Button("Manage Tags...") {
            viewModel.openTagEditorForContextMenu(photo: photo)
        }
    }

    @ViewBuilder
    private func tagToggleButton(_ tag: Tag, for photo: PhotoAsset, isChecked: Bool) -> some View {
        Button {
            viewModel.toggleTag(tag, for: photo)
        } label: {
            if isChecked {
                Label(tag.name, systemImage: "checkmark")
            } else {
                Text(tag.name)
            }
        }
    }
}
