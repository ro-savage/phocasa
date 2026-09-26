import XCTest
import AppKit
import SwiftData
@testable import Phocasa

/// The menus (REL-4 #2): what the Photo menu acts on, when its items apply, and the menu bar the app builds.
@MainActor
final class LibraryCommandsTests: XCTestCase {
    private var container: ModelContainer!
    private var viewModel: PhotoLibraryViewModel!

    override func setUp() async throws {
        container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        // Newest first: pair, jpg, raw.
        let photos = [
            PhotoAsset(fileName: "pair", jpgPath: "/cmd/a/pair.jpg", rawPath: "/cmd/a/pair.ARW", folderPath: "/cmd/a",
                       creationDate: Date(timeIntervalSince1970: 300)),
            PhotoAsset(fileName: "jpg", jpgPath: "/cmd/b/jpg.jpg", folderPath: "/cmd/b",
                       creationDate: Date(timeIntervalSince1970: 200)),
            PhotoAsset(fileName: "raw", rawPath: "/cmd/c/raw.ARW", folderPath: "/cmd/c",
                       creationDate: Date(timeIntervalSince1970: 100)),
        ]
        for photo in photos { context.insert(photo) }
        try context.save()
        viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
    }

    override func tearDown() async throws {
        viewModel?.stopEditing(save: false)
        viewModel = nil
        container = nil
    }

    private var photos: [PhotoAsset] { viewModel.library.photos }

    func testThePhotoMenuActsOnTheSelectionOrThePhotoOnScreen() {
        XCTAssertFalse(viewModel.hasCommandTarget, "nothing selected")
        XCTAssertEqual(viewModel.commandTargets.count, 0)

        viewModel.selection.select(only: photos[0].id)
        viewModel.selection.toggleSelection(for: photos[1], addToSelection: true)
        XCTAssertTrue(viewModel.hasCommandTarget)
        XCTAssertEqual(Set(viewModel.commandTargets.map(\.id)), [photos[0].id, photos[1].id])
        XCTAssertNil(viewModel.editTarget, "Edit needs one photo")

        viewModel.openDetail(for: photos[2])
        XCTAssertEqual(viewModel.commandTargets.map(\.id), [photos[2].id], "in the detail view, the photo on screen")
        XCTAssertEqual(viewModel.editTarget?.id, photos[2].id)
    }

    func testEditOpensThePhotoAndEditsItsRAWThenEndsTheEdit() {
        viewModel.selection.select(only: photos[0].id)
        XCTAssertEqual(viewModel.editTarget?.id, photos[0].id)

        viewModel.toggleEditing(raw: true)
        XCTAssertTrue(viewModel.showingDetail)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[0].id)
        XCTAssertEqual(viewModel.editSession?.isRAW, true)
        XCTAssertTrue(viewModel.isEditing(photos[0], raw: true))

        viewModel.toggleEditing(raw: false) // the pair's JPG instead
        XCTAssertEqual(viewModel.editSession?.isRAW, false)

