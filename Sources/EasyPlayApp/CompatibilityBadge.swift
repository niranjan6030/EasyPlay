import SwiftUI
import EasyPlayKit

/// The "will this work?" answer, in the same spirit as CrossOver's ratings.
struct CompatibilityBadge: View {
    let rating: CompatibilityRating
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small)
            Text(rating.displayName)
        }
        .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .foregroundStyle(colour)
        .background(colour.opacity(0.14), in: Capsule())
    }

    private var icon: String {
        switch rating {
        case .runsGreat: return "checkmark.circle.fill"
        case .runsOK: return "checkmark.circle"
        case .untested: return "questionmark.circle"
        case .notSupported: return "xmark.circle.fill"
        }
    }

    private var colour: Color {
        switch rating {
        case .runsGreat: return .green
        case .runsOK: return .orange
        case .untested: return .secondary
        case .notSupported: return .red
        }
    }
}
