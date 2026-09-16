# Obsidian Vault Destination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let MemoChat write and read notes as Markdown files in an Obsidian vault, as a user-selectable alternative to the Memos server.

**Architecture:** `Draft` (SwiftData) stays the destination-agnostic local buffer. A `DestinationRouter` reads `AppSettings.destinationKind` and dispatches either to the existing send queues (Memos, unchanged) or to a new `VaultStore` (files, no queue). All vault file code lives in `MemosIOS/Services/Vault/` and is layered so the risky logic — frontmatter splicing — is a pure value type with no I/O.

**Tech Stack:** Swift 5, SwiftUI, SwiftData, XCTest, XcodeGen. iOS 26.0 floor. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-16-obsidian-vault-destination-design.md`

## Global Constraints

- **No third-party dependencies.** The project has none today and the spec explicitly rejects Yams. Frontmatter handling is hand-rolled.
- **iOS deployment target 26.0** (`project.yml`).
- **Swift version 5.0** (`SWIFT_VERSION` in `project.yml`).
- **XcodeGen owns the project file.** After creating any new `.swift` file, run `xcodegen generate` before building. `MemosIOS/Services` is already a source path and recurses, so `MemosIOS/Services/Vault/` is picked up automatically — no `project.yml` edit needed for new vault files.
- **Tests live in `MemosIOSTests/`** and use `@testable import MemoChat` (not `import MemosIOS` — the separate app target was retired).
- **Test command:**
  ```bash
  xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  ```
  If that simulator is not installed, run `xcrun simctl list devices available` and substitute any listed iOS device name.
- **Filename format for new notes:** `YYYY-MM-DD HHmm.md` (e.g. `2026-09-16 2130.md`).
- **Image link format:** `![[filename.png]]` (Obsidian wikilink).
- **Frontmatter keys the app maintains:** `title`, `created`, `updated`, `tags`. All other keys must survive a save byte-identical.
- **Timestamps in frontmatter:** ISO-8601 with `Z` suffix, e.g. `2026-09-16T21:30:03Z`.
- **Never lose user text.** On any vault write failure the originating `Draft` stays unarchived.

---

### Task 1: Frontmatter parse and splice

The highest-risk component and the one with zero dependencies. A pure value type — no files, no simulator state.

The design requirement is that keys, comments, ordering, and formatting the app does not understand survive a save **byte-identical**. That rules out parse-to-dictionary-and-re-emit. Instead the block is modeled as an ordered list of raw text spans, and only touched spans are rewritten.

**Files:**
- Create: `MemosIOS/Services/Vault/Frontmatter.swift`
- Test: `MemosIOSTests/FrontmatterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct Frontmatter: Equatable`
  - `Frontmatter.Block` — `.entry(key: String, rawText: String)` / `.passthrough(String)`; every `rawText` includes its trailing newline
  - `static func Frontmatter.parse(_ fileText: String) -> (frontmatter: Frontmatter?, body: String)`
  - `func value(for key: String) -> String?` — trimmed scalar value, `nil` for block-sequence values
  - `mutating func set(_ key: String, rawValue: String)`
  - `mutating func remove(_ key: String)`
  - `func render() -> String` — full block including `---` delimiters, `""` when there are no blocks

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

final class FrontmatterTests: XCTestCase {

    // MARK: - Parsing

    func testParsesSimpleBlock() {
        let text = "---\ntitle: Hello\ncreated: 2026-09-16T21:30:03Z\n---\nBody text\n"
        let (fm, body) = Frontmatter.parse(text)
        XCTAssertEqual(fm?.value(for: "title"), "Hello")
        XCTAssertEqual(fm?.value(for: "created"), "2026-09-16T21:30:03Z")
        XCTAssertEqual(body, "Body text\n")
    }

    func testFileWithoutFrontmatterIsAllBody() {
        let text = "Just a note\nwith two lines\n"
        let (fm, body) = Frontmatter.parse(text)
        XCTAssertNil(fm)
        XCTAssertEqual(body, text)
    }

    /// A horizontal rule mid-body must not be mistaken for a frontmatter block.
    func testHorizontalRuleInBodyIsNotFrontmatter() {
        let text = "Some text\n---\nMore text\n"
        let (fm, body) = Frontmatter.parse(text)
        XCTAssertNil(fm)
        XCTAssertEqual(body, text)
    }

    func testEmptyBlockParsesToEmptyFrontmatter() {
        let text = "---\n---\nBody\n"
        let (fm, body) = Frontmatter.parse(text)
        XCTAssertNotNil(fm)
        XCTAssertEqual(fm?.blocks.count, 0)
        XCTAssertEqual(body, "Body\n")
    }

    /// An opening --- with no closing --- is not a block; treat the whole file as body.
    func testUnterminatedBlockIsAllBody() {
        let text = "---\ntitle: Hello\nBody with no close\n"
        let (fm, body) = Frontmatter.parse(text)
        XCTAssertNil(fm)
        XCTAssertEqual(body, text)
    }

    func testParsesCRLFLineEndings() {
        let text = "---\r\ntitle: Hello\r\n---\r\nBody\r\n"
        let (fm, body) = Frontmatter.parse(text)
        XCTAssertEqual(fm?.value(for: "title"), "Hello")
        XCTAssertEqual(body, "Body\r\n")
    }

    func testParsesBlockSequenceTags() {
        let text = "---\ntags:\n  - inbox\n  - ideas\n---\nBody\n"
        let (fm, _) = Frontmatter.parse(text)
        // The continuation lines belong to the tags entry, not to separate entries.
        XCTAssertEqual(fm?.blocks.count, 1)
        XCTAssertEqual(fm?.render(), "---\ntags:\n  - inbox\n  - ideas\n---\n")
    }

    // MARK: - Byte-identical round-trip

    func testRoundTripPreservesCommentsAndOrder() {
        let text = """
        ---
        # a comment the app knows nothing about
        zzz_custom: kept

        title: Hello
        aliases: ["one", "two"]
        ---
        Body
        """
        let (fm, _) = Frontmatter.parse(text)
        let rendered = fm!.render()
        XCTAssertTrue(rendered.contains("# a comment the app knows nothing about"))
        XCTAssertTrue(rendered.contains("zzz_custom: kept"))
        XCTAssertTrue(rendered.contains(#"aliases: ["one", "two"]"#))
        // Order preserved: custom key still precedes title.
        let customIndex = rendered.range(of: "zzz_custom")!.lowerBound
        let titleIndex = rendered.range(of: "title:")!.lowerBound
        XCTAssertLessThan(customIndex, titleIndex)
    }

    // MARK: - Mutation

    func testSetReplacesOnlyTargetEntry() {
        let text = "---\n# keep me\ncustom: untouched\ntitle: Old\n---\nBody\n"
        var (fm, _) = Frontmatter.parse(text)
        fm!.set("title", rawValue: "New")
        let rendered = fm!.render()
        XCTAssertEqual(rendered, "---\n# keep me\ncustom: untouched\ntitle: New\n---\n")
    }

    func testSetAppendsMissingKey() {
        let text = "---\ntitle: Hello\n---\nBody\n"
        var (fm, _) = Frontmatter.parse(text)
        fm!.set("updated", rawValue: "2026-09-16T21:34:11Z")
        XCTAssertEqual(fm!.render(), "---\ntitle: Hello\nupdated: 2026-09-16T21:34:11Z\n---\n")
    }

    func testRemoveDropsEntryAndLeavesNeighbours() {
        let text = "---\ntitle: Hello\ntags: [a]\ncustom: keep\n---\nBody\n"
        var (fm, _) = Frontmatter.parse(text)
        fm!.remove("tags")
        XCTAssertEqual(fm!.render(), "---\ntitle: Hello\ncustom: keep\n---\n")
    }

    func testRemoveOfAbsentKeyIsNoOp() {
        let text = "---\ntitle: Hello\n---\nBody\n"
        var (fm, _) = Frontmatter.parse(text)
        fm!.remove("nope")
        XCTAssertEqual(fm!.render(), "---\ntitle: Hello\n---\n")
    }

    func testSetReplacesMultiLineEntryWithScalar() {
        let text = "---\ntags:\n  - inbox\n  - ideas\ntitle: Hello\n---\nBody\n"
        var (fm, _) = Frontmatter.parse(text)
        fm!.set("tags", rawValue: "[one, two]")
        XCTAssertEqual(fm!.render(), "---\ntags: [one, two]\ntitle: Hello\n---\n")
    }

    func testEmptyFrontmatterRendersEmptyString() {
        let fm = Frontmatter(blocks: [])
        XCTAssertEqual(fm.render(), "")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/FrontmatterTests`
Expected: compile failure — `cannot find 'Frontmatter' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
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

    init(blocks: [Block]) {
        self.blocks = blocks
    }

    // MARK: - Parsing

    /// Splits a file into its frontmatter block and its body.
    ///
    /// A block counts only when the file *starts* with a `---` line and a
    /// closing `---` line follows. Anything else is entirely body, so a
    /// horizontal rule mid-note is never mistaken for frontmatter.
    static func parse(_ fileText: String) -> (frontmatter: Frontmatter?, body: String) {
        let lines = fileText.splitKeepingLineEndings()
        guard let first = lines.first, first.trimmedLine == "---" else {
            return (nil, fileText)
        }

        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmedLine == "---" }) else {
            return (nil, fileText)   // unterminated: not a block
        }

        let blockLines = Array(lines[1..<closingIndex])
        let body = lines[(closingIndex + 1)...].joined()
        return (Frontmatter(blocks: makeBlocks(from: blockLines)), body)
    }

    private static func makeBlocks(from lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var currentKey: String?
        var currentRaw = ""

        func flush() {
            if let key = currentKey {
                blocks.append(.entry(key: key, rawText: currentRaw))
            }
            currentKey = nil
            currentRaw = ""
        }

        for line in lines {
            if let key = line.frontmatterKey {
                flush()
                currentKey = key
                currentRaw = line
            } else if currentKey != nil, line.isEntryContinuation {
                currentRaw += line
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
            let firstLine = after.prefix(while: { !$0.isNewline })
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
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
    func render() -> String {
        guard !blocks.isEmpty else { return "" }
        return "---\n" + blocks.map(\.rawText).joined() + "---\n"
    }
}

// MARK: - Line helpers

private extension String {
    /// Splits into lines, keeping each line's own terminator so CRLF and a
    /// missing final newline both round-trip.
    func splitKeepingLineEndings() -> [String] {
        var lines: [String] = []
        var current = ""
        for character in self {
            current.append(character)
            // isNewline, not == "\n": Swift's Character is an extended grapheme
            // cluster, so "\r\n" is a SINGLE Character and never equals "\n".
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
```

