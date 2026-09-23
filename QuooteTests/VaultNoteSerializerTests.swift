import XCTest
@testable import Quoote

final class VaultNoteSerializerTests: XCTestCase {

    /// Stamps are written in the device's zone, so the tests pin UTC rather
    /// than expecting strings that move with the machine.
    private let utc = VaultNoteSerializer.TimestampStyle(timeZone: TimeZone(identifier: "UTC")!)

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

    /// A new note captured under a template. `templateKeys` is the template's
    /// frontmatter; a template declaring `title:` is the only path on which
    /// the app writes a title, now that it never inserts the key itself.
    private func renderNew(body: String, templateKeys: String = "title:\n") -> String {
        let (existing, _) = Frontmatter.parse("---\n\(templateKeys)---\n")
        return VaultNoteSerializer.render(
            body: body, existing: existing, loadedBody: nil,
            created: created, updated: updated, style: utc)
    }

    func testRenderWritesManagedKeys() {
        let text = VaultNoteSerializer.render(
            body: "My note\nwith #inbox and #ideas\n",
            existing: nil,
            loadedBody: nil,
            created: created,
            updated: updated,
            style: utc
        )
        XCTAssertTrue(text.hasPrefix("---\n"))
        XCTAssertTrue(text.contains("date: 2026-09-16T21:30:03Z\n"))
        XCTAssertTrue(text.contains("modified: 2026-09-16T21:34:11Z\n"))
        XCTAssertTrue(text.contains("tags:\n  - inbox\n  - ideas\n"))
        XCTAssertTrue(text.hasSuffix("My note\nwith #inbox and #ideas\n"))
    }

    /// The timestamps are the only keys inserted into a note that lacks them.
    /// A title is the note's own first line; repeating it in frontmatter is
    /// the template's call, not the app's.
    func testTitleIsNotInsertedWithoutTheKey() {
        let text = VaultNoteSerializer.render(
            body: "My note\n", existing: nil, loadedBody: nil, created: created, updated: updated)
        XCTAssertFalse(text.contains("title:"), text)
    }

    func testTitleIsFilledWhenTheTemplateDeclaresTheKey() {
        XCTAssertTrue(renderNew(body: "My note\n").contains("title: My note\n"))
    }

    /// A template naming the keys wins over the defaults: its `created:` is
    /// filled in place rather than joined by a second `date:`.
    func testTemplateKeyNamesWinOverTheDefaults() {
        let text = renderNew(body: "My note\n", templateKeys: "created:\nupdated:\n")
        XCTAssertTrue(text.contains("created: 2026-09-16T21:30:03Z\n"), text)
        XCTAssertTrue(text.contains("updated: 2026-09-16T21:34:11Z\n"), text)
        XCTAssertFalse(text.contains("date:"), text)
        XCTAssertFalse(text.contains("modified:"), text)
    }

    /// A note an earlier version wrote keeps its own spelling on every later
    /// save — one stamp per moment, never two.
    func testLegacyTimestampKeysAreReusedNotDuplicated() {
        let (existing, loadedBody) = Frontmatter.parse(
            "---\ncreated: 2020-01-01T00:00:00Z\nupdated: 2020-01-01T00:00:00Z\n---\nbody\n")
        let text = VaultNoteSerializer.render(
            body: "body\n", existing: existing, loadedBody: loadedBody,
            created: created, updated: updated, style: utc)
        XCTAssertTrue(text.contains("created: 2020-01-01T00:00:00Z\n"), text)
        XCTAssertTrue(text.contains("updated: 2026-09-16T21:34:11Z\n"), text)
        XCTAssertFalse(text.contains("date:"), text)
        XCTAssertFalse(text.contains("modified:"), text)
    }

    func testCreatedDateReadsEitherKey() {
        let (new, _) = Frontmatter.parse("---\ndate: 2020-01-01T00:00:00Z\n---\nx\n")
        let (old, _) = Frontmatter.parse("---\ncreated: 2020-01-01T00:00:00Z\n---\nx\n")
        let expected = VaultNoteSerializer.iso8601.date(from: "2020-01-01T00:00:00Z")
        XCTAssertEqual(new.flatMap(VaultNoteSerializer.createdDate(in:)), expected)
        XCTAssertEqual(old.flatMap(VaultNoteSerializer.createdDate(in:)), expected)
    }

