import SwiftUI

struct PhotoGridView: View {
    @Bindable var viewModel: PhotoLibraryViewModel

    var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: viewModel.gridColumns)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(viewModel.photos, id: \.id) { photo in
                        PhotoGridItemView(
                            photo: photo,
                            isSelected: viewModel.selectedPhotos.contains(photo.id),
                            onRate: { rating in
                                viewModel.setRating(rating, for: photo)
                            }
                        )
                        .id(photo.id)
                        .onTapGesture(count: 2) {
                            viewModel.openDetail(for: photo)
                        }
                        .onTapGesture(count: 1) {
                            let addToSelection = NSEvent.modifierFlags.contains(.command)
                            let rangeSelect = NSEvent.modifierFlags.contains(.shift)

                            if rangeSelect {
                                viewModel.rangeSelect(to: photo)
                            } else {
                                viewModel.toggleSelection(for: photo, addToSelection: addToSelection)
                            }
                        }
                        .contextMenu {
                            contextMenu(for: photo)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.lastSelectedId) { _, newId in
                if let id = newId {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scrollProxy.scrollTo(id, anchor: nil)
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showGridTagEditor) {
            TagEditorView(viewModel: viewModel, photo: viewModel.tagEditorTarget)
                .frame(width: 300, height: 400)
        }
        .overlay {
            if viewModel.photos.isEmpty && !viewModel.isScanning {
                if viewModel.viewingBin {
                    ContentUnavailableView {
                        Label("Bin is Empty", systemImage: "trash")
                    } description: {
                        Text("Deleted photos will appear here")
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Photos", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        if viewModel.allPhotos.isEmpty {
                            Text("Open a folder to get started")
                        } else {
                            Text("No photos match the current filter")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for photo: PhotoAsset) -> some View {
        let isMulti = viewModel.isPartOfMultiSelection(photo)

        if !viewModel.viewingBin {
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
                            viewModel.setRating(stars, for: photo)
                        }
                    }
                }
                Divider()
                Button("Clear Rating") {
                    if isMulti {
                        viewModel.setRatingForSelection(0)
                    } else {
                        viewModel.setRating(0, for: photo)
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
                                let wasSelected = viewModel.selectedPhotos
                                viewModel.selectedPhotos = [photo.id]
                                viewModel.applyPresetToSelection(preset)
                                viewModel.selectedPhotos = wasSelected
                            }
                        }
                    }
                }
            }

            Divider()

            if photo.hasAnyEdits {
                Button("Revert All Edits") {
                    viewModel.revertEditsForPhoto(photo)
                }

                Divider()
            }

            Button("Move to Bin", role: .destructive) {
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
        ForEach(viewModel.tagCategories, id: \.self) { category in
            Menu(category.capitalized) {
                ForEach(viewModel.allTags.filter { $0.category == category }, id: \.id) { tag in
                    tagToggleButton(tag, for: photo)
                }
            }
        }

        ForEach(viewModel.uncategorizedTags, id: \.id) { tag in
            tagToggleButton(tag, for: photo)
        }

        if !viewModel.allTags.isEmpty {
            Divider()
        }

        Button("Manage Tags...") {
            viewModel.openTagEditorForContextMenu(photo: photo)
        }
    }

    @ViewBuilder
    private func tagToggleButton(_ tag: Tag, for photo: PhotoAsset) -> some View {
        Button {
            viewModel.toggleTag(tag, for: photo)
        } label: {
            if viewModel.contextMenuTagState(tag, for: photo) {
                Label(tag.name, systemImage: "checkmark")
            } else {
                Text(tag.name)
            }
        }
    }
}
