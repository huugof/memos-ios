import XCTest
@testable import MemoChat

@MainActor
final class VaultStoreTests: XCTestCase {

    private var root: URL!
    private var store: VaultStore!
    private var originalNotesFolderValue: Any?
    private var originalIndex: [VaultIndexEntry] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Capture presence, not just value, so a machine with no saved folder
        // (key absent) is restored to "absent", not to "" — see
        // DestinationSettingsTests for the same pattern.
        originalNotesFolderValue = UserDefaults.standard.object(forKey: "vaultNotesFolder")
        // Capture the real on-disk index rather than wiping it permanently —
        // VaultIndex.save([]) below is for test isolation only.
        originalIndex = VaultIndex.load()

        AppSettings.vaultNotesFolder = ""
        let fileStore = VaultFileStore(root: root)
        store = VaultStore(storeProvider: { fileStore })
        VaultIndex.save([])
    }

    override func tearDownWithError() throws {
        if let originalNotesFolderValue {
            UserDefaults.standard.set(originalNotesFolderValue, forKey: "vaultNotesFolder")
        } else {
            UserDefaults.standard.removeObject(forKey: "vaultNotesFolder")
        }
        VaultIndex.save(originalIndex)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testCreateWritesFileWithFrontmatter() throws {
        let entry = try store.create(body: "Hello #inbox\n", now: Date())

        let onDisk = try String(contentsOf: root.appendingPathComponent(entry.relativePath), encoding: .utf8)
        XCTAssertTrue(onDisk.hasPrefix("---\n"))
        XCTAssertTrue(onDisk.contains("tags: [inbox]\n"))
        XCTAssertTrue(onDisk.hasSuffix("Hello #inbox\n"))
        XCTAssertEqual(store.entries.first?.relativePath, entry.relativePath)
    }

    func testCreateHonoursNotesSubfolder() throws {
        AppSettings.vaultNotesFolder = "inbox"
        let entry = try store.create(body: "In a folder\n", now: Date())
        XCTAssertTrue(entry.relativePath.hasPrefix("inbox/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.relativePath).path))
    }

    func testRefreshPicksUpExternallyCreatedFiles() async throws {
        try "---\ntitle: External\n---\nMade on the desktop\n"
            .write(to: root.appendingPathComponent("external.md"), atomically: true, encoding: .utf8)

        await store.refresh()

        XCTAssertEqual(store.entries.map(\.relativePath), ["external.md"])
        XCTAssertEqual(store.entries.first?.title, "External")
    }

    func testRefreshDropsDeletedFiles() async throws {
        let entry = try store.create(body: "Temporary\n", now: Date())
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.relativePath))

        await store.refresh()

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testUpdateRewritesBodyAndBumpsUpdated() throws {
        let entry = try store.create(body: "Original\n", now: Date(timeIntervalSince1970: 1_000_000))
        let note = try store.read(relativePath: entry.relativePath)

        let result = try store.update(note: note, body: "Revised\n", now: Date(timeIntervalSince1970: 2_000_000)).result
        guard case .written = result else {
            return XCTFail("expected .written, got \(result)")
        }

        let onDisk = try String(contentsOf: root.appendingPathComponent(entry.relativePath), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Revised\n"))
        XCTAssertTrue(onDisk.contains("updated: 1970-01-24T"))
    }

    func testUpdateAfterExternalChangeMakesConflictCopy() throws {
        let entry = try store.create(body: "Mine\n", now: Date())
        let note = try store.read(relativePath: entry.relativePath)

        // Simulate a desktop edit after we loaded the note.
        try "---\ntitle: Theirs\n---\nTheirs\n"
            .write(to: root.appendingPathComponent(entry.relativePath), atomically: true, encoding: .utf8)

        let result = try store.update(note: note, body: "Mine revised\n", now: Date()).result
        guard case .conflictCopy(let path, _) = result else {
            return XCTFail("expected .conflictCopy, got \(result)")
        }
        XCTAssertEqual(store.lastConflictPath, path)

        let theirs = try String(contentsOf: root.appendingPathComponent(entry.relativePath), encoding: .utf8)
        XCTAssertTrue(theirs.contains("Theirs\n"))
    }

    /// D9/I6: the editor's next baseline is the exact text written, never a
    /// re-read that could pick up a concurrent desktop write.
    func testUpdateReturnsNoteBuiltFromWrittenText() throws {
        let entry = try store.create(body: "Original\n", now: Date())
        let note = try store.read(relativePath: entry.relativePath)

        let outcome = try store.update(note: note, body: "Revised #tag\n", now: Date())
        guard case .written(let metadata) = outcome.result else {
            return XCTFail("expected .written, got \(outcome.result)")
        }
        let onDisk = try String(contentsOf: root.appendingPathComponent(entry.relativePath), encoding: .utf8)
        XCTAssertEqual(outcome.note.originalText, onDisk)
        XCTAssertEqual(outcome.note.relativePath, entry.relativePath)
        XCTAssertEqual(outcome.note.body, "Revised #tag\n")
        XCTAssertEqual(outcome.note.fileSize, metadata.fileSize)
        XCTAssertEqual(outcome.note.frontmatter, Frontmatter.parse(onDisk).frontmatter)

        // A second save from the returned note is a plain write, not a conflict.
        let second = try store.update(note: outcome.note, body: "Again\n", now: Date())
        guard case .written = second.result else {
            return XCTFail("expected .written, got \(second.result)")
        }
    }

    func testConflictOutcomeNoteIsTheCopy() throws {
        let entry = try store.create(body: "Mine\n", now: Date())
        let note = try store.read(relativePath: entry.relativePath)
        try "external\n".write(to: root.appendingPathComponent(entry.relativePath), atomically: true, encoding: .utf8)

        let outcome = try store.update(note: note, body: "Mine revised\n", now: Date())
        guard case .conflictCopy(let path, _) = outcome.result else {
            return XCTFail("expected .conflictCopy, got \(outcome.result)")
        }
        XCTAssertEqual(outcome.note.relativePath, path)
        let copy = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        XCTAssertEqual(outcome.note.originalText, copy)
    }

    /// Minor 3: a successful write clears a stale error.
    func testSuccessfulCreateAndUpdateClearErrorMessage() throws {
        store.errorMessage = "old failure"
        let entry = try store.create(body: "Hi\n", now: Date())
        XCTAssertNil(store.errorMessage)

        store.errorMessage = "old failure"
        let note = try store.read(relativePath: entry.relativePath)
        try store.update(note: note, body: "Hi again\n", now: Date())
        XCTAssertNil(store.errorMessage)
    }

    /// I3: delete moves the file to `.trash/` rather than removing it —
    /// gone from its original path, but recoverable on disk.
    func testDeleteRemovesFileAndEntry() throws {
        let entry = try store.create(body: "Bye\n", now: Date())
        try store.delete(relativePath: entry.relativePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.relativePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".trash/\(entry.relativePath)").path))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRefreshSurfacesMissingVaultAsErrorMessage() async {
        let failing = VaultStore(storeProvider: { throw VaultAccessError.notConfigured })
        await failing.refresh()
        XCTAssertNotNil(failing.errorMessage)
    }

    /// Ruling D: a changed-on-disk file that fails to read (e.g. a partial
    /// iCloud download) must not vanish from the drawer — the prior indexed
    /// entry for that path should be kept. Invalid UTF-8 bytes reliably make
    /// `VaultFileStore.read` throw while `listMarkdownFiles` still lists the
    /// file with metadata (size) that differs from the indexed entry, forcing
    /// it into `needsRead`.
    func testRefreshKeepsPriorEntryWhenChangedFileFailsToRead() async throws {
        let entry = try store.create(body: "Readable\n", now: Date())
        let originalTitle = entry.title

        try Data([0xFF, 0xFE, 0x00]).write(to: root.appendingPathComponent(entry.relativePath))

        await store.refresh()

        XCTAssertEqual(store.entries.map(\.relativePath), [entry.relativePath])
        XCTAssertEqual(store.entries.first?.title, originalTitle)
    }

    /// A create() landing on the main actor while refresh()'s detached work
    /// is still in flight must survive the merge back — not get reverted by
    /// the stale-relative-to-this-write snapshot the background pass
    /// computed. `store.isLoading` flips to true synchronously before
    /// refresh() suspends at its detached `await`, so once the polling loop
    /// below observes it, refresh() is guaranteed to be parked there and
    /// cannot resume until this task yields again.
    func testCreateDuringRefreshIsNotLost() async throws {
        let refreshing = Task { await store.refresh() }
        while !store.isLoading { await Task.yield() }

        let entry = try store.create(body: "Made mid-refresh\n", now: Date())

        await refreshing.value

        XCTAssertTrue(store.entries.contains { $0.relativePath == entry.relativePath })
        XCTAssertTrue(VaultIndex.load().contains { $0.relativePath == entry.relativePath })
    }

    /// Symmetric case: a delete() during an in-flight refresh must not be
    /// undone by the merge, resurrecting a note the user just removed.
    func testDeleteDuringRefreshIsNotResurrected() async throws {
        let entry = try store.create(body: "To be deleted mid-refresh\n", now: Date())

        let refreshing = Task { await store.refresh() }
        while !store.isLoading { await Task.yield() }

        try store.delete(relativePath: entry.relativePath)

        await refreshing.value

        XCTAssertFalse(store.entries.contains { $0.relativePath == entry.relativePath })
        XCTAssertFalse(VaultIndex.load().contains { $0.relativePath == entry.relativePath })
    }
}
