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

    // MARK: - yamlScalar quoting (fix round 1: real YAML-corrupting inputs)

    /// Helper: renders, re-parses the rendered text, and reads the title back
    /// through the same path the app would (Frontmatter.parse + VaultNote.title),
    /// so these are true round-trip tests, not just string-contains checks.
    private func roundTrippedTitle(forBody body: String) -> String {
        let text = VaultNoteSerializer.render(body: body, existing: nil, created: created, updated: updated)
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
        let text = VaultNoteSerializer.render(body: body, existing: nil, created: created, updated: updated)
        XCTAssertTrue(text.contains("title: \"Buy milk #groceries\"\n"))
        XCTAssertEqual(roundTrippedTitle(forBody: body), "Buy milk #groceries")
    }

    /// A bare `title: - Shopping list` is a YAML hard parse error (block
    /// sequence entry not allowed in this context), which breaks the entire
    /// frontmatter block when opened in Obsidian.
    func testTitleStartingWithDashIsQuotedAndRoundTrips() {
        let body = "- Shopping list\n"
        let text = VaultNoteSerializer.render(body: body, existing: nil, created: created, updated: updated)
        XCTAssertTrue(text.contains("title: \"- Shopping list\"\n"))
        XCTAssertEqual(roundTrippedTitle(forBody: body), "- Shopping list")
    }

    /// Bare `yes`/`no`/`true`/`false`/`on`/`off`/`null`/`~` parse as
    /// bool/nil rather than the literal string.
    func testTitleThatIsReservedWordIsQuotedAndRoundTrips() {
        let body = "yes\n"
        let text = VaultNoteSerializer.render(body: body, existing: nil, created: created, updated: updated)
        XCTAssertTrue(text.contains("title: \"yes\"\n"))
        XCTAssertEqual(roundTrippedTitle(forBody: body), "yes")
    }

    /// A bare numeric-looking title parses as a number, not a string.
    func testTitleThatIsNumericIsQuotedAndRoundTrips() {
        let body = "123\n"
        let text = VaultNoteSerializer.render(body: body, existing: nil, created: created, updated: updated)
        XCTAssertTrue(text.contains("title: \"123\"\n"))
        XCTAssertEqual(roundTrippedTitle(forBody: body), "123")
    }

    /// Leading `@`, `` ` ``, and `%` are also reserved/indicator characters in
    /// YAML and must be quoted the same way as the other leading-character cases.
    func testTitlesWithLeadingReservedCharactersAreQuoted() {
        for body in ["@mention line\n", "`code` line\n", "%directive line\n"] {
            let text = VaultNoteSerializer.render(body: body, existing: nil, created: created, updated: updated)
            let expectedTitle = String(body.dropLast())
            XCTAssertTrue(text.contains("title: \"\(expectedTitle)\"\n"), "expected quoting for: \(body)")
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
}
