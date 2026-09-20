import XCTest
@testable import MemoChat

final class VaultTemplateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_594_203)  // 2026-09-16T21:30:03Z
    private let utc = TimeZone(identifier: "UTC")!

    private func frontmatter(_ fileText: String, title: String? = "Note title") -> Frontmatter? {
        VaultTemplate.frontmatter(fromFileText: fileText, title: title, now: now, timeZone: utc)
    }

    /// The whole point of seeding through `render`'s `existing` parameter:
    /// what the template says is what lands, untouched.
    func testCopiesCustomKeysCommentsAndOrderVerbatim() throws {
        let template = """
        ---
        # where this came from
        source: phone
        status: inbox
        project:
          - alpha
          - beta
        ---
        Template body that must be ignored.
        """
        let seeded = try XCTUnwrap(frontmatter(template))
        let text = VaultNoteSerializer.render(
            body: "My note\n", existing: seeded, loadedBody: nil, created: now, updated: now)

        XCTAssertTrue(text.contains("# where this came from\n"))
        XCTAssertTrue(text.contains("source: phone\n"))
        XCTAssertTrue(text.contains("status: inbox\n"))
        XCTAssertTrue(text.contains("project:\n  - alpha\n  - beta\n"))
        XCTAssertFalse(text.contains("Template body"))
        XCTAssertTrue(text.hasSuffix("My note\n"))
    }

    /// The trap this feature would otherwise walk into: a template's empty
    /// `title:` and `created:` are slots, and the drift rule would have
    /// defended them as user-authored, freezing them empty on every capture.
    func testFillsEmptyManagedPlaceholdersKeepingTheirPosition() throws {
        let template = """
        ---
        title:
        created:
        source: phone
        ---
        """
        let seeded = try XCTUnwrap(frontmatter(template))
        let text = VaultNoteSerializer.render(
            body: "My note\n", existing: seeded, loadedBody: nil, created: now, updated: now)

        XCTAssertTrue(text.contains("title: My note\n"))
        XCTAssertTrue(text.contains("created: 2026-09-16T21:30:03Z\n"))
        let titleIndex = try XCTUnwrap(text.range(of: "title:"))
        let sourceIndex = try XCTUnwrap(text.range(of: "source:"))
        XCTAssertLessThan(titleIndex.lowerBound, sourceIndex.lowerBound)
    }

    /// A stale `created:` from a template is a placeholder, not a birth date.
    func testOverwritesATemplatesLiteralCreatedValue() throws {
        let seeded = try XCTUnwrap(frontmatter("---\ncreated: 2001-01-01\n---\n"))
        let text = VaultNoteSerializer.render(
            body: "My note\n", existing: seeded, loadedBody: nil, created: now, updated: now)

        XCTAssertTrue(text.contains("created: 2026-09-16T21:30:03Z\n"))
        XCTAssertFalse(text.contains("2001-01-01"))
    }

    /// Tags needs no special case — a template's list reads as user-maintained,
    /// so a fixed tag survives and the body's tags merge in beside it.
    func testKeepsTemplateTagsAndMergesBodyTags() throws {
        let seeded = try XCTUnwrap(frontmatter("---\ntags: [inbox]\n---\n"))
        let text = VaultNoteSerializer.render(
            body: "My note with #ideas\n", existing: seeded, loadedBody: nil, created: now, updated: now)

        XCTAssertTrue(text.contains("tags: [inbox, ideas]\n"))
    }

    // MARK: - Placeholders

    func testExpandsDateAndTimePlaceholders() throws {
        let seeded = try XCTUnwrap(frontmatter("---\nday: {{date}}\nat: {{time}}\n---\n"))
        XCTAssertEqual(seeded.value(for: "day"), "2026-09-16")
        XCTAssertEqual(seeded.value(for: "at"), "21:30")
    }

    func testExpandsExplicitFormats() throws {
        let seeded = try XCTUnwrap(frontmatter("---\nstamp: {{date:YYYY-MM-DD HH:mm}}\nday: {{date:dddd}}\n---\n"))
        XCTAssertEqual(seeded.value(for: "stamp"), "2026-09-16 21:30")
        XCTAssertEqual(seeded.value(for: "day"), "Wednesday")
    }

    /// Moment and Unicode disagree exactly where it hurts: `YYYY` is the
    /// week-based year in Unicode and `DD` is the day of the year, so passing
    /// a template's format straight to DateFormatter misdates the last days of
    /// December — 2024-12-30 would render as 2025-12-365.
    func testTranslatesMomentTokensRatherThanPassingThemThrough() throws {
        XCTAssertEqual(VaultTemplate.dateFormat(fromMomentFormat: "YYYY-MM-DD"), "yyyy-MM-dd")

        let newYearsEve = Date(timeIntervalSince1970: 1_735_516_800)  // 2024-12-30T00:00:00Z
        let seeded = try XCTUnwrap(VaultTemplate.frontmatter(
            fromFileText: "---\nday: {{date}}\n---\n", title: nil, now: newYearsEve, timeZone: utc))
        XCTAssertEqual(seeded.value(for: "day"), "2024-12-30")
    }

    func testUnknownFormatLettersBecomeLiterals() {
        XCTAssertEqual(VaultTemplate.dateFormat(fromMomentFormat: "[week] YYYY"), "'week' yyyy")
        XCTAssertEqual(VaultTemplate.dateFormat(fromMomentFormat: "QQ-YYYY"), "'QQ'-yyyy")
    }

    /// A title is the one expansion that can be arbitrary text, so it is the
    /// one that can break the block.
    func testQuotesATitleExpansionThatWouldMisparse() throws {
        let seeded = try XCTUnwrap(frontmatter("---\nalias: {{title}}\n---\n", title: "Draft: a plan"))
        XCTAssertEqual(seeded.value(for: "alias"), "'Draft: a plan'")
    }

    func testLeavesASafeTitleExpansionBare() throws {
        let seeded = try XCTUnwrap(frontmatter("---\nalias: {{title}}\n---\n", title: "A plan"))
        XCTAssertEqual(seeded.value(for: "alias"), "A plan")
    }

    /// A date expansion stays bare even though it would trip `yamlScalar()`'s
    /// date check — Obsidian's date properties need an unquoted value.
    func testDoesNotQuoteADateExpansion() throws {
        let seeded = try XCTUnwrap(frontmatter("---\ndue: {{date}}\n---\n"))
        XCTAssertEqual(seeded.value(for: "due"), "2026-09-16")
    }

    func testEscapesSubstitutionInsideAQuotedValue() throws {
        let single = try XCTUnwrap(frontmatter("---\nalias: '{{title}}'\n---\n", title: "It's here"))
        XCTAssertEqual(single.value(for: "alias"), "'It''s here'")

        let double = try XCTUnwrap(frontmatter("---\nalias: \"{{title}}\"\n---\n", title: "She said \"go\""))
        XCTAssertEqual(double.value(for: "alias"), "\"She said \\\"go\\\"\"")
    }

    func testLeavesUnsupportedSyntaxAlone() throws {
        let seeded = try XCTUnwrap(frontmatter("---\nwhen: <% tp.date.now() %>\n---\n"))
        XCTAssertEqual(seeded.value(for: "when"), "<% tp.date.now() %>")
    }

    func testTitlePlaceholderSurvivesAnEmptyBody() throws {
        let seeded = try XCTUnwrap(frontmatter("---\nalias: {{title}}\n---\n", title: nil))
        XCTAssertEqual(seeded.value(for: "alias"), "{{title}}")
    }

    // MARK: - No usable template

    func testFileWithoutAFrontmatterBlockYieldsNil() {
        XCTAssertNil(frontmatter("Just a body, no block.\n"))
        XCTAssertNil(frontmatter("---\nunterminated: true\n"))
    }

    func testEmptyBlockYieldsAnEmptyFrontmatter() throws {
        let seeded = try XCTUnwrap(frontmatter("---\n---\n"))
        let text = VaultNoteSerializer.render(
            body: "My note\n", existing: seeded, loadedBody: nil, created: now, updated: now)
        XCTAssertTrue(text.contains("title: My note\n"))
    }
}
