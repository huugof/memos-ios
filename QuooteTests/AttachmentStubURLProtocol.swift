import Foundation

/// A URLProtocol that answers from a closure and keeps score: which requests arrived, how many were in flight at
/// once, how many were cancelled before they were answered. State is static, so each test calls `reset` first.
final class AttachmentStubURLProtocol: URLProtocol {

    enum Reply {
        /// Answers after `delay` seconds.
        case data(Data, status: Int = 200, headers: [String: String] = [:], delay: TimeInterval = 0)
        case redirect(to: URL)
        /// Never answers; only a cancellation ends it.
        case hang
        case fail(URLError.Code)
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var seen: [URLRequest] = []
    private static var inFlight = 0
    private static var peak = 0
    private static var cancellations = 0

    static func reset(_ handler: @escaping (URLRequest) -> Reply = { _ in .fail(.notConnectedToInternet) }) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        seen = []; inFlight = 0; peak = 0; cancellations = 0
    }

    /// A session whose every request goes to the stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttachmentStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static var peakConcurrency: Int { lock.lock(); defer { lock.unlock() }; return peak }
    static var cancelledCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }

    private let state = NSLock()
    private var finished = false
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        Self.inFlight += 1
        Self.peak = max(Self.peak, Self.inFlight)
        let reply = Self.handler?(request) ?? .fail(.notConnectedToInternet)
        Self.lock.unlock()

        switch reply {
        case .data(let data, let status, let headers, let delay):
            let deliver = { [self] in
                state.lock(); let abandoned = stopped; state.unlock()
                guard !abandoned else { return }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                markFinished()
            }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
            } else {
                deliver()
            }
        case .redirect(let url):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
            // A client that follows the redirect stops this load. One that declines keeps it alive and expects the
            // 3xx itself to be delivered as the answer, which is what happens here once the client has had its say.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                state.lock(); let abandoned = stopped; state.unlock()
                guard !abandoned else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                markFinished()
            }
        case .hang:
            break
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
            markFinished()
        }
    }

    override func stopLoading() {
        state.lock()
        stopped = true
        let wasAnswered = finished
        finished = true
        state.unlock()
        guard !wasAnswered else { return }
        Self.lock.lock()
        Self.inFlight -= 1
        Self.cancellations += 1
        Self.lock.unlock()
    }

    private func markFinished() {
        state.lock()
        let already = finished
        finished = true
        state.unlock()
        guard !already else { return }
        Self.lock.lock()
        Self.inFlight -= 1
        Self.lock.unlock()
    }
}
