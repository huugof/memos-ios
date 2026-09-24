import Foundation

/// A note's text flattened for a history row: its lines joined into one run, heading
/// markers and embedded images/files dropped. Tags are kept — `#tag` has no space
/// after the `#`, so it never reads as a heading.
enum NoteExcerpt {
    /// Long enough to fill three wrapped lines on any phone width.
    static let maxLength = 300

    private static let embedRegex = try! NSRegularExpression(
        pattern: #"!\[\[[^\]]*\]\]|!\[[^\]]*\]\([^)]*\)"#
    )
    private static let headingRegex = try! NSRegularExpression(pattern: #"^#{1,6}\s+"#)

    static func make(from text: String) -> String {
        var parts: [String] = []
        var length = 0
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            line = replacing(embedRegex, in: line)
            line = replacing(headingRegex, in: line)
            // Collapses the gap a dropped inline image leaves, and tabs.
            line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !line.isEmpty else { continue }
            parts.append(line)
            length += line.count + 1
            if length >= maxLength { break }
        }
        return String(parts.joined(separator: " ").prefix(maxLength))
    }

    private static func replacing(_ regex: NSRegularExpression, in line: String) -> String {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }
}