- [ ] **Step 4: Regenerate the project and run the tests**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/FrontmatterTests
```
Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
git add MemosIOS/Services/Vault/Frontmatter.swift MemosIOSTests/FrontmatterTests.swift MemosIOS.xcodeproj
git commit -m "feat: add frontmatter parser with byte-identical splice"
```

---

### Task 2: VaultNote and note serialization

Turns a `Draft`'s text into the exact bytes of a `.md` file, and back. Still pure — no file system.

**Files:**
- Create: `MemosIOS/Services/Vault/VaultNote.swift`
- Test: `MemosIOSTests/VaultNoteSerializerTests.swift`

**Interfaces:**
- Consumes: `Frontmatter` (Task 1), `TagExtractor.tags(in:)` (existing, `MemoChat/ViewModels/TagExtractor.swift`).
- Produces:
  - `struct VaultNote: Identifiable, Equatable` with `relativePath: String`, `frontmatter: Frontmatter?`, `body: String`, `modifiedAt: Date`, `fileSize: Int`, `var id: String { relativePath }`, `var title: String`
  - `enum VaultNoteSerializer`
  - `static func filename(for date: Date, existing: Set<String>, timeZone: TimeZone = .current) -> String`
  - `static func render(body: String, existing: Frontmatter?, created: Date, updated: Date) -> String`
  - `static func title(forBody: String) -> String?`
  - `static let iso8601: ISO8601DateFormatter`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

final class VaultNoteSerializerTests: XCTestCase {

    private let created = Date(timeIntervalSince1970: 1_789_594_203)  // 2026-09-16T21:30:03Z
    private let updated = Date(timeIntervalSince1970: 1_789_594_451)  // 2026-09-16T21:34:11Z

    // MARK: - Filenames

    func testFilenameUsesTimestampFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 21, minute: 30))!
        let name = VaultNoteSerializer.filename(for: date, existing: [], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "2026-09-16 2130.md")
    }

    func testFilenameAppendsSuffixOnCollision() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 21, minute: 30))!
        let name = VaultNoteSerializer.filename(
            for: date,
            existing: ["2026-09-16 2130.md", "2026-09-16 2130 2.md"],
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(name, "2026-09-16 2130 3.md")
    }

    // MARK: - Titles

    func testTitleIsFirstNonEmptyLineStrippedOfHashes() {
        XCTAssertEqual(VaultNoteSerializer.title(forBody: "\n\n## My heading\nmore"), "My heading")
    }

    /// Unlike UnifiedNote.title there is no "New Note" placeholder — an empty
    /// body means the key is omitted entirely.
    func testTitleIsNilForEmptyBody() {
        XCTAssertNil(VaultNoteSerializer.title(forBody: "   \n\n  "))
    }

    // MARK: - Rendering

    func testRenderWritesManagedKeys() {
        let text = VaultNoteSerializer.render(
            body: "My note\nwith #inbox and #ideas\n",
            existing: nil,
            created: created,
            updated: updated
        )
        XCTAssertTrue(text.hasPrefix("---\n"))
        XCTAssertTrue(text.contains("title: My note\n"))
        XCTAssertTrue(text.contains("created: 2026-09-16T21:30:03Z\n"))
        XCTAssertTrue(text.contains("updated: 2026-09-16T21:34:11Z\n"))
        XCTAssertTrue(text.contains("tags: [inbox, ideas]\n"))
        XCTAssertTrue(text.hasSuffix("My note\nwith #inbox and #ideas\n"))
    }

    func testRenderPreservesUnknownKeys() {
        let (existing, _) = Frontmatter.parse("---\ncustom: keep me\n# and this comment\ntitle: Old\n---\nold body\n")
        let text = VaultNoteSerializer.render(
            body: "New body\n",
            existing: existing,
            created: created,
            updated: updated
        )
        XCTAssertTrue(text.contains("custom: keep me\n"))
        XCTAssertTrue(text.contains("# and this comment\n"))
        XCTAssertTrue(text.contains("title: New body\n"))
        XCTAssertFalse(text.contains("title: Old"))
    }

    /// created is stamped once and never rewritten on later saves.
    func testRenderKeepsOriginalCreated() {
        let (existing, _) = Frontmatter.parse("---\ncreated: 2020-01-01T00:00:00Z\n---\nbody\n")
        let text = VaultNoteSerializer.render(body: "body\n", existing: existing, created: created, updated: updated)
        XCTAssertTrue(text.contains("created: 2020-01-01T00:00:00Z\n"))
        XCTAssertFalse(text.contains("created: 2026-09-16"))
    }

    /// The drift rule: tags are app-maintained, so removing an inline tag
    /// removes it from frontmatter.
    func testRemovingInlineTagRemovesItFromFrontmatter() {
        let (existing, _) = Frontmatter.parse("---\ntags: [inbox, ideas]\n---\nold\n")
        let text = VaultNoteSerializer.render(body: "now only #inbox\n", existing: existing, created: created, updated: updated)
        XCTAssertTrue(text.contains("tags: [inbox]\n"))
    }

    func testBodyWithNoTagsOmitsTagsKey() {
        let text = VaultNoteSerializer.render(body: "no tags here\n", existing: nil, created: created, updated: updated)
        XCTAssertFalse(text.contains("tags:"))
    }

    func testEmptyBodyOmitsTitleKey() {
        let text = VaultNoteSerializer.render(body: "", existing: nil, created: created, updated: updated)
        XCTAssertFalse(text.contains("title:"))
        XCTAssertTrue(text.contains("created:"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultNoteSerializerTests`
Expected: compile failure — `cannot find 'VaultNoteSerializer' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
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
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultNoteSerializerTests
```
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add MemosIOS/Services/Vault/VaultNote.swift MemosIOSTests/VaultNoteSerializerTests.swift MemosIOS.xcodeproj
git commit -m "feat: add vault note serialization with managed frontmatter keys"
```

---

### Task 3: Vault bookmark store

Persists access to a folder the user picked. Security-scoped bookmarks go stale on restore-from-backup, so staleness is a normal condition to handle, not an error path to ignore.

**Files:**
- Create: `MemosIOS/Services/Vault/VaultBookmarkStore.swift`
- Modify: `MemosIOS/Storage/AppSettings.swift`
- Test: `MemosIOSTests/VaultBookmarkStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum VaultAccessError: LocalizedError, Equatable` — `.notConfigured`, `.stale`
  - `enum VaultBookmarkStore`
  - `static func save(url: URL) throws`
  - `static func resolve() throws -> URL`
  - `static func clear()`
  - `static func withAccess<T>(_ body: (URL) throws -> T) throws -> T`
  - `AppSettings.vaultBookmark: Data?`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

final class VaultBookmarkStoreTests: XCTestCase {

    private var originalBookmark: Data?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalBookmark = AppSettings.vaultBookmark
        AppSettings.vaultBookmark = nil
    }

    override func tearDownWithError() throws {
        AppSettings.vaultBookmark = originalBookmark
        try super.tearDownWithError()
    }

    func testResolveThrowsWhenNoVaultConfigured() {
        XCTAssertThrowsError(try VaultBookmarkStore.resolve()) { error in
            XCTAssertEqual(error as? VaultAccessError, .notConfigured)
        }
    }

    func testSaveThenResolveRoundTrips() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try VaultBookmarkStore.save(url: temp)
        XCTAssertNotNil(AppSettings.vaultBookmark)

        let resolved = try VaultBookmarkStore.resolve()
        XCTAssertEqual(resolved.standardizedFileURL.path, temp.standardizedFileURL.path)
    }

    func testClearRemovesBookmark() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try VaultBookmarkStore.save(url: temp)
        VaultBookmarkStore.clear()
        XCTAssertNil(AppSettings.vaultBookmark)
        XCTAssertThrowsError(try VaultBookmarkStore.resolve())
    }

    func testWithAccessHandsBackTheVaultURL() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try VaultBookmarkStore.save(url: temp)
        let path = try VaultBookmarkStore.withAccess { $0.standardizedFileURL.path }
        XCTAssertEqual(path, temp.standardizedFileURL.path)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultBookmarkStoreTests`
Expected: compile failure — `cannot find 'VaultBookmarkStore' in scope`.

- [ ] **Step 3: Add the AppSettings storage**

In `MemosIOS/Storage/AppSettings.swift`, add `static let vaultBookmark = "vaultBookmark"` to the private `Keys` enum, then add this property alongside the others:

```swift
    static var vaultBookmark: Data? {
        get { defaults.data(forKey: Keys.vaultBookmark) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.vaultBookmark)
            } else {
                defaults.removeObject(forKey: Keys.vaultBookmark)
            }
        }
    }
```

- [ ] **Step 4: Write the bookmark store**

```swift
import Foundation

