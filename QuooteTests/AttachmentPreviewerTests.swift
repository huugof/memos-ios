import XCTest
import Combine
@testable import Quoote

@MainActor
final class AttachmentPreviewerTests: XCTestCase {

    private var tempDirectory: URL!
    private var vaultRoot: URL!
    private var previews: URL!
    private var subscriptions: Set<AnyCancellable> = []

    /// What the editor would show as a banner.
    private final class Notices { var messages: [String] = [] }
    private let notices = Notices()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vaultRoot = tempDirectory.appendingPathComponent("vault", isDirectory: true)
        previews = tempDirectory.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        subscriptions.removeAll()
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    // MARK: Helpers

    /// `graceDelay` is long unless a test wants the spinner; waiting on iCloud is polled every 10 ms.
    private func makePreviewer(
        connectedVault: Bool = true,
        timeout: TimeInterval = 30,
        graceDelay: Duration = .seconds(60)
    ) -> AttachmentPreviewer {
        let root = vaultRoot!
        let files = AttachmentPreviewFiles(environment: .init(
            vaultAccess: { body in connectedVault ? body(VaultFileStore(root: root)) : nil },
            attachmentsFolder: { "attachments" },
            directory: previews,
            downloadTimeout: timeout,
            pollInterval: .milliseconds(10)
        ))
        return AttachmentPreviewer(files: files, graceDelay: graceDelay)
    }

    private func open(_ attachment: NoteAttachment, in previewer: AttachmentPreviewer) {
        previewer.open(attachment, notePath: nil) { [notices] in notices.messages.append($0) }
    }

    private func file(_ target: String) -> NoteAttachment {
        NoteAttachment(target: target, name: (target as NSString).lastPathComponent, kind: .file)
    }

