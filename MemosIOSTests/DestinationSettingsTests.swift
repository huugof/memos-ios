import XCTest
@testable import MemoChat

final class DestinationSettingsTests: XCTestCase {

    private var original: (DestinationKind, String, String)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        original = (AppSettings.destinationKind, AppSettings.vaultNotesFolder, AppSettings.vaultAttachmentsFolder)
    }

    override func tearDownWithError() throws {
        AppSettings.destinationKind = original.0
        AppSettings.vaultNotesFolder = original.1
        AppSettings.vaultAttachmentsFolder = original.2
        try super.tearDownWithError()
    }

    func testDefaultDestinationIsMemos() {
        UserDefaults.standard.removeObject(forKey: "destinationKind")
        XCTAssertEqual(AppSettings.destinationKind, .memos)
    }

    func testDestinationRoundTrips() {
        AppSettings.destinationKind = .vault
        XCTAssertEqual(AppSettings.destinationKind, .vault)
    }

    func testFolderDefaults() {
        UserDefaults.standard.removeObject(forKey: "vaultNotesFolder")
        UserDefaults.standard.removeObject(forKey: "vaultAttachmentsFolder")
        XCTAssertEqual(AppSettings.vaultNotesFolder, "")
        XCTAssertEqual(AppSettings.vaultAttachmentsFolder, "attachments")
    }

    func testFolderSettingsStripSlashes() {
        AppSettings.vaultNotesFolder = "/inbox/"
        XCTAssertEqual(AppSettings.vaultNotesFolder, "inbox")
    }

    func testAllKindsHaveLabels() {
        for kind in DestinationKind.allCases {
            XCTAssertFalse(kind.label.isEmpty)
        }
    }

    func testFolderSettingsDropTraversalSegments() {
        AppSettings.vaultNotesFolder = "../../etc"
        XCTAssertEqual(AppSettings.vaultNotesFolder, "etc")
        AppSettings.vaultNotesFolder = "inbox/../notes/./daily"
        XCTAssertEqual(AppSettings.vaultNotesFolder, "inbox/notes/daily")
        AppSettings.vaultAttachmentsFolder = ".."
        XCTAssertEqual(AppSettings.vaultAttachmentsFolder, "")
    }
}
