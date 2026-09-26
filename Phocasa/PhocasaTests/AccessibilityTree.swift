import AppKit
import ApplicationServices

/// The app's own accessibility tree, read the way VoiceOver reads it: through the AX API, as a client of this process
/// (no accessibility permission is needed for one's own process). SwiftUI builds its accessibility elements only once
/// a client asks, so reading `NSHostingView.accessibilityChildren()` directly finds none.
@MainActor
enum AccessibilityTree {
    struct Element {
        let element: AXUIElement

        private func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }

        var role: String? { attribute(kAXRoleAttribute) as? String }
        /// What VoiceOver says first: the description (`accessibilityLabel`), else the title.
        var label: String? { (attribute(kAXDescriptionAttribute) as? String) ?? (attribute(kAXTitleAttribute) as? String) }
        var value: String? { attribute(kAXValueAttribute).flatMap { $0 as? String } }
        /// How VoiceOver reads a value that isn't text (a slider's "3 stars").
        var valueDescription: String? { attribute(kAXValueDescriptionAttribute) as? String }
        var children: [Element] { ((attribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []).map(Element.init) }
        var isEnabled: Bool { (attribute(kAXEnabledAttribute) as? Bool) ?? true }
        /// Label and value, for matching text wherever SwiftUI puts it.
        var text: String { [label, value, valueDescription].compactMap { $0 }.joined(separator: " ") }

        @discardableResult
        func perform(_ action: String) -> Bool {
            AXUIElementPerformAction(element, action as CFString) == .success
        }
    }

    /// Every element in this app's windows.
    static func elements() -> [Element] {
        let app = Element(element: AXUIElementCreateApplication(getpid()))
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app.element, kAXWindowsAttribute as CFString, &windows)
        func walk(_ element: Element, _ depth: Int) -> [Element] {
            guard depth < 60 else { return [] }
            return [element] + element.children.flatMap { walk($0, depth + 1) }
        }
        return ((windows as? [AXUIElement]) ?? []).map(Element.init).flatMap { walk($0, 0) }
    }

    /// Spins the run loop until an element matches, for up to `seconds`.
    static func wait(seconds: TimeInterval = 5, for match: (Element) -> Bool) -> Element? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let found = elements().first(where: match) { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return nil
    }
}
