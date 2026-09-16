import Foundation

/// A note backed by a Markdown file in the vault.
struct VaultNote: Identifiable, Equatable {
    let relativePath: String
    var frontmatter: Frontmatter?
    var body: String
    var modifiedAt: Date
    var fileSize: Int

    var id: String { relativePath }

    /// Prefers the frontmatter title, falling back to the first body line and
    /// finally the filename — the list must always have something to draw.
    var title: String {
        if let fromFrontmatter = frontmatter?.value(for: "title"), !fromFrontmatter.isEmpty {
            return fromFrontmatter.trimmingQuotes()
        }
        if let fromBody = VaultNoteSerializer.title(forBody: body) {
            return fromBody
        }
        return (relativePath as NSString).lastPathComponent
    }

    var tags: [String] {
        TagExtractor.tags(in: body)
    }
}

enum VaultNoteSerializer {

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// `YYYY-MM-DD HHmm.md`, with ` 2`, ` 3`, … appended on collision.
    /// Timestamp names never collide with an edited first line, so a note's
    /// filename is stable for its whole life and inbound [[wikilinks]] survive.
    static func filename(
        for date: Date,
        existing: Set<String>,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stem = formatter.string(from: date)

        var candidate = "\(stem).md"
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(stem) \(suffix).md"
            suffix += 1
        }
        return candidate
    }

    /// First non-empty body line, stripped of leading `#`. Nil for an empty body.
    static func title(forBody body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            while trimmed.hasPrefix("#") { trimmed.removeFirst() }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Renders the complete file text: managed frontmatter keys updated in
    /// place, every other key left exactly as it was, then the body.
    static func render(
        body: String,
        existing: Frontmatter?,
        created: Date,
        updated: Date
    ) -> String {
        var frontmatter = existing ?? Frontmatter(blocks: [])

        if let title = title(forBody: body) {
            frontmatter.set("title", rawValue: title.yamlScalar())
        } else {
            frontmatter.remove("title")
        }

        // created is stamped once; a note only gets born one time.
        if frontmatter.value(for: "created") == nil {
            frontmatter.set("created", rawValue: iso8601.string(from: created))
        }
        frontmatter.set("updated", rawValue: iso8601.string(from: updated))

        let tags = TagExtractor.tags(in: body)
        if tags.isEmpty {
            frontmatter.remove("tags")
        } else {
            frontmatter.set("tags", rawValue: "[\(tags.joined(separator: ", "))]")
        }

        return frontmatter.render() + body
    }
}

private extension String {
    /// Quotes a scalar only when YAML would otherwise misread it.
    func yamlScalar() -> String {
        let needsQuoting = contains(": ") || hasPrefix("#") || hasPrefix("[") || hasPrefix("{")
            || hasPrefix("&") || hasPrefix("*") || hasPrefix("!") || hasPrefix("|") || hasPrefix(">")
            || hasSuffix(":")
        guard needsQuoting else { return self }
        return "\"\(replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    func trimmingQuotes() -> String {
        guard count >= 2, (hasPrefix("\"") && hasSuffix("\"")) || (hasPrefix("'") && hasSuffix("'")) else {
            return self
        }
        return String(dropFirst().dropLast())
    }
}
