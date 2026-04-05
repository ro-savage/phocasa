import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: PhotoLibraryViewModel
    @State private var selection: SidebarFilter? = .all

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle.angled")
                    .tag(SidebarFilter.all)
                    .badge(viewModel.allPhotos.count)

                Label("Unrated", systemImage: "star.slash")
                    .tag(SidebarFilter.unrated)
                    .badge(viewModel.allPhotos.filter { $0.rating == 0 }.count)
            }

            Section("Ratings") {
                ForEach(1...5, id: \.self) { stars in
                    HStack(spacing: 2) {
                        ForEach(0..<stars, id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .tag(SidebarFilter.rated(stars))
                    .badge(viewModel.allPhotos.filter { $0.rating == stars }.count)
                }
            }

            if !viewModel.tagCategories.isEmpty || !viewModel.uncategorizedTags.isEmpty {
                Section("Tags") {
                    ForEach(viewModel.tagCategories, id: \.self) { category in
                        Label(category.capitalized, systemImage: "folder")
                            .tag(SidebarFilter.tagCategory(category))
                            .badge(viewModel.photosInCategory(category))

                        ForEach(viewModel.allTags.filter { $0.category == category && $0.parent == nil }, id: \.id) { tag in
                            Label(tag.name, systemImage: "tag")
                                .padding(.leading, 16)
                                .tag(SidebarFilter.tag(tag.id))
                                .badge(tag.photos.count)

                            ForEach(tag.children, id: \.id) { child in
                                Label(child.name, systemImage: "tag")
                                    .padding(.leading, 32)
                                    .tag(SidebarFilter.tag(child.id))
                                    .badge(child.photos.count)
                            }
                        }
                    }

                    ForEach(viewModel.uncategorizedTags, id: \.id) { tag in
                        Label(tag.name, systemImage: "tag")
                            .tag(SidebarFilter.tag(tag.id))
                            .badge(tag.photos.count)
                    }
                }
            }

            Section {
                Label("Bin", systemImage: "trash")
                    .tag(SidebarFilter.bin)
                    .badge(viewModel.binCount)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, newValue in
            if let filter = newValue {
                viewModel.applyFilter(filter)
            }
        }
    }
}
