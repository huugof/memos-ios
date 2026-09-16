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
