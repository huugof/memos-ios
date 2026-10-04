import XCTest
import SwiftUI
@testable import Quoote

@MainActor
final class AttachmentBarLayoutTests: XCTestCase {

    private func height(of bar: AttachmentBar) -> CGFloat {
        let renderer = ImageRenderer(content: bar.frame(width: 390))
        renderer.scale = 1
        return renderer.uiImage?.size.height ?? 0
    }

    func testTheStripIsSeventyTwoPointsTallWithAnExistingFile() {
        let file = NoteAttachment(target: "Report.pdf", name: "Report.pdf", kind: .file)
        let bar = AttachmentBar(existing: [file], pendingImages: .constant([]), pendingFiles: .constant([]))
        XCTAssertEqual(height(of: bar), AttachmentBar.height)
    }

    func testTheStripKeepsItsHeightWithExistingPicturesAndPendingFiles() {
        let photo = NoteAttachment(target: "trip.jpg", name: "trip.jpg", kind: .image)
        var pending = PendingFile(filename: "Notes.txt")
        pending.isUploading = false
        let bar = AttachmentBar(existing: [photo], pendingImages: .constant([]), pendingFiles: .constant([pending]))
        XCTAssertEqual(height(of: bar), AttachmentBar.height)
    }
}
