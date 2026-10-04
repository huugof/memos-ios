import CoreGraphics
import Foundation

/// The scheme, host and port a URL must share with the configured Memos server before the app sends it a request.
struct MemosOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

/// Fetches an attachment's picture from the configured Memos server — and from nowhere else. A URL on any other
/// origin gets no request, so neither the API token nor the device's address goes to a stranger's server.
struct MemosAttachmentFetcher {

    struct Configuration {
        var endpoint: String
        var token: String
        var allowInsecureHTTP: Bool
    }

    static let defaultMaxBytes = 10 * 1024 * 1024

    let session: URLSession
    /// Read on every call, so a change in Settings applies to the next load.
    let configuration: @Sendable () -> Configuration
    var maxBytes = MemosAttachmentFetcher.defaultMaxBytes
    var timeout: TimeInterval = 15

    /// The URLs to try, best first: for an uploaded attachment the server's 600 px thumbnail, then the file
    /// itself (an older server, a type it can't thumbnail). Empty when the target must not be fetched.
    func candidateURLs(for target: String) -> [URL] {
        plan(for: target)?.urls ?? []
    }

    /// The picture, at most `maxPixel` on its longest edge, or `nil`. Never throws: a failure of any kind is
    /// just "no picture".
    func image(for target: String, maxPixel: Int) async -> CGImage? {
        guard let plan = plan(for: target) else { return nil }
        let redirects = OriginPinnedRedirects(origin: plan.origin, token: plan.token)
        for url in plan.urls {
            if Task.isCancelled { return nil }
            guard let data = await fetch(url, token: plan.token, redirects: redirects) else { continue }
            // A thumbnail the server couldn't make comes back as the original; one that isn't a picture at all
            // falls through to the next URL.
            if let image = ThumbnailDownsampler.downsample(data: data, maxPixel: maxPixel) { return image }
        }
        return nil
    }

    private func plan(for target: String) -> (urls: [URL], token: String, origin: MemosOrigin)? {
        let settings = configuration()
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let base = Self.baseURL(from: settings), let origin = MemosOrigin(url: base) else {
            return nil
        }

        let resolved: URL?
        if NoteAttachments.isAbsoluteURL(target) {
            resolved = URL(string: target)
        } else if NoteAttachments.isMemosRelative(target) {
            resolved = URL(string: base.absoluteString + target)
        } else {
            resolved = nil
        }
        guard let url = resolved, MemosOrigin(url: url) == origin else { return nil }

        guard url.path.contains("/file/attachments/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ([url], token, origin)
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "thumbnail" }) {
            items.append(URLQueryItem(name: "thumbnail", value: "true"))
        }
        components.queryItems = items
        guard let thumbnail = components.url else { return ([url], token, origin) }
        return ([thumbnail, url], token, origin)
    }

    /// The same rules `MemosClient` applies to the endpoint: trimmed, no trailing slashes, http(s) only, and
    /// plain http only when Settings allows it.
    private static func baseURL(from settings: Configuration) -> URL? {
        let trimmed = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "https" || (scheme == "http" && settings.allowInsecureHTTP) else { return nil }
        return url
    }

    /// One GET, streamed so a body over `maxBytes` is abandoned as soon as it crosses the line.
    private func fetch(_ url: URL, token: String, redirects: URLSessionTaskDelegate) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            if http.expectedContentLength > Int64(maxBytes) { return nil }

            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            return data
        } catch {
            return nil
        }
    }
}

/// Follows a redirect only while it stays on the Memos origin, carrying the token along. A redirect anywhere else
/// is not followed — the 3xx answer is the result — so the token cannot be handed on to another host.
private final class OriginPinnedRedirects: NSObject, URLSessionTaskDelegate {
    private let origin: MemosOrigin
    private let token: String

    init(origin: MemosOrigin, token: String) {
        self.origin = origin
        self.token = token
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, MemosOrigin(url: url) == origin else {
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }
}
