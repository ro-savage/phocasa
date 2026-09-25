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

    /// When the app is launched as the XCTest host, use a throwaway in-memory store so test runs
    /// never open, migrate or rescan the user's real library.
    private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// The library lives in `Application Support/Phocasa/Phocasa.store` (`StoreLocation`, which moves a store left at
    /// SwiftData's default location there first).
    private let modelContainer: ModelContainer = {
        let schema = Schema([PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self])
        let configuration = isTestHost
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: StoreLocation.prepare(in: .applicationSupportDirectory))
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
