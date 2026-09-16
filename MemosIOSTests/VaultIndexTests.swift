import XCTest
@testable import MemoChat

final class VaultIndexTests: XCTestCase {

    private var originalIndex: [VaultIndexEntry] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalIndex = VaultIndex.load()
    }

    override func tearDownWithError() throws {
        VaultIndex.save(originalIndex)
        try super.tearDownWithError()
    }

    private func entry(_ path: String, modified: TimeInterval, size: Int) -> VaultIndexEntry {
        VaultIndexEntry(
            relativePath: path,
            title: "Title",
            preview: "Preview",
            tags: [],
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: size
        )
    }

    private func metadata(_ path: String, modified: TimeInterval, size: Int) -> VaultFileMetadata {
        VaultFileMetadata(
            relativePath: path,
            modifiedAt: Date(timeIntervalSince1970: modified),
            fileSize: size
        )
    }

    func testUnchangedFilesAreNotReRead() {
        let index = [entry("a.md", modified: 100, size: 10)]
        let disk = [metadata("a.md", modified: 100, size: 10)]
        let diff = VaultIndex.diff(index: index, disk: disk)

        XCTAssertTrue(diff.needsRead.isEmpty)
        XCTAssertEqual(diff.unchanged.map(\.relativePath), ["a.md"])
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testNewFileNeedsRead() {
        let diff = VaultIndex.diff(index: [], disk: [metadata("new.md", modified: 100, size: 10)])
        XCTAssertEqual(diff.needsRead, ["new.md"])
    }

    func testModifiedDateChangeNeedsRead() {
        let index = [entry("a.md", modified: 100, size: 10)]
        let disk = [metadata("a.md", modified: 200, size: 10)]
        XCTAssertEqual(VaultIndex.diff(index: index, disk: disk).needsRead, ["a.md"])
    }

    func testSizeChangeNeedsRead() {
        let index = [entry("a.md", modified: 100, size: 10)]
        let disk = [metadata("a.md", modified: 100, size: 99)]
        XCTAssertEqual(VaultIndex.diff(index: index, disk: disk).needsRead, ["a.md"])
    }

    func testFileGoneFromDiskIsRemoved() {
        let index = [entry("a.md", modified: 100, size: 10)]
        let diff = VaultIndex.diff(index: index, disk: [])
        XCTAssertEqual(diff.removed, ["a.md"])
        XCTAssertTrue(diff.unchanged.isEmpty)
    }

    func testEntryFromNoteCapturesTitleTagsAndPreview() {
        let (frontmatter, body) = Frontmatter.parse("---\ntitle: My Note\n---\nFirst line\nSecond line with #inbox\n")
        let note = VaultNote(
            relativePath: "a.md",
            frontmatter: frontmatter,
            body: body,
            modifiedAt: Date(timeIntervalSince1970: 100),
            fileSize: 42
        )
        let made = VaultIndexEntry.make(from: note)
        XCTAssertEqual(made.title, "My Note")
        XCTAssertEqual(made.tags, ["inbox"])
        XCTAssertEqual(made.preview, "Second line with #inbox")
        XCTAssertEqual(made.fileSize, 42)
    }

    func testSaveThenLoadRoundTrips() {
        let entries = [entry("a.md", modified: 100, size: 10)]
        VaultIndex.save(entries)
        // save() writes synchronously to Application Support.
        XCTAssertEqual(VaultIndex.load(), entries)
        // tearDownWithError restores whatever real index existed before this test.
    }

    func testSubSecondModifiedDateDeltaIsUnchanged() {
        let index = [entry("a.md", modified: 100.0, size: 10)]
        let disk = [metadata("a.md", modified: 100.4, size: 10)]
        let diff = VaultIndex.diff(index: index, disk: disk)
        XCTAssertTrue(diff.needsRead.isEmpty)
        XCTAssertEqual(diff.unchanged.map(\.relativePath), ["a.md"])
    }

    func testOverOneSecondModifiedDateDeltaNeedsRead() {
        let index = [entry("a.md", modified: 100.0, size: 10)]
        let disk = [metadata("a.md", modified: 101.5, size: 10)]
        let diff = VaultIndex.diff(index: index, disk: disk)
        XCTAssertEqual(diff.needsRead, ["a.md"])
        XCTAssertTrue(diff.unchanged.isEmpty)
    }
}
