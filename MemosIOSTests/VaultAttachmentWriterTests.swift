import XCTest
@testable import MemoChat

final class VaultAttachmentWriterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testFilenameFollowsNoteStemAndIndex() {
        let name = VaultAttachmentWriter.filename(
            forNoteNamed: "2026-09-16 2130.md",
            index: 1,
            fileExtension: "png"
        )
        XCTAssertEqual(name, "2026-09-16 2130 1.png")
    }

    func testWikilinkFormat() {
        XCTAssertEqual(VaultAttachmentWriter.wikilink(for: "a b.png"), "![[a b.png]]")
    }

    func testWriteLandsInAttachmentsFolder() throws {
        let store = VaultFileStore(root: root)
        let data = Data([0x89, 0x50, 0x4E, 0x47])

        let path = try VaultAttachmentWriter.write(
            data: data,
            filename: "shot.png",
            using: store,
            folder: "attachments"
        )

        XCTAssertEqual(path, "attachments/shot.png")
        let written = try Data(contentsOf: root.appendingPathComponent(path))
        XCTAssertEqual(written, data)
    }

    func testWriteNeverOverwritesAnExistingAttachment() throws {
        // Two notes captured in the same minute derive the same stem, so their
        // first images would otherwise both be "… 1.png".
        let store = VaultFileStore(root: root)
        let first = try VaultAttachmentWriter.write(
            data: Data([0x01]), filename: "2026-09-16 2130 1.png", using: store, folder: "attachments")
        let second = try VaultAttachmentWriter.write(
            data: Data([0x02]), filename: "2026-09-16 2130 1.png", using: store, folder: "attachments")

        XCTAssertEqual(first, "attachments/2026-09-16 2130 1.png")
        XCTAssertEqual(second, "attachments/2026-09-16 2130 1 2.png")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first)), Data([0x01]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(second)), Data([0x02]))
    }

    func testWriteToVaultRootWhenFolderIsEmpty() throws {
        let store = VaultFileStore(root: root)
        let path = try VaultAttachmentWriter.write(
            data: Data([0x01]),
            filename: "shot.png",
            using: store,
            folder: ""
        )
        XCTAssertEqual(path, "shot.png")
    }
}
