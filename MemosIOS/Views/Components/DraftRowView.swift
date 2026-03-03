import SwiftUI

struct DraftRowView: View {
    let draft: Draft

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.titleLine)
                    .font(.headline)
                    .lineLimit(1)

                Text(draft.updatedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            StatusBadgeView(state: draft.displayState)
        }
        .padding(.vertical, 4)
    }
}
