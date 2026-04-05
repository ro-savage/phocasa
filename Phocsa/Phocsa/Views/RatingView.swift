import SwiftUI

struct RatingView: View {
    let rating: Int
    let compact: Bool
    var onRate: ((Int) -> Void)?

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
                    .onTapGesture {
                        if star == rating {
                            onRate?(0)
                        } else {
                            onRate?(star)
                        }
                    }
            }
        }
    }
}