/// The spec routes "bookmark stale / vault moved" and "folder access revoked" to
/// identical handling ("Same path" — the Reconnect vault banner), so there is no
/// separate access-denied case: `.stale` covers every resolution failure, including
/// a revoked permission or corrupted bookmark data.
enum VaultAccessError: LocalizedError, Equatable {
    case notConfigured
    case stale

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No vault folder has been selected yet."
        case .stale:
            return "MemoChat can't access the vault folder anymore. Reconnect it in Settings."
        }
    }
}

/// Persists the user's vault folder as a security-scoped bookmark.
///
/// Bookmarks go stale after a restore-from-backup or when the folder moves, so
/// `.stale` is an expected condition the UI surfaces as "Reconnect vault" —
/// never a silent failure.
enum VaultBookmarkStore {

    static func save(url: URL) throws {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        AppSettings.vaultBookmark = data
    }

    static func resolve() throws -> URL {
        guard let data = AppSettings.vaultBookmark else {
            throw VaultAccessError.notConfigured
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            throw VaultAccessError.stale
        }

        if isStale {
            // Refresh opportunistically; if the folder is still reachable the
            // user never learns anything went wrong.
            if (try? save(url: url)) == nil {
                throw VaultAccessError.stale
            }
        }
        return url
    }

    static func clear() {
        AppSettings.vaultBookmark = nil
    }

