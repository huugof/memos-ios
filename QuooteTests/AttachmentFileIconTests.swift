import XCTest
@testable import Quoote

final class AttachmentFileIconTests: XCTestCase {

    func testTheSymbolFollowsTheFileType() {
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "Report.pdf"), "doc.richtext")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "song.mp3"), "waveform")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "clip.mov"), "film")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "bundle.zip"), "doc.zipper")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "notes.txt"), "doc.text")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "logo.svg"), "photo")
    }

    func testAnUnknownOrMissingExtensionIsAGenericDocument() {
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "mystery.zzzzz"), "doc")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: "README"), "doc")
        XCTAssertEqual(AttachmentFileIcon.symbol(forFilename: ""), "doc")
    }

    func testTheLabelIsTheUppercasedExtensionAtMostFourLong() {
        XCTAssertEqual(AttachmentFileIcon.label(forFilename: "Report.pdf"), "PDF")
        XCTAssertEqual(AttachmentFileIcon.label(forFilename: "archive.tar.gz"), "GZ")
        XCTAssertEqual(AttachmentFileIcon.label(forFilename: "book.markdown"), "MARK")
        XCTAssertEqual(AttachmentFileIcon.label(forFilename: "README"), "")
    }
}
