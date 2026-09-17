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

    // MARK: - D1: blank lines / comments inside a multi-line entry

    func testBlankLineInsideSequenceStaysWithEntry() {
        let text = "---\ntags:\n  - inbox\n\n  - ideas\ncreated: 2026-01-01T00:00:00Z\n---\nHello #inbox\n"
        var (fm, _) = Frontmatter.parse(text)
        XCTAssertEqual(fm!.rawText(for: "tags"), "tags:\n  - inbox\n\n  - ideas\n")
        fm!.set("tags", rawValue: "[inbox]")
        XCTAssertEqual(fm!.render(), "---\ntags: [inbox]\ncreated: 2026-01-01T00:00:00Z\n---\n")
    }

    func testBlankLineInsideLastSequenceIsRemovedWithIt() {
        let text = "---\ncreated: 2026-01-01T00:00:00Z\ntags:\n  - inbox\n\n  - ideas\n---\nHello\n"
        var (fm, _) = Frontmatter.parse(text)
        fm!.remove("tags")
        fm!.set("updated", rawValue: "2026-09-16T00:00:00Z")
        XCTAssertEqual(fm!.render(), "---\ncreated: 2026-01-01T00:00:00Z\nupdated: 2026-09-16T00:00:00Z\n---\n")
    }

    func testColumnZeroCommentInsideSequenceStaysWithEntry() {
        let text = "---\ntags:\n  - inbox\n# work stuff\n  - ideas\ntitle: Hi\n---\nBody\n"
        var (fm, _) = Frontmatter.parse(text)
        fm!.set("tags", rawValue: "[inbox, ideas]")
        XCTAssertEqual(fm!.render(), "---\ntags: [inbox, ideas]\ntitle: Hi\n---\n")
    }

    /// Blank lines and comments between two entries are still passthrough and
    /// survive a rewrite of the entry above them.
    func testTrailingBlankAndCommentAfterEntryArePassthrough() {
        let text = "---\ntags:\n  - inbox\n\n# section\ntitle: Hi\n---\nBody\n"
        var (fm, _) = Frontmatter.parse(text)
        XCTAssertEqual(fm!.rawText(for: "tags"), "tags:\n  - inbox\n")
        fm!.set("tags", rawValue: "[a]")
        XCTAssertEqual(fm!.render(), "---\ntags: [a]\n\n# section\ntitle: Hi\n---\n")
    }

    func testTrailingBlankAtEndOfBlockIsKept() {
        let text = "---\ntags:\n  - inbox\n\n---\nBody\n"
        let (fm, _) = Frontmatter.parse(text)
        XCTAssertEqual(fm!.render(), "---\ntags:\n  - inbox\n\n---\n")
    }

    // MARK: - Minor 8: byte-order mark

    func testLeadingBOMIsStrippedAndReEmitted() {
        let text = "\u{FEFF}---\ntitle: Hello\n---\nBody\n"
        let (fm, body) = Frontmatter.parse(text)
        XCTAssertEqual(fm?.value(for: "title"), "Hello")
        XCTAssertEqual(body, "Body\n")
        XCTAssertEqual(fm!.render() + body, text)
    }

    func testBOMSurvivesSerializerSave() {
        let text = "\u{FEFF}---\ntitle: Hello\n---\nHello\n"
        let (fm, body) = Frontmatter.parse(text)
        let saved = VaultNoteSerializer.render(
            body: "Hello again\n", existing: fm, loadedBody: body, created: Date(), updated: Date())
        XCTAssertTrue(saved.hasPrefix("\u{FEFF}---\ntitle: Hello again\n"))
    }

    func testEmptyFrontmatterRendersEmptyString() {
        let fm = Frontmatter(blocks: [])
        XCTAssertEqual(fm.render(), "")
    }
}
