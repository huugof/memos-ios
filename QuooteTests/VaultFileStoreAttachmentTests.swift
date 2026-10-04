import XCTest
@testable import Quoote

final class VaultFileStoreAttachmentTests: XCTestCase {

    private var root: URL!
    private var store: VaultFileStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultFileStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func put(_ relativePath: String, _ data: Data = Data("x".utf8)) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func locate(_ target: String, folder: String = "attachments", note: String? = nil) -> String? {
        store.locateAttachment(target, attachmentsFolder: folder, notePath: note)
    }

    // MARK: Where a target lives

    func testTheAttachmentsFolderIsLookedInFirst() throws {
        try put("attachments/a.png")
        try put("a.png")
        try put("notes/a.png")
        XCTAssertEqual(locate("a.png", note: "notes/n.md"), "attachments/a.png")
    }

    func testThenTheVaultRoot() throws {
        try put("a.png")
        try put("notes/a.png")
        XCTAssertEqual(locate("a.png", note: "notes/n.md"), "a.png")
    }

    func testThenTheFolderOfTheNoteThatLinksIt() throws {
        try put("notes/a.png")
        try put("elsewhere/a.png")
        XCTAssertEqual(locate("a.png", note: "notes/n.md"), "notes/a.png")
    }

    func testThenAnywhereInTheVaultIgnoringCase() throws {
        try put("Deep/Er/Photo.PNG")
        XCTAssertEqual(locate("photo.png"), "Deep/Er/Photo.PNG")
    }

    func testAPathTargetIsTriedAsWritten() throws {
        try put("assets/2024/a.png")
        XCTAssertEqual(locate("assets/2024/a.png", folder: ""), "assets/2024/a.png")
        XCTAssertEqual(locate("2024/a.png", folder: "assets"), "assets/2024/a.png")
    }

    func testAnAttachmentsFolderSettingOfNothingMeansTheRoot() throws {
        try put("a.png")
        XCTAssertEqual(locate("a.png", folder: ""), "a.png")
    }

    func testAMissingFileIsNil() {
        XCTAssertNil(locate("nope.png"))
    }

    func testTargetsThatEscapeTheVaultAreRefused() throws {
        try put("secret/a.png")
        XCTAssertNil(locate("../a.png"))
        XCTAssertNil(locate("attachments/../../a.png"))
        XCTAssertNil(locate("/etc/hosts"))
        XCTAssertNil(locate("/a.png"))
        XCTAssertNil(locate(""))
        XCTAssertNil(locate("./a.png"))
    }

    func testTheWalkSkipsObsidianConfigTheTrashAndHiddenFolders() throws {
        try put(".obsidian/a.png")
        try put(".trash/a.png")
        try put(".hidden/a.png")
        XCTAssertNil(locate("a.png"))

        try put("kept/a.png")
        XCTAssertEqual(locate("a.png"), "kept/a.png")
    }

    func testAFolderNamedLikeTheFileIsNotTheFile() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("a.png"), withIntermediateDirectories: true)
        XCTAssertNil(locate("a.png", folder: ""), "a directory is not a picture")
    }

    // MARK: iCloud placeholders

    func testAnEvictedFileIsFoundThroughItsPlaceholderUnderTheRealName() throws {
        try put("attachments/.photo.jpg.icloud")
        XCTAssertEqual(locate("photo.jpg"), "attachments/photo.jpg")
    }

    func testAnEvictedFileFoundByTheWalkIsReportedUnderTheRealName() throws {
        try put("deep/folder/.photo.jpg.icloud")
        XCTAssertEqual(locate("photo.jpg"), "deep/folder/photo.jpg")
    }

    func testAPlaceholderIsNeverReadAsAPicture() throws {
        try put("attachments/.photo.jpg.icloud", Data("placeholder, not image bytes".utf8))

        guard case .notDownloaded = store.attachmentThumbnail(at: "attachments/photo.jpg", maxPixel: 192) else {
            return XCTFail("an evicted file must report .notDownloaded, not be read")
        }
    }

    // MARK: Thumbnails

    func testAPictureComesBackDownsampledWithItsModificationDate() throws {
        try put("attachments/p.png", TestImages.png(width: 600, height: 300))

        guard case .image(let image, let modified) = store.attachmentThumbnail(at: "attachments/p.png", maxPixel: 192) else {
            return XCTFail("expected an image")
        }
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 96)
        XCTAssertEqual(modified, store.attachmentModificationDate(at: "attachments/p.png"))
    }

    func testAFileThatIsNotAPictureIsUnreadable() throws {
        try put("attachments/notes.txt", Data("just words".utf8))
        guard case .unreadable = store.attachmentThumbnail(at: "attachments/notes.txt", maxPixel: 192) else {
            return XCTFail("expected .unreadable")
        }
    }

    func testAFileThatIsNotThereIsUnreadable() {
        guard case .unreadable = store.attachmentThumbnail(at: "attachments/gone.png", maxPixel: 192) else {
            return XCTFail("expected .unreadable")
        }
        XCTAssertNil(store.attachmentModificationDate(at: "attachments/gone.png"))
    }

    func testAReplacedFileHasANewModificationDate() throws {
        try put("a.png", TestImages.png(width: 100, height: 100))
        let before = store.attachmentModificationDate(at: "a.png")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: root.appendingPathComponent("a.png").path
        )
        XCTAssertNotEqual(store.attachmentModificationDate(at: "a.png"), before)
    }
}