    /// Resolves the vault and runs `body` inside a balanced security scope.
    static func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolve()
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
```

- [ ] **Step 5: Run the tests**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultBookmarkStoreTests
```
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add MemosIOS/Services/Vault/VaultBookmarkStore.swift MemosIOS/Storage/AppSettings.swift MemosIOSTests/VaultBookmarkStoreTests.swift MemosIOS.xcodeproj
git commit -m "feat: persist vault folder as a security-scoped bookmark"
```

---

### Task 4: Vault file store

All file I/O, including conflict detection. Takes its root as an injected `URL`, so tests run against a temp directory and never need a real vault.

**Files:**
- Create: `MemosIOS/Services/Vault/VaultFileStore.swift`
- Test: `MemosIOSTests/VaultFileStoreTests.swift`

**Interfaces:**
- Consumes: `VaultNote`, `VaultNoteSerializer`, `Frontmatter` (Tasks 1–2).
- Produces:
  - `struct VaultFileMetadata: Codable, Equatable` — `relativePath: String`, `modifiedAt: Date`, `fileSize: Int`
  - `enum VaultWriteResult: Equatable` — `.written(VaultFileMetadata)`, `.conflictCopy(path: String, metadata: VaultFileMetadata)`
  - `struct VaultFileStore` with `init(root: URL)`
  - `func listMarkdownFiles() throws -> [VaultFileMetadata]`
  - `func read(relativePath: String) throws -> VaultNote`
  - `func write(_ text: String, to relativePath: String) throws -> VaultFileMetadata`
  - `func writeChecked(_ text: String, to relativePath: String, expecting: VaultFileMetadata) throws -> VaultWriteResult`
  - `func delete(relativePath: String) throws`
  - `func existingFilenames(inSubfolder: String) throws -> Set<String>`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

final class VaultFileStoreTests: XCTestCase {

    private var root: URL!
    private var store: VaultFileStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultFileStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func writeFile(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testListsOnlyMarkdownFiles() throws {
        try writeFile("one.md", "# One\n")
        try writeFile("two.md", "# Two\n")
        try writeFile("image.png", "not markdown")

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(Set(files.map(\.relativePath)), ["one.md", "two.md"])
    }

    func testListsMarkdownFilesInSubfolders() throws {
        let nested = root.appendingPathComponent("daily", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Nested\n".write(to: nested.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(files.map(\.relativePath), ["daily/note.md"])
    }

    func testListSkipsObsidianConfigFolder() throws {
        let config = root.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "{}".write(to: config.appendingPathComponent("workspace.md"), atomically: true, encoding: .utf8)
        try writeFile("real.md", "# Real\n")

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(files.map(\.relativePath), ["real.md"])
    }

    func testReadSplitsFrontmatterFromBody() throws {
        try writeFile("note.md", "---\ntitle: Hello\n---\nBody text\n")
        let note = try store.read(relativePath: "note.md")
        XCTAssertEqual(note.relativePath, "note.md")
        XCTAssertEqual(note.body, "Body text\n")
        XCTAssertEqual(note.frontmatter?.value(for: "title"), "Hello")
        XCTAssertGreaterThan(note.fileSize, 0)
    }

    func testWriteCreatesFileAndReturnsMetadata() throws {
        let metadata = try store.write("# New\n", to: "new.md")
        XCTAssertEqual(metadata.relativePath, "new.md")
        let onDisk = try String(contentsOf: root.appendingPathComponent("new.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "# New\n")
    }

    func testWriteCreatesIntermediateDirectories() throws {
        _ = try store.write("# Nested\n", to: "inbox/deep/note.md")
        let onDisk = try String(contentsOf: root.appendingPathComponent("inbox/deep/note.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "# Nested\n")
    }

    func testWriteCheckedWritesWhenFileUnchanged() throws {
        try writeFile("note.md", "original\n")
        let metadata = try store.listMarkdownFiles().first { $0.relativePath == "note.md" }!

        let result = try store.writeChecked("updated\n", to: "note.md", expecting: metadata)
        guard case .written = result else {
            return XCTFail("expected .written, got \(result)")
        }
        let onDisk = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "updated\n")
    }

    /// The whole point of the conflict policy: the external edit survives.
    func testWriteCheckedMakesConflictCopyWhenFileChangedExternally() throws {
        try writeFile("note.md", "original\n")
        let stale = VaultFileMetadata(
            relativePath: "note.md",
            modifiedAt: Date(timeIntervalSince1970: 0),
            fileSize: 999
        )

        let result = try store.writeChecked("mine\n", to: "note.md", expecting: stale)
        guard case .conflictCopy(let path, _) = result else {
            return XCTFail("expected .conflictCopy, got \(result)")
        }
        XCTAssertTrue(path.hasPrefix("note (conflict "))
        XCTAssertTrue(path.hasSuffix(").md"))

        // Original untouched, ours saved alongside it.
        let original = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertEqual(original, "original\n")
        let copy = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        XCTAssertEqual(copy, "mine\n")
    }

    /// A note deleted on the desktop must not be resurrected at its old path.
    func testWriteCheckedOnMissingFileWritesFresh() throws {
        let stale = VaultFileMetadata(
            relativePath: "gone.md",
            modifiedAt: Date(timeIntervalSince1970: 0),
            fileSize: 10
        )
        let result = try store.writeChecked("text\n", to: "gone.md", expecting: stale)
        guard case .written = result else {
            return XCTFail("expected .written, got \(result)")
        }
    }

    func testDeleteRemovesFile() throws {
        try writeFile("bye.md", "x\n")
        try store.delete(relativePath: "bye.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bye.md").path))
    }

    func testExistingFilenamesInSubfolder() throws {
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try "a".write(to: inbox.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try store.existingFilenames(inSubfolder: "inbox"), ["one.md"])
        XCTAssertEqual(try store.existingFilenames(inSubfolder: "missing"), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultFileStoreTests`
Expected: compile failure — `cannot find 'VaultFileStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

struct VaultFileMetadata: Codable, Equatable {
    let relativePath: String
    let modifiedAt: Date
    let fileSize: Int
}

enum VaultWriteResult: Equatable {
    case written(VaultFileMetadata)
    case conflictCopy(path: String, metadata: VaultFileMetadata)
}

/// Every byte MemoChat reads from or writes to the vault goes through here.
///
/// `root` is injected rather than resolved internally so the whole type is
/// testable against a temp directory — no bookmark, no simulator state, no
/// real vault.
struct VaultFileStore {

    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    // MARK: - Listing

    /// Metadata for every `.md` file in the vault, recursively.
    ///
    /// Deliberately metadata-only: content is never read here. In an iCloud
    /// vault most files may be `.notDownloaded`, and materializing all of them
    /// just to draw a list is unacceptable. VaultIndex decides what to read.
    func listMarkdownFiles() throws -> [VaultFileMetadata] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [VaultFileMetadata] = []
        for case let url as URL in enumerator {
            // .obsidian holds vault config, not notes.
            if url.pathComponents.contains(".obsidian") {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let relativePath = relativePath(for: url) else { continue }
            results.append(try metadata(for: url, relativePath: relativePath))
        }
        return results
    }

    func existingFilenames(inSubfolder subfolder: String) throws -> Set<String> {
        let folder = subfolder.isEmpty ? root : root.appendingPathComponent(subfolder, isDirectory: true)
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        let names = try fileManager.contentsOfDirectory(atPath: folder.path)
        return Set(names)
    }

    // MARK: - Reading

    func read(relativePath: String) throws -> VaultNote {
        let url = root.appendingPathComponent(relativePath)
        var text = ""
        var coordinationError: NSError?
        var readError: Error?

        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                text = try String(contentsOf: readURL, encoding: .utf8)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }

        let (frontmatter, body) = Frontmatter.parse(text)
        let meta = try metadata(for: url, relativePath: relativePath)
        return VaultNote(
            relativePath: relativePath,
            frontmatter: frontmatter,
            body: body,
            modifiedAt: meta.modifiedAt,
            fileSize: meta.fileSize
        )
    }

    // MARK: - Writing

    @discardableResult
    func write(_ text: String, to relativePath: String) throws -> VaultFileMetadata {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            do {
                try text.write(to: writeURL, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }

        return try metadata(for: url, relativePath: relativePath)
    }

    /// Writes only if the file still matches `expecting`. If it changed
    /// externally, the in-app version is saved beside it as a conflict copy and
    /// the external edit is left untouched — the Dropbox/Obsidian Sync
    /// convention. Never prompts, never clobbers.
    func writeChecked(
        _ text: String,
        to relativePath: String,
        expecting: VaultFileMetadata
    ) throws -> VaultWriteResult {
        let url = root.appendingPathComponent(relativePath)

        guard fileManager.fileExists(atPath: url.path) else {
            // Deleted externally: write fresh rather than resurrect the path.
            return .written(try write(text, to: relativePath))
        }

        let current = try metadata(for: url, relativePath: relativePath)
        let unchanged = abs(current.modifiedAt.timeIntervalSince(expecting.modifiedAt)) < 1
            && current.fileSize == expecting.fileSize

        if unchanged {
            return .written(try write(text, to: relativePath))
        }

        let conflictPath = Self.conflictPath(for: relativePath, at: Date())
        let metadata = try write(text, to: conflictPath)
        return .conflictCopy(path: conflictPath, metadata: metadata)
    }

    func delete(relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { deleteURL in
            do {
                try fileManager.removeItem(at: deleteURL)
            } catch {
                deleteError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let deleteError { throw deleteError }
    }

    // MARK: - Helpers

    static func conflictPath(for relativePath: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: date)

        let path = relativePath as NSString
        let directory = path.deletingLastPathComponent
        let stem = (path.lastPathComponent as NSString).deletingPathExtension
        let name = "\(stem) (conflict \(stamp)).md"
        return directory.isEmpty ? name : "\(directory)/\(name)"
    }

    private func relativePath(for url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func metadata(for url: URL, relativePath: String) throws -> VaultFileMetadata {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return VaultFileMetadata(
            relativePath: relativePath,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            fileSize: values.fileSize ?? 0
        )
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultFileStoreTests
```
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add MemosIOS/Services/Vault/VaultFileStore.swift MemosIOSTests/VaultFileStoreTests.swift MemosIOS.xcodeproj
git commit -m "feat: add vault file store with conflict-copy writes"
```

---

### Task 5: Vault index

Solves the iCloud materialization problem. The drawer must render instantly at launch without downloading the vault, so titles and previews come from a persisted index and content is read only for files that actually changed.

Mirrors the existing `MemoCache` pattern in `MemosIOS/Storage/MemoCache.swift`.

**Files:**
- Create: `MemosIOS/Services/Vault/VaultIndex.swift`
- Test: `MemosIOSTests/VaultIndexTests.swift`

**Interfaces:**
- Consumes: `VaultFileMetadata` (Task 4), `VaultNote` (Task 2).
- Produces:
  - `struct VaultIndexEntry: Codable, Equatable, Identifiable` — `relativePath`, `title`, `preview`, `tags: [String]`, `modifiedAt`, `fileSize`; `var id: String { relativePath }`
  - `static func VaultIndexEntry.make(from: VaultNote) -> VaultIndexEntry`
  - `struct VaultIndexDiff: Equatable` — `needsRead: [String]`, `unchanged: [VaultIndexEntry]`, `removed: [String]`
  - `enum VaultIndex` with `static func load() -> [VaultIndexEntry]`, `static func save(_:)`, `static func diff(index:disk:) -> VaultIndexDiff`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

final class VaultIndexTests: XCTestCase {

    private func entry(_ path: String, modified: TimeInterval, size: Int) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: path,
            title: "Title",
            preview: "Preview",
            tags: [],
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: size
        )
    }

    private func metadata(_ path: String, modified: TimeInterval, size: Int) -> VaultFileMetadata {
        VaultFileMetadata(
            relativePath: path,
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: size
        )
    }

    func testUnchangedFilesAreNotReRead() {
        let index = [entry("a.md", modified: 100, size: 10)]
        let disk = [metadata("a.md", modified: 100, size: 10)]
        let diff = VaultIndex.diff(index: index, disk: disk)

        XCTAssertTrue(diff.needsRead.isEmpty)
        XCTAssertEqual(diff.unchanged.map(\.relativePath), ["a.md"])
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testNewFileNeedsRead() {
        let diff = VaultIndex.diff(index: [], disk: [metadata("new.md", modified: 100, size: 10)])
        XCTAssertEqual(diff.needsRead, ["new.md"])
    }

    func testModifiedDateChangeNeedsRead() {
        let index = [entry("a.md", modified: 100, size: 10)]
        let disk = [metadata("a.md", modified: 200, size: 10)]
        XCTAssertEqual(VaultIndex.diff(index: index, disk: disk).needsRead, ["a.md"])
    }

    func testSizeChangeNeedsRead() {
        let index = [entry("a.md", modified: 100, size: 10)]
        let disk = [metadata("a.md", modified: 100, size: 99)]
        XCTAssertEqual(VaultIndex.diff(index: index, disk: disk).needsRead, ["a.md"])
    }

    func testFileGoneFromDiskIsRemoved() {
        let index = [entry("a.md", modified: 100, size: 10)]
        let diff = VaultIndex.diff(index: index, disk: [])
        XCTAssertEqual(diff.removed, ["a.md"])
        XCTAssertTrue(diff.unchanged.isEmpty)
    }

    func testEntryFromNoteCapturesTitleTagsAndPreview() {
        let (frontmatter, body) = Frontmatter.parse("---\ntitle: My Note\n---\nFirst line\nSecond line with #inbox\n")
        let note = VaultNote(
            relativePath: "a.md",
            frontmatter: frontmatter,
            body: body,
            modifiedAt: Date(timeIntervalSince1970: 100),
            fileSize: 42
        )
        let made = VaultIndexEntry.make(from: note)
        XCTAssertEqual(made.title, "My Note")
        XCTAssertEqual(made.tags, ["inbox"])
        XCTAssertEqual(made.preview, "Second line with #inbox")
        XCTAssertEqual(made.fileSize, 42)
    }

    func testSaveThenLoadRoundTrips() {
        let entries = [entry("a.md", modified: 100, size: 10)]
        VaultIndex.save(entries)
        // save() writes synchronously to Application Support.
        XCTAssertEqual(VaultIndex.load(), entries)
        VaultIndex.save([])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultIndexTests`
Expected: compile failure — `cannot find 'VaultIndex' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// What the drawer needs to draw a row, without the file's content.
struct VaultIndexEntry: Codable, Equatable, Identifiable {
    let relativePath: String
    let title: String
    let preview: String
    let tags: [String]
    let modifiedAt: Date
    let fileSize: Int

    var id: String { relativePath }

    static func make(from note: VaultNote) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: note.relativePath,
            title: note.title,
            preview: Self.preview(forBody: note.body),
            tags: note.tags,
            modifiedAt: note.modifiedAt,
            fileSize: note.fileSize
        )
    }

    /// The first body line after the title line, matching UnifiedNote.preview.
    private static func preview(forBody body: String) -> String {
        var pastTitle = false
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !pastTitle {
                if !trimmed.isEmpty { pastTitle = true }
                continue
            }
            if !trimmed.isEmpty { return trimmed }
        }
        return "No additional text"
    }
}

struct VaultIndexDiff: Equatable {
    let needsRead: [String]
    let unchanged: [VaultIndexEntry]
    let removed: [String]
}

/// A persisted index of the vault, so the drawer renders instantly at launch
/// and content is downloaded only for files that actually changed.
///
/// In an iCloud vault a file may be `.notDownloaded`; reading its content
/// forces a download. Diffing on cheap metadata keeps that to the minimum.
enum VaultIndex {
    private static let filename = "vault_index_v1.json"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static var indexURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(filename)
    }

    static func load() -> [VaultIndexEntry] {
        guard let url = indexURL,
              let data = try? Data(contentsOf: url),
              let entries = try? decoder.decode([VaultIndexEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func save(_ entries: [VaultIndexEntry]) {
        guard let url = indexURL, let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Compares the persisted index against a metadata-only directory listing.
    /// A one-second tolerance on modification dates absorbs filesystem
    /// timestamp granularity differences across file providers.
    static func diff(index: [VaultIndexEntry], disk: [VaultFileMetadata]) -> VaultIndexDiff {
        let indexByPath = Dictionary(index.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let diskPaths = Set(disk.map(\.relativePath))

        var needsRead: [String] = []
        var unchanged: [VaultIndexEntry] = []

        for file in disk {
            guard let existing = indexByPath[file.relativePath] else {
                needsRead.append(file.relativePath)
                continue
            }
            let sameDate = abs(existing.modifiedAt.timeIntervalSince(file.modifiedAt)) < 1
            if sameDate && existing.fileSize == file.fileSize {
                unchanged.append(existing)
            } else {
                needsRead.append(file.relativePath)
            }
        }

        let removed = index.map(\.relativePath).filter { !diskPaths.contains($0) }
        return VaultIndexDiff(needsRead: needsRead, unchanged: unchanged, removed: removed)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultIndexTests
```
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add MemosIOS/Services/Vault/VaultIndex.swift MemosIOSTests/VaultIndexTests.swift MemosIOS.xcodeproj
git commit -m "feat: add vault index for instant launch without materializing files"
```

---

### Task 6: Destination settings and router

The switch that decides where a note goes. Small, but it's the seam the whole design rests on, so it gets its own review gate.

**Files:**
- Create: `MemoChat/Services/NoteDestination.swift`
- Modify: `MemosIOS/Storage/AppSettings.swift`
- Test: `MemosIOSTests/DestinationSettingsTests.swift`

**Interfaces:**
- Consumes: `AppSettings` (existing).
- Produces:
  - `enum DestinationKind: String, CaseIterable, Identifiable` — `.memos`, `.vault`; `var label: String`
  - `AppSettings.destinationKind: DestinationKind`
  - `AppSettings.vaultNotesFolder: String` (default `""` = vault root)
  - `AppSettings.vaultAttachmentsFolder: String` (default `"attachments"`)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

final class DestinationSettingsTests: XCTestCase {

    private var original: (DestinationKind, String, String)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        original = (AppSettings.destinationKind, AppSettings.vaultNotesFolder, AppSettings.vaultAttachmentsFolder)
    }

    override func tearDownWithError() throws {
        AppSettings.destinationKind = original.0
        AppSettings.vaultNotesFolder = original.1
        AppSettings.vaultAttachmentsFolder = original.2
        try super.tearDownWithError()
    }

    func testDefaultDestinationIsMemos() {
        UserDefaults.standard.removeObject(forKey: "destinationKind")
        XCTAssertEqual(AppSettings.destinationKind, .memos)
    }

    func testDestinationRoundTrips() {
        AppSettings.destinationKind = .vault
        XCTAssertEqual(AppSettings.destinationKind, .vault)
    }

    func testFolderDefaults() {
        UserDefaults.standard.removeObject(forKey: "vaultNotesFolder")
        UserDefaults.standard.removeObject(forKey: "vaultAttachmentsFolder")
        XCTAssertEqual(AppSettings.vaultNotesFolder, "")
        XCTAssertEqual(AppSettings.vaultAttachmentsFolder, "attachments")
    }

    func testFolderSettingsStripSlashes() {
        AppSettings.vaultNotesFolder = "/inbox/"
        XCTAssertEqual(AppSettings.vaultNotesFolder, "inbox")
    }

    func testAllKindsHaveLabels() {
        for kind in DestinationKind.allCases {
            XCTAssertFalse(kind.label.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/DestinationSettingsTests`
Expected: compile failure — `cannot find 'DestinationKind' in scope`.

- [ ] **Step 3: Write the destination type**

Create `MemoChat/Services/NoteDestination.swift`:

```swift
import Foundation

/// Where notes go. One destination is active at a time — the app never
/// dual-writes, so there is no reconciliation between the two.
enum DestinationKind: String, CaseIterable, Identifiable {
    case memos
    case vault

    var id: String { rawValue }

    var label: String {
        switch self {
        case .memos: return "Memos Server"
        case .vault: return "Obsidian Vault"
        }
    }
}
```

- [ ] **Step 4: Add the settings**

In `MemosIOS/Storage/AppSettings.swift`, add to the private `Keys` enum:

```swift
        static let destinationKind = "destinationKind"
        static let vaultNotesFolder = "vaultNotesFolder"
        static let vaultAttachmentsFolder = "vaultAttachmentsFolder"
```

Then add these properties:

```swift
    static var destinationKind: DestinationKind {
        get {
            guard let raw = defaults.string(forKey: Keys.destinationKind),
                  let kind = DestinationKind(rawValue: raw)
            else { return .memos }
            return kind
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.destinationKind) }
    }

    /// Subfolder new notes are written into. Empty means the vault root.
    /// Stored without leading or trailing slashes so path joining stays simple.
    static var vaultNotesFolder: String {
        get { defaults.string(forKey: Keys.vaultNotesFolder) ?? "" }
        set { defaults.set(Self.normalizedFolder(newValue), forKey: Keys.vaultNotesFolder) }
    }

    static var vaultAttachmentsFolder: String {
        get { defaults.string(forKey: Keys.vaultAttachmentsFolder) ?? "attachments" }
        set { defaults.set(Self.normalizedFolder(newValue), forKey: Keys.vaultAttachmentsFolder) }
    }

    private static func normalizedFolder(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
```

- [ ] **Step 5: Run the tests**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/DestinationSettingsTests
```
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add MemoChat/Services/NoteDestination.swift MemosIOS/Storage/AppSettings.swift MemosIOSTests/DestinationSettingsTests.swift MemosIOS.xcodeproj
git commit -m "feat: add destination kind and vault folder settings"
```

---

### Task 7: Vault store

The `ServerMemosStore` analogue: an observable list the views consume, backed by index + files. No queue — a file write succeeds or fails now, and retrying a stale bookmark in fifteen seconds fixes nothing.

**Files:**
- Create: `MemosIOS/Services/Vault/VaultStore.swift`
- Test: `MemosIOSTests/VaultStoreTests.swift`

**Interfaces:**
- Consumes: `VaultFileStore`, `VaultIndex`, `VaultIndexEntry`, `VaultNote`, `VaultNoteSerializer`, `VaultBookmarkStore`, `VaultAccessError`, `AppSettings.vaultNotesFolder`.
- Produces:
  - `@MainActor final class VaultStore: ObservableObject`
  - `@Published private(set) var entries: [VaultIndexEntry]`
  - `@Published private(set) var isLoading: Bool`
  - `@Published var errorMessage: String?`
  - `@Published private(set) var lastConflictPath: String?`
  - `init(storeProvider: @escaping () throws -> VaultFileStore = VaultStore.bookmarkStoreProvider)`
  - `func loadFromIndex()`
  - `func refresh() async`
  - `func refreshIfStale(maxAge: TimeInterval) async`
  - `func create(body: String, now: Date) throws -> VaultIndexEntry`
  - `func read(relativePath: String) throws -> VaultNote`
  - `func update(note: VaultNote, body: String, now: Date) throws -> VaultWriteResult`
  - `func delete(relativePath: String) throws`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

@MainActor
final class VaultStoreTests: XCTestCase {

