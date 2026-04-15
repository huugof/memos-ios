import SwiftUI

struct NoteRowView: View {
    let note: UnifiedNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(dateString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(note.preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if !note.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(note.tags.prefix(4), id: \.self) { tag in
                        Label(tag, systemImage: "tag.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var dateString: String {
        let cal = Calendar.current
        let now = Date()
        let date = note.date
        if cal.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        }
        let noteYear = cal.component(.year, from: date)
        let nowYear = cal.component(.year, from: now)
        if noteYear == nowYear {
            return Self.shortDateFormatter.string(from: date)
        }
        return Self.fullDateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
    }()
}
