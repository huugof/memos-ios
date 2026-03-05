import Foundation

enum MemosError: LocalizedError {
    case notConfigured
    case badURL
    case insecureHTTPNotAllowed
    case networkFailure(String)
    case badResponse(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Configure endpoint URL and API token first."
        case .badURL:
            return "Endpoint URL is invalid."
        case .insecureHTTPNotAllowed:
            return "HTTP endpoints are disabled. Enable Allow insecure HTTP in Settings."
        case .networkFailure(let detail):
            return "Network error: \(detail)"
        case .badResponse(let status, let body):
            if let body, !body.isEmpty {
                return "Server error (\(status)): \(body)"
            }
            return "Server error (\(status))."
        }
    }
}

struct ServerMemoSummary: Identifiable, Equatable {
    let id: String
    let resourceName: String?
    let content: String
    let updatedAt: Date?

    var isEditable: Bool {
        resourceName != nil
    }

    var title: String {
        let firstLine = content
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        return firstLine.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
    }

    var preview: String {
        let condensed = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condensed.isEmpty else { return "" }
        return String(condensed.prefix(140))
    }
}

struct ServerMemoPage: Equatable {
    let memos: [ServerMemoSummary]
    let nextPageToken: String?
}

struct MemosClient {
    var session: URLSession = .shared

