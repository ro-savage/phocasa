import SwiftUI
import AppKit

struct RatingView: View {
    let rating: Int
    let compact: Bool
    var onRate: ((Int) -> Void)?

    /// The star the latest click set, and when. Clicking the current star clears the rating, but the second
    /// click of a double-click lands on the star its first click has just set: that one must leave it set.
    @State private var lastSet: StarClick?

    private struct StarClick {
        let star: Int
        let time: TimeInterval
    }

    init(rating: Int, compact: Bool = false, onRate: ((Int) -> Void)? = nil) {
        self.rating = rating
        self.compact = compact
        self.onRate = onRate
    }

    var body: some View {
        HStack(spacing: compact ? 1 : 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(compact ? .caption2 : .body)
                    .foregroundStyle(star <= rating ? .yellow : .gray.opacity(0.5))
                    .onTapGesture { tapped(star) }
            }
        }
    }

    /// A click rates at once (there is no double-click gesture to wait for). A click on the current star clears
    /// the rating, unless it comes within the system double-click interval of the click that set that star
    /// (SwiftUI has no click count; `NSEvent.doubleClickInterval` is the user's setting). A burst of clicks on
    /// one star therefore sets it, and a deliberate click on it later clears it.
    private func tapped(_ star: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        if star == rating {
            if let lastSet, lastSet.star == star, now - lastSet.time <= NSEvent.doubleClickInterval {
                self.lastSet = StarClick(star: star, time: now)
                return
            }
            lastSet = nil
            onRate?(0)
        } else {
            lastSet = StarClick(star: star, time: now)
            onRate?(star)
        }
    }
}
