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

        let result = try store.writeChecked("updated\n", to: "note.md", expectedText: "original\n")
        guard case .written = result else {
            return XCTFail("expected .written, got \(result)")
        }
        let onDisk = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "updated\n")
    }

    /// The whole point of the conflict policy: the external edit survives.
    func testWriteCheckedMakesConflictCopyWhenFileChangedExternally() throws {
        try writeFile("note.md", "original\n")

        let result = try store.writeChecked("mine\n", to: "note.md", expectedText: "stale content\n")
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

    /// Regression for the conflict-detection hole found in round 1: mtime+size
    /// missed an external edit that preserved byte count and landed within the
    /// same wall-clock second as the read. Content comparison must not.
    func testWriteCheckedDetectsSameSecondSameSizeExternalEdit() throws {
        try writeFile("note.md", "aaaaaa\n")

        // "External" edit: same byte count, happens well within the same
        // second as the read below — exactly the case mtime+size could miss.
        try writeFile("note.md", "bbbbbb\n")

        let result = try store.writeChecked("mine\n", to: "note.md", expectedText: "aaaaaa\n")
        guard case .conflictCopy(let path, _) = result else {
            return XCTFail("expected .conflictCopy, got \(result)")
        }

        // The external edit must survive untouched, not just the enum case.
        let original = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertEqual(original, "bbbbbb\n")
        let copy = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        XCTAssertEqual(copy, "mine\n")
    }

    /// Regression for round 2: conflictPath stamps at minute granularity with
    /// no disambiguator, and write() atomically *replaces* an existing file
    /// rather than failing — so two conflicts on the same note inside one
    /// wall-clock minute must not let the second destroy the first.
    func testWriteCheckedSecondConflictInSameMinuteDoesNotDestroyFirst() throws {
        try writeFile("note.md", "original\n")

        let first = try store.writeChecked("first conflict\n", to: "note.md", expectedText: "not what's on disk\n")
        guard case .conflictCopy(let firstPath, _) = first else {
            return XCTFail("expected .conflictCopy, got \(first)")
        }

        let second = try store.writeChecked("second conflict\n", to: "note.md", expectedText: "still not what's on disk\n")
        guard case .conflictCopy(let secondPath, _) = second else {
            return XCTFail("expected .conflictCopy, got \(second)")
        }

        XCTAssertNotEqual(firstPath, secondPath, "the two conflict copies must not share a path")

        // Both survive on disk with their own distinct content — the actual
        // bytes, not just two distinct paths.
        let firstContents = try String(contentsOf: root.appendingPathComponent(firstPath), encoding: .utf8)
        XCTAssertEqual(firstContents, "first conflict\n")
        let secondContents = try String(contentsOf: root.appendingPathComponent(secondPath), encoding: .utf8)
        XCTAssertEqual(secondContents, "second conflict\n")

        // And the original itself is still untouched throughout.
        let original = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertEqual(original, "original\n")
    }

    /// A note deleted on the desktop must not be resurrected at its old path —
    /// the in-app edit is saved as a conflict copy instead, exactly like an
    /// external edit, so nothing silently reappears where the desktop just
    /// deleted it.
    func testWriteCheckedOnMissingFileWritesConflictCopyNotOriginalPath() throws {
        let result = try store.writeChecked("text\n", to: "gone.md", expectedText: "whatever was there before\n")
        guard case .conflictCopy(let path, _) = result else {
            return XCTFail("expected .conflictCopy, got \(result)")
        }
        XCTAssertNotEqual(path, "gone.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gone.md").path))
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