        viewModel.toggleEditing(raw: false) // Done Editing
        XCTAssertNil(viewModel.editSession)
        XCTAssertTrue(viewModel.showingDetail, "the photo stays on screen")
    }

    func testEditDoesNothingForAFileThePhotoHasnt() {
        viewModel.selection.select(only: photos[1].id) // JPG only
        viewModel.toggleEditing(raw: true)
        XCTAssertNil(viewModel.editSession)
        XCTAssertFalse(viewModel.showingDetail)
    }

    func testZoomAndTheChevronsStopAtTheEnds() {
        viewModel.gridColumns = 2
        XCTAssertFalse(viewModel.canZoomIn)
        XCTAssertTrue(viewModel.canZoomOut)
        viewModel.gridColumns = 20
        XCTAssertFalse(viewModel.canZoomOut)

        viewModel.openDetail(for: photos[0])
        XCTAssertFalse(viewModel.canZoomOut, "the grid's zoom does nothing in the detail view")
        XCTAssertFalse(viewModel.canNavigateDetail(direction: -1), "the first photo has none before it")
        XCTAssertTrue(viewModel.canNavigateDetail(direction: 1))
        viewModel.navigateDetail(direction: 1)
        viewModel.navigateDetail(direction: 1)
        XCTAssertEqual(viewModel.selectedDetailPhoto?.id, photos[2].id)
        XCTAssertFalse(viewModel.canNavigateDetail(direction: 1), "the last photo has none after it")
        XCTAssertTrue(viewModel.canNavigateDetail(direction: -1))
    }

    func testShowInFinderSelectsEveryFileFromAFewFolders() {
        XCTAssertEqual(PhotoLibraryViewModel.filesToShow(of: photos),
                       ["/cmd/a/pair.jpg", "/cmd/a/pair.ARW", "/cmd/b/jpg.jpg", "/cmd/c/raw.ARW"])
        XCTAssertEqual(PhotoLibraryViewModel.filesToShow(of: photos, folderLimit: 2),
                       ["/cmd/a/pair.jpg", "/cmd/a/pair.ARW", "/cmd/b/jpg.jpg"], "a Finder window per folder, at most 2")
    }

    // MARK: - The menu bar (the test host runs the app's scene)

    private struct Shortcut: Hashable {
        let key: String
        let modifiers: UInt
    }

    private func shortcut(_ item: NSMenuItem) -> Shortcut? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
        return Shortcut(key: item.keyEquivalent.lowercased(), modifiers: modifiers.rawValue)
    }

    private func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + allItems($0.submenu) }
    }

    private func menu(_ title: String) throws -> NSMenu {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu { return menu }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        struct NoMenu: Error { let title: String }
        throw NoMenu(title: title)
    }

    func testTheMenusHaveTheirItemsAndShortcuts() throws {
        let photo = allItems(try menu("Photo"))
        let library = allItems(try menu("Library"))
        let view = allItems(try menu("View"))
        func item(_ items: [NSMenuItem], _ title: String) -> NSMenuItem? { items.first { $0.title == title } }

        XCTAssertEqual(item(library, "Rescan").flatMap(shortcut), Shortcut(key: "r", modifiers: NSEvent.ModifierFlags.command.rawValue))
        XCTAssertNotNil(item(photo, "Rate"))
        XCTAssertEqual(photo.filter { ["No Rating", "1 Star", "2 Stars", "5 Stars"].contains($0.title) }.count, 4)
        XCTAssertEqual(item(photo, "Move to Bin").flatMap(shortcut)?.modifiers, NSEvent.ModifierFlags.command.rawValue)
        XCTAssertNotNil(item(photo, "Restore"))
        XCTAssertEqual(item(photo, "Show in Finder").flatMap(shortcut),
                       Shortcut(key: "r", modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue))
        XCTAssertTrue(photo.contains { $0.title.hasPrefix("Edit ") && shortcut($0)?.key == "e" })
        XCTAssertEqual(item(view, "Zoom In").flatMap(shortcut)?.key, "+")
        XCTAssertEqual(item(view, "Zoom Out").flatMap(shortcut)?.key, "-")
        XCTAssertNotNil(item(view, "Sort"))
        XCTAssertNotNil(item(view, "Back to Library"))
        XCTAssertTrue(view.contains { $0.title.contains("Sidebar") }, "SidebarCommands")
    }

    /// No shortcut of the app's own menus is a plain key (it would take the key from text fields and from the grid's
    /// own handling of digits, arrows, Space, Return and ⌫), and none is used twice anywhere in the menu bar.
    func testNoMenuShortcutIsAPlainKeyOrUsedTwice() throws {
        let ours = try ["Photo", "Library", "View"].flatMap { allItems(try menu($0)) }
        for item in ours {
            guard let shortcut = shortcut(item) else { continue }
            XCTAssertNotEqual(shortcut.modifiers & NSEvent.ModifierFlags([.command, .control]).rawValue, 0,
                              "“\(item.title)” has a plain-key shortcut")
        }
        let everything = allItems(NSApp.mainMenu).filter { !$0.isAlternate && !$0.isHidden }
        var seen: [Shortcut: String] = [:]
        for item in everything {
            guard let shortcut = shortcut(item) else { continue }
            if let other = seen[shortcut], other != item.title {
                XCTFail("“\(item.title)” and “\(other)” share a shortcut")
            }
            seen[shortcut] = item.title
        }
    }
}
