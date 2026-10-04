import XCTest
@testable import Quoote

final class ThumbnailDiskCacheTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func bytes(_ count: Int) -> Data { Data(repeating: 7, count: count) }

    func testStoredBytesComeBackAndUnknownKeysDoNot() {
        let cache = ThumbnailDiskCache(directory: directory)
        XCTAssertNil(cache.data(forKey: "https://m.example.com/a.jpg"))

        cache.store(bytes(10), forKey: "https://m.example.com/a.jpg")
        XCTAssertEqual(cache.data(forKey: "https://m.example.com/a.jpg"), bytes(10))
        XCTAssertNil(cache.data(forKey: "https://m.example.com/b.jpg"))
    }

    func testFileNamesAreAStableHashOfTheKey() {
        let name = ThumbnailDiskCache.fileName(forKey: "https://m.example.com/a.jpg")
        XCTAssertEqual(name, ThumbnailDiskCache.fileName(forKey: "https://m.example.com/a.jpg"))
        XCTAssertNotEqual(name, ThumbnailDiskCache.fileName(forKey: "https://m.example.com/b.jpg"))
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertEqual(name.count, 64 + 4)
        XCTAssertFalse(name.contains("/"), "a URL must never become a path")
    }

    func testTrimDropsTheOldestFilesFirstUntilItFits() throws {
        let cache = ThumbnailDiskCache(directory: directory, maxBytes: 250, trimEvery: 1_000)
        for index in 0..<5 {
            cache.store(bytes(100), forKey: "k\(index)")
            // Distinct, known ages: k0 is the oldest.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))],
                ofItemAtPath: directory.appendingPathComponent(ThumbnailDiskCache.fileName(forKey: "k\(index)")).path
            )
        }

        cache.trim()

        XCTAssertNil(cache.data(forKey: "k0"))
        XCTAssertNil(cache.data(forKey: "k1"))
        XCTAssertNil(cache.data(forKey: "k2"))
        XCTAssertNotNil(cache.data(forKey: "k3"))
        XCTAssertNotNil(cache.data(forKey: "k4"))
    }

    func testTrimLeavesACacheUnderTheCapAlone() {
        let cache = ThumbnailDiskCache(directory: directory, maxBytes: 1_000, trimEvery: 1_000)
        cache.store(bytes(100), forKey: "a")
        cache.store(bytes(100), forKey: "b")
        cache.trim()
        XCTAssertNotNil(cache.data(forKey: "a"))
        XCTAssertNotNil(cache.data(forKey: "b"))
    }

    func testTheCacheTrimsItselfEveryFewWrites() throws {
        let cache = ThumbnailDiskCache(directory: directory, maxBytes: 150, trimEvery: 3)
        cache.store(bytes(100), forKey: "a")
        cache.store(bytes(100), forKey: "b")
        XCTAssertNotNil(cache.data(forKey: "a"), "no trim yet: only two writes")
        // Known ages, so which file is oldest doesn't depend on the clock between writes.
        for (index, key) in ["a", "b"].enumerated() {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))],
                ofItemAtPath: directory.appendingPathComponent(ThumbnailDiskCache.fileName(forKey: key)).path
            )
        }

        cache.store(bytes(100), forKey: "c")   // the third write triggers a trim to 150 bytes

        XCTAssertNil(cache.data(forKey: "a"))
        XCTAssertNil(cache.data(forKey: "b"))
        XCTAssertNotNil(cache.data(forKey: "c"))
    }

    func testTrimOfAFolderThatDoesNotExistYetIsHarmless() {
        ThumbnailDiskCache(directory: directory).trim()
    }
}
