import Foundation

/// A note backed by a Markdown file in the vault.
struct VaultNote: Identifiable, Equatable {
    let relativePath: String
    var frontmatter: Frontmatter?
    var body: String
    var modifiedAt: Date
    var fileSize: Int

    /// The exact bytes this note was read from, used to detect external edits on
    /// save. Empty means "unknown" — treat that as changed, so the fail-safe
    /// direction is a conflict copy rather than a clobber.
    var originalText: String = ""

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
        VaultNoteSerializer.vaultTags(in: body)
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

    private static let titleTrimSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// First non-empty body line, stripped of leading `#`. Nil for an empty body.
    ///
    /// Newline characters are trimmed too, so a CRLF body doesn't yield a
    /// title ending in `\r`; a leading byte-order mark is ignored.
    static func title(forBody body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            var trimmed = line.trimmingCharacters(in: titleTrimSet)
            guard !trimmed.isEmpty else { continue }
            while trimmed.hasPrefix("#") { trimmed.removeFirst() }
            trimmed = trimmed.trimmingCharacters(in: titleTrimSet)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - Vault tags

    private static let fencePattern = try! NSRegularExpression(pattern: #"^[ \t]*(`{3,}|~{3,})"#)

    private static let nonTagSpans: [NSRegularExpression] = [
        #"(`+)[^`]*?\1"#,                    // inline code spans
        #"\[\[[^\]\n]*\]\]"#,                // [[wikilinks]], incl. #heading fragments
        #"\]\([^)\n]*\)"#,                   // markdown link / image targets
        #"[A-Za-z][A-Za-z0-9+.\-]*://\S*"#,  // bare URLs
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let vaultTagPattern = try! NSRegularExpression(pattern: #"(?:^|(?<=\s))#([A-Za-z0-9_-]+)"#)

    /// Inline `#tags` for the vault destination.
    ///
    /// `TagExtractor` (Memos mode, deliberately unchanged) matches `#`
    /// anywhere, which in a Markdown vault turns `[[Note#Heading]]` and
    /// `https://x/a#frag` into tags. This variant first blanks out code,
    /// wikilinks, link targets, and bare URLs, then accepts `#` only at the
    /// start of the text or after whitespace. Normalization mirrors
    /// TagExtractor: lowercased, de-duplicated, first-seen order.
    static func vaultTags(in text: String) -> [String] {
        // Fenced code blocks, line by line; an unterminated fence runs to the end.
        var kept: [String] = []
        var openFence: String?
        for line in text.components(separatedBy: "\n") {
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = fencePattern.firstMatch(in: line, range: lineRange),
               let markerRange = Range(match.range(at: 1), in: line) {
                let marker = String(line[markerRange])
                if let fence = openFence {
                    if marker.first == fence.first && marker.count >= fence.count {
                        openFence = nil
                    }
                } else {
                    openFence = marker
                }
                kept.append("")
                continue
            }
            kept.append(openFence == nil ? line : "")
        }

        var stripped = kept.joined(separator: "\n")
        for pattern in nonTagSpans {
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            stripped = pattern.stringByReplacingMatches(in: stripped, range: range, withTemplate: " ")
        }

        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        var seen = Set<String>()
        var result: [String] = []
        for match in vaultTagPattern.matches(in: stripped, range: range) {
            guard let r = Range(match.range(at: 1), in: stripped) else { continue }
            let tag = String(stripped[r]).lowercased()
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    /// Parses a frontmatter `tags` entry's raw text into a list: inline
    /// `[a, b]`, a block sequence of `- a` lines, or a bare scalar or comma
    /// list. Quotes and a leading `#` are stripped; original case is kept.
    static func parseTags(rawEntry: String) -> [String] {
        let lines = rawEntry.components(separatedBy: .newlines)
        guard let first = lines.first, let colon = first.firstIndex(of: ":") else { return [] }

        var items: [String] = []
        let inlineValue = first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if !inlineValue.isEmpty {
            var value = inlineValue
            if value.hasPrefix("[") && value.hasSuffix("]") {
                value = String(value.dropFirst().dropLast())
            }
            items = value.components(separatedBy: ",")
        } else {
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("-") else { continue }
                items.append(String(trimmed.dropFirst()))
            }
        }

        return items.compactMap { item in
            var tag = item.trimmingCharacters(in: .whitespaces).trimmingQuotes()
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespaces)
            return tag.isEmpty ? nil : tag
        }
    }

    // MARK: - Rendering

    /// Renders the complete file text: managed frontmatter keys updated in
    /// place, every other key left exactly as it was, then the body.
    ///
    /// `loadedBody` is the body as it was read from disk (nil for a brand-new
    /// note). `title` and `tags` are app-owned only while they are absent or
    /// still equal what the app would have derived from `loadedBody`; values
    /// the user set elsewhere (e.g. Obsidian Properties) are preserved, and
    /// body tag changes since load are merged into a user-maintained list.
    ///
    /// On a brand-new note `existing` may be a template's frontmatter (see
    /// `VaultTemplate`). Its keys are copied verbatim, but `title` and
    /// `created` are written by the app rather than defended, since a
    /// template's copies of them are placeholders. `tags` needs no special
    /// case: a template's list is already treated as user-maintained, so a
    /// fixed `tags: [inbox]` survives and the body's tags merge in.
    static func render(
        body: String,
        existing: Frontmatter?,
        loadedBody: String?,
        created: Date,
        updated: Date
    ) -> String {
        var frontmatter = existing ?? Frontmatter(blocks: [])
        var body = body
        if body.hasPrefix("\u{FEFF}") {
            // A byte-order mark belongs before the block, not after it.
            body.removeFirst()
            frontmatter.hasByteOrderMark = true
        }

        applyTitle(to: &frontmatter, body: body, loadedBody: loadedBody)

        // created is stamped once; a note only gets born one time. A new note
        // (no loadedBody) stamps regardless: any value there came from a
        // template, and a template's `created:` is a placeholder, not a birth.
        if loadedBody == nil || frontmatter.value(for: "created") == nil {
            frontmatter.set("created", rawValue: iso8601.string(from: created))
        }
        frontmatter.set("updated", rawValue: iso8601.string(from: updated))

        applyTags(to: &frontmatter, body: body, loadedBody: loadedBody)

        return frontmatter.render() + body
    }

    private static func applyTitle(to frontmatter: inout Frontmatter, body: String, loadedBody: String?) {
        if frontmatter.contains("title"), loadedBody != nil {
            // Present: app-owned only if it still equals the title derived
            // from the body as loaded. Anything else is the user's.
            //
            // A new note has no loaded body to compare against, so the check is
            // skipped entirely: its frontmatter came from a template, whose
            // `title:` is a slot to fill, not a value to defend. Without this
            // the guard would find nothing to derive, bail, and freeze an
            // empty title onto every note ever captured.
            guard let current = frontmatter.value(for: "title")?.trimmingQuotes(),
                  let derived = loadedBody.flatMap(title(forBody:)),
                  current == derived
            else { return }
        }
        if let newTitle = title(forBody: body) {
            frontmatter.set("title", rawValue: newTitle.yamlScalar())
        } else {
            frontmatter.remove("title")
        }
    }

    private static func applyTags(to frontmatter: inout Frontmatter, body: String, loadedBody: String?) {
        let newTags = vaultTags(in: body)

        guard let rawEntry = frontmatter.rawText(for: "tags") else {
            if !newTags.isEmpty {
                frontmatter.set("tags", rawValue: inlineTags(newTags))
            }
            return
        }

        let existing = parseTags(rawEntry: rawEntry)
        let loadedTags = vaultTags(in: loadedBody ?? "")
        // Compared case-insensitively, as Obsidian treats tags (and as the
        // extractor lowercases); the user's spelling is kept on output.
        let existingKeys = existing.map { $0.lowercased() }

        if Set(existingKeys) == Set(loadedTags) {
            // App-owned: the drift rule — mirror the body exactly.
            if newTags.isEmpty {
                frontmatter.remove("tags")
            } else if existing != newTags {
                frontmatter.set("tags", rawValue: inlineTags(newTags))
            }
            return
        }

        // User-maintained: keep their list and order, drop only tags removed
        // from the body since load, append tags newly added to the body.
        let kept = existing.filter { tag in
            let key = tag.lowercased()
            return !(loadedTags.contains(key) && !newTags.contains(key))
        }
        let added = newTags.filter { !existingKeys.contains($0) }
        if kept.count != existing.count || !added.isEmpty {
            frontmatter.set("tags", rawValue: inlineTags(kept + added))
        }
    }

    /// `[a, b]` flow sequence. Items that would break a flow sequence are
    /// single-quoted.
    private static func inlineTags(_ tags: [String]) -> String {
        let items = tags.map { tag -> String in
            let flowUnsafe = tag.contains(where: { ",[]{}".contains($0) })
            if flowUnsafe && tag.yamlScalar() == tag {
                return "'\(tag.replacingOccurrences(of: "'", with: "''"))'"
            }
            return tag.yamlScalar()
        }
        return "[\(items.joined(separator: ", "))]"
    }
}

extension String {
    /// YAML 1.1 scalars that parse as bool/null rather than string, checked
    /// case-insensitively against the whole value.
    fileprivate static let yamlReservedScalars: Set<String> = ["~", "null", "true", "false", "yes", "no", "on", "off"]

    /// Characters that YAML treats as indicators when they start a plain scalar.
    /// Internal rather than fileprivate: `VaultTemplate` checks the same set
    /// when a `{{title}}` expansion lands in a template value.
    static let yamlLeadingIndicators: Set<Character> = [
        "-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`",
    ]

    /// Whether the whole string would parse as a YAML number (int or float).
    fileprivate var looksLikeYAMLNumber: Bool {
        !isEmpty && Double(self) != nil
    }

    /// Quotes a scalar only when YAML would otherwise misread it, using the
    /// single-quoted style: its only escape is `''` for a literal `'`, so
    /// backslashes (e.g. `C:\Users`) survive untouched.
    ///
    /// Verified against a real YAML parser (Ruby's Psych): a leading indicator
    /// character, a mid-string `: ` or ` #`, a trailing `:`, reserved words,
    /// numbers, and date-like prefixes all misparse or fail when left bare.
    /// Over-quoting is harmless; under-quoting silently corrupts the note.
    func yamlScalar() -> String {
        guard needsYAMLQuoting else { return self }
        return "'\(replacingOccurrences(of: "'", with: "''"))'"
    }

    private var needsYAMLQuoting: Bool {
        guard let first, let last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if String.yamlLeadingIndicators.contains(first) { return true }
        if contains(": ") || contains(" #") || hasSuffix(":") { return true }
        if String.yamlReservedScalars.contains(lowercased()) { return true }
        if looksLikeYAMLNumber { return true }
        if range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return true }
        if contains("\\") { return true }
        if unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return true }
        return false
    }

    /// Reverses YAML scalar quoting. Single-quoted: unwrap and turn `''` into
    /// `'`. Double-quoted (older app output, other tools): unwrap and
    /// unescape `\"` and `\\`; other escapes are left as written.
    func trimmingQuotes() -> String {
        guard count >= 2 else { return self }
        if hasPrefix("'") && hasSuffix("'") {
            return String(dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if hasPrefix("\"") && hasSuffix("\"") {
            var result = ""
            var escaping = false
            for character in dropFirst().dropLast() {
                if escaping {
                    if character != "\"" && character != "\\" { result.append("\\") }
                    result.append(character)
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            if escaping { result.append("\\") }
            return result
        }
        return self
    }
}
