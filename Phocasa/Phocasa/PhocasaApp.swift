import SwiftUI
import SwiftData

private struct OpenFolderActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var openFolderAction: (() -> Void)? {
        get { self[OpenFolderActionKey.self] }
        set { self[OpenFolderActionKey.self] = newValue }
    }
}

@main
struct PhocasaApp: App {
    @FocusedValue(\.openFolderAction) var openFolder
    /// Quit waits for pending metadata writes (see `AppDelegate`).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The store `LibraryLocation.current` picks: the user's library in `Application Support/Phocasa/Phocasa.store`
    /// (`StoreLocation`, which moves a store left at SwiftData's default location there first); when the app is
    /// launched as the XCTest host, a throwaway in-memory store so test runs never open, migrate or rescan it; with
    /// `PHOCASA_DEVELOPMENT_LIBRARY=1` in a Debug build, the development library in
    /// `Application Support/Phocasa-Development/`.
    private let modelContainer: ModelContainer = {
        let schema = Schema([PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self])
        let configuration = LibraryLocation.current.prepareStore().map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    openFolder?()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
