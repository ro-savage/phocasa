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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self])
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
