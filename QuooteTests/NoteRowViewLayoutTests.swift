import XCTest
import SwiftUI
@testable import Quoote

@MainActor
final class NoteRowViewLayoutTests: XCTestCase {

    private func row(attachments: [NoteAttachment]?) -> NoteRowView {
        let entry = VaultIndexEntry(
            relativePath: "a.md", title: "Hello", preview: "Hello there", tags: [],
            modifiedAt: Date(), fileSize: 1, attachments: attachments
        )
        return NoteRowView(note: .vault(entry))
    }

    private func height(of view: NoteRowView) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: 320))
        renderer.scale = 1
        return renderer.uiImage?.size.height ?? 0
    }

    func testARowWithoutAttachmentsIsShorterThanTheTile() {
        XCTAssertLessThan(height(of: row(attachments: [])), AttachmentTile.size)
    }

    func testARowWithAnAttachmentGrowsToHoldTheTile() {
        let file = NoteAttachment(target: "Report.pdf", name: "Report.pdf", kind: .file)
        XCTAssertGreaterThanOrEqual(height(of: row(attachments: [file])), AttachmentTile.size)
    }

    func testANoteNotScannedYetRendersLikeOneWithNothingAttached() {
        XCTAssertEqual(height(of: row(attachments: nil)), height(of: row(attachments: [])))
    }
}
