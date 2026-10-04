import XCTest
@testable import Quoote

final class AttachmentPreviewFilesTests: XCTestCase {

    private var tempDirectory: URL!
    private var vaultRoot: URL!
    private var previews: URL!

    /// A clock the tests move by hand, so waiting on iCloud takes no time.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vaultRoot = tempDirectory.appendingPathComponent("vault", isDirectory: true)
        previews = tempDirectory.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func makeFiles(
        connectedVault: Bool = true,
        timeout: TimeInterval = 30,
        pollInterval: Duration = .seconds(1),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onAccess: @escaping @Sendable () -> Void = {}
    ) -> AttachmentPreviewFiles {
        let root = vaultRoot!
        return AttachmentPreviewFiles(environment: .init(
            vaultAccess: { body in
                onAccess()
                return connectedVault ? body(VaultFileStore(root: root)) : nil
            },
            attachmentsFolder: { "attachments" },
            directory: previews,
            downloadTimeout: timeout,
            pollInterval: pollInterval,
            now: now,
            sleep: sleep
        ))
    }

    private func file(_ target: String) -> NoteAttachment {
        NoteAttachment(target: target, name: (target as NSString).lastPathComponent, kind: .file)
    }

    private func put(_ relativePath: String, _ data: Data = Data("x".utf8)) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// What is in the previews folder: one folder per preview still open.
    private func previewFolders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: previews.path)) ?? []
    }

    private func isInsideAFolderOfItsOwn(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
            == previews.standardizedFileURL.path
    }

    // MARK: Finding and copying

    func testAVaultFileIsCopiedUnderItsOwnNameIntoAFolderOfItsOwn() async throws {
        let bytes = Data("%PDF-1.4 a report".utf8)
        try put("attachments/Q3 Report.pdf", bytes)

        let outcome = await makeFiles().localFile(for: file("Q3 Report.pdf"), notePath: nil)

        guard case .ready(let url) = outcome else { return XCTFail("expected a copy, got \(outcome)") }
        XCTAssertEqual(url.lastPathComponent, "Q3 Report.pdf")
        XCTAssertTrue(isInsideAFolderOfItsOwn(url), "\(url.path)")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testAFileBesideTheNoteIsFoundThroughTheNotePath() async throws {
        try put("notes/Plan.pdf", Data("plan".utf8))

        let outcome = await makeFiles().localFile(for: file("Plan.pdf"), notePath: "notes/Today.md")

        guard case .ready(let url) = outcome else { return XCTFail("expected a copy, got \(outcome)") }
        XCTAssertEqual(try Data(contentsOf: url), Data("plan".utf8))
    }

    func testAFileThatIsNotInTheVaultIsMissingAndLeavesNothingBehind() async {
        let outcome = await makeFiles().localFile(for: file("nope.pdf"), notePath: nil)

        XCTAssertEqual(outcome, .missing)
        XCTAssertEqual(previewFolders(), [])
    }

    func testATargetThatClimbsOutOfTheVaultIsMissing() async throws {
        try put("secret.pdf")
        let outcome = await makeFiles().localFile(for: file("../secret.pdf"), notePath: nil)
        XCTAssertEqual(outcome, .missing)
    }

    func testAMemosAttachmentIsNotPreviewedYetAndTheVaultIsNotOpened() async {
        let accesses = Counter()
        let memos = NoteAttachment(target: "/file/attachments/u1/Report.pdf", name: "Report.pdf", kind: .file)

        let outcome = await makeFiles(onAccess: { accesses.increment() }).localFile(for: memos, notePath: nil)

        XCTAssertEqual(outcome, .unsupported)
        XCTAssertEqual(accesses.value, 0)
        XCTAssertEqual(previewFolders(), [])
    }

    func testWithNoVaultConnectedTheVaultIsUnavailable() async throws {
        try put("attachments/Report.pdf")
        let outcome = await makeFiles(connectedVault: false).localFile(for: file("Report.pdf"), notePath: nil)
        XCTAssertEqual(outcome, .vaultUnavailable)
        XCTAssertEqual(previewFolders(), [])
    }

    func testTwoPreviewsOfFilesWithTheSameNameDoNotCollide() async throws {
        try put("attachments/Scan.pdf", Data("first".utf8))
        try put("other/Scan.pdf", Data("second".utf8))
        let files = makeFiles()

        let a = await files.localFile(for: file("attachments/Scan.pdf"), notePath: nil)
        let b = await files.localFile(for: file("other/Scan.pdf"), notePath: nil)

        guard case .ready(let first) = a, case .ready(let second) = b else { return XCTFail("expected two copies") }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    // MARK: iCloud

    func testAnEvictedFileIsWaitedForThenCopied() async throws {
        try put("attachments/.Report.pdf.icloud", Data("placeholder".utf8))
        let bytes = Data("%PDF the real bytes".utf8)
        let clock = Clock()
        let sleeps = Counter()
        let root = vaultRoot!

        let files = makeFiles(now: { clock.now }, sleep: { duration in
            clock.advance(TimeInterval(duration.components.seconds))
            if sleeps.increment() == 2 {   // iCloud delivers the file during the second wait
                try? FileManager.default.removeItem(at: root.appendingPathComponent("attachments/.Report.pdf.icloud"))
                try? bytes.write(to: root.appendingPathComponent("attachments/Report.pdf"))
            }
        })
        let outcome = await files.localFile(for: file("Report.pdf"), notePath: nil)

        guard case .ready(let url) = outcome else { return XCTFail("expected a copy, got \(outcome)") }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(sleeps.value, 2)
    }

    func testAFileThatNeverArrivesTimesOutAfterThePatienceRunsOutAndLeavesNothingBehind() async throws {
        try put("attachments/.Report.pdf.icloud", Data("placeholder".utf8))
        let clock = Clock()
        let sleeps = Counter()

        let files = makeFiles(timeout: 5, now: { clock.now }, sleep: { duration in
            clock.advance(TimeInterval(duration.components.seconds))
            sleeps.increment()
        })
        let outcome = await files.localFile(for: file("Report.pdf"), notePath: nil)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(sleeps.value, 5, "one poll a second for the five seconds")
        XCTAssertEqual(previewFolders(), [])
    }

    func testStoppingTheWaitReportsCancelledAndLeavesNothingBehind() async throws {
        try put("attachments/.Report.pdf.icloud", Data("placeholder".utf8))
        let waiting = Counter()
        let files = makeFiles(sleep: { _ in
            waiting.increment()
            try await Task.sleep(for: .seconds(60))
        })

        let task = Task { await files.localFile(for: file("Report.pdf"), notePath: nil) }
        while waiting.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(previewFolders(), [])
    }

    // MARK: Cleaning up

    func testDiscardingACopyRemovesItsFolderAndOnlyThat() async throws {
        try put("attachments/A.pdf")
        try put("attachments/B.pdf")
        let files = makeFiles()
        guard case .ready(let a) = await files.localFile(for: file("A.pdf"), notePath: nil),
              case .ready(let b) = await files.localFile(for: file("B.pdf"), notePath: nil) else {
            return XCTFail("expected two copies")
        }

        files.discard(a)

        XCTAssertFalse(FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testDiscardNeverTouchesAnythingOutsideAPreviewFolder() throws {
        try put("attachments/Keep.pdf")
        let vaultFile = vaultRoot.appendingPathComponent("attachments/Keep.pdf")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let looseFile = previews.appendingPathComponent("loose.pdf")
        try Data("x".utf8).write(to: looseFile)
        let files = makeFiles()

        files.discard(vaultFile)
        files.discard(looseFile)
        files.discard(previews)

        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultFile.path), "a vault file is never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: looseFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previews.path))
    }

    func testOldCopiesAreSweptAndRecentOnesKept() throws {
        let fileManager = FileManager.default
        let old = previews.appendingPathComponent("old", isDirectory: true)
        let recent = previews.appendingPathComponent("recent", isDirectory: true)
        for folder in [old, recent] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("a.pdf"))
        }
        try fileManager.setAttributes([.creationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: old.path)

        makeFiles().removeStaleCopies(olderThan: 3600)

        XCTAssertFalse(fileManager.fileExists(atPath: old.path))
        XCTAssertTrue(fileManager.fileExists(atPath: recent.path))
    }
}
