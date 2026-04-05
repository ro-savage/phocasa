import SwiftUI
import SwiftData

@main
struct PhocasaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("openFolder")
}
