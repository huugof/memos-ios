import XCTest
import SwiftUI
@testable import Quoote

@MainActor
final class AttachmentTileLayoutTests: XCTestCase {

    private func renderedSize<V: View>(_ view: V) -> CGSize? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size
    }

    func testAFileTileIsFiftySixPointsSquare() {
        let file = NoteAttachment(target: "/file/attachments/u/a.pdf", name: "a.pdf", kind: .file)
        XCTAssertEqual(renderedSize(AttachmentTile(attachment: file)), CGSize(width: 56, height: 56))
    }

    func testAnImageTileIsFiftySixPointsSquareBeforeItsPictureArrives() {
        let image = NoteAttachment(target: "/file/attachments/u/a.jpg", name: "a.jpg", kind: .image)
        XCTAssertEqual(renderedSize(AttachmentTile(attachment: image)), CGSize(width: 56, height: 56))
    }

    func testTheExtraBadgeDoesNotChangeTheTileSize() {
        let file = NoteAttachment(target: "/file/attachments/u/a.pdf", name: "a.pdf", kind: .file)
        XCTAssertEqual(renderedSize(AttachmentTile(attachment: file, extra: 12)), CGSize(width: 56, height: 56))
    }
}
