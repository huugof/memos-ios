import Foundation

/// Seeds a new note's frontmatter from a Markdown file in the vault.
///
/// The template's frontmatter block is parsed and handed to
/// `VaultNoteSerializer.render` as the note's `existing` frontmatter, so every
/// key, its order, its quoting style and any comments survive verbatim —
/// exactly the guarantee that already protects a desktop-edited note. Only the
/// managed keys (`date`, `modified`, `tags`, and `title` where the template
/// has one) are then written over the top.
///
/// The template's *body* is ignored: in a compose-first app the note's text is
/// what the user typed.
enum VaultTemplate {

    /// Parses `fileText` and expands the `{{date}}`, `{{time}}` and
    /// `{{title}}` placeholders the Obsidian core Templates plugin defines.
    /// Returns nil when the file has no frontmatter block — there is then
    /// nothing to seed, and the note renders as it would with no template.
    ///
    /// Templater's `<% … %>` syntax is deliberately left untouched rather than
    /// half-emulated; it would land in the file literally.
    static func frontmatter(
        fromFileText fileText: String,
        title: String?,
        now: Date,
        timeZone: TimeZone = .current
    ) -> Frontmatter? {
        guard let parsed = Frontmatter.parse(fileText).frontmatter else { return nil }

        let context = Context(title: title, now: now, timeZone: timeZone)
        let blocks = parsed.blocks.map { block -> Frontmatter.Block in
            switch block {
            case .entry(let key, let rawText):
                return .entry(key: key, rawText: expandEntry(rawText, context: context))
            case .passthrough(let rawText):
                // Comments and blank lines: substitute, but never requote —
                // a comment has no YAML value to protect.
                return .passthrough(substitute(rawText, context: context, escape: { $0 }).text)
            }
        }
        // A template's byte-order mark is its own; the note's is decided by the
        // note's body in `render`.
        return Frontmatter(blocks: blocks, hasByteOrderMark: false)
    }

    private struct Context {
        let title: String?
        let now: Date
        let timeZone: TimeZone
    }

    // MARK: - Entry expansion

    /// Expands one `key: value` entry, keeping the value valid YAML.
    ///
    /// Only `{{title}}` can produce arbitrary text, so only a title expansion
    /// triggers protective quoting; a date or time is safe by construction and
    /// is left bare, which is both what Obsidian writes and what its date
    /// properties expect.
    private static func expandEntry(_ rawText: String, context: Context) -> String {
        let lines = rawText.components(separatedBy: "\n")
        guard lines.dropFirst().allSatisfy(\.isEmpty),
              let first = lines.first,
              let colon = first.firstIndex(of: ":")
        else {
            // Multi-line entry (a block sequence or folded scalar): substitute
            // without requoting — there is no single value to wrap.
            return substitute(rawText, context: context, escape: { $0 }).text
        }

        let head = String(first[...colon])
        let rest = String(first[first.index(after: colon)...])
        let trailing = String(rawText.dropFirst(first.count))

        let leading = String(rest.prefix { $0 == " " || $0 == "\t" })
        let value = String(rest.dropFirst(leading.count))

        let expanded: String
        if value.hasPrefix("'") {
            expanded = substitute(value, context: context) {
                $0.replacingOccurrences(of: "'", with: "''")
            }.text
        } else if value.hasPrefix("\"") {
            expanded = substitute(value, context: context) {
                $0.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            }.text
        } else {
            let result = substitute(value, context: context, escape: { $0 })
            if result.didExpandTitle && needsProtectiveQuoting(result.text) {
                expanded = "'\(result.text.replacingOccurrences(of: "'", with: "''"))'"
            } else {
                expanded = result.text
            }
        }

        return head + leading + expanded + trailing
    }

