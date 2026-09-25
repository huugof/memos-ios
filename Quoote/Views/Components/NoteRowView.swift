import SwiftUI

struct NoteRowView: View {
    let note: UnifiedNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.excerpt)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)

            // One Text so date and tags truncate together on a single line.
            Text("\(Text(dateString).foregroundStyle(.secondary))\(tagsText)")
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var tagsText: Text {
        let tags = note.tags
        guard !tags.isEmpty else { return Text(verbatim: "") }
        let joined = tags.map { "#\($0)" }.joined(separator: " ")
        return Text(verbatim: "  \(joined)").foregroundStyle(appAccent)
    }

    /// Always carries the time; the day is spelled out only when it isn't today.
    private var dateString: String {
        let cal = Calendar.current
        let date = note.date
        let time = Self.timeFormatter.string(from: date)
        if cal.isDateInToday(date) { return time }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        let day = (sameYear ? Self.shortDateFormatter : Self.fullDateFormatter).string(from: date)
        return "\(day) \(time)"
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
