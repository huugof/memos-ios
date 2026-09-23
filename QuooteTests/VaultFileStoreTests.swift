import XCTest
@testable import Quoote

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

    /// Minor 6: a file whose metadata can't be read must not fail the whole
    /// listing — it should just be skipped, leaving every other file intact.
    ///
    /// A genuine OS-level `resourceValues` failure for an entry that
    /// `FileManager`'s enumerator has already yielded turns out to be
    /// impossible to force deterministically in a plain temp directory:
    /// the enumerator eagerly `lstat`s every entry as part of producing it
    /// (confirmed experimentally — symlink loops up to depth 40, dangling
    /// symlink targets, POSIX mode 000, and an ACL `deny readattr` entry all
    /// still resolve without error). The real trigger is a transient
    /// iCloud/file-provider failure, which needs a real ubiquitous
    /// container. So this test instead pins the *contract*: `listMarkdownFiles`
    /// never throws just because a listed entry is unusual (here, a symlink
    /// whose target doesn't exist), and every real file is still returned.
    func testListToleratesUnusualDirectoryEntriesWithoutFailing() throws {
        try writeFile("good.md", "# Good\n")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling.md"),
            withDestinationURL: root.appendingPathComponent("does-not-exist.md")
        )

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(Set(files.map(\.relativePath)), ["good.md", "dangling.md"])
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

    /// I3: a swipe-delete moves the file to `.trash/` (Obsidian's own trash
    /// convention) rather than deleting it outright, so it isn't
    /// unrecoverable for a note that also lives on the desktop vault.
    func testDeleteRemovesFile() throws {
        try writeFile("bye.md", "x\n")
        try store.delete(relativePath: "bye.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bye.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".trash/bye.md").path))
    }

    /// I3: a second delete of a same-named file must not clobber the first
    /// trashed copy — disambiguate with " 2", " 3", … the same way conflict
    /// copies and new attachment files do.
    func testDeleteDisambiguatesAgainstExistingTrashName() throws {
        try writeFile("note.md", "first\n")
        try store.delete(relativePath: "note.md")

        try writeFile("note.md", "second\n")
        try store.delete(relativePath: "note.md")

        let firstTrashed = try String(contentsOf: root.appendingPathComponent(".trash/note.md"), encoding: .utf8)
        let secondTrashed = try String(contentsOf: root.appendingPathComponent(".trash/note 2.md"), encoding: .utf8)
        XCTAssertEqual(firstTrashed, "first\n")
        XCTAssertEqual(secondTrashed, "second\n")
    }

    /// I3: deleting a path that's already missing counts as success.
    func testDeleteOfMissingSourceDoesNotThrow() throws {
        XCTAssertNoThrow(try store.delete(relativePath: "never-existed.md"))
    }

    /// Follow-up A (batch-3 review): `.trash` flattens subfolders by design —
    /// Obsidian's own "move to Obsidian trash" always drops items at the
    /// trash root regardless of parent folder, so that part is intentionally
    /// left as-is. What must hold is that two same-named notes from
    /// DIFFERENT subfolders never clobber each other once flattened: they
    /// disambiguate to distinct trash names, each with its original,
    /// untouched contents.
    func testDeleteFromDifferentSubfoldersDisambiguatesWithoutClobbering() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Projects/2020", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes/2021", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeFile("Projects/2020/meeting.md", "from 2020 projects\n")
        try writeFile("Notes/2021/meeting.md", "from 2021 notes\n")

        try store.delete(relativePath: "Projects/2020/meeting.md")
        try store.delete(relativePath: "Notes/2021/meeting.md")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Projects/2020/meeting.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/2021/meeting.md").path))

        let firstTrashed = try String(contentsOf: root.appendingPathComponent(".trash/meeting.md"), encoding: .utf8)
        let secondTrashed = try String(contentsOf: root.appendingPathComponent(".trash/meeting 2.md"), encoding: .utf8)
        XCTAssertEqual(firstTrashed, "from 2020 projects\n")
        XCTAssertEqual(secondTrashed, "from 2021 notes\n")
    }

    /// I3: trashed files must never resurface in the note listing.
    func testListSkipsTrashFolder() throws {
        try writeFile("keep.md", "# Keep\n")
        try writeFile("gone.md", "# Gone\n")
        try store.delete(relativePath: "gone.md")

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(files.map(\.relativePath), ["keep.md"])
    }

    /// I5: attachment (and other new-file) writes go through a temp file and
    /// a coordinated move, but the visible behavior is the same as a direct
    /// write: the bytes land at the requested path.
    func testWriteNewFileWritesDataAtPreferredName() throws {
        let data = Data([0x01, 0x02, 0x03])
        let path = try store.writeNewFile(data, preferredName: "shot.png", inSubfolder: "attachments")

        XCTAssertEqual(path, "attachments/shot.png")
        let onDisk = try Data(contentsOf: root.appendingPathComponent(path))
        XCTAssertEqual(onDisk, data)
    }

    /// I5: reuses the shared " 2"/" 3" disambiguation rather than overwriting.
    func testWriteNewFileDisambiguatesAgainstExistingFile() throws {
        let first = try store.writeNewFile(Data([0x01]), preferredName: "shot.png", inSubfolder: "attachments")
        let second = try store.writeNewFile(Data([0x02]), preferredName: "shot.png", inSubfolder: "attachments")

        XCTAssertEqual(first, "attachments/shot.png")
        XCTAssertEqual(second, "attachments/shot 2.png")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first)), Data([0x01]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(second)), Data([0x02]))
    }

    /// I5: the temp file used for the coordinated move must not survive a
    /// failed move. Force the move to fail with a read-only destination
    /// directory (existence check and listing still succeed; only the
    /// `moveItem` write is refused), which is what actually happens on
    /// `moveItem` failure — a directory-vs-file name collision would just
    /// get disambiguated to a different, non-colliding name instead.
    func testWriteNewFileCleansUpTempFileOnFailure() throws {
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: attachments.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: attachments.path) }

        let tempDir = FileManager.default.temporaryDirectory
        let before = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)

        XCTAssertThrowsError(try store.writeNewFile(Data([0x01]), preferredName: "shot.png", inSubfolder: "attachments"))

        let after = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(Set(after).subtracting(before), [], "the temp file created for the failed move must be cleaned up")
    }

    // Follow-up B (batch-3 review): `writeNewFile` now also cleans up the
    // temp file if the INITIAL `data.write(to: tempURL)` itself throws (e.g.
    // disk full), not just on the coordination/move failure paths above —
    // see VaultFileStore.swift. No test is added for this one specifically:
    // the only locally-reproducible way to make that initial write fail
    // (chmod'ing the temp directory to deny entry creation, the same
    // technique `testWriteNewFileCleansUpTempFileOnFailure` above uses for
    // the move step) blocks the file from being created at all, so "no temp
    // file is left behind" holds trivially whether or not the new cleanup
    // code runs — it doesn't discriminate the fix from its absence. I
    // confirmed this by running that technique against the pre-fix code and
    // watching the assertion pass anyway. A genuine repro needs either an
    // actual disk-full condition or making `FileManager` injectable into
    // `VaultFileStore` so a test double can simulate a write that creates a
    // partial file and then throws — both out of scope for this low-severity
    // fix, so per the brief's 2-attempt cap this falls back to review of the
    // 3-line change instead of a test.

    func testExistingFilenamesInSubfolder() throws {
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try "a".write(to: inbox.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try store.existingFilenames(inSubfolder: "inbox"), ["one.md"])
        XCTAssertEqual(try store.existingFilenames(inSubfolder: "missing"), [])
    }

    // MARK: - I4: iCloud placeholders

    /// A not-yet-downloaded (or evicted) iCloud file is represented on disk
    /// as a dot-prefixed `.Name.md.icloud` placeholder. `listMarkdownFiles`
    /// must surface it as `Name.md` with `needsDownload == true` — not hide
    /// it (as `.skipsHiddenFiles` used to) and not list it under its raw
    /// on-disk name.
    func testListMapsICloudPlaceholderToRealNameWithNeedsDownload() throws {
        try writeFile(".Foo.md.icloud", "placeholder contents")

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(files.map(\.relativePath), ["Foo.md"])
        XCTAssertEqual(files.first?.needsDownload, true)
    }

    /// Same mapping applies to `existingFilenames`, so `create`'s
    /// same-minute-filename disambiguation sees the placeholder as the real
    /// name and doesn't overwrite a note that already exists (just not yet
    /// downloaded) on another device.
    func testExistingFilenamesMapsICloudPlaceholderToRealName() throws {
        try writeFile(".Foo.md.icloud", "placeholder contents")

        XCTAssertTrue(try store.existingFilenames(inSubfolder: "").contains("Foo.md"))
    }

    /// A regular (non-placeholder) hidden file must still be skipped, same
    /// as `.skipsHiddenFiles` used to do.
    func testListSkipsOrdinaryHiddenFiles() throws {
        try writeFile(".hidden.md", "# Hidden\n")
        try writeFile("visible.md", "# Visible\n")

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(files.map(\.relativePath), ["visible.md"])
    }

    /// A placeholder whose mapped name isn't a `.md` file (e.g. an
    /// attachment) must not be reported by `listMarkdownFiles` — only the
    /// markdown-file listing maps placeholders; other file types aren't
    /// notes.
    func testListIgnoresNonMarkdownICloudPlaceholder() throws {
        try writeFile(".photo.png.icloud", "placeholder")
        try writeFile("real.md", "# Real\n")

        let files = try store.listMarkdownFiles()
        XCTAssertEqual(files.map(\.relativePath), ["real.md"])
    }

    /// Old on-disk `VaultFileMetadata` JSON, persisted before `needsDownload`
    /// existed, must still decode — with the field defaulting to `false`.
    func testVaultFileMetadataDecodesOldJSONWithoutNeedsDownloadKey() throws {
        let oldJSON = """
        {"relativePath":"note.md","modifiedAt":719000000,"fileSize":42}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VaultFileMetadata.self, from: oldJSON)
        XCTAssertEqual(decoded.relativePath, "note.md")
        XCTAssertEqual(decoded.fileSize, 42)
        XCTAssertEqual(decoded.needsDownload, false)
    }
}
