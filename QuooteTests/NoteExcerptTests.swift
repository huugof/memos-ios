import XCTest
@testable import Quoote

final class NoteExcerptTests: XCTestCase {

    func testJoinsNonEmptyLines() {
        XCTAssertEqual(NoteExcerpt.make(from: "Grocery run\n\nmilk, eggs\n  bread  \n"), "Grocery run milk, eggs bread")
    }

    func testStripsHeadingMarkersButKeepsTags() {
        XCTAssertEqual(NoteExcerpt.make(from: "## Plans\n#idea for the weekend"), "Plans #idea for the weekend")
    }

    func testDropsEmbeddedImagesAndFiles() {
        let text = "Trip\n![](https://x.test/a.jpg)\n![[photo 1.jpg]]\nlook at this ![cap](b.png) view"
        XCTAssertEqual(NoteExcerpt.make(from: text), "Trip look at this view")
    }

    func testCapsLength() {
        let long = String(repeating: "word ", count: 200)
        XCTAssertEqual(NoteExcerpt.make(from: long).count, NoteExcerpt.maxLength)
    }

    func testUnifiedLocalNoteUsesExcerpt() {
        let note = UnifiedNote.local(Draft(text: "# Title\nbody #tag"))
        XCTAssertEqual(note.excerpt, "Title body #tag")
    }

    func testDropsLinksToMemosFilesButKeepsOrdinaryLinks() {
        let text = """
        Quarterly numbers
        [Report.pdf](https://m.example.com/file/attachments/u/Report.pdf)
        see [the site](https://example.com) too
        """
        XCTAssertEqual(NoteExcerpt.make(from: text), "Quarterly numbers see [the site](https://example.com) too")
    }

    func testANoteThatIsOnlyAFileLinkHasNoExcerpt() {
        let link = "[My Doc.pdf](https://m.example.com/file/attachments/u/My Doc.pdf)"
        XCTAssertEqual(NoteExcerpt.make(from: link), "")
    }

    func testDropsTheOlderMemosFilePathToo() {
        XCTAssertEqual(NoteExcerpt.make(from: "Scan [x.pdf](/o/r/12/x.pdf)"), "Scan")
    }

    func testAFileNamedWithParenthesesIsDroppedWhole() {
        // "Invoice (1).pdf" is the usual name of a second download of the same file.
        let text = "Invoice [Invoice (1).pdf](https://m.example.com/file/attachments/u/Invoice (1).pdf)"
        XCTAssertEqual(NoteExcerpt.make(from: text), "Invoice")
    }

    func testAnImageLinkWithParenthesesInItsNameIsDroppedWhole() {
        let text = "Trip ![](https://m.example.com/file/attachments/u/photo(1).png)"
        XCTAssertEqual(NoteExcerpt.make(from: text), "Trip")
    }

    func testAFileOnlyNoteWithParenthesesInTheNameShowsTheFileName() {
        let link = "[Scan (2).pdf](https://m.example.com/file/attachments/u/Scan (2).pdf)"
        XCTAssertEqual(UnifiedNote.local(Draft(text: link)).excerpt, "Scan (2).pdf")
    }
}
