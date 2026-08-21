import XCTest
@testable import MemoChat

final class NoteTextViewListEditingTests: XCTestCase {
    func testNormalizesUnorderedListSpaceInsertionToTab() {
        let text = "-"

        let normalization = NoteTextViewListEditing.normalizedSpaceInsertion(in: text, caretLocation: 1)

        XCTAssertEqual(
            normalization,
            NoteTextViewListEditing.SpaceInsertionNormalization(
                lineRange: NSRange(location: 0, length: 1),
                replacementLine: "-\t"
            )
        )
    }

    func testNormalizesDelimitedOrderedListSpaceInsertionToTab() {
        let text = "1."

        let normalization = NoteTextViewListEditing.normalizedSpaceInsertion(in: text, caretLocation: 2)

        XCTAssertEqual(
            normalization,
            NoteTextViewListEditing.SpaceInsertionNormalization(
                lineRange: NSRange(location: 0, length: 2),
                replacementLine: "1.\t"
            )
        )
    }

    func testNormalizesBareOrderedListSpaceInsertionToTab() {
        let text = "1"

        let normalization = NoteTextViewListEditing.normalizedSpaceInsertion(in: text, caretLocation: 1)

        XCTAssertEqual(
            normalization,
            NoteTextViewListEditing.SpaceInsertionNormalization(
                lineRange: NSRange(location: 0, length: 1),
                replacementLine: "1\t"
            )
        )
    }

    func testDoesNotNormalizeSpaceInsertionInPlainText() {
        XCTAssertNil(NoteTextViewListEditing.normalizedSpaceInsertion(in: "hello", caretLocation: 5))
        XCTAssertNil(NoteTextViewListEditing.normalizedSpaceInsertion(in: "version 1", caretLocation: 9))
    }

    func testContinuationPreservesTabSeparatedBareOrderedListStyle() {
        let continuation = NoteTextViewListEditing.continuationPrefix(for: "1\tfirst item")

        XCTAssertEqual(continuation, "2\t")
    }

    func testNormalizesTaskTabToSpace() {
        let text = "-\t[ ] hello"

        let normalization = NoteTextViewListEditing.normalizedTaskTab(in: text, caretLocation: 11)

        XCTAssertEqual(
            normalization,
            NoteTextViewListEditing.SpaceInsertionNormalization(
                lineRange: NSRange(location: 0, length: 11),
                replacementLine: "- [ ] hello"
            )
        )
    }

    func testDoesNotNormalizeTaskWithoutTab() {
        XCTAssertNil(NoteTextViewListEditing.normalizedTaskTab(in: "- [ ] hello", caretLocation: 11))
    }

    func testDoesNotNormalizeTabInNonTaskLine() {
        XCTAssertNil(NoteTextViewListEditing.normalizedTaskTab(in: "-\thello", caretLocation: 7))
    }

    func testExitReplacementSupportsBareOrderedListWithSeparator() {
        XCTAssertEqual(NoteTextViewListEditing.exitListReplacement(for: "1\t"), "")
        XCTAssertEqual(NoteTextViewListEditing.exitListReplacement(for: "1 "), "")
        XCTAssertNil(NoteTextViewListEditing.exitListReplacement(for: "1"))
    }
}