    private var root: URL!
    private var store: VaultStore!
    private var originalNotesFolder: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        originalNotesFolder = AppSettings.vaultNotesFolder
        AppSettings.vaultNotesFolder = ""
        let fileStore = VaultFileStore(root: root)
        store = VaultStore(storeProvider: { fileStore })
        VaultIndex.save([])
    }

    override func tearDownWithError() throws {
        AppSettings.vaultNotesFolder = originalNotesFolder
        VaultIndex.save([])
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testCreateWritesFileWithFrontmatter() throws {
        let entry = try store.create(body: "Hello #inbox\n", now: Date())

        let onDisk = try String(contentsOf: root.appendingPathComponent(entry.relativePath), encoding: .utf8)
        XCTAssertTrue(onDisk.hasPrefix("---\n"))
        XCTAssertTrue(onDisk.contains("tags: [inbox]\n"))
        XCTAssertTrue(onDisk.hasSuffix("Hello #inbox\n"))
        XCTAssertEqual(store.entries.first?.relativePath, entry.relativePath)
    }

    func testCreateHonoursNotesSubfolder() throws {
        AppSettings.vaultNotesFolder = "inbox"
        let entry = try store.create(body: "In a folder\n", now: Date())
        XCTAssertTrue(entry.relativePath.hasPrefix("inbox/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.relativePath).path))
    }

    func testRefreshPicksUpExternallyCreatedFiles() async throws {
        try "---\ntitle: External\n---\nMade on the desktop\n"
            .write(to: root.appendingPathComponent("external.md"), atomically: true, encoding: .utf8)

        await store.refresh()

        XCTAssertEqual(store.entries.map(\.relativePath), ["external.md"])
        XCTAssertEqual(store.entries.first?.title, "External")
    }

    func testRefreshDropsDeletedFiles() async throws {
        let entry = try store.create(body: "Temporary\n", now: Date())
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.relativePath))

        await store.refresh()

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testUpdateRewritesBodyAndBumpsUpdated() throws {
        let entry = try store.create(body: "Original\n", now: Date(timeIntervalSince1970: 1_000_000))
        let note = try store.read(relativePath: entry.relativePath)

        let result = try store.update(note: note, body: "Revised\n", now: Date(timeIntervalSince1970: 2_000_000))
        guard case .written = result else {
            return XCTFail("expected .written, got \(result)")
        }

        let onDisk = try String(contentsOf: root.appendingPathComponent(entry.relativePath), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Revised\n"))
        XCTAssertTrue(onDisk.contains("updated: 1970-01-24T"))
    }

    func testUpdateAfterExternalChangeMakesConflictCopy() throws {
        let entry = try store.create(body: "Mine\n", now: Date())
        let note = try store.read(relativePath: entry.relativePath)

        // Simulate a desktop edit after we loaded the note.
        try "---\ntitle: Theirs\n---\nTheirs\n"
            .write(to: root.appendingPathComponent(entry.relativePath), atomically: true, encoding: .utf8)

        let result = try store.update(note: note, body: "Mine revised\n", now: Date())
        guard case .conflictCopy(let path, _) = result else {
            return XCTFail("expected .conflictCopy, got \(result)")
        }
        XCTAssertEqual(store.lastConflictPath, path)

        let theirs = try String(contentsOf: root.appendingPathComponent(entry.relativePath), encoding: .utf8)
        XCTAssertTrue(theirs.contains("Theirs\n"))
    }

    func testDeleteRemovesFileAndEntry() throws {
        let entry = try store.create(body: "Bye\n", now: Date())
        try store.delete(relativePath: entry.relativePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.relativePath).path))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRefreshSurfacesMissingVaultAsErrorMessage() async {
        let failing = VaultStore(storeProvider: { throw VaultAccessError.notConfigured })
        await failing.refresh()
        XCTAssertNotNil(failing.errorMessage)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultStoreTests`
Expected: compile failure — `cannot find 'VaultStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import SwiftUI

/// The vault's answer to ServerMemosStore: an observable list of notes the
/// views render, backed by the persisted index and the file store.
///
/// Deliberately queue-free. Network writes deserve retry and backoff; file
/// writes fail structurally — a stale bookmark is not fixed by trying again in
/// fifteen seconds — so failures surface as messages instead.
@MainActor
final class VaultStore: ObservableObject {

    @Published private(set) var entries: [VaultIndexEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Set when a save had to go to a conflict copy, so the UI can say so.
    @Published private(set) var lastConflictPath: String?

    private let storeProvider: () throws -> VaultFileStore
    private var lastRefreshAt: Date?

    /// Resolves the file store through the user's saved bookmark. Tests inject
    /// a temp-directory store instead.
    static let bookmarkStoreProvider: () throws -> VaultFileStore = {
        VaultFileStore(root: try VaultBookmarkStore.resolve())
    }

    init(storeProvider: @escaping () throws -> VaultFileStore = VaultStore.bookmarkStoreProvider) {
        self.storeProvider = storeProvider
    }

    // MARK: - Loading

    /// Renders the drawer from the persisted index — no I/O wait, no download.
    func loadFromIndex() {
        guard entries.isEmpty else { return }
        entries = VaultIndex.load().sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < maxAge { return }
        await refresh()
    }

    /// Reconciles the index against the vault, reading content only for files
    /// that are new or changed.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let fileStore = try storeProvider()
            let onDisk = try fileStore.listMarkdownFiles()
            let diff = VaultIndex.diff(index: VaultIndex.load(), disk: onDisk)

            var refreshed = diff.unchanged
            for path in diff.needsRead {
                // A single unreadable file must not abort the whole refresh:
                // in an iCloud vault a download can fail transiently.
                guard let note = try? fileStore.read(relativePath: path) else { continue }
                refreshed.append(VaultIndexEntry.make(from: note))
            }

            refreshed.sort { $0.modifiedAt > $1.modifiedAt }
            entries = refreshed
            VaultIndex.save(refreshed)
            lastRefreshAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Writing

    @discardableResult
    func create(body: String, now: Date = Date()) throws -> VaultIndexEntry {
        let fileStore = try storeProvider()
        let folder = AppSettings.vaultNotesFolder
        let existing = try fileStore.existingFilenames(inSubfolder: folder)
        let filename = VaultNoteSerializer.filename(for: now, existing: existing)
        let relativePath = folder.isEmpty ? filename : "\(folder)/\(filename)"

        let text = VaultNoteSerializer.render(body: body, existing: nil, created: now, updated: now)
        let metadata = try fileStore.write(text, to: relativePath)

        let (frontmatter, parsedBody) = Frontmatter.parse(text)
        let note = VaultNote(
            relativePath: relativePath,
            frontmatter: frontmatter,
            body: parsedBody,
            modifiedAt: metadata.modifiedAt,
            fileSize: metadata.fileSize
        )
        let entry = VaultIndexEntry.make(from: note)
        upsert(entry)
        return entry
    }

    func read(relativePath: String) throws -> VaultNote {
        try storeProvider().read(relativePath: relativePath)
    }

    /// Saves an edit, preserving unknown frontmatter and writing a conflict
    /// copy if the file changed externally since `note` was read.
    @discardableResult
    func update(note: VaultNote, body: String, now: Date = Date()) throws -> VaultWriteResult {
        let fileStore = try storeProvider()
        let text = VaultNoteSerializer.render(
            body: body,
            existing: note.frontmatter,
            created: note.frontmatter.flatMap { fm in
                fm.value(for: "created").flatMap(VaultNoteSerializer.iso8601.date(from:))
            } ?? now,
            updated: now
        )

        let expecting = VaultFileMetadata(
            relativePath: note.relativePath,
            modifiedAt: note.modifiedAt,
            fileSize: note.fileSize
        )
        let result = try fileStore.writeChecked(text, to: note.relativePath, expecting: expecting)

        switch result {
        case .written(let metadata):
            lastConflictPath = nil
            upsert(entry(from: text, path: metadata.relativePath, metadata: metadata))
        case .conflictCopy(let path, let metadata):
            lastConflictPath = path
            upsert(entry(from: text, path: path, metadata: metadata))
        }
        return result
    }

    func delete(relativePath: String) throws {
        try storeProvider().delete(relativePath: relativePath)
        entries.removeAll { $0.relativePath == relativePath }
        VaultIndex.save(entries)
    }

    // MARK: - Helpers

    private func entry(from text: String, path: String, metadata: VaultFileMetadata) -> VaultIndexEntry {
        let (frontmatter, body) = Frontmatter.parse(text)
        return VaultIndexEntry.make(from: VaultNote(
            relativePath: path,
            frontmatter: frontmatter,
            body: body,
            modifiedAt: metadata.modifiedAt,
            fileSize: metadata.fileSize
        ))
    }

    private func upsert(_ entry: VaultIndexEntry) {
        entries.removeAll { $0.relativePath == entry.relativePath }
        entries.append(entry)
        entries.sort { $0.modifiedAt > $1.modifiedAt }
        VaultIndex.save(entries)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultStoreTests
```
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add MemosIOS/Services/Vault/VaultStore.swift MemosIOSTests/VaultStoreTests.swift MemosIOS.xcodeproj
git commit -m "feat: add VaultStore backed by index and file store"
```

---

### Task 8: UnifiedNote vault case

Lets the existing history list render vault notes without knowing what a vault is.

**Files:**
- Modify: `MemoChat/ViewModels/UnifiedNote.swift`
- Test: `MemosIOSTests/UnifiedNoteVaultTests.swift`

**Interfaces:**
- Consumes: `VaultIndexEntry` (Task 5).
- Produces:
  - `UnifiedNote.vault(VaultIndexEntry)` case
  - `NoteEditorTarget.vaultFile(String)` case
  - `static func UnifiedNote.merge(vaultEntries:drafts:excludeDraftID:) -> [UnifiedNote]`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

final class UnifiedNoteVaultTests: XCTestCase {

    private func entry(_ path: String, title: String, modified: TimeInterval, tags: [String] = []) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: path,
            title: title,
            preview: "preview",
            tags: tags,
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: 10
        )
    }

    func testVaultNoteExposesTitleDateAndTags() {
        let note = UnifiedNote.vault(entry("a.md", title: "Hello", modified: 500, tags: ["inbox"]))
        XCTAssertEqual(note.title, "Hello")
        XCTAssertEqual(note.date, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(note.tags, ["inbox"])
        XCTAssertEqual(note.id, "v-a.md")
    }

    func testVaultNoteEditorTargetIsVaultFile() {
        let note = UnifiedNote.vault(entry("folder/a.md", title: "Hello", modified: 500))
        XCTAssertEqual(note.editorTarget, .vaultFile("folder/a.md"))
    }

    func testMergeSortsVaultEntriesNewestFirst() {
        let notes = UnifiedNote.merge(
            vaultEntries: [
                entry("old.md", title: "Old", modified: 100),
                entry("new.md", title: "New", modified: 900)
            ],
            drafts: []
        )
        XCTAssertEqual(notes.map(\.title), ["New", "Old"])
    }

    func testMergeIncludesUnsentLocalDrafts() {
        let draft = Draft(text: "Unsent local note")
        let notes = UnifiedNote.merge(
            vaultEntries: [entry("a.md", title: "Filed", modified: 100)],
            drafts: [draft]
        )
        XCTAssertEqual(Set(notes.map(\.title)), ["Filed", "Unsent local note"])
    }

    func testMergeExcludesBlankAndArchivedDrafts() {
        let blank = Draft(text: "   ")
        let archived = Draft(text: "Already filed")
        archived.isArchived = true

        let notes = UnifiedNote.merge(vaultEntries: [], drafts: [blank, archived])
        XCTAssertTrue(notes.isEmpty)
    }

    func testMergeExcludesTheDraftBeingComposed() {
        let composing = Draft(text: "Still typing")
        let notes = UnifiedNote.merge(vaultEntries: [], drafts: [composing], excludeDraftID: composing.id)
        XCTAssertTrue(notes.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/UnifiedNoteVaultTests`
Expected: compile failure — `type 'UnifiedNote' has no member 'vault'`.

- [ ] **Step 3: Extend UnifiedNote**

In `MemoChat/ViewModels/UnifiedNote.swift`, add a case to `NoteEditorTarget`:

```swift
enum NoteEditorTarget: Hashable {
    case newNote
    case localDraft(UUID)
    case serverMemo(String) // memoID
    case vaultFile(String)  // relative path inside the vault
}
```

Add the case to the enum itself:

```swift
enum UnifiedNote: Identifiable {
    case local(Draft)
    case server(ServerMemoSummary, editDraft: ServerMemoEditDraft?)
    case vault(VaultIndexEntry)
```

Then extend each existing computed property with a `.vault` branch:

```swift
    var id: String {
        switch self {
        case .local(let draft): return "d-\(draft.id.uuidString)"
        case .server(let memo, _): return "m-\(memo.id)"
        case .vault(let entry): return "v-\(entry.relativePath)"
        }
    }

    var editorTarget: NoteEditorTarget {
        switch self {
        case .local(let draft): return .localDraft(draft.id)
        case .server(let memo, _): return .serverMemo(memo.id)
        case .vault(let entry): return .vaultFile(entry.relativePath)
        }
    }

    var content: String {
        switch self {
        case .local(let draft):
            return draft.text
        case .server(let memo, let editDraft):
            if let ed = editDraft, ed.hasLocalChanges {
                let local = ed.localContent.trimmingCharacters(in: .whitespacesAndNewlines)
                return local.isEmpty ? memo.preferredDisplayText : local
            }
            return memo.preferredDisplayText
        case .vault(let entry):
            // The index holds no body — the list only needs title and preview,
            // and reading content here would force an iCloud download per row.
            return "\(entry.title)\n\(entry.preview)"
        }
    }

    var title: String {
        if case .vault(let entry) = self { return entry.title }
        let lines = content.components(separatedBy: "\n")
        let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        var line = firstNonEmpty
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "New Note" : line
    }

    var preview: String {
        if case .vault(let entry) = self { return entry.preview }
        let lines = content.components(separatedBy: "\n")
        var pastTitle = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !pastTitle {
                if !trimmed.isEmpty { pastTitle = true }
                continue
            }
            if !trimmed.isEmpty { return trimmed }
        }
        return "No additional text"
    }

    var date: Date {
        switch self {
        case .local(let draft): return draft.createdAt
        case .server(let memo, _): return memo.updatedAt ?? .distantPast
        case .vault(let entry): return entry.modifiedAt
        }
    }

    var tags: [String] {
        if case .vault(let entry) = self { return entry.tags }
        return TagExtractor.tags(in: content)
    }

    var hasAttachments: Bool {
        switch self {
        case .local(let draft): return draft.text.contains("![")
        case .server(let memo, _): return memo.hasAttachments || memo.content.contains("![")
        case .vault: return false
        }
    }

    var hasFiles: Bool {
        switch self {
        case .local, .vault: return false
        case .server(let memo, _): return memo.attachmentCount > 0
        }
    }
```

Add the vault merge alongside the existing one:

```swift
    /// Vault-mode merge: filed notes come from the index, plus any local draft
    /// that hasn't been written out yet.
    static func merge(
        vaultEntries: [VaultIndexEntry],
        drafts: [Draft],
        excludeDraftID: UUID? = nil
    ) -> [UnifiedNote] {
        var notes = vaultEntries.map { UnifiedNote.vault($0) }
        for draft in drafts where !draft.isBlank && !draft.isArchived && draft.id != excludeDraftID {
            notes.append(.local(draft))
        }
        return notes.sorted { $0.date > $1.date }
    }
```

- [ ] **Step 4: Run the full suite**

Existing `switch` statements over `UnifiedNote` elsewhere may now be non-exhaustive; the compiler will name them. Fix each by adding a `.vault` branch consistent with the ones above.

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: PASS — the new 6 plus all pre-existing tests.

- [ ] **Step 5: Commit**

```bash
git add MemoChat/ViewModels/UnifiedNote.swift MemosIOSTests/UnifiedNoteVaultTests.swift MemosIOS.xcodeproj
git commit -m "feat: add vault case to UnifiedNote"
```

---

### Task 9: Settings UI

Where the user picks a destination and connects a vault. Folder picking uses `UIDocumentPickerViewController` in folder mode via `.fileImporter`.

**Files:**
- Modify: `MemosIOS/Views/SettingsView.swift`
- Create: `MemoChat/Views/Components/VaultSettingsSection.swift`

**Interfaces:**
- Consumes: `DestinationKind`, `AppSettings.destinationKind`, `AppSettings.vaultNotesFolder`, `AppSettings.vaultAttachmentsFolder`, `VaultBookmarkStore`.
- Produces: `struct VaultSettingsSection: View`.

No unit tests — this is view code whose behavior is the picker, which is not unit-testable. It is covered by the manual verification checklist in Task 11.

- [ ] **Step 1: Create the settings section**

```swift
import SwiftUI
import UniformTypeIdentifiers

/// Destination picker plus vault configuration. Shown inside SettingsView.
struct VaultSettingsSection: View {

    @State private var destination = AppSettings.destinationKind
    @State private var notesFolder = AppSettings.vaultNotesFolder
    @State private var attachmentsFolder = AppSettings.vaultAttachmentsFolder
    @State private var isPickingFolder = false
    @State private var vaultPath: String?
    @State private var errorMessage: String?

    var body: some View {
        Section("Destination") {
            Picker("Send notes to", selection: $destination) {
                ForEach(DestinationKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .onChange(of: destination) { _, newValue in
                AppSettings.destinationKind = newValue
            }
        }

        if destination == .vault {
            Section("Obsidian Vault") {
                Button {
                    isPickingFolder = true
                } label: {
                    HStack {
                        Text(vaultPath == nil ? "Choose Vault Folder…" : "Change Vault Folder…")
                        Spacer()
                        if let vaultPath {
                            Text(vaultPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }

                TextField("Notes subfolder (blank = vault root)", text: $notesFolder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { AppSettings.vaultNotesFolder = notesFolder }

                TextField("Attachments subfolder", text: $attachmentsFolder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { AppSettings.vaultAttachmentsFolder = attachmentsFolder }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add the picker and state refresh**

Append these to `VaultSettingsSection`, inside `body` after the last `Section`:

```swift
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try VaultBookmarkStore.save(url: url)
                    vaultPath = url.lastPathComponent
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .onAppear { refreshVaultPath() }
```

And this method on the struct:

```swift
    private func refreshVaultPath() {
        do {
            vaultPath = try VaultBookmarkStore.resolve().lastPathComponent
            errorMessage = nil
        } catch VaultAccessError.notConfigured {
            vaultPath = nil
            errorMessage = nil
        } catch {
            vaultPath = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
```

- [ ] **Step 3: Mount it in SettingsView**

Open `MemosIOS/Views/SettingsView.swift`, find the top-level `Form` (or `List`), and insert `VaultSettingsSection()` as its first child so the destination choice appears above the Memos server fields.

- [ ] **Step 4: Build and check it renders**

```bash
xcodegen generate
xcodebuild build -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add MemoChat/Views/Components/VaultSettingsSection.swift MemosIOS/Views/SettingsView.swift MemosIOS.xcodeproj
git commit -m "feat: add destination picker and vault folder settings UI"
```

---

### Task 10: Wire the compose and list flows

Routes sends and edits to the active destination. This is where the feature becomes usable.

**Files:**
- Modify: `MemoChat/Views/ComposeRootView.swift`
- Modify: `MemoChat/Views/NotesListView.swift`
- Modify: `MemoChat/Views/NoteEditorView.swift`

**Interfaces:**
- Consumes: `VaultStore` (Task 7), `DestinationKind` / `AppSettings.destinationKind` (Task 6), `UnifiedNote.vault` and `NoteEditorTarget.vaultFile` (Task 8).
- Produces: no new public API — behavior only.

- [ ] **Step 1: Provide the VaultStore from the root**

In `MemoChat/Views/ComposeRootView.swift`, add alongside the existing `@StateObject` declarations:

```swift
    @StateObject private var vaultStore = VaultStore()
```

Add it to the environment next to the other `.environmentObject` calls:

```swift
        .environmentObject(vaultStore)
```

Replace the existing `.task` that primes the server store so vault mode does no network work at all:

```swift
        .task {
            switch AppSettings.destinationKind {
            case .memos:
                serverMemosStore.loadFromCache(MemoCache.load())
                serverMemosStore.onFirstPageFetched = { MemoCache.save($0) }
                await serverMemosStore.refresh(force: true)
            case .vault:
                vaultStore.loadFromIndex()
                await vaultStore.refresh()
            }
        }
```

And update `autoSyncLoop` so the poll hits the active destination:

```swift
    private func autoSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            switch AppSettings.destinationKind {
            case .memos:
                await serverMemosStore.refreshIfStale(maxAge: 30)
            case .vault:
                await vaultStore.refreshIfStale(maxAge: 30)
            }
        }
    }
```

In the `.onChange(of: scenePhase)` `.active` branch, replace the trailing
`Task { await serverMemosStore.refreshIfStale() }` with:

```swift
                switch AppSettings.destinationKind {
                case .memos:
                    Task { await serverMemosStore.refreshIfStale() }
                case .vault:
                    Task { await vaultStore.refreshIfStale(maxAge: 5) }
                }
```

- [ ] **Step 2: Route the send**

In `MemoChat/Views/NoteEditorView.swift`, add the store next to the existing environment objects (after `@EnvironmentObject private var pinnedStore: PinnedNotesStore`, around line 26):

```swift
    @EnvironmentObject private var vaultStore: VaultStore
```

Add vault editing state next to the server memo state (after `@State private var serverMemoError: String?`, around line 37):

```swift
    // Vault note editing state
    @State private var loadedVaultNote: VaultNote?
    @State private var vaultNoteBody: String = ""
    @State private var vaultError: String?
```

There are **two** call sites of `sendQueue.enqueue(draft, in: modelContext)` in this file — one in `sendHome()` (line 412) and one in `commitDraft()` (line 464). Replace both with `dispatchSend(draft)`, and add this method:

```swift
    /// Sends the current draft to whichever destination is active. The Memos
    /// path keeps its queue; the vault path writes the file immediately.
    private func dispatchSend(_ draft: Draft) {
        switch AppSettings.destinationKind {
        case .memos:
            sendQueue.enqueue(draft, in: modelContext)
        case .vault:
            do {
                try vaultStore.create(body: draft.text)
                draft.isArchived = true
                draft.lastSentAt = Date()
                draft.sendState = .sent
                draft.lastError = nil
            } catch {
                // Leave the draft unarchived so no text is lost.
                draft.sendState = .failed
                draft.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            modelContext.saveOrAssert()
        }
    }
```

- [ ] **Step 3: Add the vault editing target**

Adding `NoteEditorTarget.vaultFile` in Task 8 makes **five** `switch target` statements in this file non-exhaustive. The compiler will flag each; here is every one and what it needs.

`noteID` (line 66) — the pinned-note identifier must match `UnifiedNote.id`:

```swift
        case .vaultFile(let path):
            return "v-\(path)"
```

`textBinding` (line 213):

```swift
        case .vaultFile:
            return $vaultNoteBody
```

`commitCurrent()` (line 451):

```swift
        case .vaultFile:
            saveVaultNote()
```

`saveCurrentState()` (line 475):

```swift
        case .vaultFile:
            saveVaultNote()
```

`setup()` (line 516):

```swift
        case .vaultFile(let path):
            loadVaultNote(path)
```

Then add the two methods, next to `loadServerMemo(memoID:)`:

```swift
    /// Loads a vault note's body on demand. The list holds only index entries —
    /// in an iCloud vault, reading bodies to draw rows would download the vault.
    private func loadVaultNote(_ relativePath: String) {
        do {
            let note = try vaultStore.read(relativePath: relativePath)
            loadedVaultNote = note
            vaultNoteBody = note.body
            vaultError = nil
        } catch {
            vaultError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Saves the open vault note. A conflict is reported, not retried — the
    /// user's text is already safely on disk under the conflict name.
    private func saveVaultNote() {
        guard let note = loadedVaultNote else { return }
        do {
            let result = try vaultStore.update(note: note, body: vaultNoteBody)
            switch result {
            case .written:
                vaultError = nil
                // Re-read so the next save compares against current metadata.
                loadedVaultNote = try? vaultStore.read(relativePath: note.relativePath)
            case .conflictCopy(let path, _):
                vaultError = "This note changed elsewhere. Your version was saved as \(path)."
            }
        } catch {
            vaultError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
```

Finally, surface `vaultError` wherever the view already presents `serverMemoError`, so a failed vault save is never silent.

**Write cadence:** `schedulePersist()` (line 490) already debounces at 400ms for local SwiftData saves. Do **not** reuse it for vault writes — the spec calls for ~2s to avoid thrashing iCloud sync. Add a separate debounce and call it from the same place `schedulePersist()` is called when the target is `.vaultFile`:

```swift
    @State private var vaultSaveTask: Task<Void, Never>?

    private func scheduleVaultSave() {
        vaultSaveTask?.cancel()
        vaultSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveVaultNote()
        }
    }
```

`commitCurrent()` and `saveCurrentState()` already fire on disappear and background, so an in-flight debounce is always flushed.

- [ ] **Step 4: Render vault notes in the list**

In `MemoChat/Views/NotesListView.swift`, add:

```swift
    @EnvironmentObject private var vaultStore: VaultStore
```

Where the view builds its notes via `UnifiedNote.merge(drafts:memos:editDrafts:)`, branch on destination:

```swift
    private var notes: [UnifiedNote] {
        switch AppSettings.destinationKind {
        case .memos:
            return UnifiedNote.merge(
                drafts: drafts,
                memos: serverMemosStore.memos,
                editDrafts: editDrafts
            )
        case .vault:
            return UnifiedNote.merge(
                vaultEntries: vaultStore.entries,
                drafts: drafts
            )
        }
    }
```

- [ ] **Step 5: Build and run the full suite**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: BUILD SUCCEEDED, all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add MemoChat/Views MemosIOS.xcodeproj
git commit -m "feat: route compose, list, and edit flows through the active destination"
```

---

### Task 11: Image attachments and manual device verification

Completes the feature, then verifies the parts no unit test can reach.

**Files:**
- Create: `MemosIOS/Services/Vault/VaultAttachmentWriter.swift`
- Modify: `MemoChat/Views/NoteEditorView.swift` (`attachmentMarkdown(existingText:)` line 593)
- Test: `MemosIOSTests/VaultAttachmentWriterTests.swift`

**Interfaces:**
- Consumes: `VaultFileStore` (Task 4), `AppSettings.vaultAttachmentsFolder` (Task 6).
- Produces:
  - `enum VaultAttachmentWriter`
  - `static func filename(forNoteNamed:index:fileExtension:) -> String`
  - `static func wikilink(for filename: String) -> String`
  - `static func write(data:filename:using:folder:) throws -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MemoChat

final class VaultAttachmentWriterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testFilenameFollowsNoteStemAndIndex() {
        let name = VaultAttachmentWriter.filename(
            forNoteNamed: "2026-09-16 2130.md",
            index: 1,
            fileExtension: "png"
        )
        XCTAssertEqual(name, "2026-09-16 2130 1.png")
    }

    func testWikilinkFormat() {
        XCTAssertEqual(VaultAttachmentWriter.wikilink(for: "a b.png"), "![[a b.png]]")
    }

    func testWriteLandsInAttachmentsFolder() throws {
        let store = VaultFileStore(root: root)
        let data = Data([0x89, 0x50, 0x4E, 0x47])

        let path = try VaultAttachmentWriter.write(
            data: data,
            filename: "shot.png",
            using: store,
            folder: "attachments"
        )

        XCTAssertEqual(path, "attachments/shot.png")
        let written = try Data(contentsOf: root.appendingPathComponent(path))
        XCTAssertEqual(written, data)
    }

    func testWriteToVaultRootWhenFolderIsEmpty() throws {
        let store = VaultFileStore(root: root)
        let path = try VaultAttachmentWriter.write(
            data: Data([0x01]),
            filename: "shot.png",
            using: store,
            folder: ""
        )
        XCTAssertEqual(path, "shot.png")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultAttachmentWriterTests`
Expected: compile failure — `cannot find 'VaultAttachmentWriter' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Writes images into the vault's attachment folder and produces the Obsidian
/// wikilink that references them.
///
/// Wikilinks resolve regardless of the note's folder depth, which plain
/// relative markdown paths do not. The cost is portability outside Obsidian,
/// accepted because the destination is named for Obsidian.
enum VaultAttachmentWriter {

    static func filename(forNoteNamed noteName: String, index: Int, fileExtension: String) -> String {
        let stem = (noteName as NSString).deletingPathExtension
        return "\(stem) \(index).\(fileExtension)"
    }

    static func wikilink(for filename: String) -> String {
        "![[\(filename)]]"
    }

    /// Writes the data and returns the path it landed at, relative to the vault root.
    @discardableResult
    static func write(
        data: Data,
        filename: String,
        using store: VaultFileStore,
        folder: String
    ) throws -> String {
        let relativePath = folder.isEmpty ? filename : "\(folder)/\(filename)"
        let url = store.root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return relativePath
    }
}
```

- [ ] **Step 4: Wire attachments into the editor**

In `MemoChat/Views/NoteEditorView.swift`, `appendPendingAttachments(to:)` (line 562) currently uploads images to the Memos server and inserts the markdown returned by `attachmentMarkdown(existingText:)` (line 593). In vault mode there is no upload — the bytes go straight into the vault folder.

Add this method and call it from `appendPendingAttachments(to:)` when `AppSettings.destinationKind == .vault`, in place of the server upload branch:

```swift
    /// Writes pending images into the vault and returns their wikilinks.
    /// Images that fail to write are skipped rather than aborting the note —
    /// losing an attachment is recoverable, losing the text is not.
    private func vaultAttachmentMarkdown(forNoteNamed noteName: String) -> [String] {
        guard let fileStore = try? VaultFileStore(root: VaultBookmarkStore.resolve()) else { return [] }
        let folder = AppSettings.vaultAttachmentsFolder

        var links: [String] = []
        for (offset, image) in pendingImages.enumerated() {
            guard let data = image.pngData() else { continue }
            let filename = VaultAttachmentWriter.filename(
                forNoteNamed: noteName,
                index: offset + 1,
                fileExtension: "png"
            )
            guard (try? VaultAttachmentWriter.write(
                data: data,
                filename: filename,
                using: fileStore,
                folder: folder
            )) != nil else { continue }
            links.append(VaultAttachmentWriter.wikilink(for: filename))
        }
        return links
    }
```

For `noteName`, pass `VaultNoteSerializer.filename(for: Date(), existing: [])`. That derives the same `YYYY-MM-DD HHmm` stem the note itself will get, without coupling the attachment write to the note write — the two only need to *look* related in the vault, and an occasional one-minute skew is harmless.

The links must be appended to the draft text **before** `dispatchSend(draft)` runs, so they are part of the body `VaultStore.create` serializes.

- [ ] **Step 5: Run the tests**

```bash
xcodegen generate
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MemosIOSTests/VaultAttachmentWriterTests
```
Expected: PASS, 4 tests.

- [ ] **Step 6: Run the whole suite**

```bash
xcodebuild test -scheme MemoChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: all tests PASS — 28 pre-existing plus 69 new (14 + 10 + 4 + 11 + 7 + 5 + 8 + 6 + 4).

- [ ] **Step 7: Manual device verification**

These cannot be unit-tested. Run each on a **physical device** with a real iCloud-synced Obsidian vault and record the result.

- [ ] Pick a vault folder in Settings; confirm the folder name appears.
- [ ] Capture a note; confirm the `.md` file appears in Obsidian on the desktop with correct frontmatter.
- [ ] Force-quit and relaunch; confirm the drawer renders from the index **before** any file I/O, and the vault is still connected (bookmark survived).
- [ ] Add a custom key and a comment to a note's frontmatter on the desktop, edit the note in MemoChat, confirm both survive **byte-identical**.
- [ ] Edit a note on the desktop while it is open in MemoChat, save in MemoChat, confirm a conflict copy appears and the desktop version is untouched.
- [ ] Delete a note on the desktop; confirm it leaves the drawer on next foreground.
- [ ] Attach an image; confirm it lands in the attachments folder and renders in Obsidian.
- [ ] Repeat the capture and relaunch checks with a vault in a third-party file provider (Working Copy or Dropbox).
- [ ] Restore-from-backup is impractical to stage: instead, delete the vault folder, reopen the app, and confirm the "Reconnect vault" message appears rather than a silent failure.

- [ ] **Step 8: Commit**

```bash
git add MemosIOS/Services/Vault/VaultAttachmentWriter.swift MemoChat/Views/NoteEditorView.swift MemosIOSTests/VaultAttachmentWriterTests.swift MemosIOS.xcodeproj
git commit -m "feat: write image attachments into the vault as wikilinks"
```

---

## Deferred to follow-up plans

Per the spec's "Out of scope" section, these are **not** in this plan:

1. **Frontmatter editor UI** — arbitrary user key/value editing. `Frontmatter.set`/`remove` from Task 1 is the API it builds on. Needs its own decision on how manually-added frontmatter tags union with body tags.
2. **SiloNote-inspired UI** — drawer stats (Notes/Tags/Days), contribution heatmap, editor inline toolbar row.
3. **Launch speed** — the `LaunchTrace` cold-launch measurement from 2026-06-28, still untaken.
