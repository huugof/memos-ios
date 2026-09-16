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
    /// YAML 1.1 scalars that parse as bool/null rather than string, checked
    /// case-insensitively against the whole (trimmed) value.
    static let yamlReservedScalars: Set<String> = ["~", "null", "true", "false", "yes", "no", "on", "off"]

    /// Whether the whole string would parse as a YAML number (int or float).
    var looksLikeYAMLNumber: Bool {
        !isEmpty && Double(self) != nil
    }

    /// Quotes a scalar only when YAML would otherwise misread it.
    ///
    /// Verified against a real YAML parser (Ruby's Psych): an unquoted mid-string
    /// " #" is read as a comment (silently truncating everything after it), a
    /// leading "-" (or "?", "@", "`", "%") either starts a block-sequence/mapping
    /// construct or is a reserved indicator and breaks parsing, and bare
    /// true/false/yes/no/on/off/null/~ or a numeric literal parse as their
    /// non-string type instead of the text the app wrote. Over-quoting here is
    /// harmless; under-quoting silently corrupts the user's note.
    func yamlScalar() -> String {
        let needsQuoting = contains(": ") || contains(" #") || hasPrefix("#")
            || hasPrefix("[") || hasPrefix("{") || hasPrefix("&") || hasPrefix("*")
            || hasPrefix("!") || hasPrefix("|") || hasPrefix(">") || hasPrefix("-")
            || hasPrefix("?") || hasPrefix("@") || hasPrefix("`") || hasPrefix("%")
            || hasSuffix(":")
            || String.yamlReservedScalars.contains(lowercased())
            || looksLikeYAMLNumber
        guard needsQuoting else { return self }
        return "\"\(replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// Reverses `yamlScalar()`: strips a matching outer quote pair and, for
    /// double quotes, un-escapes the `\"` sequences `yamlScalar()` introduced.
    /// Single-quoted values are left as-is since this app never writes them.
    func trimmingQuotes() -> String {
        guard count >= 2 else { return self }
        if hasPrefix("\"") && hasSuffix("\"") {
            let inner = String(dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
        }
        if hasPrefix("'") && hasSuffix("'") {
            return String(dropFirst().dropLast())
        }
        return self
    }
}
