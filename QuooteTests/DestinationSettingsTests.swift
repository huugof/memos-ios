import XCTest
@testable import Quoote

final class DestinationSettingsTests: XCTestCase {

    private var originalDestinationKind: Any?
    private var originalVaultNotesFolder: Any?
    private var originalVaultAttachmentsFolder: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDestinationKind = UserDefaults.standard.object(forKey: "destinationKind")
        originalVaultNotesFolder = UserDefaults.standard.object(forKey: "vaultNotesFolder")
        originalVaultAttachmentsFolder = UserDefaults.standard.object(forKey: "vaultAttachmentsFolder")
    }

    override func tearDownWithError() throws {
        Self.restore(originalDestinationKind, forKey: "destinationKind")
        Self.restore(originalVaultNotesFolder, forKey: "vaultNotesFolder")
        Self.restore(originalVaultAttachmentsFolder, forKey: "vaultAttachmentsFolder")
        try super.tearDownWithError()
    }

    private static func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
