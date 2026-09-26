import SwiftUI

struct SidebarView: View {
    let viewModel: PhotoLibraryViewModel

    private var library: LibraryStore { viewModel.library }

    var body: some View {
        List {
            // Clear filters button
            if !library.activeFilters.isEmpty && !library.viewingBin {
                Button(action: { library.applyFilter(.all) }) {
                    HStack {
                        Text("Clear Filters")
                        Spacer()
                        Image(systemName: "xmark.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Section("Library") {
                sidebarRow(filter: .all, badge: library.allPhotos.count) {
                    Label("All Photos", systemImage: "photo.on.rectangle.angled")
                }

                sidebarRow(filter: .unrated, badge: library.ratingCounts[0, default: 0]) {
                    Label("Unrated", systemImage: "star.slash")
                }
            }

            Section("Ratings") {
                ForEach(1...5, id: \.self) { stars in
                    sidebarRow(filter: .rated(stars), badge: library.ratingCounts[stars, default: 0]) {
                        HStack(spacing: 2) {
                            ForEach(0..<stars, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                            Spacer()
                        }
                    }
                }
            }

            Section("File Type") {
                sidebarRow(filter: .jpgOnly, badge: library.jpgCount) {
                    Label("JPG", systemImage: "photo")
                }

                sidebarRow(filter: .rawOnly, badge: library.rawCount) {
                    Label("RAW", systemImage: "camera.filters")
                }
            }

            if !library.tagCategories.isEmpty || !library.uncategorizedTags.isEmpty {
                Section("Tags") {
                    ForEach(library.tagCategories, id: \.self) { category in
                        sidebarRow(filter: .tagCategory(category), badge: library.categoryCounts[category, default: 0]) {
                            Label(category.capitalized, systemImage: "folder")
                        }

                        ForEach(library.tagsByCategory[category] ?? [], id: \.id) { tag in
                            sidebarRow(filter: .tag(tag.id), badge: library.tagCounts[tag.id, default: 0]) {
                                Label(tag.name, systemImage: "tag")
                                    .padding(.leading, 16)
                            }
                        }
                    }

                    ForEach(library.uncategorizedTags, id: \.id) { tag in
                        sidebarRow(filter: .tag(tag.id), badge: library.tagCounts[tag.id, default: 0]) {
                            Label(tag.name, systemImage: "tag")
                        }
                    }
                }
            }

            LibraryFoldersSection(viewModel: viewModel)

            Section {
                sidebarRow(filter: .bin, badge: library.binCount) {
                    Label("Bin", systemImage: "trash")
                }
            }
        }
        .listStyle(.sidebar)
        // "Remove from Library…" (a library folder's context menu) takes its photos out of the library: asked first.
        .confirmationDialog(
            viewModel.pendingFolderRemoval?.title ?? "",
            isPresented: Binding(get: { viewModel.pendingFolderRemoval != nil },
                                 set: { if !$0 { viewModel.pendingFolderRemoval = nil } }),
            titleVisibility: .visible,
            presenting: viewModel.pendingFolderRemoval
        ) { request in
            Button("Remove from Library", role: .destructive) { viewModel.confirmFolderRemoval(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }

    private func isFilterActive(_ filter: SidebarFilter) -> Bool {
        switch filter {
        case .all:
            return library.activeFilters.isEmpty && !library.viewingBin
        case .bin:
            return library.viewingBin
        default:
            return library.activeFilters.contains(filter)
        }
    }

    @ViewBuilder
    private func sidebarRow<Content: View>(
        filter: SidebarFilter,
        badge: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SidebarRowButton(
            isSelected: isFilterActive(filter),
            badge: badge,
            action: {
                let isShiftHeld = NSEvent.modifierFlags.contains(.shift)
                library.applyFilter(filter, isShiftHeld: isShiftHeld)
            },
            content: content
        )
    }
}

private struct SidebarRowButton<Content: View>: View {
    let isSelected: Bool
    let badge: Int
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    private var backgroundOpacity: Double {
        if isSelected { return 0.3 }
        if isHovered { return 0.12 }
        return 0
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .badge(badge)
        .listRowBackground(Color.accentColor.opacity(backgroundOpacity))
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