    private func put(_ relativePath: String, _ data: Data = Data("x".utf8)) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// iCloud finishing the download of an evicted file: the placeholder gives way to the real thing.
    private func deliver(_ relativePath: String, _ data: Data) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        try? FileManager.default.removeItem(at: placeholder)
        try data.write(to: url, options: .atomic)
    }

    private func previewFolders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: previews.path)) ?? []
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: What can be previewed

    func testOnlyAVaultAttachmentCanBePreviewedForNow() {
        XCTAssertTrue(AttachmentPreviewer.canPreview(file("Report.pdf")))
        XCTAssertTrue(AttachmentPreviewer.canPreview(NoteAttachment(target: "attachments/a.png", name: "a.png", kind: .image)))
        XCTAssertFalse(AttachmentPreviewer.canPreview(NoteAttachment(target: "/file/attachments/u/a.png", name: "a.png", kind: .image)))
        XCTAssertFalse(AttachmentPreviewer.canPreview(NoteAttachment(target: "/o/r/12/x.pdf", name: "x.pdf", kind: .file)))
        XCTAssertFalse(AttachmentPreviewer.canPreview(
            NoteAttachment(target: "https://m.example.com/file/attachments/u/r.pdf", name: "r.pdf", kind: .file)))
    }

    func testAMemosAttachmentIsIgnored() async throws {
        let previewer = makePreviewer()

        open(NoteAttachment(target: "/file/attachments/u/Report.pdf", name: "Report.pdf", kind: .file), in: previewer)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(previewer.previewURL)
        XCTAssertNil(previewer.loadingIdentity)
        XCTAssertEqual(notices.messages, [])
    }

    // MARK: Opening

    func testOpeningAVaultFileShowsACopyOfIt() async throws {
        let bytes = Data("%PDF-1.4 report".utf8)
        try put("attachments/Report.pdf", bytes)
        let previewer = makePreviewer()

        open(file("Report.pdf"), in: previewer)
        await waitUntil("the preview") { previewer.previewURL != nil }

        let url = try XCTUnwrap(previewer.previewURL)
        XCTAssertEqual(url.lastPathComponent, "Report.pdf")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNil(previewer.loadingIdentity)
        XCTAssertEqual(notices.messages, [])
    }

    func testAFileOnTheDeviceNeverShowsASpinner() async throws {
        try put("attachments/Report.pdf")
        let previewer = makePreviewer(graceDelay: .seconds(60))
        var seen: [String?] = []
        previewer.$loadingIdentity.sink { seen.append($0) }.store(in: &subscriptions)

        open(file("Report.pdf"), in: previewer)
        await waitUntil("the preview") { previewer.previewURL != nil }

        XCTAssertTrue(seen.allSatisfy { $0 == nil }, "the spinner flashed: \(seen)")
    }

    func testAnEvictedFileShowsASpinnerWhileItIsWaitedForThenOpens() async throws {
        try put("attachments/.Report.pdf.icloud", Data("placeholder".utf8))
        let previewer = makePreviewer(graceDelay: .zero)
        let attachment = file("Report.pdf")

        open(attachment, in: previewer)
        await waitUntil("the spinner") { previewer.loadingIdentity == attachment.identity }
        XCTAssertNil(previewer.previewURL)

        try deliver("attachments/Report.pdf", Data("%PDF real".utf8))
        await waitUntil("the preview") { previewer.previewURL != nil }

        XCTAssertNil(previewer.loadingIdentity)
        XCTAssertEqual(notices.messages, [])
    }

    // MARK: Taps while something is loading

    func testTappingAnotherAttachmentWhileOneLoadsReplacesIt() async throws {
        try put("attachments/.Slow.pdf.icloud", Data("placeholder".utf8))
        try put("attachments/Quick.pdf", Data("quick".utf8))
        let previewer = makePreviewer(graceDelay: .zero)
        let slow = file("Slow.pdf")

        open(slow, in: previewer)
        await waitUntil("the spinner") { previewer.loadingIdentity == slow.identity }
        open(file("Quick.pdf"), in: previewer)
        await waitUntil("the preview") { previewer.previewURL != nil }

        XCTAssertEqual(previewer.previewURL?.lastPathComponent, "Quick.pdf")
        XCTAssertNil(previewer.loadingIdentity)

        // Even if the dropped file turns up now, it neither takes over nor leaves a copy nor complains.
        try deliver("attachments/Slow.pdf", Data("slow".utf8))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(previewer.previewURL?.lastPathComponent, "Quick.pdf")
        XCTAssertEqual(previewFolders().count, 1)
        XCTAssertEqual(notices.messages, [])
    }

    func testTappingTheSameAttachmentTwiceWhileItLoadsOpensItOnce() async throws {
        try put("attachments/.Report.pdf.icloud", Data("placeholder".utf8))
        let previewer = makePreviewer(graceDelay: .zero)
        let attachment = file("Report.pdf")
        var opened: [URL] = []
        previewer.$previewURL.compactMap { $0 }.sink { opened.append($0) }.store(in: &subscriptions)

        open(attachment, in: previewer)
        await waitUntil("the spinner") { previewer.loadingIdentity == attachment.identity }
        open(attachment, in: previewer)
        try deliver("attachments/Report.pdf", Data("%PDF".utf8))
        await waitUntil("the preview") { previewer.previewURL != nil }
        try await Task.sleep(for: .milliseconds(200))   // time for a second preview to show itself, were there one

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(previewFolders().count, 1)
    }

    func testCancellingDropsALoadInProgress() async throws {
        try put("attachments/.Report.pdf.icloud", Data("placeholder".utf8))
        let previewer = makePreviewer(graceDelay: .zero)
        let attachment = file("Report.pdf")
        open(attachment, in: previewer)
        await waitUntil("the spinner") { previewer.loadingIdentity == attachment.identity }

        previewer.cancel()
        XCTAssertNil(previewer.loadingIdentity)

        // The file turns up afterwards: nothing opens, nothing is left behind, nobody is told.
        try deliver("attachments/Report.pdf", Data("%PDF".utf8))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(previewer.previewURL)
        XCTAssertEqual(previewFolders(), [])
        XCTAssertEqual(notices.messages, [])
    }

    // MARK: Cleaning up

    /// The sheet is told to close before it has finished sliding away, and QuickLook is still showing the file then.
    func testClosingThePreviewDeletesTheCopyOnceTheSheetHasGone() async throws {
        try put("attachments/Report.pdf")
        let previewer = makePreviewer()
        open(file("Report.pdf"), in: previewer)
        await waitUntil("the preview") { previewer.previewURL != nil }
        XCTAssertEqual(previewFolders().count, 1)

        previewer.previewURL = nil   // the sheet is told to close
        XCTAssertEqual(previewFolders().count, 1, "the copy stays while the sheet slides away")

        previewer.previewDidClose()  // and it has gone
        XCTAssertEqual(previewFolders(), [])
    }

    func testCancellingLetsGoOfACopyStillWaitingForItsSheet() async throws {
        try put("attachments/Report.pdf")
        let previewer = makePreviewer()
        open(file("Report.pdf"), in: previewer)
        await waitUntil("the preview") { previewer.previewURL != nil }
        previewer.previewURL = nil

        previewer.cancel()   // the editor is going away, and its sheet's callback may never come

        XCTAssertEqual(previewFolders(), [])
    }

    func testOpeningAnotherFileDeletesTheEarlierCopy() async throws {
        try put("attachments/A.pdf")
        try put("attachments/B.pdf")
        let previewer = makePreviewer()
        open(file("A.pdf"), in: previewer)
        await waitUntil("the first preview") { previewer.previewURL != nil }
        let first = try XCTUnwrap(previewer.previewURL)

        open(file("B.pdf"), in: previewer)
        await waitUntil("the second preview") { previewer.previewURL != nil && previewer.previewURL != first }
        previewer.previewDidClose()   // the sheet showing the first has gone

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(previewFolders().count, 1, "the one being shown stays")
    }

    // MARK: When it goes wrong

    func testAFileThatIsNotInTheVaultIsReported() async {
        let previewer = makePreviewer()

        open(file("nope.pdf"), in: previewer)
        await waitUntil("the notice") { !notices.messages.isEmpty }

        XCTAssertEqual(notices.messages, ["Couldn't find \"nope.pdf\" in your vault."])
        XCTAssertNil(previewer.previewURL)
        XCTAssertNil(previewer.loadingIdentity)
    }

    func testAVaultThatCannotBeReachedIsReported() async throws {
        try put("attachments/Report.pdf")
        let previewer = makePreviewer(connectedVault: false)

        open(file("Report.pdf"), in: previewer)
        await waitUntil("the notice") { !notices.messages.isEmpty }

        XCTAssertEqual(notices.messages, ["Quoote can't reach your vault. Reconnect it in Settings."])
    }

    func testAFileICloudHasNotDeliveredInTimeIsReported() async throws {
        try put("attachments/.Report.pdf.icloud", Data("placeholder".utf8))
        let previewer = makePreviewer(timeout: 0)

        open(file("Report.pdf"), in: previewer)
        await waitUntil("the notice") { !notices.messages.isEmpty }

        XCTAssertEqual(notices.messages, ["\"Report.pdf\" hasn't finished downloading from iCloud. Try again in a moment."])
        XCTAssertNil(previewer.loadingIdentity)
    }

    func testAFileThatCannotBeCopiedIsReported() async throws {
        try put("attachments/Report.pdf")
        try Data("in the way".utf8).write(to: previews)   // the copies' folder can't be made
        let previewer = makePreviewer()

        open(file("Report.pdf"), in: previewer)
        await waitUntil("the notice") { !notices.messages.isEmpty }

        XCTAssertEqual(notices.messages, ["Couldn't open \"Report.pdf\"."])
        XCTAssertNil(previewer.previewURL)
    }
}
