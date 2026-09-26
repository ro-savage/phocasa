import SwiftUI
import AppKit

struct RatingView: View {
    let rating: Int
    let compact: Bool
    var onRate: ((Int) -> Void)?

    /// A click on the current star clears the rating, but only once a double-click can no longer follow.
    @State private var pendingClear: Task<Void, Never>?

    /// Filled stars: a dark gold on light backgrounds (the system yellow is 1.6:1 on white), the system yellow on dark
    /// ones (the `RatingStar` asset). Empty stars are `.secondary`.
    static let starColor = Color("RatingStar")

    init(rating: Int, compact: Bool = false, onRate: ((Int) -> Void)? = nil) {
        self.rating = rating
        self.compact = compact
        self.onRate = onRate
    }

    var body: some View {
        let stars = HStack(spacing: compact ? 1 : 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(compact ? .caption2 : .body)
                    .foregroundStyle(star <= rating ? AnyShapeStyle(Self.starColor) : AnyShapeStyle(.secondary))
                    .onTapGesture { tapped(star) }
            }
        }
        // One element for VoiceOver: a slider, "Rating, 3 stars", adjusted a star at a time; read-only without onRate.
        if let onRate {
            stars.accessibilityRepresentation {
                Slider(value: Binding(get: { Double(rating) }, set: { onRate(Int($0.rounded())) }), in: 0...5, step: 1) {
                    Text("Rating")
                }
                .accessibilityValue(Self.accessibilityValue(rating))
            }
        } else {
            stars
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rating")
                .accessibilityValue(Self.accessibilityValue(rating))
        }
    }

    /// "No rating", "1 star" … "5 stars", worked out once: every grid cell has a rating.
    private static let spokenValues = (0...5).map { $0 == 0 ? "No rating" : $0.counted("star") }

    /// "No rating", "1 star", "3 stars".
    static func accessibilityValue(_ rating: Int) -> String {
        spokenValues[min(max(rating, 0), 5)]
    }

    /// There is no double-click gesture to wait for, so a click on another star rates at once.
    ///
    /// - The second click of a double-click (click count 2 or more) does nothing: the first click has already
    ///   rated. That holds wherever it lands. In a rating filter the rated photo leaves the grid straight away,
    ///   and the second click would otherwise rate the photo that moved into its place.
    /// - A click on the current star clears the rating after the double-click interval, unless a second click
    ///   follows. So a double-click on the current star leaves it set, without clearing it in between.
    private func tapped(_ star: Int) {
        pendingClear?.cancel()
        pendingClear = nil
        guard Self.clickCountOfCurrentEvent() < 2 else { return }

        if star == rating {
            let onRate = onRate
            pendingClear = Task { @MainActor in
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                if !Task.isCancelled { onRate?(0) }
            }
        } else {
            onRate?(star)
        }
    }

    /// The click count of the mouse event being handled, as the window server counted it (clicks within the
    /// user's double-click time and distance). SwiftUI's tap gestures don't expose it, just as they don't expose
    /// the modifier keys (`NSEvent.modifierFlags`, a known AppKit exception). SwiftUI runs the tap action while
    /// AppKit dispatches the mouse-up, so `NSApp.currentEvent` is that event. Anything else counts as one click.
    static func clickCountOfCurrentEvent() -> Int {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown else { return 1 }
        return event.clickCount
    }
}
