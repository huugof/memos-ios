import Foundation

/// A first line like `@3pm` or `@3 hours ago` that backdates a new vault note:
/// the note's filename and `date` use that time, and the line itself is dropped.
enum TimeDirective {
    /// The time the body's first line names, and the body without it (plus the blank
    /// line that usually follows). Nil when the first line isn't a directive.
    static func parse(_ body: String, now: Date = Date(), calendar: Calendar = .current) -> (date: Date, body: String)? {
        var lines = body.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("@"),
              let date = date(from: String(first.dropFirst()), now: now, calendar: calendar)
        else { return nil }
        lines.removeFirst()
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return (date, lines.joined(separator: "\n"))
    }

    static func date(from phrase: String, now: Date, calendar: Calendar = .current) -> Date? {
        let phrase = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        guard !phrase.isEmpty else { return nil }
        if let relative = relativeDate(from: phrase, now: now, calendar: calendar) { return relative }
        return absoluteDate(from: phrase, now: now, calendar: calendar)
    }

    /// `3 hours ago`, `20 min ago`, `2d ago`, `an hour ago`.
    private static func relativeDate(from phrase: String, now: Date, calendar: Calendar) -> Date? {
        let pattern = #"^(\d+|an?)\s*(m|mins?|minutes?|h|hrs?|hours?|d|days?|w|wks?|weeks?)\s+ago$"#
        guard let match = phrase.firstMatch(of: try! Regex(pattern)),
              let countText = match.output[1].substring,
              let unitText = match.output[2].substring
        else { return nil }
        let count = Int(countText) ?? 1
        let component: Calendar.Component
        var amount = count
        switch unitText.first {
        case "m": component = .minute
        case "h": component = .hour
        case "d": component = .day
        default: component = .day; amount = count * 7
        }
        return calendar.date(byAdding: component, value: -amount, to: now)
    }

    /// `3pm`, `3:30 pm`, `15:00`, `yesterday 9am` — via the system date detector.
    /// A bare time later than now means the most recent one, i.e. yesterday's.
    private static func absoluteDate(from phrase: String, now: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(phrase.startIndex..., in: phrase)
        guard let match = detector.firstMatch(in: phrase, options: [], range: range),
              match.range.length == range.length,
              var date = match.date
        else { return nil }
        // Pin the detector's answer to `now`'s timeline (it uses the real clock).
        let names = ["today", "yesterday", "tomorrow"]
        if !names.contains(where: phrase.contains) {
            let time = calendar.dateComponents([.hour, .minute], from: date)
            guard let today = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: now)
            else { return nil }
            date = today > now ? calendar.date(byAdding: .day, value: -1, to: today) ?? today : today
        }
        return date
    }
}
