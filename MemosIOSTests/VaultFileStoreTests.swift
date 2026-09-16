import XCTest
@testable import MemoChat

final class VaultFileStoreTests: XCTestCase {

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

    private func writeFile(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testListsOnlyMarkdownFiles() throws {
        try writeFile("one.md", "# One\n")
        try writeFile("two.md", "# Two\n")
        try writeFile("image.png", "not markdown")

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(Set(files.map(\.relativePath)), ["one.md", "two.md"])
    }

    func testListsMarkdownFilesInSubfolders() throws {
        let nested = root.appendingPathComponent("daily", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Nested\n".write(to: nested.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(files.map(\.relativePath), ["daily/note.md"])
    }

    func testListSkipsObsidianConfigFolder() throws {
        let config = root.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "{}".write(to: config.appendingPathComponent("workspace.md"), atomically: true, encoding: .utf8)
        try writeFile("real.md", "# Real\n")

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(files.map(\.relativePath), ["real.md"])
    }

    func testReadSplitsFrontmatterFromBody() throws {
        try writeFile("note.md", "---\ntitle: Hello\n---\nBody text\n")
        let note = try store.read(relativePath: "note.md")
        XCTAssertEqual(note.relativePath, "note.md")
        XCTAssertEqual(note.body, "Body text\n")
        XCTAssertEqual(note.frontmatter?.value(for: "title"), "Hello")
        XCTAssertGreaterThan(note.fileSize, 0)
    }

    func testWriteCreatesFileAndReturnsMetadata() throws {
        let metadata = try store.write("# New\n", to: "new.md")
        XCTAssertEqual(metadata.relativePath, "new.md")
        let onDisk = try String(contentsOf: root.appendingPathComponent("new.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "# New\n")
    }

    func testWriteCreatesIntermediateDirectories() throws {
        _ = try store.write("# Nested\n", to: "inbox/deep/note.md")
        let onDisk = try String(contentsOf: root.appendingPathComponent("inbox/deep/note.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "# Nested\n")
    }

    func testWriteCheckedWritesWhenFileUnchanged() throws {
        try writeFile("note.md", "original\n")
        let metadata = try store.listMarkdownFiles().first { $0.relativePath == "note.md" }!

        let result = try store.writeChecked("updated\n", to: "note.md", expecting: metadata)
        guard case .written = result else {
            return XCTFail("expected .written, got \(result)")
        }
        let onDisk = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "updated\n")
    }

    /// The whole point of the conflict policy: the external edit survives.
    func testWriteCheckedMakesConflictCopyWhenFileChangedExternally() throws {
        try writeFile("note.md", "original\n")
        let stale = VaultFileMetadata(
            relativePath: "note.md",
            modifiedAt: Date(timeIntervalSince1970: 0),
            fileSize: 999
        )

        let result = try store.writeChecked("mine\n", to: "note.md", expecting: stale)
        guard case .conflictCopy(let path, _) = result else {
            return XCTFail("expected .conflictCopy, got \(result)")
        }
        XCTAssertTrue(path.hasPrefix("note (conflict "))
        XCTAssertTrue(path.hasSuffix(").md"))

        // Original untouched, ours saved alongside it.
        let original = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertEqual(original, "original\n")
        let copy = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        XCTAssertEqual(copy, "mine\n")
    }

    /// A note deleted on the desktop must not be resurrected at its old path.
    func testWriteCheckedOnMissingFileWritesFresh() throws {
        let stale = VaultFileMetadata(
            relativePath: "gone.md",
            modifiedAt: Date(timeIntervalSince1970: 0),
            fileSize: 10
        )
        let result = try store.writeChecked("text\n", to: "gone.md", expecting: stale)
        guard case .written = result else {
            return XCTFail("expected .written, got \(result)")
        }
    }

    func testDeleteRemovesFile() throws {
        try writeFile("bye.md", "x\n")
        try store.delete(relativePath: "bye.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bye.md").path))
    }

    func testExistingFilenamesInSubfolder() throws {
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try "a".write(to: inbox.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try store.existingFilenames(inSubfolder: "inbox"), ["one.md"])
        XCTAssertEqual(try store.existingFilenames(inSubfolder: "missing"), [])
    }
}