    /// Whether a plain scalar would misparse — the narrow check, not
    /// `yamlScalar()`'s. Quoting here must not fire on a date or a number: a
    /// template's `due: {{date}}` should stay a YAML date, as Obsidian writes it.
    private static func needsProtectiveQuoting(_ value: String) -> Bool {
        guard let first = value.first, let last = value.last else { return false }
        if first.isWhitespace || last.isWhitespace { return true }
        if String.yamlLeadingIndicators.contains(first) { return true }
        if value.contains(": ") || value.contains(" #") || value.hasSuffix(":") { return true }
        if value.contains(where: { $0.isNewline }) { return true }
        return false
    }

    // MARK: - Placeholders

    private static let placeholder = try! NSRegularExpression(
        pattern: #"\{\{\s*(date|time|title)\s*(?::([^}]*))?\s*\}\}"#,
        options: [.caseInsensitive]
    )

    private static func substitute(
        _ text: String,
        context: Context,
        escape: (String) -> String
    ) -> (text: String, didExpandTitle: Bool) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = placeholder.matches(in: text, range: range)
        guard !matches.isEmpty else { return (text, false) }

        var result = text
        var didExpandTitle = false
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result)
            else { continue }
            let name = result[nameRange].lowercased()
            let format = Range(match.range(at: 2), in: result).map { String(result[$0]) }

            let replacement: String
            switch name {
            case "date":
                replacement = formatted(context.now, format: format ?? "YYYY-MM-DD", in: context.timeZone)
            case "time":
                replacement = formatted(context.now, format: format ?? "HH:mm", in: context.timeZone)
            default:
                guard let title = context.title else { continue }
                replacement = title
                didExpandTitle = true
            }
            result.replaceSubrange(matchRange, with: escape(replacement))
        }
        return (result, didExpandTitle)
    }

    /// `en_US_POSIX` deliberately: the placeholder's output goes into a YAML
    /// scalar, and a locale with non-Latin digits would make `{{date}}`
    /// unparseable as a date. The cost is English month and weekday names.
    private static func formatted(_ date: Date, format: String, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat(fromMomentFormat: format)
        return formatter.string(from: date)
    }

    /// Moment.js tokens (what Obsidian's templates are written in) to Unicode
    /// `DateFormatter` ones. The two disagree on the common cases: moment's
    /// `YYYY` is the calendar year where Unicode's is the week-based one, and
    /// moment's `DD` is the day of the month where Unicode's is the day of the
    /// year — passing a moment format straight through silently produces the
    /// wrong date in the last week of December.
    private static let formatTokens: [String: String] = [
        "YYYY": "yyyy", "YY": "yy",
        "MMMM": "MMMM", "MMM": "MMM", "MM": "MM", "M": "M",
        "DD": "dd", "D": "d",
        "dddd": "EEEE", "ddd": "EEE",
        "HH": "HH", "H": "H", "hh": "hh", "h": "h",
        "mm": "mm", "m": "m",
        "ss": "ss", "s": "s",
        "A": "a", "a": "a",
    ]

    /// Unrecognized letter runs become quoted literals rather than being
    /// handed to `DateFormatter` as tokens, so an unsupported format prints
    /// itself instead of expanding into something unrelated.
    static func dateFormat(fromMomentFormat format: String) -> String {
        var out = ""
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]

            if character == "[" {
                var end = format.index(after: index)
                var literal = ""
                while end < format.endIndex, format[end] != "]" {
                    literal.append(format[end])
                    end = format.index(after: end)
                }
                out += quotedLiteral(literal)
                index = end < format.endIndex ? format.index(after: end) : end
                continue
            }

            if character.isLetter {
                var end = index
                var run = ""
                while end < format.endIndex, format[end] == character {
                    run.append(character)
                    end = format.index(after: end)
                }
                out += formatTokens[run] ?? quotedLiteral(run)
                index = end
                continue
            }

            out += character == "'" ? "''" : String(character)
            index = format.index(after: index)
        }
        return out
    }

    private static func quotedLiteral(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return "'\(text.replacingOccurrences(of: "'", with: "''"))'"
    }
}
