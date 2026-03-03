import SwiftUI

struct StatusBadgeView: View {
    let state: Draft.SendState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor.opacity(0.2))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch state {
        case .idle:
            return .gray
        case .sending:
            return .blue
        case .sent:
            return .green
        case .failed:
            return .red
        }
    }
}
