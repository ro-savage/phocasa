import SwiftUI
import SwiftData

@main
struct PhocasaApp: App {
    /// Quit waits for pending metadata writes (see `AppDelegate`).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The app's one window. A `Window`, not a `WindowGroup`: a launch opens one library, and each window of a group
    /// built a library of its own on the same store (a second window, a tab, or a Dock click after closing the
    /// window started a second full load and a second concurrent scan, which inserted every photo again). A `Window`
    /// has no New Window and no tabs, and as the app's only scene it quits the app when it closes.
    static let windowID = "library"

    /// This launch's library (`LibraryLaunch.open`) at the location `LibraryLocation.current` picks: the user's
    /// library in `Application Support/Phocasa/`, locked, backed up and opened; when the app is the XCTest host, a
    /// throwaway in-memory store; with `PHOCASA_DEVELOPMENT_LIBRARY=1` in a Debug build, the development library in
    /// `Application Support/Phocasa-Development/`. Or why it couldn't be opened. The app keeps it for its whole life,
    /// and with it the library's lock: a static, opened once however often SwiftUI makes the `App` (a second
    /// `flock` in the same process would find the first one held).
    @MainActor private static let launch = LibraryLaunch.open(LibraryLocation.current)

    /// The window's coordinator, owned by the app rather than the window: a window that closes and opens again shows
    /// the library it had (`setModelContext` is a no-op for the context it already has) instead of loading and
    /// rescanning it again.
    @State private var viewModel = PhotoLibraryViewModel()

    var body: some Scene {
        Window("Phocasa", id: Self.windowID) {
            switch Self.launch.outcome {
            case .opened(let container):
                ContentView(viewModel: viewModel)
                    .modelContainer(container)
            case .unavailable(let problem):
                LibraryUnavailableView(problem: problem)
            }
        }
        .commands { LibraryCommands() }
    }
}