    /// The loaded body's first line is "Old", so `title: Old` is app-derived
    /// and follows the new first line (C1 made the loaded body an input).
    func testRenderPreservesUnknownKeys() {
        let (existing, loadedBody) = Frontmatter.parse("---\ncustom: keep me\n# and this comment\ntitle: Old\n---\nOld\nbody\n")
        let text = VaultNoteSerializer.render(
            body: "New body\n",
            existing: existing,
            loadedBody: loadedBody,
            created: created,
            updated: updated
        )
        XCTAssertTrue(text.contains("custom: keep me\n"))
        XCTAssertTrue(text.contains("# and this comment\n"))
        XCTAssertTrue(text.contains("title: New body\n"))
        XCTAssertFalse(text.contains("title: Old"))
    }

    /// The creation stamp is written once and never rewritten on later saves.
    func testRenderKeepsOriginalCreated() {
        let (existing, loadedBody) = Frontmatter.parse("---\ndate: 2020-01-01T00:00:00Z\n---\nbody\n")
        let text = VaultNoteSerializer.render(body: "body\n", existing: existing, loadedBody: loadedBody, created: created, updated: updated)
        XCTAssertTrue(text.contains("date: 2020-01-01T00:00:00Z\n"))
        XCTAssertFalse(text.contains("date: 2026-09-16"))
    }

    /// The drift rule: tags the app wrote (they equal the loaded body's tags)
    /// are app-maintained, so removing an inline tag removes it from frontmatter.
    func testRemovingInlineTagRemovesItFromFrontmatter() {
        let (existing, loadedBody) = Frontmatter.parse("---\ntags: [inbox, ideas]\n---\nold #inbox #ideas\n")
        let text = VaultNoteSerializer.render(body: "now only #inbox\n", existing: existing, loadedBody: loadedBody, created: created, updated: updated)
        XCTAssertTrue(text.contains("tags:\n  - inbox\n"))
    }

    /// The shape Obsidian writes, and so the shape the rest of the vault is
    /// already in. Flow style would be valid YAML and still look foreign.
    func testTagsAreWrittenAsABlockSequence() {
        let text = VaultNoteSerializer.render(
            body: "Hello #one #two #three-tags\n", existing: nil, loadedBody: nil,
            created: created, updated: updated, style: utc)
        XCTAssertTrue(text.contains("tags:\n  - one\n  - two\n  - three-tags\n"), text)
    }

    /// A block item still needs quoting where a plain scalar would misparse —
    /// bare `yes` reads back as a boolean.
    func testBlockSequenceItemsAreQuotedWhereYAMLNeedsIt() {
        let (existing, _) = Frontmatter.parse("---\ntags: [yes]\n---\n")
        let text = VaultNoteSerializer.render(
            body: "Hello #ideas\n", existing: existing, loadedBody: nil,
            created: created, updated: updated, style: utc)
        XCTAssertTrue(text.contains("tags:\n  - 'yes'\n  - ideas\n"), text)
    }

    // MARK: - C1: user-owned title and tags survive a save

    private func renderEdit(file: String, newBody: String) -> String {
        let (existing, loadedBody) = Frontmatter.parse(file)
        return VaultNoteSerializer.render(
            body: newBody, existing: existing, loadedBody: loadedBody, created: created, updated: updated)
    }

    /// The reviewer's harness: Properties tags and a custom title on a
    /// desktop note must survive the first Quoote edit.
    func testDesktopPropertiesTagsAndTitleSurviveEdit() {
        let file = "---\ntitle: My Project\ntags:\n  - project\n  - work\n---\n# Kickoff notes\nSome text\n"
        let text = renderEdit(file: file, newBody: "# Kickoff notes\nSome text, edited\n")
        XCTAssertTrue(text.hasPrefix("---\ntitle: My Project\ntags:\n  - project\n  - work\ndate: "), text)
        XCTAssertFalse(text.contains("Kickoff notes\ndate"))
        XCTAssertTrue(text.hasSuffix("---\n# Kickoff notes\nSome text, edited\n"))
    }

