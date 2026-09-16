import XCTest
@testable import MemoChat

final class VaultBookmarkStoreTests: XCTestCase {

    private var originalBookmark: Data?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalBookmark = AppSettings.vaultBookmark
        AppSettings.vaultBookmark = nil
    }

    override func tearDownWithError() throws {
        AppSettings.vaultBookmark = originalBookmark
        try super.tearDownWithError()
    }

    func testResolveThrowsWhenNoVaultConfigured() {
        XCTAssertThrowsError(try VaultBookmarkStore.resolve()) { error in
            XCTAssertEqual(error as? VaultAccessError, .notConfigured)
        }
    }

    func testSaveThenResolveRoundTrips() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try VaultBookmarkStore.save(url: temp)
        XCTAssertNotNil(AppSettings.vaultBookmark)

        let resolved = try VaultBookmarkStore.resolve()
        XCTAssertEqual(resolved.standardizedFileURL.path, temp.standardizedFileURL.path)
    }

    func testClearRemovesBookmark() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try VaultBookmarkStore.save(url: temp)
        VaultBookmarkStore.clear()
        XCTAssertNil(AppSettings.vaultBookmark)
        XCTAssertThrowsError(try VaultBookmarkStore.resolve())
    }

    func testWithAccessHandsBackTheVaultURL() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try VaultBookmarkStore.save(url: temp)
        let path = try VaultBookmarkStore.withAccess { $0.standardizedFileURL.path }
        XCTAssertEqual(path, temp.standardizedFileURL.path)
    }
}
