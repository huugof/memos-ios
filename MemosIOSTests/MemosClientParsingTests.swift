import XCTest
import Foundation
@testable import Memos

final class MemosClientParsingTests: XCTestCase {
    override func tearDownWithError() throws {
        ParsingMockURLProtocol.requestHandler = nil
        try super.tearDownWithError()
    }

    func testFetchMemosPageParsesWrappedMemoEntries() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/memos")
            let body = """
            {
              "memos": [
                {
                  "memo": {
                    "name": "memos/one",
                    "content": "Hello\\n![photo](resource)",
                    "updateTime": "2026-03-05T12:00:00Z",
                    "resources": [{ "name": "resources/1" }]
                  }
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com/api/v1/memos")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let page = try await client.fetchMemosPage(
            baseURLString: "https://example.com",
            token: "token",
            allowInsecureHTTP: false,
            pageSize: 30,
            pageToken: nil
        )

        XCTAssertEqual(page.memos.count, 1)
        let memo = try XCTUnwrap(page.memos.first)
        XCTAssertEqual(memo.id, "memos/one")
        XCTAssertEqual(memo.content, "Hello\n![photo](resource)")
        XCTAssertEqual(memo.attachmentCount, 1)
        XCTAssertTrue(memo.hasFullContent)
    }

    func testFetchMemosPageKeepsAttachmentRowsWhenContentMissing() async throws {
        let client = makeClient { _ in
            let body = """
            {
              "memos": [
                {
                  "name": "memos/photo",
                  "content": "   ",
                  "snippet": "Trip photo",
                  "resources": [{ "name": "resources/2" }]
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com/api/v1/memos")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let page = try await client.fetchMemosPage(
            baseURLString: "https://example.com",
            token: "token",
            allowInsecureHTTP: false,
            pageSize: 30,
            pageToken: nil
        )

        XCTAssertEqual(page.memos.count, 1)
        let memo = try XCTUnwrap(page.memos.first)
        XCTAssertEqual(memo.id, "memos/photo")
        XCTAssertEqual(memo.content.trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(memo.snippet, "Trip photo")
        XCTAssertEqual(memo.attachmentCount, 1)
        XCTAssertFalse(memo.hasFullContent)
    }

    func testFetchMemosPageDropsRowsWithNoContentSnippetOrAttachments() async throws {
        let client = makeClient { _ in
            let body = """
            {
              "memos": [
                {
                  "name": "memos/empty",
                  "content": "   "
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com/api/v1/memos")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let page = try await client.fetchMemosPage(
            baseURLString: "https://example.com",
            token: "token",
            allowInsecureHTTP: false,
            pageSize: 30,
            pageToken: nil
        )

        XCTAssertTrue(page.memos.isEmpty)
    }

    func testFetchMemoReturnsFullContentForEditing() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/memos/abc")
            let body = """
            {
              "name": "memos/abc",
              "content": "Full note body",
              "updateTime": "2026-03-05T12:00:00Z"
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com/api/v1/memos/abc")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let memo = try await client.fetchMemo(
            resourceName: "memos/abc",
            baseURLString: "https://example.com",
            token: "token",
            allowInsecureHTTP: false
        )

        XCTAssertEqual(memo.id, "memos/abc")
        XCTAssertEqual(memo.content, "Full note body")
        XCTAssertTrue(memo.hasFullContent)
    }

    private func makeClient(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> MemosClient {
        ParsingMockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParsingMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return MemosClient(session: session)
    }
}

private final class ParsingMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