    func testAddingInlineTagAppendsToFrontmatterTags() {
        let file = "---\ntags: [project, work]\n---\nNotes\n"
        let text = renderEdit(file: file, newBody: "Notes #new\n")
        XCTAssertTrue(text.contains("tags:\n  - project\n  - work\n  - new\n"), text)
    }

    func testRemovingInlineTagAlsoInFrontmatterRemovesIt() {
        let file = "---\ntags: [project, work]\n---\nNotes #work\n"
        let text = renderEdit(file: file, newBody: "Notes\n")
        XCTAssertTrue(text.contains("tags:\n  - project\n"), text)
    }

    /// A bare scalar (quoted, with `#`) parses as one tag; an unmirrored body
    /// tag is appended to it.
    func testScalarUserTagsMergeWithBodyTags() {
        let file = "---\ntags: \"#Project\"\n---\nNotes #work\n"
        let text = renderEdit(file: file, newBody: "Notes #work edited\n")
        XCTAssertTrue(text.contains("tags:\n  - Project\n  - work\n"), text)
    }

    func testCommaSeparatedUserTagsParse() {
        XCTAssertEqual(VaultNoteSerializer.parseTags(rawEntry: "tags: a, 'b', #c\n"), ["a", "b", "c"])
        XCTAssertEqual(VaultNoteSerializer.parseTags(rawEntry: "tags: [a, \"b\"]\n"), ["a", "b"])
        XCTAssertEqual(VaultNoteSerializer.parseTags(rawEntry: "tags:\n  - a\n  - \"#b\"\n"), ["a", "b"])
    }

    /// Unchanged merge result leaves the user's raw text byte-identical.
    func testUserBlockTagsByteIdenticalWhenNothingChanged() {
        let file = "---\ntags:\n  - project\n  - work\n---\nNotes #work\n"
        let text = renderEdit(file: file, newBody: "Notes #work, more\n")
        XCTAssertTrue(text.contains("tags:\n  - project\n  - work\n"), text)
    }

    /// App-authored note: tags equal the loaded body's tags, so the drift rule
    /// applies exactly as before — including removing the key when empty.
    func testAppAuthoredTagsFollowDriftRule() {
        let file = "---\ntags: [inbox, ideas]\n---\nHello #inbox #ideas\n"
        XCTAssertTrue(renderEdit(file: file, newBody: "Hello #ideas #later\n").contains("tags:\n  - ideas\n  - later\n"))
        XCTAssertFalse(renderEdit(file: file, newBody: "Hello\n").contains("tags:"))
    }

    func testCustomTitleSurvivesEdit() {
        let file = "---\ntitle: \"Custom: name\"\n---\nFirst line\n"
        let text = renderEdit(file: file, newBody: "Changed first line\n")
        XCTAssertTrue(text.contains("title: \"Custom: name\"\n"), text)
    }

    func testAppDerivedTitleFollowsFirstLine() {
        let file = "---\ntitle: First line\n---\nFirst line\n"
        let text = renderEdit(file: file, newBody: "Changed first line\n")
        XCTAssertTrue(text.contains("title: Changed first line\n"), text)
        XCTAssertFalse(renderEdit(file: file, newBody: "").contains("title:"))
    }

    /// An app-derived title that was quoted on write still counts as app-owned.
    func testQuotedAppDerivedTitleFollowsFirstLine() {
        let file = "---\ntitle: 'Buy milk #groceries'\n---\nBuy milk #groceries\n"
        let text = renderEdit(file: file, newBody: "Buy bread #groceries\n")
        XCTAssertTrue(text.contains("title: 'Buy bread #groceries'\n"), text)
    }

    // MARK: - I2: vault tag extraction

