import XCTest
@testable import Quoote

final class MemosAttachmentFetcherTests: XCTestCase {

    private let png = TestImages.png(width: 600, height: 300)

    override func setUp() {
        super.setUp()
        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
    }

    override func tearDown() {
        AttachmentStubURLProtocol.reset()
        super.tearDown()
    }

    private func fetcher(
        endpoint: String = "https://memos.example.com",
        token: String = "tok",
        allowInsecureHTTP: Bool = false,
        maxBytes: Int = MemosAttachmentFetcher.defaultMaxBytes
    ) -> MemosAttachmentFetcher {
        MemosAttachmentFetcher(
            session: AttachmentStubURLProtocol.session(),
            configuration: { .init(endpoint: endpoint, token: token, allowInsecureHTTP: allowInsecureHTTP) },
            maxBytes: maxBytes
        )
    }

    private func urls() -> [String] {
        AttachmentStubURLProtocol.requests.compactMap { $0.url?.absoluteString }
    }

    // MARK: What gets requested

    func testAMemosRelativeTargetAsksForTheThumbnailWithTheToken() async throws {
        let image = await fetcher().image(for: "/file/attachments/u/image.jpg", maxPixel: 192)

        XCTAssertEqual(image?.width, 192)
        XCTAssertEqual(urls(), ["https://memos.example.com/file/attachments/u/image.jpg?thumbnail=true"])
        XCTAssertEqual(AttachmentStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testThePlainURLIsTheFallbackWhenTheThumbnailFails() async {
        AttachmentStubURLProtocol.reset { [png] request in
            request.url?.query?.contains("thumbnail=true") == true ? .data(Data(), status: 500) : .data(png)
        }

        let image = await fetcher().image(for: "/file/attachments/u/image.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(urls(), [
            "https://memos.example.com/file/attachments/u/image.jpg?thumbnail=true",
            "https://memos.example.com/file/attachments/u/image.jpg",
        ])
    }

    func testAThumbnailThatIsNotAPictureFallsBackToThePlainURL() async {
        AttachmentStubURLProtocol.reset { [png] request in
            request.url?.query?.contains("thumbnail=true") == true ? .data(Data("<html>".utf8)) : .data(png)
        }

        let image = await fetcher().image(for: "/file/attachments/u/image.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(urls().count, 2)
    }

    func testOlderServerPathsAreFetchedAsIs() async {
        let image = await fetcher().image(for: "/o/r/12/a.png", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(urls(), ["https://memos.example.com/o/r/12/a.png"])
    }

    func testAnExistingQueryIsKeptWhenTheThumbnailFlagIsAdded() {
        let candidates = fetcher().candidateURLs(for: "https://memos.example.com/file/attachments/u/a.jpg?x=1")
        XCTAssertEqual(candidates.map(\.absoluteString), [
            "https://memos.example.com/file/attachments/u/a.jpg?x=1&thumbnail=true",
            "https://memos.example.com/file/attachments/u/a.jpg?x=1",
        ])
    }

    func testASubpathInstallKeepsItsPrefix() {
        let candidates = fetcher(endpoint: "https://example.com/memos/").candidateURLs(for: "/file/attachments/u/a.jpg")
        XCTAssertEqual(candidates.map(\.absoluteString), [
            "https://example.com/memos/file/attachments/u/a.jpg?thumbnail=true",
            "https://example.com/memos/file/attachments/u/a.jpg",
        ])
    }

    func testFilenamesWithSpacesAndNonLatinLettersStillMakeARequest() async {
        let image = await fetcher().image(for: "/file/attachments/u/My Photo é 写真.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.first?.url?.host, "memos.example.com")
    }

    func testAVaultTargetIsNeverFetched() {
        XCTAssertEqual(fetcher().candidateURLs(for: "photo.png"), [])
        XCTAssertEqual(fetcher().candidateURLs(for: "/photo.png"), [])
    }

    // MARK: Who gets asked

    func testAnotherHostGetsNoRequestAtAll() async {
        let image = await fetcher().image(for: "https://evil.example.net/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty, "the token must not go anywhere else")
    }

    func testAnAbsoluteURLOnTheMemosOriginIsFetchedWithTheToken() async {
        let image = await fetcher().image(for: "https://memos.example.com/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testOriginsAreComparedIgnoringCaseAndDefaultPorts() async {
        let sameOrigin = fetcher(endpoint: "https://Memos.Example.com:443/")
        let image = await sameOrigin.image(for: "https://memos.example.com/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNotNil(image)

        AttachmentStubURLProtocol.reset { [png] _ in .data(png) }
        let otherPort = await fetcher().image(for: "https://memos.example.com:8443/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNil(otherPort)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testTheSchemeMustMatchSoTheTokenNeverTravelsOverPlainHTTP() async {
        let image = await fetcher().image(for: "http://memos.example.com/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testAPlainHTTPEndpointIsOnlyUsedWhenSettingsAllowIt() async {
        let refused = await fetcher(endpoint: "http://192.168.1.5:5230").image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNil(refused)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)

        let allowed = await fetcher(endpoint: "http://192.168.1.5:5230", allowInsecureHTTP: true)
            .image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNotNil(allowed)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.first?.url?.port, 5230)
    }

    func testNoEndpointOrNoTokenMeansNoRequest() async {
        let noEndpoint = await fetcher(endpoint: "  ").image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        let noToken = await fetcher(token: " ").image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        let badScheme = await fetcher(endpoint: "ftp://memos.example.com").image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(noEndpoint)
        XCTAssertNil(noToken)
        XCTAssertNil(badScheme)
        XCTAssertTrue(AttachmentStubURLProtocol.requests.isEmpty)
    }

    func testARedirectToAnotherHostIsNotFollowed() async {
        let evil = URL(string: "https://evil.example.net/x.png")!
        AttachmentStubURLProtocol.reset { [png] request in
            request.url?.host == "memos.example.com" ? .redirect(to: evil) : .data(png)
        }

        let image = await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
        XCTAssertFalse(urls().contains { $0.contains("evil.example.net") }, "the redirect must not be followed")
    }

    func testARedirectWithinTheMemosOriginIsFollowedWithTheToken() async {
        let elsewhere = URL(string: "https://memos.example.com/moved/a.png")!
        AttachmentStubURLProtocol.reset { [png] request in
            request.url?.path.hasPrefix("/file/") == true ? .redirect(to: elsewhere) : .data(png)
        }

        let image = await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNotNil(image)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.last?.url, elsewhere)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    // MARK: Limits and failures

    func testABodyOverTheCapIsAbandoned() async {
        AttachmentStubURLProtocol.reset { _ in .data(Data(repeating: 1, count: 2_000)) }

        let image = await fetcher(maxBytes: 1_000).image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
    }

    func testADeclaredLengthOverTheCapIsRefusedBeforeReadingAnything() async {
        AttachmentStubURLProtocol.reset { [png] _ in .data(png, headers: ["Content-Length": "5000000"]) }

        let image = await fetcher(maxBytes: 1_000_000).image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image, "5 MB promised against a 1 MB cap: refused on the headers alone")
    }

    func testAnErrorStatusIsNoPicture() async {
        AttachmentStubURLProtocol.reset { _ in .data(Data("nope".utf8), status: 401) }

        let image = await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192)

        XCTAssertNil(image)
        XCTAssertEqual(urls().count, 2, "thumbnail, then the plain URL")
    }

    func testANetworkErrorIsNoPicture() async {
        AttachmentStubURLProtocol.reset { _ in .fail(.notConnectedToInternet) }
        let image = await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192)
        XCTAssertNil(image)
    }

    func testCancellingTheTaskCancelsTheRequest() async throws {
        AttachmentStubURLProtocol.reset { _ in .hang }
        let task = Task { await fetcher().image(for: "/file/attachments/u/a.jpg", maxPixel: 192) }

        while AttachmentStubURLProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let image = await task.value
        // URLSession reports the cancellation to the protocol a moment later.
        for _ in 0..<100 where AttachmentStubURLProtocol.cancelledCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(image)
        XCTAssertEqual(AttachmentStubURLProtocol.cancelledCount, 1)
        XCTAssertEqual(AttachmentStubURLProtocol.requests.count, 1, "no fallback request after a cancel")
    }
}
