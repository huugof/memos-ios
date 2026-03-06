import XCTest
import SwiftData
import Foundation
@testable import Memos

@MainActor
final class ServerMemoSaveQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var modelContext: ModelContext!

    private var originalEndpointBaseURL: String = ""
    private var originalAllowInsecureHTTP = false

    override func setUpWithError() throws {
        try super.setUpWithError()

        originalEndpointBaseURL = AppSettings.endpointBaseURL
        originalAllowInsecureHTTP = AppSettings.allowInsecureHTTP

        AppSettings.endpointBaseURL = "https://example.com"
        AppSettings.allowInsecureHTTP = false
        try? KeychainTokenStore.setToken("test-token")

        let schema = Schema([Draft.self, ServerMemoEditDraft.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        modelContext = container.mainContext
    }

    override func tearDownWithError() throws {
        AppSettings.endpointBaseURL = originalEndpointBaseURL
        AppSettings.allowInsecureHTTP = originalAllowInsecureHTTP
        try? KeychainTokenStore.deleteToken()

        MockURLProtocol.requestHandler = nil
        modelContext = nil
        container = nil

        try super.tearDownWithError()
    }

    func testEnqueueMarksEditAsPending() throws {
        let memo = ServerMemoSummary(id: "memos/123", resourceName: "memos/123", content: "Old", updatedAt: Date())
        let editDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)

        _ = ServerMemoSaveService.stageLocalContent("Updated", for: editDraft, in: modelContext)
        let didQueue = ServerMemoSaveService.enqueue(editDraft: editDraft, in: modelContext)

        XCTAssertTrue(didQueue)
        XCTAssertEqual(editDraft.saveState, .pending)
        XCTAssertNil(editDraft.lastError)
    }

    func testSaveNowFailureKeepsPendingState() async throws {
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data("temporary outage".utf8))
        }

        let queue = ServerMemoSaveQueueController(client: makeMockClient())
        let memo = ServerMemoSummary(id: "memos/abc", resourceName: "memos/abc", content: "Original", updatedAt: Date())
        let editDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
        _ = ServerMemoSaveService.stageLocalContent("Changed", for: editDraft, in: modelContext)

        let outcome = await queue.saveNow(editDraft, in: modelContext)

        if case .success = outcome {
            XCTFail("Expected save to fail")
        }

        XCTAssertEqual(editDraft.saveState, .pending)
        XCTAssertFalse((editDraft.lastError ?? "").isEmpty)
    }

    func testSaveNowSuccessClearsPendingAndSyncsContent() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body = """
            {"name":"memos/abc","content":"Changed","updateTime":"2026-03-05T12:00:00Z"}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let queue = ServerMemoSaveQueueController(client: makeMockClient())
        let memo = ServerMemoSummary(id: "memos/abc", resourceName: "memos/abc", content: "Original", updatedAt: Date())
        let editDraft = ServerMemoSaveService.upsertEditDraft(for: memo, in: modelContext)
        _ = ServerMemoSaveService.stageLocalContent("Changed", for: editDraft, in: modelContext)

        let outcome = await queue.saveNow(editDraft, in: modelContext)

        guard case let .success(updatedMemo) = outcome else {
            XCTFail("Expected save to succeed")
            return
        }

        XCTAssertEqual(updatedMemo.id, "memos/abc")
        XCTAssertEqual(editDraft.saveState, .idle)
        XCTAssertEqual(editDraft.localContent, "Changed")
        XCTAssertEqual(editDraft.serverContent, "Changed")
        XCTAssertNil(editDraft.lastError)
        XCTAssertNotNil(editDraft.lastSyncedAt)
    }

    private func makeMockClient() -> MemosClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return MemosClient(session: session)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
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
