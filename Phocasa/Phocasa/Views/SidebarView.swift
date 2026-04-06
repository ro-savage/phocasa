import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: PhotoLibraryViewModel

    var body: some View {
        List {
            // Clear filters button
            if !viewModel.activeFilters.isEmpty && !viewModel.viewingBin {
                Button(action: { viewModel.applyFilter(.all) }) {
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
                sidebarRow(filter: .all, badge: viewModel.allPhotos.count) {
                    Label("All Photos", systemImage: "photo.on.rectangle.angled")
                }

                sidebarRow(filter: .unrated, badge: viewModel.ratingCounts[0, default: 0]) {
                    Label("Unrated", systemImage: "star.slash")
                }
            }

            Section("Ratings") {
                ForEach(1...5, id: \.self) { stars in
                    sidebarRow(filter: .rated(stars), badge: viewModel.ratingCounts[stars, default: 0]) {
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
                sidebarRow(filter: .jpgOnly, badge: viewModel.jpgCount) {
                    Label("JPG", systemImage: "photo")
                }

                sidebarRow(filter: .rawOnly, badge: viewModel.rawCount) {
                    Label("RAW", systemImage: "camera.filters")
                }
            }

            if !viewModel.tagCategories.isEmpty || !viewModel.uncategorizedTags.isEmpty {
                Section("Tags") {
                    ForEach(viewModel.tagCategories, id: \.self) { category in
                        sidebarRow(filter: .tagCategory(category), badge: viewModel.categoryCounts[category, default: 0]) {
                            Label(category.capitalized, systemImage: "folder")
                        }

                        ForEach(viewModel.allTags.filter { $0.category == category && $0.parent == nil }, id: \.id) { tag in
                            sidebarRow(filter: .tag(tag.id), badge: viewModel.tagCounts[tag.id, default: 0]) {
                                Label(tag.name, systemImage: "tag")
                                    .padding(.leading, 16)
                            }

                            ForEach(tag.children, id: \.id) { child in
                                sidebarRow(filter: .tag(child.id), badge: viewModel.tagCounts[child.id, default: 0]) {
                                    Label(child.name, systemImage: "tag")
                                        .padding(.leading, 32)
                                }
                            }
                        }
                    }

                    ForEach(viewModel.uncategorizedTags, id: \.id) { tag in
                        sidebarRow(filter: .tag(tag.id), badge: viewModel.tagCounts[tag.id, default: 0]) {
                            Label(tag.name, systemImage: "tag")
                        }
                    }
                }
            }

            Section {
                sidebarRow(filter: .bin, badge: viewModel.binCount) {
                    Label("Bin", systemImage: "trash")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func isFilterActive(_ filter: SidebarFilter) -> Bool {
        switch filter {
        case .all:
            return viewModel.activeFilters.isEmpty && !viewModel.viewingBin
        case .bin:
            return viewModel.viewingBin
        default:
            return viewModel.activeFilters.contains(filter)
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
                viewModel.applyFilter(filter, isShiftHeld: isShiftHeld)
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