    func testVaultTagsIgnoreLinkFragments() {
        XCTAssertEqual(VaultNoteSerializer.vaultTags(in: "See [[Project#Goals]] and https://x.com/a#frag"), [])
        XCTAssertEqual(VaultNoteSerializer.vaultTags(in: "[text](https://x.com/b#frag) ![img](a.png#x)"), [])
    }

    func testVaultTagsFindProseAndLeadingTags() {
        XCTAssertEqual(VaultNoteSerializer.vaultTags(in: "#Real start\nand #real again, #other\n"), ["real", "other"])
    }

    func testVaultTagsIgnoreCode() {
        XCTAssertEqual(VaultNoteSerializer.vaultTags(in: "use `#notatag` here #yes"), ["yes"])
        XCTAssertEqual(VaultNoteSerializer.vaultTags(in: "```\n#fenced\n```\n#after"), ["after"])
    }

    func testVaultTagsRequireWhitespaceBeforeHash() {
        XCTAssertEqual(VaultNoteSerializer.vaultTags(in: "issue#12 and C#"), [])
    }

    func testNoteTagsUseVaultExtractor() {
        let note = VaultNote(relativePath: "a.md", frontmatter: nil, body: "[[A#B]] #tag", modifiedAt: created, fileSize: 1)
        XCTAssertEqual(note.tags, ["tag"])
    }

    func testRenderDoesNotMirrorWikilinkFragments() {
        let text = VaultNoteSerializer.render(
            body: "See [[Project#Goals]]\n", existing: nil, loadedBody: nil, created: created, updated: updated)
        XCTAssertFalse(text.contains("tags:"))
    }

    // MARK: - Minor 9: CRLF titles

    func testTitleTrimsCarriageReturn() {
        XCTAssertEqual(VaultNoteSerializer.title(forBody: "Hello\r\nWorld\r\n"), "Hello")
        XCTAssertTrue(renderNew(body: "Hello\r\nWorld\r\n").contains("title: Hello\n"))
    }

    func testBodyWithNoTagsOmitsTagsKey() {
        let text = VaultNoteSerializer.render(body: "no tags here\n", existing: nil, loadedBody: nil, created: created, updated: updated)
        XCTAssertFalse(text.contains("tags:"))
    }

    func testEmptyBodyOmitsTitleKey() {
        let text = renderNew(body: "")
        XCTAssertFalse(text.contains("title:"))
        XCTAssertTrue(text.contains("date:"))
    }

    // MARK: - yamlScalar quoting (fix round 1: real YAML-corrupting inputs)

    /// Helper: renders, re-parses the rendered text, and reads the title back
    /// through the same path the app would (Frontmatter.parse + VaultNote.title),
    /// so these are true round-trip tests, not just string-contains checks.
    private func roundTrippedTitle(forBody body: String) -> String {
        let text = renderNew(body: body)
        let (frontmatter, parsedBody) = Frontmatter.parse(text)
        let note = VaultNote(relativePath: "note.md", frontmatter: frontmatter, body: parsedBody, modifiedAt: updated, fileSize: text.utf8.count)
        return note.title
    }

    /// A bare `title: Buy milk #groceries` reads back as `Buy milk` in a real
    /// YAML parser — the `#` starts a comment. This is the app's single most
    /// likely input shape, since titles are derived from the body's first line
    /// and inline #tags are the app's defining feature.
    func testTitleWithInlineHashIsQuotedAndRoundTrips() {
        let body = "Buy milk #groceries\n"
        let text = renderNew(body: body)
        XCTAssertTrue(text.contains("title: 'Buy milk #groceries'\n"))
        XCTAssertEqual(roundTrippedTitle(forBody: body), "Buy milk #groceries")
    }

    /// A bare `title: - Shopping list` is a YAML hard parse error (block
    /// sequence entry not allowed in this context), which breaks the entire
    /// frontmatter block when opened in Obsidian.
    func testTitleStartingWithDashIsQuotedAndRoundTrips() {
        let body = "- Shopping list\n"
        let text = renderNew(body: body)
        XCTAssertTrue(text.contains("title: '- Shopping list'\n"))
        XCTAssertEqual(roundTrippedTitle(forBody: body), "- Shopping list")
    }

