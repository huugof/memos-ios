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
}
