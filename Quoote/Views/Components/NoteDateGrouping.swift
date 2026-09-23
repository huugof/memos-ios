import Foundation

enum NoteDateGrouping {
    struct Group: Identifiable {
        let id: String
        let header: String
        var notes: [UnifiedNote]
    }

    static func group(_ notes: [UnifiedNote]) -> [Group] {
        let cal = Calendar.current
        let now = Date()
        var groups: [Group] = []
        var headerIndex: [String: Int] = [:]

        for note in notes {
            let header = sectionHeader(for: note.date, now: now, cal: cal)
            if let idx = headerIndex[header] {
                groups[idx].notes.append(note)
            } else {
                headerIndex[header] = groups.count
                groups.append(Group(id: header, header: header, notes: [note]))
            }
        }
        return groups
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f
    }()

    private static func sectionHeader(for date: Date, now: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let noteYear = cal.component(.year, from: date)
        let nowYear = cal.component(.year, from: now)
        if noteYear == nowYear {
            return monthFormatter.string(from: date)
        }
        return "\(noteYear)"
    }
}
