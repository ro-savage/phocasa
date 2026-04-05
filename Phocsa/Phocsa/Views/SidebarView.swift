import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: PhotoLibraryViewModel

    var body: some View {
        List(selection: Binding<SidebarFilter?>(
            get: { viewModel.currentFilter },
            set: { if let filter = $0 { viewModel.applyFilter(filter) } }
        )) {
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
                    }
                    .tag(SidebarFilter.rated(stars))
                    .badge(viewModel.allPhotos.filter { $0.rating == stars }.count)
                }
            }

            if !viewModel.tagCategories.isEmpty {
                ForEach(viewModel.tagCategories, id: \.self) { category in
                    Section(category.capitalized) {
                        let tagsInCategory = viewModel.allTags.filter { $0.category == category && $0.parent == nil }
                        ForEach(tagsInCategory, id: \.id) { tag in
                            Label(tag.name, systemImage: "tag")
                                .tag(SidebarFilter.tag(tag.id))
                                .badge(tag.photos.count)

                            ForEach(tag.children, id: \.id) { child in
                                Label(child.name, systemImage: "tag")
                                    .padding(.leading, 16)
                                    .tag(SidebarFilter.tag(child.id))
                                    .badge(child.photos.count)
                            }
                        }
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
    }
}
