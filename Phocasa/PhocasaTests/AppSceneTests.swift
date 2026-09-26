import XCTest
import AppKit
@testable import Phocasa

/// The app's scene, as the test host (the app itself, on an in-memory store) runs it: one `Window`, so a launch builds
/// one library. A `WindowGroup` let a second window, a tab or a Dock click after closing the window build a second
/// library on the same store, and run a second scan beside the first.
@MainActor
final class AppSceneTests: XCTestCase {

    /// The app's library window, once the host has shown it.
    private func libraryWindow() throws -> NSWindow {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == PhocasaApp.windowID }) {
                return window
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        struct NoWindow: Error { let windows: [String?] }
        throw NoWindow(windows: NSApp.windows.map { $0.identifier?.rawValue })
    }

    private func menuItems(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + menuItems($0.submenu) }
    }

    func testTheAppShowsOneLibraryWindowThatCantBeTabbed() throws {
        let window = try libraryWindow()

        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == PhocasaApp.windowID }.count, 1)
        XCTAssertEqual(window.tabbingMode, .disallowed, "no tab bar, so no + that would open a second library")
    }

    func testThereIsNoCommandThatOpensASecondWindow() throws {
        _ = try libraryWindow()
        let items = menuItems(NSApp.mainMenu)
        XCTAssertFalse(items.isEmpty)

        XCTAssertEqual(items.filter { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }
            .map(\.title), [], "no ⌘N")
        let windowing: Set = ["Show Tab Bar", "Show All Tabs", "Merge All Windows", "Move Tab to New Window"]
        XCTAssertEqual(items.map(\.title).filter { $0.hasPrefix("New ") || windowing.contains($0) }, [],
                       "no New Window, New Tab or Show Tab Bar")
        XCTAssertTrue(items.contains { $0.title == "Open Folder..." }, "the File menu still opens a folder")
    }
}
