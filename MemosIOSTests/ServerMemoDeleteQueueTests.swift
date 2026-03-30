import XCTest
import SwiftData
import Foundation
@testable import Memos

@MainActor
final class ServerMemoDeleteQueueTests: XCTestCase {
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

        let schema = Schema([Draft.self, ServerMemoEditDraft.self, ServerMemoDeleteTask.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        modelContext = container.mainContext
    }

    override func tearDownWithError() throws {
        AppSettings.endpointBaseURL = originalEndpointBaseURL
        AppSettings.allowInsecureHTTP = originalAllowInsecureHTTP
        try? KeychainTokenStore.deleteToken()

        DeleteMockURLProtocol.requestHandler = nil
        modelContext = nil
        container = nil
        try super.tearDownWithError()
    }

    func testEnqueueCreatesPendingDeleteTask() throws {
        let didQueue = ServerMemoDeleteService.enqueue(
            memoID: "memos/abc",
            resourceName: "memos/abc",
            in: modelContext
        )

        XCTAssertTrue(didQueue)
        let tasks = try allTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].memoID, "memos/abc")
        XCTAssertEqual(tasks[0].deleteState, .pending)
    }

    func testQueueProcessingMarksDeleteResolvedOnSuccess() async throws {
        DeleteMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            let response = HTTPURLResponse(
                url: URL(string: "https://example.com/api/v1/memos/abc")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let queue = ServerMemoDeleteQueueController(client: makeMockClient())
        _ = queue.enqueue(memoID: "memos/abc", resourceName: "memos/abc", in: modelContext)
        queue.startProcessing(in: modelContext)

        try await Task.sleep(for: .milliseconds(180))
        queue.stopProcessing()

        let tasks = try allTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].deleteState, .resolved)
        XCTAssertNil(tasks[0].lastError)
    }

    private func allTasks() throws -> [ServerMemoDeleteTask] {
        try modelContext.fetch(FetchDescriptor<ServerMemoDeleteTask>())
    }

    private func makeMockClient() -> MemosClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeleteMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return MemosClient(session: session)
    }
}

private final class DeleteMockURLProtocol: URLProtocol {
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
