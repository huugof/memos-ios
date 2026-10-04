import XCTest
import UIKit
@testable import Quoote

final class AttachmentThumbnailLoaderTests: XCTestCase {

    private var tempDirectory: URL!
    private var vaultRoot: URL!
    private let png = TestImages.png(width: 600, height: 300)

    /// A clock the tests move by hand, to step over the one-minute failure memory.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
    }
    private let clock = Clock()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vaultRoot = tempDirectory.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
    }

    override func tearDownWithError() throws {
        AttachmentStubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func makeLoader(connectedVault: Bool = true, maxConcurrentLoads: Int = 4) -> AttachmentThumbnailLoader {
        let root = vaultRoot!
        let clock = clock
        return AttachmentThumbnailLoader(environment: .init(
            session: AttachmentStubURLProtocol.session(),
            endpoint: { "https://memos.example.com" },
            token: { "tok" },
            allowInsecureHTTP: { false },
            vaultAccess: { body in connectedVault ? body(VaultFileStore(root: root)) : nil },
            attachmentsFolder: { "attachments" },
            diskCache: ThumbnailDiskCache(directory: tempDirectory.appendingPathComponent("thumbs")),
            now: { clock.now },
            maxConcurrentLoads: maxConcurrentLoads
        ))
    }

    private func image(_ target: String) -> NoteAttachment {
        NoteAttachment(target: target, name: (target as NSString).lastPathComponent, kind: .image)
    }

    private func put(_ relativePath: String, _ data: Data) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func waitForFirstRequest() async throws {
        while AttachmentStubURLProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Vault pictures

    func testAVaultPictureLoadsThenIsServedFromMemory() async throws {
        try put("attachments/p.png", png)
        let loader = makeLoader()
        let attachment = image("p.png")
        XCTAssertNil(loader.cachedImage(for: attachment, notePath: nil))

        let loaded = await loader.thumbnail(for: attachment, notePath: nil)

        let picture = try XCTUnwrap(loaded)
        XCTAssertEqual(picture.size, CGSize(width: 192, height: 96))
        XCTAssertTrue(loader.cachedImage(for: attachment, notePath: nil) === picture)
    }

    func testAnUnchangedVaultFileIsNotDecodedAgain() async throws {
        try put("attachments/p.png", png)
        let loader = makeLoader()

        let first = await loader.thumbnail(for: image("p.png"), notePath: nil)
        let second = await loader.thumbnail(for: image("p.png"), notePath: nil)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    func testAReplacedVaultFileIsLoadedAgain() async throws {
        try put("attachments/p.png", png)
        let loader = makeLoader()
        let first = await loader.thumbnail(for: image("p.png"), notePath: nil)
        XCTAssertEqual(first?.size, CGSize(width: 192, height: 96))

        try put("attachments/p.png", TestImages.png(width: 100, height: 300))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: vaultRoot.appendingPathComponent("attachments/p.png").path
        )
        let second = await loader.thumbnail(for: image("p.png"), notePath: nil)

        XCTAssertEqual(second?.size.height, 192)
        XCTAssertLessThan(second?.size.width ?? 999, 100)
    }

    func testTheSameTargetInTwoNoteFoldersIsTwoPictures() async throws {
        try put("a/pic.png", TestImages.png(width: 300, height: 300))
        try put("b/pic.png", TestImages.png(width: 300, height: 100))
        let loader = makeLoader()

        let first = await loader.thumbnail(for: image("pic.png"), notePath: "a/note.md")
        let second = await loader.thumbnail(for: image("pic.png"), notePath: "b/note.md")

        XCTAssertEqual(first?.size, CGSize(width: 192, height: 192))
        XCTAssertEqual(second?.size, CGSize(width: 192, height: 64))
    }

    func testAMissingFileIsRetriedAfterAMinuteSoALateSyncShowsUp() async throws {
        let loader = makeLoader()
        let miss = await loader.thumbnail(for: image("late.png"), notePath: nil)
        XCTAssertNil(miss)

        try put("attachments/late.png", png)   // it syncs in
        let tooSoon = await loader.thumbnail(for: image("late.png"), notePath: nil)
        XCTAssertNil(tooSoon, "a failure is remembered for a minute")

        clock.advance(61)
        let later = await loader.thumbnail(for: image("late.png"), notePath: nil)
        XCTAssertNotNil(later)
    }

    func testAnEvictedFileStaysOnItsIconAndComesBackWhenItsDownloaded() async throws {
        try put("attachments/.p.png.icloud", Data("placeholder".utf8))
        let loader = makeLoader()
        let evicted = await loader.thumbnail(for: image("p.png"), notePath: nil)
        XCTAssertNil(evicted)

        try FileManager.default.removeItem(at: vaultRoot.appendingPathComponent("attachments/.p.png.icloud"))
        try put("attachments/p.png", png)
        clock.advance(61)
        let back = await loader.thumbnail(for: image("p.png"), notePath: nil)
        XCTAssertNotNil(back)
    }

    func testWithoutAConnectedVaultThereIsNoPictureAndNoCrash() async {
        let result = await makeLoader(connectedVault: false).thumbnail(for: image("p.png"), notePath: nil)
        XCTAssertNil(result)
    }

    // MARK: Memos pictures

    func testAMemosPictureIsFetchedOnceThenServedFromMemory() async {
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")

        let first = await loader.thumbnail(for: attachment, notePath: nil)
        let second = await loader.thumbnail(for: attachment, notePath: nil)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1)
    }

    func testAMemosPictureIsKeptOnDiskSoItShowsOffline() async {
        let attachment = image("/file/attachments/u/a.jpg")
        _ = await makeLoader().thumbnail(for: attachment, notePath: nil)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1)

        AttachmentStubURLProtocol.reset { _ in .fail(.notConnectedToInternet) }
        let relaunched = makeLoader()   // empty memory, same folder on disk
        let offline = await relaunched.thumbnail(for: attachment, notePath: nil)

        XCTAssertNotNil(offline)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testAPictureOnAnotherHostIsNeverRequested() async {
        let result = await makeLoader().thumbnail(for: image("https://evil.example.net/a.png"), notePath: nil)

        XCTAssertNil(result)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testAFailedDownloadIsNotRetriedForAMinute() async {
        AttachmentStubURLProtocol.reset { _ in .data(Data(), status: 500) }
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")

        let first = await loader.thumbnail(for: attachment, notePath: nil)
        XCTAssertNil(first)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 2, "the thumbnail, then the plain URL")

        let second = await loader.thumbnail(for: attachment, notePath: nil)
        XCTAssertNil(second)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 2, "no new request inside the minute")

        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
        clock.advance(61)
        let third = await loader.thumbnail(for: attachment, notePath: nil)
        XCTAssertNotNil(third)
    }

    // MARK: Sharing, cancelling, limiting

    func testTheSamePictureAskedForAtOnceIsFetchedOnce() async {
        AttachmentStubURLProtocol.reset { [png] _ in .data(png, delay: 0.3) }
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")

        async let first = loader.thumbnail(for: attachment, notePath: nil)
        async let second = loader.thumbnail(for: attachment, notePath: "x/y.md")
        async let third = loader.thumbnail(for: attachment, notePath: nil)
        let results = await [first, second, third]

        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1)
    }

    func testTheDownloadIsCancelledOnlyWhenTheLastWaiterLeaves() async throws {
        AttachmentStubURLProtocol.reset { _ in .hang }
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")
        let first = Task { await loader.thumbnail(for: attachment, notePath: nil) }
        let second = Task { await loader.thumbnail(for: attachment, notePath: nil) }
        try await waitForFirstRequest()
        try await Task.sleep(for: .milliseconds(100))   // both are waiting by now

        first.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(AttachmentStubURLProtocol.cancelledCount, 0, "one waiter is still interested")

        second.cancel()
        for _ in 0..<100 where AttachmentStubURLProtocol.cancelledCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(AttachmentStubURLProtocol.cancelledCount, 1)
        _ = await first.value
        _ = await second.value
    }

    func testACancelledLoadIsNotRememberedAsAFailure() async throws {
        AttachmentStubURLProtocol.reset { _ in .hang }
        let loader = makeLoader()
        let attachment = image("/file/attachments/u/a.jpg")
        let task = Task { await loader.thumbnail(for: attachment, notePath: nil) }
        try await waitForFirstRequest()
        task.cancel()
        _ = await task.value

        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
        let retried = await loader.thumbnail(for: attachment, notePath: nil)   // no clock advance

        XCTAssertNotNil(retried)
    }

    func testAtMostTheLimitOfLoadsRunAtOnce() async {
        AttachmentStubURLProtocol.reset { [png] _ in .data(png, delay: 0.1) }
        let loader = makeLoader(maxConcurrentLoads: 2)
        let attachments = (0..<6).map { image("/file/attachments/u/\($0).jpg") }

        await withTaskGroup(of: Void.self) { group in
            for attachment in attachments {
                group.addTask { _ = await loader.thumbnail(for: attachment, notePath: nil) }
            }
        }

        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 6)
        XCTAssertEqual(AttachmentStubURLProtocol.peakConcurrency, 2)
    }

    func testFilesNeverReachTheLoader() async {
        let loader = makeLoader()
        let file = NoteAttachment(target: "/file/attachments/u/a.pdf", name: "a.pdf", kind: .file)

        let result = await loader.thumbnail(for: file, notePath: nil)

        XCTAssertNil(result)
        XCTAssertNil(loader.cachedImage(for: file, notePath: nil))
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }
}