    func createMemo(content: String, baseURLString: String, token: String, allowInsecureHTTP: Bool) async throws {
        let (baseURL, trimmedToken) = try validatedBaseURLAndToken(
            baseURLString: baseURLString,
            token: token,
            allowInsecureHTTP: allowInsecureHTTP
        )
        let endpoint = baseURL.appendingPathComponent("api/v1/memos")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content], options: [])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MemosError.badURL
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw MemosError.badResponse(http.statusCode, body)
            }
        } catch let error as MemosError {
            throw error
        } catch {
            throw MemosError.networkFailure(error.localizedDescription)
        }
    }

    func fetchTags(baseURLString: String, token: String, allowInsecureHTTP: Bool) async throws -> [String] {
        let (baseURL, trimmedToken) = try validatedBaseURLAndToken(
            baseURLString: baseURLString,
            token: token,
            allowInsecureHTTP: allowInsecureHTTP
        )

        var endpoints: [URL] = [
            baseURL.appendingPathComponent("api/v1/tags"),
            baseURL.appendingPathComponent("api/v1/memos/-/tags")
        ]
        if var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/memos"), resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "pageSize", value: "200")]
            if let memosURL = components.url {
                endpoints.append(memosURL)
            }
        }

        var collectedTags: Set<String> = []
        var didReceiveSuccess = false

        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else { continue }
                didReceiveSuccess = true
                collectedTags.formUnion(Self.extractTags(from: data))
            } catch {
                continue
            }
        }

        guard didReceiveSuccess else {
            throw MemosError.networkFailure("Unable to fetch tags from the server.")
        }

        return collectedTags.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    func fetchMemos(
        baseURLString: String,
        token: String,
        allowInsecureHTTP: Bool,
        pageSize: Int = 100
    ) async throws -> [ServerMemoSummary] {
        let page = try await fetchMemosPage(
            baseURLString: baseURLString,
            token: token,
            allowInsecureHTTP: allowInsecureHTTP,
            pageSize: pageSize,
            pageToken: nil
        )
        return page.memos
    }

    func fetchMemosPage(
        baseURLString: String,
        token: String,
        allowInsecureHTTP: Bool,
        pageSize: Int = 30,
        pageToken: String?
    ) async throws -> ServerMemoPage {
        let (baseURL, trimmedToken) = try validatedBaseURLAndToken(
            baseURLString: baseURLString,
            token: token,
            allowInsecureHTTP: allowInsecureHTTP
        )

        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/memos"), resolvingAgainstBaseURL: false) else {
            throw MemosError.badURL
        }
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "pageSize", value: String(max(1, pageSize)))]
        if let pageToken, !pageToken.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems
        guard let endpoint = components.url else {
            throw MemosError.badURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MemosError.badURL
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw MemosError.badResponse(http.statusCode, body)
            }

            return Self.extractMemosPage(from: data)
        } catch let error as MemosError {
            throw error
        } catch {
            throw MemosError.networkFailure(error.localizedDescription)
        }
    }

    func updateMemoContent(
        resourceName: String,
        content: String,
        baseURLString: String,
        token: String,
        allowInsecureHTTP: Bool
    ) async throws -> ServerMemoSummary {
        let (baseURL, trimmedToken) = try validatedBaseURLAndToken(
            baseURLString: baseURLString,
            token: token,
            allowInsecureHTTP: allowInsecureHTTP
        )

        let normalizedResourceName = Self.normalizedResourceName(from: resourceName)
        var endpoint = baseURL.appendingPathComponent("api/v1")
        for segment in normalizedResourceName.split(separator: "/") {
            endpoint.appendPathComponent(String(segment))
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MemosError.badURL
        }
        components.queryItems = [URLQueryItem(name: "updateMask", value: "content")]
        guard let finalURL = components.url else {
            throw MemosError.badURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 15
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content], options: [])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MemosError.badURL
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw MemosError.badResponse(http.statusCode, body)
            }

            if let memo = Self.extractMemoSummary(from: data, fallbackIndex: 0) {
                return memo
            }

            return ServerMemoSummary(
                id: normalizedResourceName,
                resourceName: normalizedResourceName,
                content: content,
                updatedAt: Date()
            )
        } catch let error as MemosError {
            throw error
        } catch {
            throw MemosError.networkFailure(error.localizedDescription)
        }
    }

    private func validatedBaseURLAndToken(
        baseURLString: String,
        token: String,
        allowInsecureHTTP: Bool
    ) throws -> (URL, String) {
        let trimmedBase = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !trimmedToken.isEmpty else {
            throw MemosError.notConfigured
        }

        let normalizedBase = trimmedBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let baseURL = URL(string: normalizedBase),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MemosError.badURL
        }

        guard let scheme = components.scheme?.lowercased() else {
            throw MemosError.badURL
        }

        if scheme == "http" && !allowInsecureHTTP {
            throw MemosError.insecureHTTPNotAllowed
        }

        if scheme != "https" && scheme != "http" {
            throw MemosError.badURL
        }

        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let cleanedURL = components.url else {
            throw MemosError.badURL
        }

        return (cleanedURL, trimmedToken)
    }

    private static func extractTags(from data: Data) -> Set<String> {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let directTagList = payload as? [String] {
            return Set(directTagList.compactMap { normalizedTag(from: $0) })
        }

        var tags: Set<String> = []
        collectTags(from: payload, into: &tags)
        return tags
    }

    private static func extractMemosPage(from data: Data) -> ServerMemoPage {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else {
            return ServerMemoPage(memos: [], nextPageToken: nil)
        }

        let memoObjects: [[String: Any]]
        let nextPageToken: String?
        if let dict = payload as? [String: Any] {
            if let memos = dict["memos"] as? [[String: Any]] {
                memoObjects = memos
            } else if let memos = dict["data"] as? [[String: Any]] {
                memoObjects = memos
            } else {
                memoObjects = []
            }
            nextPageToken = (dict["nextPageToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let array = payload as? [[String: Any]] {
            memoObjects = array
            nextPageToken = nil
        } else {
            memoObjects = []
            nextPageToken = nil
        }

        var summaries: [ServerMemoSummary] = []
        summaries.reserveCapacity(memoObjects.count)

        for (index, memo) in memoObjects.enumerated() {
            guard let summary = extractMemoSummary(from: memo, fallbackIndex: index) else {
                continue
            }
            summaries.append(summary)
        }

        let sorted = summaries.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (l?, r?):
                if l != r { return l > r }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.id < rhs.id
        }
        let token = nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        return ServerMemoPage(memos: sorted, nextPageToken: token)
    }

    private static func memoContent(from memo: [String: Any]) -> String {
        if let content = memo["content"] as? String {
            return content
        }
        if let content = memo["memo"] as? String {
            return content
        }
        return ""
    }

    private static func extractMemoSummary(from data: Data, fallbackIndex: Int) -> ServerMemoSummary? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        guard let memo = unwrapMemoObject(from: payload) else {
            return nil
        }

        return extractMemoSummary(from: memo, fallbackIndex: fallbackIndex)
    }

    private static func extractMemoSummary(from memo: [String: Any], fallbackIndex: Int) -> ServerMemoSummary? {
        let content = memoContent(from: memo)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let identifier = memoIdentifiers(from: memo, fallbackIndex: fallbackIndex)
        let updatedAt = memoUpdatedAt(from: memo)
        return ServerMemoSummary(
            id: identifier.id,
            resourceName: identifier.resourceName,
            content: content,
            updatedAt: updatedAt
        )
    }

    private static func unwrapMemoObject(from payload: Any) -> [String: Any]? {
        if let memo = payload as? [String: Any] {
            if let nested = memo["memo"] as? [String: Any] {
                return nested
            }
            if let nested = memo["data"] as? [String: Any] {
                return nested
            }
            return memo
        }
        return nil
    }

    private static func memoIdentifiers(from memo: [String: Any], fallbackIndex: Int) -> (id: String, resourceName: String?) {
        if let name = memo["name"] as? String, !name.isEmpty {
            let resourceName = normalizedResourceName(from: name)
            return (resourceName, resourceName)
        }

        if let uid = memo["uid"] as? String, !uid.isEmpty {
            let resourceName = normalizedResourceName(from: uid)
            return (resourceName, resourceName)
        }

        if let id = memo["id"] as? String, !id.isEmpty {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let resourceName = normalizedResourceName(from: trimmed)
                return (resourceName, resourceName)
            }
        }

        if let idInt = memo["id"] as? Int {
            let resourceName = normalizedResourceName(from: String(idInt))
            return (resourceName, resourceName)
        }

        let fallback = "memo-\(fallbackIndex)"
        return (fallback, nil)
    }

    private static func normalizedResourceName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "memos/unknown"
        }
        if trimmed.hasPrefix("memos/") {
            return trimmed
        }
        return "memos/\(trimmed)"
    }

    private static func memoUpdatedAt(from memo: [String: Any]) -> Date? {
        let candidates: [Any?] = [
            memo["updateTime"],
            memo["updatedAt"],
            memo["displayTime"],
            memo["createTime"],
            memo["createdAt"],
            memo["updatedTs"],
            memo["createdTs"]
        ]

        for value in candidates {
            if let date = decodeDate(value) {
                return date
            }
        }

        return nil
    }

    private static func decodeDate(_ raw: Any?) -> Date? {
        guard let raw else { return nil }

        if let date = raw as? Date {
            return date
        }

        if let numeric = raw as? NSNumber {
            return decodeUnixTimestamp(numeric.doubleValue)
        }

        if let intValue = raw as? Int {
            return decodeUnixTimestamp(Double(intValue))
        }

        if let doubleValue = raw as? Double {
            return decodeUnixTimestamp(doubleValue)
        }

        if let stringValue = raw as? String {
            if let iso = isoDateWithFractionalSeconds.date(from: stringValue) {
                return iso
            }
            if let iso = isoDate.date(from: stringValue) {
                return iso
            }
            if let numeric = Double(stringValue) {
                return decodeUnixTimestamp(numeric)
            }
        }

        return nil
    }

    private static func decodeUnixTimestamp(_ value: Double) -> Date? {
        guard value.isFinite else { return nil }
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        if value > 0 {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }

    private static let isoDateWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func collectTags(from value: Any, into tags: inout Set<String>) {
        switch value {
        case let array as [Any]:
            array.forEach { collectTags(from: $0, into: &tags) }
        case let dictionary as [String: Any]:
            for (key, nestedValue) in dictionary {
                if key.lowercased().contains("tag") {
                    if let tagString = nestedValue as? String,
                       let normalized = normalizedTag(from: tagString) {
                        tags.insert(normalized)
                    }
                    if let tagArray = nestedValue as? [String] {
                        for tagString in tagArray {
                            if let normalized = normalizedTag(from: tagString) {
                                tags.insert(normalized)
                            }
                        }
                    }
                }
                collectTags(from: nestedValue, into: &tags)
            }
        case let stringValue as String:
            for tag in hashtags(in: stringValue) {
                tags.insert(tag)
            }
        default:
            break
        }
    }

    private static func hashtags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "#([A-Za-z0-9_-]+)") else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[swiftRange])
        }
    }

    private static func normalizedTag(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("tags/") {
            value.removeFirst("tags/".count)
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard !value.isEmpty else { return nil }
        guard !value.contains(where: { $0.isWhitespace }) else { return nil }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return value
    }
}
