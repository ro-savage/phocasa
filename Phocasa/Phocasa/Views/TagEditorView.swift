import SwiftUI

/// Adds and removes tags. From the grid's context menu it edits the photo clicked, or the whole selection when that
/// photo is part of a multi-selection; in the detail view, only the photo on screen
/// (`PhotoLibraryViewModel.tagEditorEditsSelection`).
struct TagEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PhotoLibraryViewModel
    let photo: PhotoAsset?

    @State private var newTagName = ""
    @State private var newTagCategory = ""
    @State private var searchText = ""

    private var isMultiSelection: Bool {
        viewModel.tagEditorEditsSelection
    }

    private var filteredExistingTags: [Tag] {
        if searchText.isEmpty {
            return viewModel.library.allTags
        }
        let query = searchText.lowercased()
        return viewModel.library.allTags.filter {
            $0.name.lowercased().contains(query) || $0.category.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isMultiSelection ? "Tags (\(viewModel.selection.selectedPhotos.count) photos)" : "Tags")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            // Current tags on this photo
            if let photo, !photo.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(photo.tags, id: \.id) { tag in
                            HStack(spacing: 4) {
                                Text(tag.fullName)
                                    .font(.caption)
                                Button(action: {
                                    viewModel.library.removeTag(tag, from: photo)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.15), in: Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
            }

            Divider()

            // Search existing tags
            TextField("Search tags...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            // Existing tags list
            List {
                ForEach(filteredExistingTags, id: \.id) { tag in
                    Button(action: {
                        applyTag(tag)
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(tag.name)
                                    .font(.body)
                                if !tag.category.isEmpty {
                                    Text(tag.category)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if let photo, photo.tags.contains(where: { $0.id == tag.id }) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)

            Divider()

            // Create new tag
            VStack(alignment: .leading, spacing: 6) {
                Text("New Tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Category (optional)", text: $newTagCategory)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)

                    TextField("Name", text: $newTagName)
                        .textFieldStyle(.roundedBorder)

                    Button("Add") {
                        addNewTag()
                    }
                    .disabled(newTagName.isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .onExitCommand {
            dismiss()
        }
    }

    private func applyTag(_ tag: Tag) {
        viewModel.toggleTagFromEditor(tag, photo: photo)
    }

    private func addNewTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        let category = newTagCategory.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }

        viewModel.addTagFromEditor(name: name, category: category, photo: photo)
        newTagName = ""
    }
}
