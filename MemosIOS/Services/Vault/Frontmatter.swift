import Foundation

/// A YAML frontmatter block modeled as ordered raw text spans rather than a
/// parsed dictionary. Only spans the app explicitly rewrites change; everything
/// else — comments, blank lines, key order, quoting style, nested structures —
/// survives a save byte-identical. See the design doc for why a YAML
/// round-tripper was rejected.
struct Frontmatter: Equatable {

    enum Block: Equatable {
        /// A `key: value` entry. `rawText` spans the key line plus any indented
        /// or `- ` continuation lines, and includes the trailing newline.
        case entry(key: String, rawText: String)
        /// Comments and blank lines. Includes the trailing newline.
        case passthrough(String)

        var rawText: String {
            switch self {
            case .entry(_, let raw): return raw
            case .passthrough(let raw): return raw
            }
        }
    }

    private(set) var blocks: [Block]

    /// The file began with a U+FEFF byte-order mark before `---`. It is
    /// stripped for parsing and re-emitted by `render()`.
    var hasByteOrderMark: Bool

    init(blocks: [Block], hasByteOrderMark: Bool = false) {
        self.blocks = blocks
        self.hasByteOrderMark = hasByteOrderMark
    }

    // MARK: - Parsing

    /// Splits a file into its frontmatter block and its body.
    ///
    /// A block counts only when the file *starts* with a `---` line and a
    /// closing `---` line follows. Anything else is entirely body, so a
    /// horizontal rule mid-note is never mistaken for frontmatter.
    ///
    /// A leading U+FEFF byte-order mark is skipped for detection and recorded
    /// in `hasByteOrderMark`, so `render()` puts it back. A file with no block
    /// is returned whole (BOM included) as body.
    static func parse(_ fileText: String) -> (frontmatter: Frontmatter?, body: String) {
        var text = Substring(fileText)
        let hasBOM = text.first == "\u{FEFF}"
        if hasBOM { text = text.dropFirst() }

        let lines = String(text).splitKeepingLineEndings()
        guard let first = lines.first, first.trimmedLine == "---" else {
            return (nil, fileText)
        }

        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmedLine == "---" }) else {
            return (nil, fileText)   // unterminated: not a block
        }

        let blockLines = Array(lines[1..<closingIndex])
        let body = lines[(closingIndex + 1)...].joined()
        return (Frontmatter(blocks: makeBlocks(from: blockLines), hasByteOrderMark: hasBOM), body)
    }

    /// Groups lines into entries and passthrough spans.
    ///
    /// Blank lines and column-0 `#` comments seen while inside an entry are
    /// held as pending: if a continuation line follows, they belong to the
    /// entry (so rewriting or removing it can't strand the rest of a list);
    /// otherwise they are emitted as passthrough after the entry.
    private static func makeBlocks(from lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var currentKey: String?
        var currentRaw = ""
        var pending: [String] = []

        func flush() {
            if let key = currentKey {
                blocks.append(.entry(key: key, rawText: currentRaw))
            }
            blocks.append(contentsOf: pending.map(Block.passthrough))
            currentKey = nil
            currentRaw = ""
            pending = []
        }

        for line in lines {
            if let key = line.frontmatterKey {
                flush()
                currentKey = key
                currentRaw = line
            } else if currentKey != nil, line.isEntryContinuation {
                currentRaw += pending.joined() + line
                pending = []
            } else if currentKey != nil, line.trimmedLine.isEmpty || line.hasPrefix("#") {
                pending.append(line)
            } else {
                flush()
                blocks.append(.passthrough(line))
            }
        }
        flush()
        return blocks
    }

    // MARK: - Reading

    /// The trimmed scalar value for a key. Returns nil for block-sequence
    /// values, which have no single-line scalar to report.
    func value(for key: String) -> String? {
        for case .entry(let k, let raw) in blocks where k == key {
            guard let colon = raw.firstIndex(of: ":") else { return nil }
            let after = raw[raw.index(after: colon)...]
            // `"\r\n"` is a single grapheme cluster in Swift, so it fails both
            // `!= "\n"` and `!= "\r"` individually; `isNewline` catches it.
            let firstLine = after.prefix(while: { !$0.isNewline })
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Whether an entry with this key exists, whatever its value shape.
    func contains(_ key: String) -> Bool {
        rawText(for: key) != nil
    }

    /// The complete raw text of a key's entry (key line plus continuations).
    func rawText(for key: String) -> String? {
        for case .entry(let k, let raw) in blocks where k == key {
            return raw
        }
        return nil
    }

    // MARK: - Mutation

    /// Replaces the raw text of an existing entry, or appends a new one.
    /// Neighbouring blocks are never touched.
    mutating func set(_ key: String, rawValue: String) {
        let replacement = Block.entry(key: key, rawText: "\(key): \(rawValue)\n")
        if let index = blocks.firstIndex(where: { if case .entry(let k, _) = $0 { return k == key }; return false }) {
            blocks[index] = replacement
        } else {
            blocks.append(replacement)
        }
    }

    mutating func remove(_ key: String) {
        blocks.removeAll { if case .entry(let k, _) = $0 { return k == key }; return false }
    }

    // MARK: - Rendering

    /// The complete block including delimiters, or "" when there is nothing to write.
    /// A recorded byte-order mark is re-emitted first.
    func render() -> String {
        let bom = hasByteOrderMark ? "\u{FEFF}" : ""
        guard !blocks.isEmpty else { return bom }
        return bom + "---\n" + blocks.map(\.rawText).joined() + "---\n"
    }
}

// MARK: - Line helpers

private extension String {
    /// Splits into lines, keeping each line's own terminator so CRLF and a
    /// missing final newline both round-trip.
    ///
    /// Swift's `Character` is an extended grapheme cluster, and `"\r\n"` is a
    /// single such cluster — it never equals the `Character` literal `"\n"`.
    /// Checking `character.isNewline` (true for `\n`, `\r`, and `\r\n` alike)
    /// is what makes CRLF-terminated lines split correctly.
    func splitKeepingLineEndings() -> [String] {
        var lines: [String] = []
        var current = ""
        for character in self {
            current.append(character)
            if character.isNewline {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    var trimmedLine: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The key of a top-level `key:` line, or nil. Indented lines are never keys.
    var frontmatterKey: String? {
        guard let firstCharacter = first, !firstCharacter.isWhitespace else { return nil }
        guard let colon = firstIndex(of: ":") else { return nil }
        let key = String(self[startIndex..<colon])
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
        else { return nil }
        return key
    }

    /// Indented lines and `- ` sequence items continue the entry above them.
    var isEntryContinuation: Bool {
        guard let firstCharacter = first else { return false }
        if firstCharacter == "\n" || firstCharacter == "\r" { return false }
        return firstCharacter == " " || firstCharacter == "\t" || hasPrefix("- ")
    }
}