    /// Bare `yes`/`no`/`true`/`false`/`on`/`off`/`null`/`~` parse as
    /// bool/nil rather than the literal string.
    func testTitleThatIsReservedWordIsQuotedAndRoundTrips() {
        let body = "yes\n"
        let text = renderNew(body: body)
        XCTAssertTrue(text.contains("title: 'yes'\n"))
        XCTAssertEqual(roundTrippedTitle(forBody: body), "yes")
    }

    /// A bare numeric-looking title parses as a number, not a string.
    func testTitleThatIsNumericIsQuotedAndRoundTrips() {
        let body = "123\n"
        let text = renderNew(body: body)
        XCTAssertTrue(text.contains("title: '123'\n"))
        XCTAssertEqual(roundTrippedTitle(forBody: body), "123")
    }

    /// Leading `@`, `` ` ``, and `%` are also reserved/indicator characters in
    /// YAML and must be quoted the same way as the other leading-character cases.
    func testTitlesWithLeadingReservedCharactersAreQuoted() {
        for body in ["@mention line\n", "`code` line\n", "%directive line\n"] {
            let text = renderNew(body: body)
            let expectedTitle = String(body.dropLast())
            XCTAssertTrue(text.contains("title: '\(expectedTitle)'\n"), "expected quoting for: \(body)")
            XCTAssertEqual(roundTrippedTitle(forBody: body), expectedTitle)
        }
    }

    /// The read-side inverse of the write-side `\"` escaping: a title with a
    /// literal double quote must round-trip through the app's own UI without
    /// stray backslashes.
    func testTitleWithDoubleQuoteRoundTrips() {
        let body = "He said \"hi\": bye\n"
        XCTAssertEqual(roundTrippedTitle(forBody: body), "He said \"hi\": bye")
    }

    // MARK: - D2: unsafe YAML scalars (single-quoted style)

    /// render → Frontmatter.parse → value(for:) → unquote must return the
    /// original title for every harness input that used to corrupt YAML.
    func testUnsafeTitlesRoundTrip() {
        let titles = [
            "\"Hello,\" she said",
            "'Tis the season",
            "- see C:\\Users\\hugo",
            ", and then",
            "\"Quoted whole\"",
            "2026-09-16",
            "path C:\\Users\\hugo",
            "ends with colon:",
            "it's fine",
        ]
        for title in titles {
            let text = renderNew(body: "\(title)\n")
            let (frontmatter, _) = Frontmatter.parse(text)
            let raw = frontmatter?.value(for: "title")
            XCTAssertEqual(raw?.trimmingQuotes(), title, "round trip failed for \(title); wrote \(raw ?? "nil")")
        }
    }

    func testUnsafeTitlesUseSingleQuotedStyle() {
        let expectations: [(String, String)] = [
            ("\"Hello,\" she said", "'\"Hello,\" she said'"),
            ("'Tis the season", "'''Tis the season'"),
            ("- see C:\\Users\\hugo", "'- see C:\\Users\\hugo'"),
            (", and then", "', and then'"),
            ("\"Quoted whole\"", "'\"Quoted whole\"'"),
            ("2026-09-16", "'2026-09-16'"),
        ]
        for (title, expected) in expectations {
            let text = renderNew(body: "\(title)\n")
            XCTAssertTrue(text.contains("title: \(expected)\n"), "for \(title): \(text)")
        }
    }

    func testPlainTitleStaysUnquoted() {
        let text = renderNew(body: "Plain title, with comma\n")
        XCTAssertTrue(text.contains("title: Plain title, with comma\n"))
    }

    /// Existing files (and older app output) use double quotes.
    func testDoubleQuotedTitleStillReads() {
        let (fm, body) = Frontmatter.parse("---\ntitle: \"a \\\"b\\\" c\\\\d\"\n---\nx\n")
        let note = VaultNote(relativePath: "n.md", frontmatter: fm, body: body, modifiedAt: created, fileSize: 1)
        XCTAssertEqual(note.title, "a \"b\" c\\d")
    }
}
